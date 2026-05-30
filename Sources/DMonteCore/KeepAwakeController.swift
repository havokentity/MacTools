import Foundation
import IOKit
import IOKit.pwr_mgt

public extension DefaultsKey {
    /// Whether Keep Awake should also prevent the display from sleeping. The integrator should
    /// register a default of `false` for this key in `AppDefaults.registerDefaults()`.
    static let keepAwakeKeepDisplayOn = "tool.keepAwake.keepDisplayOn"

    /// Stores the last-used duration (in seconds) chosen by the user; `0` means indefinitely.
    static let keepAwakeLastDuration = "tool.keepAwake.lastDuration"
}

/// Owns the power-management assertion that keeps the Mac awake, plus the optional countdown
/// timer for timed sessions. UI observes the `@Published` state; all mutation happens on the
/// main actor so the assertion ID and timer are never touched concurrently.
@MainActor
public final class KeepAwakeController: ObservableObject {
    /// `true` while a sleep-prevention assertion is held.
    @Published public private(set) var isActive = false

    /// When `true`, the assertion also prevents the *display* from sleeping (not just idle system
    /// sleep). Persisted so it survives relaunches. Changing it while active re-creates the
    /// assertion with the new type.
    @Published public private(set) var keepDisplayOn: Bool

    /// Seconds left in a timed session, or `nil` for an indefinite session / when inactive.
    @Published public private(set) var remaining: TimeInterval?

    private var assertionID: IOPMAssertionID = IOPMAssertionID(0)
    private var hasAssertion = false

    private var countdownTimer: Timer?
    private var sessionEnd: Date?

    private let assertionReason = "DMonte Keep Awake" as CFString

    public init() {
        keepDisplayOn = AppDefaults.shared.bool(forKey: DefaultsKey.keepAwakeKeepDisplayOn)
    }

    deinit {
        // `deinit` is nonisolated; release the raw assertion directly so we never leak it.
        if hasAssertion {
            IOPMAssertionRelease(assertionID)
        }
    }

    // MARK: - Public API

    /// Starts (or restarts) keeping the Mac awake.
    /// - Parameter duration: number of seconds to stay awake, or `nil` for indefinitely. A
    ///   non-positive duration is treated as indefinite.
    public func activate(duration: TimeInterval?) {
        createAssertionIfNeeded()
        isActive = true

        if let duration, duration > 0 {
            startCountdown(duration: duration)
        } else {
            stopCountdown()
        }
    }

    /// Releases the assertion and stops any countdown. Safe to call when already inactive.
    public func deactivate() {
        releaseAssertion()
        stopCountdown()
        isActive = false
    }

    /// Toggles between active (indefinite) and inactive.
    public func toggle() {
        if isActive {
            deactivate()
        } else {
            activate(duration: nil)
        }
    }

    /// Updates the "keep display on" preference. If a session is in progress, the live assertion is
    /// re-created with the new behaviour while preserving any remaining countdown.
    public func setKeepDisplayOn(_ newValue: Bool) {
        guard newValue != keepDisplayOn else { return }
        keepDisplayOn = newValue
        AppDefaults.shared.set(newValue, forKey: DefaultsKey.keepAwakeKeepDisplayOn)

        guard hasAssertion else { return }
        // Recreate with the new assertion type so the change takes effect immediately.
        releaseAssertion()
        createAssertionIfNeeded()
    }

    // MARK: - Assertion management

    private var assertionType: String {
        keepDisplayOn
            ? kIOPMAssertionTypePreventUserIdleDisplaySleep
            : kIOPMAssertionTypePreventUserIdleSystemSleep
    }

    private func createAssertionIfNeeded() {
        guard !hasAssertion else { return }

        var newID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            assertionType as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            assertionReason,
            &newID
        )

        if result == kIOReturnSuccess {
            assertionID = newID
            hasAssertion = true
        }
    }

    private func releaseAssertion() {
        guard hasAssertion else { return }
        IOPMAssertionRelease(assertionID)
        hasAssertion = false
        assertionID = IOPMAssertionID(0)
    }

    // MARK: - Countdown

    private func startCountdown(duration: TimeInterval) {
        stopCountdown()

        let end = Date().addingTimeInterval(duration)
        sessionEnd = end
        remaining = duration

        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tickCountdown()
            }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    private func stopCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        sessionEnd = nil
        remaining = nil
    }

    private func tickCountdown() {
        guard let end = sessionEnd else {
            stopCountdown()
            return
        }

        let left = end.timeIntervalSinceNow
        if left <= 0 {
            // Session elapsed: tear everything down.
            deactivate()
        } else {
            remaining = left
        }
    }
}
