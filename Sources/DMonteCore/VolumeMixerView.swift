import AppKit
import CoreAudio
import SwiftUI

private enum VolumeMixerTab: String, CaseIterable, Identifiable {
    case apps = "Apps"
    case ignored = "Ignored"

    var id: String { rawValue }
}

private let volumeMixerDefaultsSuiteName = "com.havokentity.mactools.shared"

private struct VolumeMixerSnapshot: Sendable {
    let engineState: AppVolumeMixerEngineState
    let masterVolumeState: AppVolumeMasterVolumeState
    /// The rows to show — already ignore-filtered, so display-only.
    let targets: [AppVolumeTarget]
    /// Every discovered target *before* ignore filtering. Engine reaping and
    /// auto-processing reconciliation both run over this: a hidden row must not
    /// read as "the process is gone" (that would drop attenuation and unmute the
    /// tap), and a hidden-but-active app's kept-alive engine still has to be
    /// re-resolved on default-output / plug-unplug changes.
    let allTargets: [AppVolumeTarget]
    /// Every active target's id *before* ignore filtering, so engine reaping can
    /// tell "this process is gone" from "this row is merely hidden".
    let activeTargetIDs: Set<String>
    let ignoredApps: [AppVolumeIgnoredAppInfo]
    let outputDevices: [AppVolumeOutputDevice]
    let outputRouteUIDsByTargetID: [String: [String]]
    let localIgnoredAppCount: Int
    let defaultIgnoredOverrideCount: Int
}

@MainActor
public final class AppVolumeMixerController: ObservableObject {
    @Published public private(set) var targets: [AppVolumeTarget] = []
    @Published public private(set) var engineState: AppVolumeMixerEngineState = .unsupportedOS
    @Published public private(set) var masterVolumeState = AppVolumeMasterVolumeState()
    @Published public private(set) var sessionState = AppVolumeMixerSessionState()
    @Published public private(set) var expandedTargetIDs: Set<String> = []
    @Published public private(set) var ignoredApps: [AppVolumeIgnoredAppInfo] = []
    @Published public private(set) var outputDevices: [AppVolumeOutputDevice] = []
    @Published public private(set) var outputRouteUIDsByTargetID: [String: [String]] = [:]
    @Published public private(set) var localIgnoredAppCount = 0
    @Published public private(set) var defaultIgnoredOverrideCount = 0
    @Published public private(set) var smartPinCandidateCount = 0
    @Published public private(set) var hideIgnoredApps: Bool
    @Published public private(set) var smartFilter: Bool

    private var audioEngines: [String: AppVolumeMixerAudioEngine] = [:]
    /// Pre-mute gain stash per stableKey so unmuting restores the user's
    /// level instead of jumping to 100%. Session-scoped by design (not
    /// persisted); absent or ~silent entries fall back to full volume.
    private var preMuteGains: [String: Float] = [:]
    /// Per-target manual processing override, keyed by stableKey:
    /// `true`  = user pressed play — force processing on, even at unity gain;
    /// `false` = user pressed stop — never auto-restart.
    /// Absent  = automatic policy (see `shouldRunProcessing`).
    /// A force-off is cleared when the user adjusts that target's gain — the
    /// natural "re-engage" gesture. Session-scoped by design.
    private var manualProcessingOverrides: [String: Bool] = [:]
    private var refreshTask: Task<Void, Never>?
    private var refreshWorkTask: Task<Void, Never>?
    private var refreshRequestID = 0
    private var pendingGainPersistence: [String: Float] = [:]
    private var gainPersistenceTask: Task<Void, Never>?

    public init() {
        let defaults = AppDefaults.shared
        self.hideIgnoredApps = (defaults.object(forKey: DefaultsKey.volumeMixerHideIgnoredApps) as? Bool) ?? true
        self.smartFilter = (defaults.object(forKey: DefaultsKey.volumeMixerSmartFilter) as? Bool) ?? true
        refresh()
        startAutoRefresh()
        // The debounced gain write has to survive quit, and the `deinit` flush
        // below cannot carry it: the delegate holds this controller for the life
        // of the process and `NSApp.terminate` exits without unwinding it, so
        // deinit never runs in the shipping app.
        //
        // Selector-based rather than block-based because the delivery has to be
        // *synchronous on the posting thread* — nothing drains the main queue
        // after `willTerminate`, so an enqueued write would be dropped exactly
        // when it matters, silently. Selector observers are always called
        // synchronously, and unlike a block observer the registration can be
        // undone in `deinit` without keeping a token alive.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleApplicationWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }

    /// `nonisolated` so the hop is explicit: AppKit always posts this on the
    /// main thread, which `assumeIsolated` asserts rather than assumes.
    @objc
    private nonisolated func handleApplicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            flushPendingGainPersistence()
        }
    }

    deinit {
        refreshTask?.cancel()
        refreshWorkTask?.cancel()
        gainPersistenceTask?.cancel()
        let pendingGains = pendingGainPersistence
        if !pendingGains.isEmpty {
            let defaults = UserDefaults(suiteName: volumeMixerDefaultsSuiteName) ?? .standard
            AppVolumeMixerKit.setGains(pendingGains, defaults: defaults)
        }
        for engine in audioEngines.values {
            engine.stop()
        }
        // Last: passing `self` out of a deinit bars every later property read.
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }

    public func refresh() {
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        refreshRequestID += 1
        let requestID = refreshRequestID
        let hideIgnoredApps = hideIgnoredApps
        let smartFilter = smartFilter
        engineState = AppVolumeMixerKit.engineState()
        refreshWorkTask?.cancel()
        refreshWorkTask = Task.detached(priority: .utility) { [hideIgnoredApps, smartFilter, requestID] in
            let defaults = UserDefaults(suiteName: volumeMixerDefaultsSuiteName) ?? .standard
            // Discover unfiltered and apply the ignore filter here: the reap set
            // has to see every live target, not just the displayed ones.
            let discoveredTargets = AppVolumeMixerKit.targets(
                defaults: defaults,
                hideIgnoredApps: false,
                smartFilter: smartFilter
            )
            let snapshot = VolumeMixerSnapshot(
                engineState: AppVolumeMixerKit.engineState(),
                masterVolumeState: AppVolumeMixerKit.masterVolumeState(),
                targets: hideIgnoredApps ? discoveredTargets.filter { !$0.isIgnored } : discoveredTargets,
                allTargets: discoveredTargets,
                activeTargetIDs: Set(discoveredTargets.filter(\.isActive).map(\.id)),
                ignoredApps: AppVolumeMixerKit.ignoredApps(defaults: defaults, smartFilter: smartFilter),
                outputDevices: AppVolumeMixerKit.outputDevices(),
                outputRouteUIDsByTargetID: AppVolumeMixerKit.persistedOutputRoutes(defaults: defaults),
                localIgnoredAppCount: AppVolumeMixerKit.persistedIgnoredApps(defaults: defaults).count,
                defaultIgnoredOverrideCount: AppVolumeMixerKit.persistedIncludedDefaultIgnoredAppIDs(defaults: defaults).count
            )
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.applyRefreshSnapshot(snapshot, requestID: requestID)
            }
        }
    }

    private func applyRefreshSnapshot(_ snapshot: VolumeMixerSnapshot, requestID: Int) {
        guard requestID == refreshRequestID else { return }
        refreshWorkTask = nil
        engineState = snapshot.engineState
        masterVolumeState = snapshot.masterVolumeState
        let refreshedTargets = applyingPendingGains(snapshot.targets)
        let refreshedAllTargets = applyingPendingGains(snapshot.allTargets)
        ignoredApps = snapshot.ignoredApps
        outputDevices = snapshot.outputDevices
        outputRouteUIDsByTargetID = snapshot.outputRouteUIDsByTargetID
        localIgnoredAppCount = snapshot.localIgnoredAppCount
        defaultIgnoredOverrideCount = snapshot.defaultIgnoredOverrideCount
        // KNOWN STRUCTURAL LIMIT: when a process disappears from the active
        // target list entirely (its audio session fully torn down — distinct
        // from a mere output pause, which keeps the target active and is
        // handled by `shouldRunProcessing`), its engine must be reaped here:
        // the tapped process objects no longer exist. If such an app later
        // resumes audio it plays unprocessed at full volume for up to one
        // ~2s poll cycle until rediscovery restarts the engine. Do not "fix"
        // this by keeping the engine — there is nothing left to tap.
        // The ids come from the snapshot's unfiltered active set, never from
        // the displayed `targets`: the ignore filters only hide rows, and a
        // hidden row must not read as "the process is gone" — that would drop
        // the app's attenuation and unmute its tap behind the user's back.
        let staleEngineIDs = audioEngines.keys.filter { !snapshot.activeTargetIDs.contains($0) }
        for id in staleEngineIDs {
            audioEngines[id]?.stop()
            audioEngines.removeValue(forKey: id)
        }
        targets = refreshedTargets
        smartPinCandidateCount = refreshedTargets.filter { !$0.isPinned && AppVolumeMixerKit.isSmartPinCandidate($0) }.count
        // Reconcile over the unfiltered set, for the same reason the reap above
        // does: a hidden-but-active app keeps its engine, and that engine still
        // has to be re-resolved here on default-output / plug-unplug changes.
        reconcileAutoProcessing(over: refreshedAllTargets)
        sessionState = AppVolumeMixerSessionState(
            activeTargetIDs: Set(audioEngines.keys),
            errorMessage: sessionState.errorMessage
        )
    }

    public func setHideIgnoredApps(_ value: Bool) {
        hideIgnoredApps = value
        AppDefaults.shared.set(value, forKey: DefaultsKey.volumeMixerHideIgnoredApps)
        refresh()
    }

    public func setSmartFilter(_ value: Bool) {
        smartFilter = value
        AppDefaults.shared.set(value, forKey: DefaultsKey.volumeMixerSmartFilter)
        refresh()
    }

    public func setMasterVolume(_ volume: Float) {
        guard let deviceID = masterVolumeState.deviceID, masterVolumeState.volumeSupported else { return }
        let clamped = AppVolumeTarget.clampGain(volume)
        masterVolumeState = masterVolumeState.withVolume(clamped)
        guard AudioDeviceKit.setVolume(clamped, for: deviceID) else {
            refresh()
            return
        }
    }

    public func toggleMasterMute() {
        guard let deviceID = masterVolumeState.deviceID, masterVolumeState.muteSupported else { return }
        let newValue = !masterVolumeState.isMuted
        if AudioDeviceKit.setMuted(newValue, for: deviceID) {
            masterVolumeState = masterVolumeState.withMuted(newValue)
        } else {
            refresh()
        }
    }

    public func setGain(_ gain: Float, for target: AppVolumeTarget) {
        let clamped = AppVolumeTarget.clampGain(gain)
        scheduleGainPersistence(clamped, forKey: target.stableKey)
        // Adjusting the gain after a manual stop is the natural re-engage
        // gesture — the user wants attenuation again — so return the target
        // to automatic policy. A force-on is deliberately left in place: it
        // agrees with what the slider asks for and keeps processing pinned
        // even if the slider returns to unity gain.
        if manualProcessingOverrides[target.stableKey] == false {
            manualProcessingOverrides.removeValue(forKey: target.stableKey)
        }
        if let engine = audioEngines[target.id] {
            engine.setGain(clamped)
        }
        if target.isActive {
            if Self.shouldRunProcessing(
                isActive: true,
                gain: clamped,
                hasCustomRoute: !outputRouteUIDs(for: target).isEmpty,
                manualOverride: manualProcessingOverrides[target.stableKey]
            ) {
                // Pass the target carrying the new gain so a freshly started
                // engine begins at the dragged level, not the previous value.
                ensureProcessing(for: targetWithGain(target, gain: clamped), reportError: true)
            } else {
                stopProcessing(for: target.id)
            }
        }
        targets = targets.map { item in
            guard item.id == target.id else { return item }
            return targetWithGain(item, gain: clamped)
        }
        sessionState = AppVolumeMixerSessionState(
            activeTargetIDs: Set(audioEngines.keys),
            errorMessage: sessionState.errorMessage
        )
    }

    /// Per-app mute toggle. Muting stashes the current level so unmuting can
    /// restore it instead of jumping to 100%; the stash is session-scoped.
    public func toggleMute(for target: AppVolumeTarget) {
        let key = target.stableKey
        if target.gain <= 0.001 {
            setGain(Self.unmuteRestoreGain(stashed: preMuteGains.removeValue(forKey: key)), for: target)
        } else {
            preMuteGains[key] = target.gain
            setGain(0, for: target)
        }
    }

    /// Gain to restore on unmute: the stashed pre-mute level, falling back to
    /// full volume when nothing was stashed or the stash is itself ~silent
    /// (restoring ~0 would leave the unmute button doing nothing audible).
    nonisolated static func unmuteRestoreGain(stashed: Float?) -> Float {
        guard let stashed, stashed > 0.001 else { return 1 }
        return AppVolumeTarget.clampGain(stashed)
    }

    public func outputRouteUIDs(for target: AppVolumeTarget) -> [String] {
        outputRouteUIDsByTargetID[target.stableKey] ?? []
    }

    public func toggleOutputRoute(_ outputDevice: AppVolumeOutputDevice, for target: AppVolumeTarget) {
        var routeUIDs = outputRouteUIDs(for: target)
        if routeUIDs.contains(outputDevice.uid) {
            routeUIDs.removeAll { $0 == outputDevice.uid }
        } else {
            routeUIDs.append(outputDevice.uid)
        }
        setOutputRouteUIDs(routeUIDs, for: target)
    }

    public func useDefaultOutputRoute(for target: AppVolumeTarget) {
        setOutputRouteUIDs([], for: target)
    }

    private func setOutputRouteUIDs(_ outputUIDs: [String], for target: AppVolumeTarget) {
        let wasProcessing = audioEngines[target.id] != nil
        AppVolumeMixerKit.setOutputRouteUIDs(outputUIDs, for: target)
        outputRouteUIDsByTargetID[target.stableKey] = outputUIDs
        if outputUIDs.isEmpty {
            outputRouteUIDsByTargetID.removeValue(forKey: target.stableKey)
        }
        if wasProcessing {
            stopProcessing(for: target.id, keepError: true)
            ensureProcessing(for: target, reportError: true)
        }
        refresh()
    }

    public func toggleProcessing(for target: AppVolumeTarget) {
        if audioEngines[target.id] != nil {
            // Row stop button: force-off so the 2-second reconciler does not
            // undo the stop while the target is still attenuated/routed.
            manualProcessingOverrides[target.stableKey] = false
            stopProcessing(for: target.id)
            return
        }
        // Row play button: force-on so processing sticks even at unity gain.
        manualProcessingOverrides[target.stableKey] = true
        ensureProcessing(for: target, reportError: true)
    }

    public func togglePin(for target: AppVolumeTarget) {
        if target.isPinned {
            AppVolumeMixerKit.unpin(target)
        } else {
            AppVolumeMixerKit.pin(target)
        }
        refresh()
    }

    public func ignore(_ target: AppVolumeTarget) {
        AppVolumeMixerKit.ignore(target)
        refresh()
    }

    public func unignore(identifier: String) {
        AppVolumeMixerKit.unignore(identifier: identifier)
        refresh()
    }

    public func clearIgnoredApps() {
        AppVolumeMixerKit.clearIgnoredApps()
        refresh()
    }

    public func includeDefaultIgnoredApp(identifier: String) {
        AppVolumeMixerKit.includeDefaultIgnoredApp(identifier: identifier)
        refresh()
    }

    public func restoreDefaultIgnoredApp(identifier: String) {
        AppVolumeMixerKit.restoreDefaultIgnoredApp(identifier: identifier)
        refresh()
    }

    public func clearDefaultIgnoredAppOverrides() {
        AppVolumeMixerKit.clearDefaultIgnoredAppOverrides()
        refresh()
    }

    public func smartPinAudioApps() {
        for target in targets where !target.isPinned && AppVolumeMixerKit.isSmartPinCandidate(target) {
            AppVolumeMixerKit.pin(target)
        }
        refresh()
    }

    public func toggleExpanded(for target: AppVolumeTarget) {
        if expandedTargetIDs.contains(target.id) {
            expandedTargetIDs.remove(target.id)
        } else {
            expandedTargetIDs.insert(target.id)
        }
    }

    public func stopProcessing() {
        // Footer "Stop processing" button: an explicit user gesture, so mark
        // every currently-processing target force-off — otherwise the
        // 2-second reconciler would restart the attenuated ones immediately.
        // (Engine keys are target ids, which are stableKeys.)
        for id in audioEngines.keys {
            manualProcessingOverrides[id] = false
        }
        for engine in audioEngines.values {
            engine.stop()
        }
        audioEngines.removeAll()
        sessionState = AppVolumeMixerSessionState()
    }

    private func startAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    /// Pure reconcile predicate: should this target's engine be running?
    /// Centralizes the policy shared by the 2-second reconciler and
    /// `setGain(_:for:)` so manual play/stop overrides and the "keep engines
    /// for paused apps" rule cannot drift apart.
    ///
    /// Policy:
    /// - Inactive targets (no tappable audio session) never process.
    /// - A manual override always wins: a force-off target is never
    ///   auto-started and a force-on target is never auto-stopped.
    /// - Otherwise process exactly when the target is attenuated
    ///   (gain < 0.999) or custom-routed.
    /// - `isRunningOutput` is deliberately NOT an input: a tap on a process
    ///   that has merely paused output renders silence, and keeping the
    ///   engine alive while paused is what makes resume seamless (no ~2s
    ///   full-volume blast to the default device while the poll catches up).
    ///   The cost — the aggregate's IO proc idling while the app is paused —
    ///   is acceptable for attenuated/routed targets.
    nonisolated static func shouldRunProcessing(
        isActive: Bool,
        gain: Float,
        hasCustomRoute: Bool,
        manualOverride: Bool?,
        isIgnored: Bool = false
    ) -> Bool {
        // Ignoring an app moves it to the denylist tab: the mixer is being told to leave it
        // alone. That has to release the tap, not merely hide the row — an ignored app should
        // play back through the system untouched. Checked first, so it overrides even an explicit
        // play override or a custom route. The app's gain is left persisted, so un-ignoring it
        // restores the level the reconciler will then re-apply.
        //
        // This does NOT couple to the "Hide Ignored Apps" display filter: the reconciler runs over
        // the unfiltered target set, so hiding a row still changes nothing about processing.
        guard !isIgnored else { return false }
        guard isActive else { return false }
        if let manualOverride {
            return manualOverride
        }
        return gain < 0.999 || hasCustomRoute
    }

    private func applyingPendingGains(_ targets: [AppVolumeTarget]) -> [AppVolumeTarget] {
        targets.map { target in
            guard let pendingGain = pendingGainPersistence[target.stableKey] else { return target }
            return targetWithGain(target, gain: pendingGain)
        }
    }

    private func reconcileAutoProcessing(over reconcileTargets: [AppVolumeTarget]) {
        for target in reconcileTargets {
            if Self.shouldRunProcessing(
                isActive: target.isActive,
                gain: target.gain,
                hasCustomRoute: !outputRouteUIDs(for: target).isEmpty,
                manualOverride: manualProcessingOverrides[target.stableKey],
                isIgnored: target.isIgnored
            ) {
                ensureProcessing(for: target, reportError: false)
            } else if audioEngines[target.id] != nil {
                stopProcessing(for: target.id, keepError: true)
            }
        }
    }

    private func ensureProcessing(for target: AppVolumeTarget, reportError: Bool) {
        // Only `isActive` is required (not `isRunningOutput`): starting or
        // keeping an engine for a paused-but-active app just renders silence,
        // and is exactly what keeps a resume attenuated instead of blasting
        // at full volume for up to ~2s. See `shouldRunProcessing`.
        guard target.isActive else {
            if reportError {
                sessionState = AppVolumeMixerSessionState(
                    activeTargetIDs: Set(audioEngines.keys),
                    errorMessage: AppVolumeMixerError.noActiveAppAudio.message
                )
            }
            return
        }
        let routeUIDs = outputRouteUIDs(for: target)
        // Keep the engine when the requested route is unchanged AND it still
        // resolves to the devices the engine is playing through. Re-resolving
        // here is what picks up default-output switches and plug/unplug events
        // (there are no HAL property listeners; everything rides this poll) —
        // a changed resolution forces a restart within one refresh cycle.
        if let engine = audioEngines[target.id],
           engine.activeAudioObjectIDs == target.audioObjectIDs,
           engine.requestedOutputUIDs == routeUIDs,
           engine.activeOutputUIDs == AppVolumeMixerAudioEngine.resolvedOutputUIDs(forRequestedOutputUIDs: routeUIDs) {
            engine.setGain(target.gain)
            return
        }
        audioEngines[target.id]?.stop()
        let engine = AppVolumeMixerAudioEngine()
        do {
            try engine.start(
                target: target,
                gain: target.gain,
                outputUIDs: routeUIDs
            )
            audioEngines[target.id] = engine
            sessionState = AppVolumeMixerSessionState(activeTargetIDs: Set(audioEngines.keys))
        } catch let error as AppVolumeMixerError {
            audioEngines.removeValue(forKey: target.id)
            if reportError {
                sessionState = AppVolumeMixerSessionState(
                    activeTargetIDs: Set(audioEngines.keys),
                    errorMessage: error.message
                )
            }
        } catch {
            audioEngines.removeValue(forKey: target.id)
            if reportError {
                sessionState = AppVolumeMixerSessionState(
                    activeTargetIDs: Set(audioEngines.keys),
                    errorMessage: error.localizedDescription
                )
            }
        }
    }

    private func stopProcessing(for id: String, keepError: Bool = false) {
        audioEngines[id]?.stop()
        audioEngines.removeValue(forKey: id)
        sessionState = AppVolumeMixerSessionState(
            activeTargetIDs: Set(audioEngines.keys),
            errorMessage: keepError ? sessionState.errorMessage : nil
        )
    }

    private func scheduleGainPersistence(_ gain: Float, forKey key: String) {
        pendingGainPersistence[key] = gain
        gainPersistenceTask?.cancel()
        gainPersistenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.flushPendingGainPersistence()
        }
    }

    /// Writes the debounced gains through inline. Deferring to a detached task
    /// would be a second window in which a quit loses them, and the pending map
    /// is drained here, so nothing would be left to retry.
    private func flushPendingGainPersistence() {
        let updates = pendingGainPersistence
        pendingGainPersistence.removeAll()
        gainPersistenceTask = nil
        guard !updates.isEmpty else { return }
        AppVolumeMixerKit.setGains(updates, defaults: AppDefaults.shared)
    }

    private func targetWithGain(_ target: AppVolumeTarget, gain: Float) -> AppVolumeTarget {
        AppVolumeTarget(
            processID: target.processID,
            audioObjectIDs: target.audioObjectIDs,
            subprocesses: target.subprocesses,
            bundleIdentifier: target.bundleIdentifier,
            displayName: target.displayName,
            isActive: target.isActive,
            isRunningOutput: target.isRunningOutput,
            isPinned: target.isPinned,
            isIgnored: target.isIgnored,
            isLocallyIgnored: target.isLocallyIgnored,
            isDefaultIgnored: target.isDefaultIgnored,
            gain: gain
        )
    }
}

public struct VolumeMixerPopoverView: View {
    @ObservedObject private var controller: AppVolumeMixerController
    @State private var hoveredExpandTargetID: String?
    @State private var hoveredMuteTargetID: String?
    @State private var hoveredMasterMute = false
    @State private var hoveredRevealIgnoredID: String?
    @State private var hoveredIncludeDefaultIgnoredID: String?
    @State private var selectedTab: VolumeMixerTab = .apps
    @State private var searchText = ""
    private let onQuit: () -> Void

    public init(controller: AppVolumeMixerController, onQuit: @escaping () -> Void) {
        self.controller = controller
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: VolumeMixerSizing.sectionSpacing) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .padding(VolumeMixerSizing.outerPadding)
        .frame(width: VolumeMixerSizing.panelWidth, height: VolumeMixerSizing.panelHeight)
        .frostedPanel(cornerRadius: 18)
    }

    private var header: some View {
        HStack {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: VolumeMixerSizing.titleSize, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text("Volume Mixer")
                .font(.system(size: VolumeMixerSizing.titleSize, weight: .semibold))
                .foregroundStyle(Color.primary)
            Spacer()
            mixerStatusBadge
            Button(action: { controller.refresh() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: VolumeMixerSizing.bodySize, weight: .medium))
                    .foregroundStyle(Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Refresh apps")
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: VolumeMixerSizing.rowSpacing) {
            Picker("", selection: $selectedTab) {
                ForEach(VolumeMixerTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            filterControls

            switch selectedTab {
            case .apps:
                appList
            case .ignored:
                ignoredList
            }
        }
    }

    private var filterControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: VolumeMixerSizing.captionSize, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                TextField("Search apps", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: VolumeMixerSizing.bodySize))
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: VolumeMixerSizing.captionSize, weight: .semibold))
                            .foregroundStyle(Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )

            HStack(spacing: 14) {
                Toggle(
                    "Smart Filter",
                    isOn: Binding(
                        get: { controller.smartFilter },
                        set: { controller.setSmartFilter($0) }
                    )
                )
                .toggleStyle(.checkbox)
                .font(.system(size: VolumeMixerSizing.captionSize))
                .help("Use the shipped ignored-app database")

                Toggle(
                    "Hide Ignored Apps",
                    isOn: Binding(
                        get: { controller.hideIgnoredApps },
                        set: { controller.setHideIgnoredApps($0) }
                    )
                )
                .toggleStyle(.checkbox)
                .font(.system(size: VolumeMixerSizing.captionSize))
                .help("Hide ignored apps from the app list")

                Spacer(minLength: 0)

                Button(action: { controller.smartPinAudioApps() }) {
                    Label("Smart Pin", systemImage: "pin.fill")
                        .font(.system(size: VolumeMixerSizing.captionSize, weight: .medium))
                }
                .buttonStyle(.borderless)
                .disabled(controller.smartPinCandidateCount == 0)
                .help(controller.smartPinCandidateCount == 0 ? "No browser or media apps to pin" : "Pin browsers and media apps")
            }
        }
    }

    private var appList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VolumeMixerSizing.rowSpacing) {
                sectionHeader("MASTER VOLUME")
                masterVolumeRow
                    .padding(.bottom, 4)
                sectionHeader("APP VOLUME")
                if let errorMessage = controller.sessionState.errorMessage {
                    errorRow(errorMessage)
                }
                if controller.targets.isEmpty {
                    emptyRow("No app audio yet")
                } else if filteredTargets.isEmpty {
                    emptyRow("No matching apps")
                } else {
                    ForEach(filteredTargets) { target in
                        appVolumeRow(target)
                    }
                }
            }
        }
        .frame(maxHeight: VolumeMixerSizing.scrollMaxHeight)
    }

    private var masterVolumeRow: some View {
        let state = controller.masterVolumeState
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(action: { controller.toggleMasterMute() }) {
                    Image(systemName: masterVolumeIconName(for: state))
                        .font(.system(size: VolumeMixerSizing.checkmarkSize, weight: .medium))
                        .foregroundStyle(state.isMuted ? Color.red : Color.accentColor)
                        .frame(width: 22, height: 22)
                        .background(masterMuteButtonBackground(isSupported: state.muteSupported))
                }
                .buttonStyle(.plain)
                .disabled(!state.muteSupported)
                .onHover { isHovering in
                    hoveredMasterMute = isHovering && state.muteSupported
                }
                .help(masterMuteHelp(for: state))

                VStack(alignment: .leading, spacing: 1) {
                    Text("Master Volume")
                        .font(.system(size: VolumeMixerSizing.bodySize, weight: .medium))
                        .foregroundStyle(state.hasOutputDevice ? Color.primary : Color.secondary)
                        .lineLimit(1)
                    Text(state.volumeSupported ? state.deviceName : masterVolumeStatusText(for: state))
                        .font(.system(size: VolumeMixerSizing.captionSize))
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Text(state.volumeSupported ? "\(Int((state.volume * 100).rounded()))%" : "--")
                    .font(.system(size: VolumeMixerSizing.captionSize).monospacedDigit())
                    .foregroundStyle(Color.secondary)
                    .frame(width: 38, alignment: .trailing)
            }

            Slider(
                value: Binding(
                    get: { state.volume },
                    set: { controller.setMasterVolume($0) }
                ),
                in: 0...1
            )
            .disabled(!state.volumeSupported)
        }
        .padding(.vertical, VolumeMixerSizing.rowVerticalPadding)
        .padding(.horizontal, VolumeMixerSizing.rowHorizontalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(isActive: false))
        .opacity(state.hasOutputDevice ? 1 : 0.72)
    }

    private var ignoredList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VolumeMixerSizing.rowSpacing) {
                ignoredListHeader
                if controller.ignoredApps.isEmpty {
                    emptyRow("No ignored apps")
                } else if filteredIgnoredApps.isEmpty {
                    emptyRow("No matching ignored apps")
                } else {
                    ForEach(filteredIgnoredApps) { ignoredApp in
                        ignoredAppRow(ignoredApp)
                    }
                }
            }
        }
        .frame(maxHeight: VolumeMixerSizing.scrollMaxHeight)
    }

    private var filteredTargets: [AppVolumeTarget] {
        let query = normalizedSearchText
        guard !query.isEmpty else { return controller.targets }
        return controller.targets.filter { targetMatchesSearch($0, query: query) }
    }

    private var filteredIgnoredApps: [AppVolumeIgnoredAppInfo] {
        let query = normalizedSearchText
        guard !query.isEmpty else { return controller.ignoredApps }
        return controller.ignoredApps.filter { ignoredAppMatchesSearch($0, query: query) }
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var mixerStatusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(mixerStatusColor)
                .frame(width: 7, height: 7)
            Text(mixerStatusText)
                .font(.system(size: VolumeMixerSizing.captionSize, weight: .medium))
                .foregroundStyle(Color.secondary)
        }
        .help(mixerStatusHelp)
    }

    private func appVolumeRow(_ target: AppVolumeTarget) -> some View {
        let isProcessing = controller.sessionState.activeTargetIDs.contains(target.id)
        let isExpanded = controller.expandedTargetIDs.contains(target.id)
        let canExpand = target.isActive && !target.subprocesses.isEmpty
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(action: { controller.toggleExpanded(for: target) }) {
                    Image(systemName: canExpand ? (isExpanded ? "chevron.down" : "chevron.right") : "chevron.right")
                        .font(.system(size: VolumeMixerSizing.captionSize, weight: .semibold))
                        .foregroundStyle(canExpand ? Color.secondary : Color.secondary.opacity(0.25))
                        .frame(width: 22, height: 22)
                        .background(expandButtonBackground(for: target, canExpand: canExpand))
                }
                .buttonStyle(.plain)
                .disabled(!canExpand)
                .onHover { isHovering in
                    hoveredExpandTargetID = isHovering && canExpand ? target.id : (hoveredExpandTargetID == target.id ? nil : hoveredExpandTargetID)
                }
                .help(canExpand ? "Show audio processes" : "No audio processes yet")
                Button(action: { controller.toggleMute(for: target) }) {
                    Image(systemName: appVolumeIconName(for: target.gain))
                        .font(.system(size: VolumeMixerSizing.checkmarkSize, weight: .medium))
                        .foregroundStyle(target.gain <= 0.001 ? Color.red : Color.accentColor)
                        .frame(width: 22, height: 22)
                        .background(muteButtonBackground(for: target))
                }
                .buttonStyle(.plain)
                .onHover { isHovering in
                    hoveredMuteTargetID = isHovering ? target.id : (hoveredMuteTargetID == target.id ? nil : hoveredMuteTargetID)
                }
                .help(target.gain <= 0.001 ? "Unmute" : "Mute")
                VStack(alignment: .leading, spacing: 1) {
                    Text(target.displayName)
                        .font(.system(size: VolumeMixerSizing.bodySize, weight: .medium))
                        .foregroundStyle(target.isActive ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !target.isActive {
                        Text("Inactive")
                            .font(.system(size: VolumeMixerSizing.captionSize))
                            .foregroundStyle(Color.secondary)
                    } else if target.backingProcessCount > 1 {
                        Text("\(target.backingProcessCount) audio processes")
                            .font(.system(size: VolumeMixerSizing.captionSize))
                            .foregroundStyle(Color.secondary)
                    }
                }
                Spacer(minLength: 0)
                Text("\(Int((target.gain * 100).rounded()))%")
                    .font(.system(size: VolumeMixerSizing.captionSize).monospacedDigit())
                    .foregroundStyle(Color.secondary)
                    .frame(width: 38, alignment: .trailing)
                outputRouteMenu(for: target)
                Button(action: { controller.togglePin(for: target) }) {
                    Image(systemName: target.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: VolumeMixerSizing.captionSize, weight: .semibold))
                        .foregroundStyle(target.isPinned ? Color.accentColor : Color.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help(target.isPinned ? "Unpin app" : "Pin app")
                Button(action: { controller.toggleProcessing(for: target) }) {
                    Image(systemName: target.isActive ? (isProcessing ? "stop.fill" : "play.fill") : "hourglass")
                        .font(.system(size: VolumeMixerSizing.captionSize, weight: .semibold))
                        .foregroundStyle(isProcessing ? Color.red : (target.isActive ? Color.accentColor : Color.secondary))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .disabled(!target.isActive)
                .help(target.isActive ? (isProcessing ? "Stop processing" : "Start processing") : "Open the app or play audio to start processing")
            }
            Slider(
                value: Binding(
                    get: { target.gain },
                    set: { controller.setGain($0, for: target) }
                ),
                in: 0...1
            )
            if isExpanded {
                subprocessList(for: target)
            }
        }
        .padding(.vertical, VolumeMixerSizing.rowVerticalPadding)
        .padding(.horizontal, VolumeMixerSizing.rowHorizontalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(isActive: isProcessing))
        .opacity(target.isActive ? 1 : 0.72)
        .contextMenu {
            if target.isLocallyIgnored {
                Button("Remove from Ignore List") {
                    controller.unignore(identifier: target.stableKey)
                }
            } else {
                Button("Add to Ignore List") {
                    controller.ignore(target)
                }
            }
            if target.isDefaultIgnored {
                Text("Included by Smart Filter")
            }
        }
    }

    private func outputRouteMenu(for target: AppVolumeTarget) -> some View {
        let routeUIDs = controller.outputRouteUIDs(for: target)
        let isCustomRoute = !routeUIDs.isEmpty
        return Menu {
            Button(action: { controller.useDefaultOutputRoute(for: target) }) {
                Label("System Default", systemImage: routeUIDs.isEmpty ? "checkmark" : "speaker.wave.2")
            }
            Divider()
            if controller.outputDevices.isEmpty {
                Text("No output devices")
            } else {
                ForEach(controller.outputDevices) { device in
                    Button(action: { controller.toggleOutputRoute(device, for: target) }) {
                        Label {
                            Text(device.isDefault ? "\(device.name) (Default)" : device.name)
                        } icon: {
                            HStack(spacing: 3) {
                                if routeUIDs.contains(device.uid) {
                                    Image(systemName: "checkmark")
                                }
                                Image(systemName: outputDeviceIconName(for: device))
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: isCustomRoute ? "speaker.wave.2.circle.fill" : "speaker.wave.2.circle")
                .font(.system(size: VolumeMixerSizing.captionSize, weight: .semibold))
                .foregroundStyle(isCustomRoute ? Color.accentColor : Color.secondary)
                .frame(width: 20, height: 20)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(outputRouteHelp(for: target))
    }

    private func ignoredAppRow(_ ignoredApp: AppVolumeIgnoredAppInfo) -> some View {
        let canReveal = ignoredAppURL(for: ignoredApp) != nil
        let isDisabledDefault = ignoredApp.source == .shippedDefaultDisabled
        return HStack(spacing: 8) {
            Button(action: { revealIgnoredAppInFinder(ignoredApp) }) {
                Image(systemName: ignoredRevealIconName(for: ignoredApp))
                    .font(.system(size: VolumeMixerSizing.checkmarkSize, weight: .medium))
                    .foregroundStyle(canReveal && !isDisabledDefault ? Color.accentColor : Color.secondary.opacity(0.45))
                    .frame(width: 22, height: 22)
                    .background(ignoredRevealButtonBackground(for: ignoredApp, canReveal: canReveal))
            }
            .buttonStyle(.plain)
            .disabled(!canReveal)
            .onHover { isHovering in
                hoveredRevealIgnoredID = isHovering && canReveal ? ignoredApp.id : (hoveredRevealIgnoredID == ignoredApp.id ? nil : hoveredRevealIgnoredID)
            }
            .help(canReveal ? "Show in Finder" : "Cannot locate app bundle")
            VStack(alignment: .leading, spacing: 1) {
                Text(ignoredApp.displayName)
                    .font(.system(size: VolumeMixerSizing.bodySize, weight: .medium))
                    .foregroundStyle(isDisabledDefault ? Color.secondary : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(ignoredApp.bundleIdentifier ?? ignoredApp.persistenceIdentifier)
                    .font(.system(size: VolumeMixerSizing.captionSize))
                    .foregroundStyle(isDisabledDefault ? Color.secondary.opacity(0.65) : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if ignoredApp.source == .local {
                Button(action: { controller.unignore(identifier: ignoredApp.persistenceIdentifier) }) {
                    Image(systemName: "xmark")
                        .font(.system(size: VolumeMixerSizing.captionSize, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("Remove from ignore list")
            } else {
                HStack(spacing: 6) {
                    Text(isDisabledDefault ? "Default off" : "Default")
                        .font(.system(size: VolumeMixerSizing.captionSize))
                        .foregroundStyle(Color.secondary)
                    Button(action: { toggleDefaultIgnoredApp(ignoredApp) }) {
                        Image(systemName: isDisabledDefault ? "eye.slash" : "eye")
                            .font(.system(size: VolumeMixerSizing.captionSize, weight: .semibold))
                            .foregroundStyle(isDisabledDefault ? Color.secondary : Color.accentColor)
                            .frame(width: 20, height: 20)
                            .background(includeDefaultButtonBackground(for: ignoredApp))
                    }
                    .buttonStyle(.plain)
                    .onHover { isHovering in
                        hoveredIncludeDefaultIgnoredID = isHovering ? ignoredApp.id : (hoveredIncludeDefaultIgnoredID == ignoredApp.id ? nil : hoveredIncludeDefaultIgnoredID)
                    }
                    .help(isDisabledDefault ? "Restore Smart Filter ignore" : "Show in Apps list")
                }
            }
        }
        .padding(.vertical, VolumeMixerSizing.rowVerticalPadding)
        .padding(.horizontal, VolumeMixerSizing.rowHorizontalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(isActive: false))
        .opacity(isDisabledDefault ? 0.58 : 1)
    }

    private func ignoredRevealIconName(for ignoredApp: AppVolumeIgnoredAppInfo) -> String {
        switch ignoredApp.source {
        case .shippedDefault:
            return "sparkle.magnifyingglass"
        case .shippedDefaultDisabled:
            return "eye.slash.fill"
        case .local:
            return "eye.slash.fill"
        }
    }

    private func toggleDefaultIgnoredApp(_ ignoredApp: AppVolumeIgnoredAppInfo) {
        if ignoredApp.source == .shippedDefaultDisabled {
            controller.restoreDefaultIgnoredApp(identifier: ignoredApp.persistenceIdentifier)
        } else {
            controller.includeDefaultIgnoredApp(identifier: ignoredApp.persistenceIdentifier)
        }
    }

    private var ignoredListHeader: some View {
        HStack(spacing: 8) {
            sectionHeader("IGNORED APPS")
            Spacer()
            Button(action: { controller.clearDefaultIgnoredAppOverrides() }) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: VolumeMixerSizing.captionSize, weight: .semibold))
                    .foregroundStyle(controller.defaultIgnoredOverrideCount == 0 ? Color.secondary.opacity(0.45) : Color.accentColor)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .disabled(controller.defaultIgnoredOverrideCount == 0)
            .help(controller.defaultIgnoredOverrideCount == 0 ? "No default status overrides" : "Reset default ignore statuses")
            Button(action: { controller.clearIgnoredApps() }) {
                Image(systemName: "trash")
                    .font(.system(size: VolumeMixerSizing.captionSize, weight: .semibold))
                    .foregroundStyle(controller.localIgnoredAppCount == 0 ? Color.secondary.opacity(0.45) : Color.red)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .disabled(controller.localIgnoredAppCount == 0)
            .help(controller.localIgnoredAppCount == 0 ? "No local ignored apps" : "Clear local ignored apps")
        }
    }

    private func ignoredRevealButtonBackground(
        for ignoredApp: AppVolumeIgnoredAppInfo,
        canReveal: Bool
    ) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(canReveal && hoveredRevealIgnoredID == ignoredApp.id ? Color.accentColor.opacity(0.14) : Color.clear)
    }

    private func includeDefaultButtonBackground(for ignoredApp: AppVolumeIgnoredAppInfo) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(hoveredIncludeDefaultIgnoredID == ignoredApp.id ? Color.accentColor.opacity(0.14) : Color.clear)
    }

    private func ignoredAppURL(for ignoredApp: AppVolumeIgnoredAppInfo) -> URL? {
        guard let bundleIdentifier = ignoredApp.bundleIdentifier else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    private func revealIgnoredAppInFinder(_ ignoredApp: AppVolumeIgnoredAppInfo) {
        guard let url = ignoredAppURL(for: ignoredApp) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func muteButtonBackground(for target: AppVolumeTarget) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(hoveredMuteTargetID == target.id ? Color.accentColor.opacity(0.14) : Color.clear)
    }

    private func expandButtonBackground(for target: AppVolumeTarget, canExpand: Bool) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(canExpand && hoveredExpandTargetID == target.id ? Color.accentColor.opacity(0.14) : Color.clear)
    }

    private func masterMuteButtonBackground(isSupported: Bool) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(isSupported && hoveredMasterMute ? Color.accentColor.opacity(0.14) : Color.clear)
    }

    private func subprocessList(for target: AppVolumeTarget) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(target.subprocesses) { subprocess in
                HStack(spacing: 6) {
                    Circle()
                        .fill(subprocess.isRunningOutput ? Color.green : Color.secondary.opacity(0.35))
                        .frame(width: 6, height: 6)
                    Text(subprocess.displayName)
                        .font(.system(size: VolumeMixerSizing.captionSize, weight: .medium))
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Text("pid \(subprocess.processID) · obj \(subprocess.audioObjectID)")
                        .font(.system(size: VolumeMixerSizing.captionSize).monospacedDigit())
                        .foregroundStyle(Color.secondary.opacity(0.78))
                        .lineLimit(1)
                }
            }
        }
        .padding(.leading, 24)
        .padding(.top, 2)
    }

    private func targetMatchesSearch(_ target: AppVolumeTarget, query: String) -> Bool {
        if target.displayName.lowercased().contains(query) {
            return true
        }
        if target.bundleIdentifier?.lowercased().contains(query) == true {
            return true
        }
        return target.subprocesses.contains { subprocess in
            subprocess.displayName.lowercased().contains(query)
                || subprocess.bundleIdentifier?.lowercased().contains(query) == true
                || "\(subprocess.processID)".contains(query)
        }
    }

    private func ignoredAppMatchesSearch(_ ignoredApp: AppVolumeIgnoredAppInfo, query: String) -> Bool {
        ignoredApp.displayName.lowercased().contains(query)
            || ignoredApp.persistenceIdentifier.lowercased().contains(query)
            || ignoredApp.bundleIdentifier?.lowercased().contains(query) == true
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: VolumeMixerSizing.sectionHeaderSize, weight: .semibold))
            .foregroundStyle(Color.secondary)
            .kerning(0.5)
    }

    private func emptyRow(_ message: String) -> some View {
        Text(message)
            .font(.system(size: VolumeMixerSizing.bodySize))
            .foregroundStyle(Color.secondary)
            .padding(.vertical, VolumeMixerSizing.rowVerticalPadding)
    }

    private func errorRow(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: VolumeMixerSizing.captionSize, weight: .semibold))
                .foregroundStyle(Color.orange)
            Text(message)
                .font(.system(size: VolumeMixerSizing.captionSize))
                .foregroundStyle(Color.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, VolumeMixerSizing.rowVerticalPadding)
        .padding(.horizontal, VolumeMixerSizing.rowHorizontalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(isActive: false))
    }

    private func rowBackground(isActive: Bool) -> some View {
        RoundedRectangle(cornerRadius: VolumeMixerSizing.rowCornerRadius, style: .continuous)
            .fill(isActive ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
    }

    private var footer: some View {
        HStack {
            Text("\(controller.targets.count) apps")
                .font(.system(size: VolumeMixerSizing.captionSize))
                .foregroundStyle(Color.secondary)
            if !controller.sessionState.activeTargetIDs.isEmpty {
                Text("· processing")
                    .font(.system(size: VolumeMixerSizing.captionSize))
                    .foregroundStyle(Color.secondary)
            }
            Spacer()
            if !controller.sessionState.activeTargetIDs.isEmpty {
                Button(action: { controller.stopProcessing() }) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: VolumeMixerSizing.bodySize, weight: .medium))
                        .foregroundStyle(Color.red)
                }
                .buttonStyle(.plain)
                .help("Stop processing")
            }
            Button(action: onQuit) {
                Text("Quit")
                    .font(.system(size: VolumeMixerSizing.bodySize, weight: .medium))
                    .foregroundStyle(Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Quit Volume Mixer")
        }
    }

    private var mixerStatusColor: Color {
        switch controller.engineState {
        case .available: .green
        case .needsAudioCapturePermission: .orange
        case .unsupportedOS: .secondary
        }
    }

    private var mixerStatusText: String {
        switch controller.engineState {
        case .available: "Tap API"
        case .needsAudioCapturePermission: "Setup"
        case .unsupportedOS: "14.2+"
        }
    }

    private var mixerStatusHelp: String {
        switch controller.engineState {
        case .available:
            "CoreAudio process taps are available"
        case .needsAudioCapturePermission:
            "Add NSAudioCaptureUsageDescription to the app bundle"
        case .unsupportedOS:
            "Per-app capture requires macOS 14.2 or newer"
        }
    }

    private func appVolumeIconName(for gain: Float) -> String {
        if gain <= 0.001 {
            return "speaker.slash.fill"
        }
        if gain < 0.5 {
            return "speaker.wave.1.fill"
        }
        return "speaker.wave.2.fill"
    }

    private func masterVolumeIconName(for state: AppVolumeMasterVolumeState) -> String {
        if state.isMuted {
            return "speaker.slash.fill"
        }
        return appVolumeIconName(for: state.volume)
    }

    private func masterMuteHelp(for state: AppVolumeMasterVolumeState) -> String {
        guard state.muteSupported else { return "Mute not available for this device" }
        return state.isMuted ? "Unmute master volume" : "Mute master volume"
    }

    private func masterVolumeStatusText(for state: AppVolumeMasterVolumeState) -> String {
        guard state.hasOutputDevice else { return "No output device" }
        return "\(state.deviceName) volume unavailable"
    }

    private func outputDeviceIconName(for device: AppVolumeOutputDevice) -> String {
        let name = device.name.lowercased()
        if name.contains("airpods max") {
            return "airpodsmax"
        }
        if name.contains("airpods pro") {
            return "airpodspro"
        }
        if name.contains("airpods") {
            return "airpods"
        }
        if name.contains("beats") {
            return "beats.headphones"
        }
        if name.contains("earbuds") || name.contains("buds") {
            return "earbuds"
        }
        if name.contains("headphone") {
            return "headphones"
        }
        if name.contains("homepod") {
            return "homepod"
        }
        if name.contains("macbook") || name.contains("built-in") || name.contains("internal") || name.contains("speaker") {
            return "macbook"
        }
        if name.contains("imac") || name.contains("display") || name.contains("monitor") {
            return "display"
        }
        if name.contains("mac mini") {
            return "macmini"
        }
        if name.contains("tv") {
            return "tv"
        }
        if name.contains("bluetooth") || name.contains("airplay") {
            return "airplayaudio"
        }
        return "speaker.wave.2"
    }

    private func outputRouteHelp(for target: AppVolumeTarget) -> String {
        let routeUIDs = controller.outputRouteUIDs(for: target)
        guard !routeUIDs.isEmpty else {
            return "Route to system default output"
        }
        let routeNames = controller.outputDevices
            .filter { routeUIDs.contains($0.uid) }
            .map(\.name)
        guard !routeNames.isEmpty else {
            return "Route to selected outputs"
        }
        return "Route to \(routeNames.joined(separator: ", "))"
    }
}
