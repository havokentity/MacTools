import AppKit
import Foundation

public extension DefaultsKey {
    /// Whether Eject All asks for a second press before acting. Ejecting every external disk at
    /// once is the one action here that is both irreversible-in-the-moment and easy to hit by
    /// accident, so the integrator registers a default of `true` for this key.
    static let driveEjectorConfirmsEjectAll = "tool.driveEjector.confirmsEjectAll"
}

/// One volume queued for ejection, flattened out of the `@MainActor` model so the work can hop
/// to a background task without carrying main-actor state across the boundary.
private struct EjectRequest: Sendable {
    let id: String
    let name: String
    let url: URL
}

/// Owns the list of ejectable volumes and the ejection attempts against them.
///
/// It is an `NSObject` because it observes `NSWorkspace`'s mount notifications by selector, the
/// same pattern `ActivationTracker` uses: workspace notifications are posted on the main thread,
/// so a `@MainActor` selector target receives them already on the right actor.
///
/// The controller never decides what is safe to eject — `DriveEjectorKit` does, both when
/// building the list and again inside every `eject` call.
@MainActor
public final class DriveEjectorController: NSObject, ObservableObject {
    /// The volumes currently offered. Only ever assigned from `DriveEjectorKit.ejectableVolumes()`.
    @Published public private(set) var volumes: [VolumeDescriptor] = []

    /// The inline status line: progress while ejecting, then the honest result.
    @Published public private(set) var statusMessage: String?

    /// Mount points with an eject in flight, so their rows can show progress and refuse a
    /// second press instead of racing a duplicate unmount.
    @Published public private(set) var busyVolumeIDs: Set<String> = []

    /// `true` once Eject All has been requested and is waiting for the confirming press.
    @Published public private(set) var isConfirmingEjectAll = false

    /// Persisted preference: require a second press for Eject All.
    @Published public private(set) var confirmsEjectAll: Bool

    public override init() {
        confirmsEjectAll = AppDefaults.shared.bool(forKey: DefaultsKey.driveEjectorConfirmsEjectAll)
        super.init()
        refresh()
    }

    // No `deinit` cleanup: a nonisolated `deinit` may not touch the main actor under Swift 6, and
    // removing a selector-based workspace observer requires it. The app delegate calls
    // `stopObserving()` on termination instead.

    // MARK: - Public API

    /// Re-reads the mount table. Cheap enough to call on every mount notification.
    public func refresh() {
        volumes = DriveEjectorKit.ejectableVolumes()

        // Drop busy markers for volumes that are gone; otherwise a successful eject would leave
        // a phantom entry that suppresses a later eject of a disk remounted at the same point.
        let liveIDs = Set(volumes.map(\.id))
        busyVolumeIDs.formIntersection(liveIDs)

        if volumes.isEmpty {
            isConfirmingEjectAll = false
        }
    }

    /// Begins observing mount/unmount activity so the list stays truthful without polling.
    public func startObserving() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(volumeWillUnmount(_:)),
            name: NSWorkspace.willUnmountNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(volumeDidUnmount(_:)),
            name: NSWorkspace.didUnmountNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(volumeDidMount(_:)),
            name: NSWorkspace.didMountNotification,
            object: nil
        )
    }

    /// Stops observing workspace mount activity (for app-termination cleanup).
    public func stopObserving() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    /// Ejects one volume. The verdict is re-derived from fresh resource values inside
    /// `DriveEjectorKit.eject(volumeAt:)`, so a stale row cannot authorise anything.
    public func eject(_ volume: VolumeDescriptor) {
        guard !busyVolumeIDs.contains(volume.id) else {
            return
        }

        busyVolumeIDs.insert(volume.id)
        statusMessage = "Ejecting “\(volume.name)”…"

        let request = EjectRequest(id: volume.id, name: volume.name, url: volume.url)
        Task.detached(priority: .userInitiated) {
            let outcome = DriveEjectorKit.eject(volumeAt: request.url)
            await MainActor.run { [weak self] in
                self?.finish(request, outcome: outcome)
            }
        }
    }

    /// Asks to eject every listed volume. With confirmation enabled the first call only arms the
    /// action; the second (`confirmEjectAll()`) performs it.
    public func requestEjectAll() {
        guard !volumes.isEmpty else {
            return
        }

        if confirmsEjectAll, !isConfirmingEjectAll {
            isConfirmingEjectAll = true
            return
        }

        confirmEjectAll()
    }

    /// Performs the batch eject. Every volume goes through the same per-volume safety re-check as
    /// a single eject — “all” describes the selection, never a relaxation of the rule.
    public func confirmEjectAll() {
        isConfirmingEjectAll = false

        let targets = volumes
            .filter { !busyVolumeIDs.contains($0.id) }
            .map { EjectRequest(id: $0.id, name: $0.name, url: $0.url) }
        guard !targets.isEmpty else {
            return
        }

        targets.forEach { busyVolumeIDs.insert($0.id) }
        statusMessage = "Ejecting \(targets.count) volume\(targets.count == 1 ? "" : "s")…"

        Task.detached(priority: .userInitiated) {
            // Sequential on purpose: run in parallel, macOS stacks up its own “disk in use”
            // panels and the user cannot tell which volume each one belongs to.
            var results: [(EjectRequest, EjectionOutcome)] = []
            for target in targets {
                results.append((target, DriveEjectorKit.eject(volumeAt: target.url)))
            }

            await MainActor.run { [weak self] in
                self?.finishBatch(results)
            }
        }
    }

    /// Abandons an armed Eject All.
    public func cancelEjectAll() {
        isConfirmingEjectAll = false
    }

    /// Updates the Eject All confirmation preference, disarming any request already in flight so
    /// the pending state cannot outlive the setting that created it.
    public func setConfirmsEjectAll(_ newValue: Bool) {
        guard newValue != confirmsEjectAll else {
            return
        }

        confirmsEjectAll = newValue
        AppDefaults.shared.set(newValue, forKey: DefaultsKey.driveEjectorConfirmsEjectAll)
        isConfirmingEjectAll = false
    }

    /// Clears the status line, e.g. when the popover is reopened.
    public func clearStatus() {
        statusMessage = nil
    }

    // MARK: - Workspace notifications

    /// A volume is about to go away — mark it busy so its row reads as in-progress rather than
    /// inviting a press that would race the unmount already under way (which may be Finder's).
    @objc private func volumeWillUnmount(_ notification: Notification) {
        guard let url = notification.volumeURL else {
            return
        }
        busyVolumeIDs.insert(url.path)
    }

    @objc private func volumeDidUnmount(_ notification: Notification) {
        refresh()
    }

    @objc private func volumeDidMount(_ notification: Notification) {
        refresh()
    }

    // MARK: - Private

    private func finish(_ request: EjectRequest, outcome: EjectionOutcome) {
        busyVolumeIDs.remove(request.id)
        statusMessage = message(for: outcome, volumeName: request.name)
        refresh()
    }

    private func finishBatch(_ results: [(EjectRequest, EjectionOutcome)]) {
        results.forEach { busyVolumeIDs.remove($0.0.id) }

        let failures = results.filter { $0.1 != .ejected }

        if failures.isEmpty {
            let count = results.count
            statusMessage = "Ejected \(count) volume\(count == 1 ? "" : "s")"
        } else if let (request, outcome) = failures.first, failures.count == 1 {
            // One holdout: name it and say exactly why, which is far more actionable than a tally.
            statusMessage = message(for: outcome, volumeName: request.name)
        } else {
            let ejected = results.count - failures.count
            let names = failures.map { "“\($0.0.name)”" }.joined(separator: ", ")
            statusMessage = "Ejected \(ejected) of \(results.count) — \(names) still mounted"
        }

        refresh()
    }

    private func message(for outcome: EjectionOutcome, volumeName: String) -> String {
        switch outcome {
        case .ejected:
            "Ejected “\(volumeName)”"
        case .blocked(let verdict):
            // A blocked eject is a safety refusal, not a failure of the disk — word it as such.
            "Didn’t eject “\(volumeName)” — \(verdict.blockedReason ?? "it’s no longer eligible")"
        case .failed(let reason):
            "Couldn’t eject “\(volumeName)” — \(reason)"
        }
    }
}

private extension Notification {
    /// The mount point carried by an `NSWorkspace` mount/unmount notification.
    var volumeURL: URL? {
        userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
    }
}
