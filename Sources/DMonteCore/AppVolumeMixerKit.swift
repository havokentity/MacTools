import AppKit
import Accelerate
import CoreAudio
import Darwin
import Foundation
import os.lock

public struct AppVolumeSubprocess: Identifiable, Sendable, Equatable {
    public let processID: pid_t
    public let audioObjectID: AudioObjectID
    public let bundleIdentifier: String?
    public let displayName: String
    public let isRunningOutput: Bool

    public var id: AudioObjectID { audioObjectID }

    public init(
        processID: pid_t,
        audioObjectID: AudioObjectID,
        bundleIdentifier: String?,
        displayName: String,
        isRunningOutput: Bool
    ) {
        self.processID = processID
        self.audioObjectID = audioObjectID
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.isRunningOutput = isRunningOutput
    }
}

public struct AppVolumeTarget: Identifiable, Sendable, Equatable {
    public let processID: pid_t
    public let audioObjectIDs: [AudioObjectID]
    public let subprocesses: [AppVolumeSubprocess]
    public let bundleIdentifier: String?
    public let displayName: String
    public let isActive: Bool
    public let isRunningOutput: Bool
    public let isPinned: Bool
    public let isIgnored: Bool
    public let isLocallyIgnored: Bool
    public let isDefaultIgnored: Bool
    public let gain: Float

    public var id: String { stableKey }

    public var stableKey: String {
        Self.stableKey(
            processID: processID,
            bundleIdentifier: bundleIdentifier,
            displayName: displayName
        )
    }

    /// Single source of truth for the persistence key used by gains, pins,
    /// ignores, and output routes. Both `stableKey` and the kit's discovery
    /// path derive keys from here so the write and read schemes cannot drift.
    /// Prefers the bundle identifier; bundle-less audio processes (mpv,
    /// afplay, bare binaries) fall back to `name:<displayName>` so their
    /// settings survive relaunches; `pid:` is a last resort for processes
    /// with no usable name. (Keys previously written as `pid:<pid>` for
    /// bundle-less apps were never matched on read, so no migration applies.)
    public static func stableKey(
        processID: pid_t,
        bundleIdentifier: String?,
        displayName: String?
    ) -> String {
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }
        if let displayName, !displayName.isEmpty {
            return "name:\(displayName)"
        }
        return "pid:\(processID)"
    }

    public var backingProcessCount: Int { subprocesses.count }

    public init(
        processID: pid_t,
        audioObjectIDs: [AudioObjectID],
        subprocesses: [AppVolumeSubprocess] = [],
        bundleIdentifier: String?,
        displayName: String,
        isActive: Bool = true,
        isRunningOutput: Bool,
        isPinned: Bool = false,
        isIgnored: Bool = false,
        isLocallyIgnored: Bool = false,
        isDefaultIgnored: Bool = false,
        gain: Float
    ) {
        self.processID = processID
        let sortedSubprocesses = subprocesses.sorted { $0.audioObjectID < $1.audioObjectID }
        self.subprocesses = sortedSubprocesses
        self.audioObjectIDs = sortedSubprocesses.isEmpty ? audioObjectIDs.sorted() : sortedSubprocesses.map(\.audioObjectID)
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.isActive = isActive
        self.isRunningOutput = isRunningOutput
        self.isPinned = isPinned
        self.isIgnored = isIgnored
        self.isLocallyIgnored = isLocallyIgnored
        self.isDefaultIgnored = isDefaultIgnored
        self.gain = Self.clampGain(gain)
    }

    public init(
        processID: pid_t,
        audioObjectID: AudioObjectID,
        bundleIdentifier: String?,
        displayName: String,
        isRunningOutput: Bool,
        gain: Float
    ) {
        self.init(
            processID: processID,
            audioObjectIDs: [audioObjectID],
            subprocesses: [
                AppVolumeSubprocess(
                    processID: processID,
                    audioObjectID: audioObjectID,
                    bundleIdentifier: bundleIdentifier,
                    displayName: displayName,
                    isRunningOutput: isRunningOutput
                )
            ],
            bundleIdentifier: bundleIdentifier,
            displayName: displayName,
            isActive: true,
            isRunningOutput: isRunningOutput,
            isPinned: false,
            isIgnored: false,
            isLocallyIgnored: false,
            isDefaultIgnored: false,
            gain: gain
        )
    }

    public static func clampGain(_ value: Float) -> Float {
        min(1, max(0, value))
    }
}

public struct AppVolumeOutputDevice: Identifiable, Sendable, Equatable {
    public let deviceID: AudioDeviceID
    public let uid: String
    public let name: String
    public let isDefault: Bool

    public var id: String { uid }

    public init(deviceID: AudioDeviceID, uid: String, name: String, isDefault: Bool) {
        self.deviceID = deviceID
        self.uid = uid
        self.name = name
        self.isDefault = isDefault
    }
}

public struct AppVolumeMasterVolumeState: Sendable, Equatable {
    public let deviceID: AudioDeviceID?
    public let deviceName: String
    public let volume: Float
    public let volumeSupported: Bool
    public let isMuted: Bool
    public let muteSupported: Bool

    public var hasOutputDevice: Bool { deviceID != nil }

    public init(
        deviceID: AudioDeviceID? = nil,
        deviceName: String = "System Output",
        volume: Float = 0,
        volumeSupported: Bool = false,
        isMuted: Bool = false,
        muteSupported: Bool = false
    ) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.volume = AppVolumeTarget.clampGain(volume)
        self.volumeSupported = volumeSupported
        self.isMuted = isMuted
        self.muteSupported = muteSupported
    }

    public func withVolume(_ volume: Float) -> AppVolumeMasterVolumeState {
        AppVolumeMasterVolumeState(
            deviceID: deviceID,
            deviceName: deviceName,
            volume: volume,
            volumeSupported: volumeSupported,
            isMuted: isMuted,
            muteSupported: muteSupported
        )
    }

    public func withMuted(_ muted: Bool) -> AppVolumeMasterVolumeState {
        AppVolumeMasterVolumeState(
            deviceID: deviceID,
            deviceName: deviceName,
            volume: volume,
            volumeSupported: volumeSupported,
            isMuted: muted,
            muteSupported: muteSupported
        )
    }
}

public struct AppVolumeIgnoredAppInfo: Codable, Identifiable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable {
        case shippedDefault
        case shippedDefaultDisabled
        case local
    }

    public let persistenceIdentifier: String
    public let bundleIdentifier: String?
    public let displayName: String
    public let source: Source

    public var id: String { persistenceIdentifier }

    public init(
        persistenceIdentifier: String,
        bundleIdentifier: String?,
        displayName: String,
        source: Source
    ) {
        self.persistenceIdentifier = persistenceIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.source = source
    }

    public init(target: AppVolumeTarget, source: Source = .local) {
        self.init(
            persistenceIdentifier: target.stableKey,
            bundleIdentifier: target.bundleIdentifier,
            displayName: target.displayName,
            source: source
        )
    }
}

public struct AppVolumePinnedAppInfo: Codable, Identifiable, Sendable, Equatable {
    public let persistenceIdentifier: String
    public let bundleIdentifier: String?
    public let displayName: String

    public var id: String { persistenceIdentifier }

    public init(
        persistenceIdentifier: String,
        bundleIdentifier: String?,
        displayName: String
    ) {
        self.persistenceIdentifier = persistenceIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
    }

    public init(target: AppVolumeTarget) {
        self.init(
            persistenceIdentifier: target.stableKey,
            bundleIdentifier: target.bundleIdentifier,
            displayName: target.displayName
        )
    }
}

public enum AppVolumeMixerEngineState: Sendable, Equatable {
    case unsupportedOS
    case needsAudioCapturePermission
    case available
}

public struct AppVolumeMixerSessionState: Sendable, Equatable {
    public let activeTargetIDs: Set<String>
    public let errorMessage: String?

    public var activeTargetID: String? { activeTargetIDs.first }

    public init(activeTargetIDs: Set<String> = [], errorMessage: String? = nil) {
        self.activeTargetIDs = activeTargetIDs
        self.errorMessage = errorMessage
    }

    public init(activeTargetID: String?, errorMessage: String? = nil) {
        self.init(activeTargetIDs: activeTargetID.map { [$0] } ?? [], errorMessage: errorMessage)
    }
}

public final class AppVolumeMixerAudioEngine: @unchecked Sendable {
    /// Gain shared between the main thread (writer, via `setGain`) and the
    /// realtime HAL IO proc (reader). A plain `var Float` touched from both
    /// threads is a data race — UB under the memory model, trips TSan, and
    /// the compiler may hoist the load out of the render loop — so access is
    /// guarded by an `os_unfair_lock` (macOS 14 target; the Synchronization
    /// module's `Atomic` is unavailable). The writer locks unconditionally;
    /// the render thread only *tries* the lock, because a realtime audio
    /// thread must never block: waiting on a lock held by the (preemptible)
    /// main thread is a priority inversion and a missed render deadline is an
    /// audible glitch. On a failed trylock it reuses the last gain it
    /// successfully read — that cache is render-thread-local, so it needs no
    /// synchronization of its own.
    private final class RenderState: @unchecked Sendable {
        private var gain: Float
        /// Read and written only by the realtime IO proc thread.
        private var lastRenderGain: Float
        /// Heap-allocated so the lock has a stable address; an inline struct
        /// stored property could be moved/copied by Swift value semantics.
        private let lock: UnsafeMutablePointer<os_unfair_lock>

        init(gain: Float) {
            self.gain = gain
            self.lastRenderGain = gain
            self.lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
            self.lock.initialize(to: os_unfair_lock())
        }

        deinit {
            lock.deinitialize(count: 1)
            lock.deallocate()
        }

        /// Writer side (main thread).
        func setGain(_ value: Float) {
            os_unfair_lock_lock(lock)
            gain = value
            os_unfair_lock_unlock(lock)
        }

        /// Reader side; call only from the realtime IO proc. Never blocks.
        func renderGain() -> Float {
            if os_unfair_lock_trylock(lock) {
                lastRenderGain = gain
                os_unfair_lock_unlock(lock)
            }
            return lastRenderGain
        }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var renderState: RenderState?
    private var renderStatePointer: UnsafeMutableRawPointer?
    private(set) public var activeTargetID: String?
    private(set) public var activeAudioObjectIDs: [AudioObjectID] = []
    /// Resolved device UIDs the engine is actually playing through.
    private(set) public var activeOutputUIDs: [String] = []
    /// The route as requested in `start(target:gain:outputUIDs:)`, before
    /// resolution (`[]` means "System Default"). Keep-alive checks compare
    /// against this, not `activeOutputUIDs`, which always holds resolved UIDs.
    private(set) public var requestedOutputUIDs: [String] = []
    /// Devices this engine needs held at `reconciledSampleRate` (e.g. 48 kHz so
    /// an HDMI/TV output matches the source). The rate to put back lives in
    /// `ForcedSampleRates`, which restores a device only once no engine still
    /// depends on the forced rate.
    private var forcedSampleRateDeviceIDs: [AudioObjectID] = []
    /// The common rate `alignSampleRates` settled on for the current route —
    /// NOT the originals held by `ForcedSampleRates`, which exist only to be
    /// put back on stop.
    private var reconciledSampleRate: Double?

    public init() {}

    deinit {
        stop()
    }

    public func start(target: AppVolumeTarget, gain: Float, outputUIDs: [String] = []) throws {
        stop()
        guard #available(macOS 14.2, *) else {
            throw AppVolumeMixerError.unsupportedOS
        }
        guard !target.audioObjectIDs.isEmpty else {
            throw AppVolumeMixerError.noActiveAppAudio
        }
        let requestedOutputUIDs = outputUIDs
        let hasCustomOutputRoute = !outputUIDs.isEmpty
        let outputDevices = Self.routedOutputDevices(outputUIDs: outputUIDs)
        guard let primaryOutput = outputDevices.first else {
            throw AppVolumeMixerError.noDefaultOutputDevice
        }
        let outputUIDs = outputDevices.map(\.uid)
        let sourceOutput = Self.sourceOutputDevice() ?? primaryOutput

        MixerDebug.log("start target='\(target.displayName)' audioObjects=\(target.audioObjectIDs) customRoute=\(hasCustomOutputRoute)")
        MixerDebug.log("  source: name='\(sourceOutput.name)' uid='\(sourceOutput.uid)' id=\(sourceOutput.deviceID) rate=\(Self.nominalSampleRate(for: sourceOutput.deviceID).map { String($0) } ?? "nil")")
        for output in outputDevices {
            MixerDebug.log("  output: name='\(output.name)' uid='\(output.uid)' id=\(output.deviceID) rate=\(Self.nominalSampleRate(for: output.deviceID).map { String($0) } ?? "nil") supported=\(Self.availableNominalSampleRates(for: output.deviceID))")
        }

        // Reconcile sample rates *before* tapping. The render loop is a raw
        // byte copy with no resampling, so the tap (source) and every routed
        // output must share one nominal rate. HDMI/TV outputs typically run at
        // a fixed 48 kHz that differs from the Mac's default, which otherwise
        // produces silence. We align everything to a common supported rate
        // (refcounted, so the originals go back once no engine needs them), and
        // create the tap afterwards so it latches the reconciled source rate.
        try alignSampleRates(source: sourceOutput, outputs: outputDevices)
        MixerDebug.log("  afterAlign: sourceRate=\(Self.nominalSampleRate(for: sourceOutput.deviceID).map { String($0) } ?? "nil") forced=\(forcedSampleRateDeviceIDs)")

        let state = RenderState(gain: AppVolumeTarget.clampGain(gain))
        do {
            // For a custom output route, use a process-wide stereo-mixdown tap:
            // it captures the app's audio independent of which device it plays
            // to, which is exactly what we reproduce on the routed output. A
            // device-scoped tap (pinned to the source device's stream) was
            // observed to deliver silence here (render `signal=false`), killing
            // routed audio. Plain volume changes (no route) keep the
            // device-scoped tap, with mixdown as a fallback.
            let tap = try Self.createTap(
                for: target,
                outputUID: sourceOutput.uid,
                outputID: sourceOutput.deviceID,
                preferDeviceScopedTap: !hasCustomOutputRoute,
                allowStereoMixdownFallback: true
            )
            MixerDebug.log("  tap created id=\(tap.id) uuid=\(tap.description.uuid)")
            let aggregateID: AudioObjectID
            do {
                aggregateID = try Self.createAggregateDevice(
                    target: target,
                    tapUUID: tap.description.uuid,
                    outputUIDs: outputUIDs
                )
            } catch {
                // The tap was already created in the HAL; without this it leaks
                // on every failed aggregate creation — and the 2-second
                // reconciler retries start(), accumulating leaked tap objects.
                // (The later failure paths below clean up both the same way.)
                AppVolumeMixerKit.destroyTap(tap.id)
                throw error
            }
            MixerDebug.log("  aggregate created id=\(aggregateID) rate=\(Self.nominalSampleRate(for: aggregateID).map { String($0) } ?? "nil")")
            // Best-effort: pin the aggregate itself to the reconciled rate too.
            if let chosenRate = reconciledSampleRate {
                _ = Self.setNominalSampleRate(chosenRate, for: aggregateID)
            }

            let statePointer = Unmanaged.passRetained(state).toOpaque()
            var ioProcID: AudioDeviceIOProcID?
            let createStatus = AudioDeviceCreateIOProcID(
                aggregateID,
                Self.ioProc,
                statePointer,
                &ioProcID
            )
            guard createStatus == noErr, let ioProcID else {
                Unmanaged<RenderState>.fromOpaque(statePointer).release()
                Self.destroyAggregateDevice(aggregateID)
                AppVolumeMixerKit.destroyTap(tap.id)
                throw AppVolumeMixerError.coreAudioStatus(createStatus)
            }

            MixerDebug.log("  ioProc create status=\(createStatus)")
            let startStatus = AudioDeviceStart(aggregateID, ioProcID)
            MixerDebug.log("  AudioDeviceStart status=\(startStatus) → \(startStatus == noErr ? "RUNNING" : "FAILED")")
            guard startStatus == noErr else {
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
                Unmanaged<RenderState>.fromOpaque(statePointer).release()
                Self.destroyAggregateDevice(aggregateID)
                AppVolumeMixerKit.destroyTap(tap.id)
                throw AppVolumeMixerError.coreAudioStatus(startStatus)
            }

            self.tapID = tap.id
            self.aggregateID = aggregateID
            self.ioProcID = ioProcID
            self.renderState = state
            self.renderStatePointer = statePointer
            self.activeTargetID = target.id
            self.activeAudioObjectIDs = target.audioObjectIDs
            self.activeOutputUIDs = outputUIDs
            self.requestedOutputUIDs = requestedOutputUIDs
        } catch {
            // Never leave devices on a forced rate (or the app muted) if we
            // couldn't finish wiring up the route.
            restoreSampleRates()
            throw error
        }
    }

    /// Pure bookkeeping behind `ForcedSampleRates`: how many engines depend on a
    /// device's forced rate, and what is owed back once none do. Free of
    /// CoreAudio so the refcount rule itself stays testable.
    struct ForcedSampleRateLedger {
        private struct Entry {
            let originalRate: Double
            var holders: Int
        }

        private var entries: [AudioObjectID: Entry] = [:]

        init() {}

        /// Whether some engine already holds `deviceID` at a forced rate.
        func isForced(_ deviceID: AudioObjectID) -> Bool {
            entries[deviceID] != nil
        }

        /// Adds one holder. `originalRate` counts only for the first: what the
        /// device is owed is the rate it ran at before any engine touched it,
        /// not the forced rate a later holder finds it on.
        mutating func acquire(_ deviceID: AudioObjectID, originalRate: Double) {
            if var entry = entries[deviceID] {
                entry.holders += 1
                entries[deviceID] = entry
            } else {
                entries[deviceID] = Entry(originalRate: originalRate, holders: 1)
            }
        }

        /// Drops one holder, yielding the rate to restore only when it was the
        /// last engine depending on the forced one.
        mutating func release(_ deviceID: AudioObjectID) -> Double? {
            guard var entry = entries[deviceID] else { return nil }
            entry.holders -= 1
            guard entry.holders <= 0 else {
                entries[deviceID] = entry
                return nil
            }
            entries.removeValue(forKey: deviceID)
            return entry.originalRate
        }
    }

    /// Process-wide refcount of the nominal sample rates the mixer's engines
    /// have forced. Engines routinely align the same devices — every engine taps
    /// the system default output — so an engine that restored "its" original
    /// rate on stop would strand every other engine still routed through that
    /// device: the render loop does not resample, and the reconciler only
    /// compares object ids and output UIDs, so a clobbered engine is never
    /// restarted and its audio stays broken. Restore only on the last release.
    ///
    /// Refcounting alone is not enough: a live engine's render loop assumes its
    /// devices stay at the rate chosen when it started, so a device another
    /// engine is already driving must not be retuned. `pinnedRate` reports that
    /// held rate so `alignSampleRates` constrains a new route to it rather than
    /// clobbering the device at acquire time. Mirrors `MonitorSampleRateRegistry`.
    private enum ForcedSampleRates {
        nonisolated(unsafe) private static var ledger = ForcedSampleRateLedger()
        /// The rate each device is currently held at by live engines, kept in
        /// lockstep with the ledger's holders so a later route aligns to it.
        nonisolated(unsafe) private static var pinnedRates: [AudioObjectID: Double] = [:]
        private static let lock = NSLock()

        /// The rate a live engine is already holding `deviceID` at, if any.
        static func pinnedRate(for deviceID: AudioObjectID) -> Double? {
            lock.lock()
            defer { lock.unlock() }
            return pinnedRates[deviceID]
        }

        /// Aligns `deviceID` to `rate` and takes a reference on it. Returns
        /// `true` when the caller holds one and must `release` it on stop.
        static func acquire(_ rate: Double, for deviceID: AudioObjectID) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard let current = AppVolumeMixerAudioEngine.nominalSampleRate(for: deviceID) else {
                return false
            }
            if ledger.isForced(deviceID) {
                // Already held by another engine. Ride its reference and never
                // retune: its non-resampling render loop assumes the pinned rate
                // stays put, so clobbering the device here would silence it.
                // `alignSampleRates` already constrained this route to
                // `pinnedRate`, so `rate` matches what the device is on.
                ledger.acquire(deviceID, originalRate: current)
                return true
            }
            // First holder. Pin the rate the device actually ends up on so later
            // routes align to it instead of retuning the device under this one. A
            // fixed-rate device may refuse the change; take no reference then,
            // since nothing was forced and there is nothing to put back.
            let needsChange = abs(current - rate) > 1
            if needsChange, !AppVolumeMixerAudioEngine.setNominalSampleRate(rate, for: deviceID) {
                return false
            }
            pinnedRates[deviceID] = needsChange ? rate : current
            ledger.acquire(deviceID, originalRate: current)
            return true
        }

        /// Drops one reference, restoring the original rate only once no other
        /// engine depends on the forced one.
        static func release(_ deviceID: AudioObjectID) {
            lock.lock()
            defer { lock.unlock() }
            guard let originalRate = ledger.release(deviceID) else { return }
            let pinned = pinnedRates.removeValue(forKey: deviceID)
            // Only put a rate back if the first holder actually moved the device;
            // one pinned at the rate it already ran at owes nothing, and setting
            // it would clobber whatever the device is on now.
            if let pinned, abs(pinned - originalRate) <= 1 { return }
            _ = AppVolumeMixerAudioEngine.setNominalSampleRate(originalRate, for: deviceID)
        }
    }

    /// Forces the source and every routed output device onto one common nominal
    /// sample rate so the (non-resampling) render loop produces sound. Throws
    /// `.incompatibleOutputSampleRate` if the devices share no rate. References
    /// are taken through `ForcedSampleRates` for `stop()` to release.
    private func alignSampleRates(
        source: AppVolumeOutputDevice,
        outputs: [AppVolumeOutputDevice]
    ) throws {
        let deviceIDs = Self.uniqued([source.deviceID] + outputs.map(\.deviceID))
        let rateSets = deviceIDs.map { deviceID -> [Double] in
            // A device another engine is already driving must stay at its held
            // rate — retuning it would break that engine's non-resampling render
            // loop — so its pinned rate is the only candidate here.
            if let pinned = ForcedSampleRates.pinnedRate(for: deviceID) { return [pinned] }
            return Self.availableNominalSampleRates(for: deviceID)
        }
        let preferred = ForcedSampleRates.pinnedRate(for: source.deviceID)
            ?? Self.nominalSampleRate(for: source.deviceID)
        guard let chosen = Self.chooseCommonSampleRate(
            preferred: preferred,
            deviceSupportedRates: rateSets
        ) else {
            throw AppVolumeMixerError.incompatibleOutputSampleRate
        }
        reconciledSampleRate = chosen

        forcedSampleRateDeviceIDs = deviceIDs.filter { ForcedSampleRates.acquire(chosen, for: $0) }
    }

    /// Releases the forced rates `alignSampleRates` took references on; a device
    /// is put back only once no other engine still depends on it.
    private func restoreSampleRates() {
        for deviceID in forcedSampleRateDeviceIDs {
            ForcedSampleRates.release(deviceID)
        }
        forcedSampleRateDeviceIDs = []
        reconciledSampleRate = nil
    }

    public func setGain(_ gain: Float) {
        renderState?.setGain(AppVolumeTarget.clampGain(gain))
    }

    public func stop() {
        if aggregateID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        if let renderStatePointer {
            Unmanaged<RenderState>.fromOpaque(renderStatePointer).release()
        }
        if aggregateID != kAudioObjectUnknown {
            Self.destroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            if #available(macOS 14.2, *) {
                AppVolumeMixerKit.destroyTap(tapID)
            }
        }
        // Drop this route's hold on the device sample rates it forced.
        restoreSampleRates()

        tapID = AudioObjectID(kAudioObjectUnknown)
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        ioProcID = nil
        renderState = nil
        renderStatePointer = nil
        activeTargetID = nil
        activeAudioObjectIDs = []
        activeOutputUIDs = []
        requestedOutputUIDs = []
    }

    @available(macOS 14.2, *)
    private struct CreatedTap {
        let description: CATapDescription
        let id: AudioObjectID
    }

    @available(macOS 14.2, *)
    private static func createTap(
        for target: AppVolumeTarget,
        outputUID: String,
        outputID: AudioDeviceID,
        preferDeviceScopedTap: Bool,
        allowStereoMixdownFallback: Bool
    ) throws -> CreatedTap {
        if preferDeviceScopedTap,
           let streamIndex = firstOutputStreamIndex(for: outputID),
           let tap = try? createTapDescription(
            CATapDescription(processes: target.audioObjectIDs, deviceUID: outputUID, stream: streamIndex),
            name: target.displayName
           ) {
            MixerDebug.log("  tap path=device-scoped on uid='\(outputUID)' stream=\(streamIndex)")
            return tap
        }

        guard allowStereoMixdownFallback else {
            MixerDebug.log("  tap path=NONE (device-scoped failed, mixdown fallback disabled) → throwing")
            throw AppVolumeMixerError.noRoutableSourceOutput
        }

        MixerDebug.log("  tap path=stereo-mixdown (device-scoped unavailable)")
        return try createTapDescription(
            CATapDescription(stereoMixdownOfProcesses: target.audioObjectIDs),
            name: target.displayName
        )
    }

    @available(macOS 14.2, *)
    private static func createTapDescription(
        _ description: CATapDescription,
        name: String
    ) throws -> CreatedTap {
        description.name = "DMonte \(name)"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else {
            throw AppVolumeMixerError.coreAudioStatus(status)
        }
        return CreatedTap(description: description, id: tapID)
    }

    private static func createAggregateDevice(
        target: AppVolumeTarget,
        tapUUID: UUID,
        outputUIDs: [String]
    ) throws -> AudioObjectID {
        guard let primaryOutputUID = outputUIDs.first else {
            throw AppVolumeMixerError.noDefaultOutputDevice
        }
        let aggregateUID = "com.havokentity.mactools.volumemixer.aggregate.\(UUID().uuidString)"
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "DMonte Volume Mixer \(target.displayName)",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: primaryOutputUID,
            kAudioAggregateDeviceClockDeviceKey: primaryOutputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: outputUIDs.map { uid in
                [
                    kAudioSubDeviceUIDKey: uid,
                    kAudioSubDeviceDriftCompensationKey: uid != primaryOutputUID
                ]
            },
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: false
                ]
            ]
        ]

        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
        guard status == noErr, aggregateID != kAudioObjectUnknown else {
            throw AppVolumeMixerError.coreAudioStatus(status)
        }
        return aggregateID
    }

    private static func routedOutputDevices(outputUIDs: [String]) -> [AppVolumeOutputDevice] {
        let availableOutputs = AppVolumeMixerKit.outputDevices()
        if outputUIDs.isEmpty {
            return availableOutputs.filter(\.isDefault).prefix(1).map { $0 }
        }

        let requestedUIDs = Set(outputUIDs)
        let selected = availableOutputs.filter { requestedUIDs.contains($0.uid) }
        return selected.isEmpty ? availableOutputs.filter(\.isDefault).prefix(1).map { $0 } : selected
    }

    /// Resolves the device UIDs that `start(target:gain:outputUIDs:)` would
    /// route through right now for the given requested route (`[]` means
    /// "System Default"). Lets callers detect, without restarting the engine,
    /// whether a running engine's `activeOutputUIDs` still match what the
    /// requested route resolves to — e.g. after the default output device
    /// changes or a routed device is plugged/unplugged.
    static func resolvedOutputUIDs(forRequestedOutputUIDs outputUIDs: [String]) -> [String] {
        routedOutputDevices(outputUIDs: outputUIDs).map(\.uid)
    }

    private static func sourceOutputDevice() -> AppVolumeOutputDevice? {
        guard let defaultOutputID = AudioDeviceKit.defaultOutputDeviceID(),
              let uid = AudioDeviceKit.uid(for: defaultOutputID),
              !uid.isEmpty else {
            return nil
        }
        let name = AudioDeviceKit.outputDevices().first(where: { $0.id == defaultOutputID })?.name ?? "Default Output"
        return AppVolumeOutputDevice(
            deviceID: defaultOutputID,
            uid: uid,
            name: name,
            isDefault: true
        )
    }

    private static func firstOutputStreamIndex(for deviceID: AudioDeviceID) -> UInt? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else {
            return nil
        }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var streams = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &streams) == noErr else {
            return nil
        }
        for (index, streamID) in streams.enumerated() {
            var directionAddress = AudioObjectPropertyAddress(
                mSelector: kAudioStreamPropertyDirection,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var direction: UInt32 = 0
            var directionSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(streamID, &directionAddress, 0, nil, &directionSize, &direction) == noErr,
               direction == 0 {
                return UInt(index)
            }
        }
        return nil
    }

    private static func destroyAggregateDevice(_ aggregateID: AudioObjectID) {
        guard aggregateID != kAudioObjectUnknown else { return }
        AudioHardwareDestroyAggregateDevice(aggregateID)
    }

    // MARK: - Sample-rate reconciliation
    //
    // Thin forwarders to the shared `CoreAudioSampleRate` helper, kept so the
    // engine's call sites (and the existing test surface) stay unchanged.

    static func uniqued(_ ids: [AudioObjectID]) -> [AudioObjectID] {
        CoreAudioSampleRate.uniqued(ids)
    }

    static func nominalSampleRate(for deviceID: AudioObjectID) -> Double? {
        CoreAudioSampleRate.nominalSampleRate(for: deviceID)
    }

    static func availableNominalSampleRates(for deviceID: AudioObjectID) -> [Double] {
        CoreAudioSampleRate.availableNominalSampleRates(for: deviceID)
    }

    static func ratesFromRanges(_ ranges: [AudioValueRange]) -> [Double] {
        CoreAudioSampleRate.ratesFromRanges(ranges)
    }

    @discardableResult
    static func setNominalSampleRate(_ rate: Double, for deviceID: AudioObjectID) -> Bool {
        CoreAudioSampleRate.setNominalSampleRate(rate, for: deviceID)
    }

    static func chooseCommonSampleRate(
        preferred: Double?,
        deviceSupportedRates: [[Double]]
    ) -> Double? {
        CoreAudioSampleRate.chooseCommonSampleRate(
            preferred: preferred,
            deviceSupportedRates: deviceSupportedRates
        )
    }

    private static func stringProperty(
        _ selector: AudioObjectPropertySelector,
        for objectID: AudioObjectID
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr -> OSStatus in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else {
            throw AppVolumeMixerError.coreAudioStatus(status)
        }
        return value as String
    }

    /// Diagnostic-only render callback counter (used by `MixerDebug`).
    nonisolated(unsafe) private static var renderCallCount: UInt64 = 0

    private static let ioProc: AudioDeviceIOProc = { _, _, inputData, _, outputData, _, clientData in
        guard let clientData else {
            return noErr
        }
        let state = Unmanaged<RenderState>.fromOpaque(clientData).takeUnretainedValue()
        render(inputData: inputData, outputData: outputData, gain: state.renderGain())
        return noErr
    }

    static func render(
        inputData: UnsafePointer<AudioBufferList>,
        outputData: UnsafeMutablePointer<AudioBufferList>,
        gain: Float
    ) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        let outputs = UnsafeMutableAudioBufferListPointer(outputData)

        if MixerDebug.enabled {
            renderCallCount &+= 1
            // Log roughly once a second (callbacks fire ~100×/s) to show whether
            // the IOProc runs and whether the tap is actually delivering signal.
            if renderCallCount % 100 == 1 {
                let inBytes = inputs.first?.mDataByteSize ?? 0
                let peak = (inputs.first?.mData).map {
                    MixerDebug.peak($0, byteCount: Int(inBytes))
                } ?? 0
                let outBytes = outputs.first?.mDataByteSize ?? 0
                let inChannels = inputs.first?.mNumberChannels ?? 0
                let outChannels = outputs.first?.mNumberChannels ?? 0
                MixerDebug.log("render #\(renderCallCount) inputs=\(inputs.count) inBytes=\(inBytes) inCh=\(inChannels) peak=\(String(format: "%.3f", peak)) outputs=\(outputs.count) outBytes=\(outBytes) outCh=\(outChannels) gain=\(gain)")
            }
        }

        guard !inputs.isEmpty else {
            for outputIndex in 0..<outputs.count {
                let output = outputs[outputIndex]
                if let outputData = output.mData, output.mDataByteSize > 0 {
                    memset(outputData, 0, Int(output.mDataByteSize))
                }
                outputs[outputIndex] = output
            }
            return
        }

        for outputIndex in 0..<outputs.count {
            let input = inputs[min(outputIndex, inputs.count - 1)]
            var output = outputs[outputIndex]
            guard let inputData = input.mData,
                  let outputData = output.mData else {
                if let outputData = output.mData, output.mDataByteSize > 0 {
                    memset(outputData, 0, Int(output.mDataByteSize))
                }
                outputs[outputIndex] = output
                continue
            }
            let inChannels = Int(input.mNumberChannels)
            let outChannels = Int(output.mNumberChannels)
            let sampleSize = MemoryLayout<Float32>.size
            if inChannels != outChannels, inChannels > 0, outChannels > 0,
               Int(input.mDataByteSize).isMultiple(of: sampleSize * inChannels),
               Int(output.mDataByteSize).isMultiple(of: sampleSize * outChannels) {
                // The tap's frame layout (stereo mixdown) differs from this
                // output's (mono, 5.1, 7.1 HDMI/AVR…). A raw interleaved copy
                // would smear frames across channels — each speaker plays a
                // time-decimated burst of the wrong channel, which is heard as
                // quieter, garbled playback — so map per-frame instead.
                renderChannelMapped(
                    input: inputData, inChannels: inChannels, inBytes: Int(input.mDataByteSize),
                    output: &output, outputData: outputData, outChannels: outChannels,
                    gain: gain
                )
                outputs[outputIndex] = output
                continue
            }
            let byteCount = min(Int(input.mDataByteSize), Int(output.mDataByteSize))
            guard byteCount > 0 else {
                outputs[outputIndex] = output
                continue
            }
            if byteCount.isMultiple(of: MemoryLayout<Float32>.size) {
                let sampleCount = byteCount / MemoryLayout<Float32>.size
                let source = inputData.assumingMemoryBound(to: Float32.self)
                let destination = outputData.assumingMemoryBound(to: Float32.self)
                if gain <= .ulpOfOne {
                    memset(outputData, 0, byteCount)
                } else if abs(gain - 1) <= .ulpOfOne {
                    if UnsafeRawPointer(source) != UnsafeRawPointer(destination) {
                        memcpy(outputData, inputData, byteCount)
                    }
                } else {
                    var scalar = gain
                    vDSP_vsmul(source, 1, &scalar, destination, 1, vDSP_Length(sampleCount))
                }
                if Int(output.mDataByteSize) > byteCount {
                    memset(outputData.advanced(by: byteCount), 0, Int(output.mDataByteSize) - byteCount)
                }
                output.mDataByteSize = UInt32(byteCount)
            } else {
                memcpy(outputData, inputData, byteCount)
                if Int(output.mDataByteSize) > byteCount {
                    memset(outputData.advanced(by: byteCount), 0, Int(output.mDataByteSize) - byteCount)
                }
                output.mDataByteSize = UInt32(byteCount)
            }
            outputs[outputIndex] = output
        }
    }

    /// Frame-wise copy between interleaved float buffers with different channel
    /// counts: source channels land on the same-numbered output channels (mono
    /// fans out to both fronts), output channels with no source stay silent,
    /// and a mono output gets the average of the source's front pair.
    /// Runs on the realtime IO thread — strided vDSP only, no allocation.
    private static func renderChannelMapped(
        input inputData: UnsafeMutableRawPointer,
        inChannels: Int,
        inBytes: Int,
        output: inout AudioBuffer,
        outputData: UnsafeMutableRawPointer,
        outChannels: Int,
        gain: Float
    ) {
        let sampleSize = MemoryLayout<Float32>.size
        let frames = min(inBytes / (sampleSize * inChannels), Int(output.mDataByteSize) / (sampleSize * outChannels))
        let writtenBytes = frames * outChannels * sampleSize
        if frames > 0 {
            let source = inputData.assumingMemoryBound(to: Float32.self)
            let destination = outputData.assumingMemoryBound(to: Float32.self)
            if gain <= .ulpOfOne {
                memset(outputData, 0, writtenBytes)
            } else if outChannels == 1 {
                // inChannels >= 2 here (1 == 1 takes the matched-layout path).
                var scalar = gain * 0.5
                vDSP_vasm(
                    source, vDSP_Stride(inChannels),
                    source.advanced(by: 1), vDSP_Stride(inChannels),
                    &scalar,
                    destination, 1,
                    vDSP_Length(frames)
                )
            } else {
                // A mono source feeds both front channels; extra source
                // channels beyond the output's count are dropped.
                let fedChannels = min(outChannels, max(inChannels, 2))
                var scalar = gain
                for channel in 0..<fedChannels {
                    vDSP_vsmul(
                        source.advanced(by: min(channel, inChannels - 1)), vDSP_Stride(inChannels),
                        &scalar,
                        destination.advanced(by: channel), vDSP_Stride(outChannels),
                        vDSP_Length(frames)
                    )
                }
                for channel in fedChannels..<outChannels {
                    vDSP_vclr(
                        destination.advanced(by: channel), vDSP_Stride(outChannels),
                        vDSP_Length(frames)
                    )
                }
            }
        }
        if Int(output.mDataByteSize) > writtenBytes {
            memset(outputData.advanced(by: writtenBytes), 0, Int(output.mDataByteSize) - writtenBytes)
        }
        output.mDataByteSize = UInt32(writtenBytes)
    }
}

public enum AppVolumeMixerKit {
    private struct DiscoveredApp {
        let processID: pid_t
        let bundleIdentifier: String?
        let displayName: String
        var subprocesses: [AppVolumeSubprocess]
        var isRunningOutput: Bool
    }

    private struct ApplicationIdentity {
        let processID: pid_t
        let bundleIdentifier: String?
        let displayName: String
    }

    private typealias ResponsibilityFunc = @convention(c) (pid_t) -> pid_t

    private static let defaultIgnoredBundlePrefixes = [
        ("ai.elementlabs.lmstudio", "LM Studio"),
        ("com.adobe.Acrobat.Pro", "Acrobat"),
        ("com.adobe.acc.AdobeDesktopService", "Creative Cloud Core Service"),
        ("com.adobe.acc.AdobeCreativeCloud", "Creative Cloud"),
        ("com.adobe.accmac", "Adobe Content Synchronizer"),
        ("com.adobe.AdobeCRDaemon", "Adobe Crash Processor"),
        ("com.adobe.AdobeIPCBroker", "Creative Cloud Interprocess Service"),
        ("com.adobe.AdobeResourceSynchronizer", "Acrobat Collaboration Synchronizer"),
        ("com.adobe.ccd.helper", "Creative Cloud Helper"),
        ("com.adobe.CCXProcess", "Creative Cloud Content Manager"),
        ("com.anthropic.claudefordesktop", "Claude"),
        ("com.apple.AccessibilityUIServer", "Accessibility"),
        ("com.apple.accessibility", "Apple Accessibility Services"),
        ("com.apple.AppSSOAgent", "Single Sign-On"),
        ("com.apple.AquaAppearanceHelper", "AquaAppearanceHelper"),
        ("com.apple.assistant", "Siri and Assistant Services"),
        ("com.apple.audio", "Apple Audio Services"),
        ("com.apple.backgroundtaskmanagement.agent", "BackgroundTaskManagementAgent"),
        ("com.apple.controlcenter", "Control Center"),
        ("com.apple.coreaudio", "CoreAudio Services"),
        ("com.apple.corespeech", "Speech Services"),
        ("com.apple.CoreLocationAgent", "CoreLocationAgent"),
        ("com.apple.coreservices.uiagent", "CoreServicesUIAgent"),
        ("com.apple.finder", "Finder"),
        ("com.apple.iCal", "Calendar"),
        ("com.apple.loginwindow", "loginwindow"),
        ("com.apple.mediaremote", "Media Remote Services"),
        ("com.apple.nbagent", "nbagent"),
        ("com.apple.notificationcenter", "Notification Center"),
        ("com.apple.security.Keychain-Circle-Notification", "Keychain Circle Notification"),
        ("com.apple.siri", "Siri"),
        ("com.apple.Siri", "Siri"),
        ("com.apple.Spotlight", "Spotlight"),
        ("com.apple.storeuid", "storeuid"),
        ("com.apple.speech", "Speech Services"),
        ("com.apple.SoftwareUpdateNotificationManager", "Software Update Notification Manager"),
        ("com.apple.systemsound", "System Sounds"),
        ("com.apple.systempreferences", "System Settings"),
        ("com.apple.systemuiserver", "SystemUIServer"),
        ("com.apple.Terminal", "Terminal"),
        ("com.apple.TextInputMenuAgent", "TextInputMenuAgent"),
        ("com.apple.TextInputSwitcher", "TextInputSwitcher"),
        ("com.apple.UIKitSystemApp", "UIKitSystem"),
        ("com.apple.universalcontrol", "UniversalControl"),
        ("com.apple.UserNotifications", "User Notifications"),
        ("com.apple.wallpaper.agent", "Wallpaper"),
        ("com.apple.wifi.WiFiAgent", "Wi-Fi"),
        ("com.electron.ollama", "Ollama"),
        ("com.figma.agent", "FigmaAgent"),
        ("com.figma.Desktop", "Figma"),
        ("com.google.drivefs", "Google Drive"),
        ("com.havokentity.mactools", "DMonte"),
        ("com.jetbrains.cefserver", "cef_server"),
        ("com.jetbrains.rider", "JetBrains Rider"),
        ("com.jetbrains.toolbox", "JetBrains Toolbox"),
        ("com.logi.cp-dev-mgr", "Logi Options+"),
        ("com.logi.ghub", "Logitech G HUB"),
        ("com.logi.ghub.agent", "Logitech G HUB Agent"),
        ("com.logi.pluginservice", "LogiPluginService"),
        ("com.lwouis.alt-tab-macos", "AltTab"),
        ("com.openai.codex", "Codex"),
        ("com.openai.sky.CUAService", "Codex Computer Use"),
        ("com.parallels.toolbox", "Parallels Toolbox"),
        ("com.parallels.toolbox.BreakTime", "Break Time"),
        ("com.parallels.toolbox.ClipboardHistory", "Clipboard History"),
        ("com.parallels.toolbox.ConvertVideo", "Convert Video"),
        ("com.raycast.macos", "Raycast"),
        ("com.sluhai.copybox", "CopyBox"),
        ("com.tunabellysoftware.tgpro", "TG Pro"),
        ("com.unity3d.unityhub", "Unity Hub"),
        ("de.bahoom.FinderPath", "FinderPath"),
        ("org.friendlyventures.BentoBox", "BentoBox"),
        ("org.pqrs.Karabiner-Core-Service", "Karabiner-Core-Service"),
        ("org.pqrs.Karabiner-Menu", "Karabiner-Menu"),
        ("org.pqrs.Karabiner-NotificationWindow", "Karabiner-NotificationWindow")
    ]

    private static let smartPinBundlePrefixes = [
        "app.zen-browser.zen",
        "com.apple.Music",
        "com.apple.QuickTimePlayerX",
        "com.apple.Safari",
        "com.apple.TV",
        "com.brave.Browser",
        "com.colliderli.iina",
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "com.operasoftware.Opera",
        "com.spotify.client",
        "com.tidal.desktop",
        "com.valvesoftware.steam",
        "com.vivaldi.Vivaldi",
        "company.thebrowser.Browser",
        "org.mozilla.firefox",
        "org.videolan.vlc",
        "tv.plex.desktop"
    ]

    private static let smartPinNameTokens = [
        "arc",
        "brave",
        "chrome",
        "edge",
        "firefox",
        "iina",
        "music",
        "opera",
        "plex",
        "quicktime",
        "safari",
        "spotify",
        "steam",
        "tidal",
        "vivaldi",
        "vlc",
        "zen"
    ]

    private static let displayNameBundleRenames = [
        ("com.valvesoftware.steam", "Steam")
    ]

    private static let displayNamePrefixRenames = [
        ("steam helper", "Steam"),
        ("steamwebhelper", "Steam"),
        ("steam helper renderer", "Steam"),
        ("steam helper gpu", "Steam"),
        ("steam helper plugin", "Steam")
    ]

    private static let defaultIgnoredNamePrefixes = [
        ("audiomxd", "Audio Mixer Daemon"),
        ("coreaudiod", "CoreAudio Daemon"),
        ("corespeech", "Speech Services"),
        ("dictationd", "Dictation"),
        ("speechrecognitiond", "Speech Recognition"),
        ("systemsoundserv", "System Sound Server"),
        ("systemsoundserverd", "System Sound Server")
    ]

    public static func engineState() -> AppVolumeMixerEngineState {
        if #available(macOS 14.2, *) {
            return hasAudioCaptureUsageDescription ? .available : .needsAudioCapturePermission
        }
        return .unsupportedOS
    }

    @MainActor
    public static func targets() -> [AppVolumeTarget] {
        targets(defaults: AppDefaults.shared)
    }

    public static func targets(
        defaults: UserDefaults,
        hideIgnoredApps: Bool? = nil,
        smartFilter: Bool? = nil
    ) -> [AppVolumeTarget] {
        let gains = persistedGains(defaults: defaults)
        let pinnedApps = persistedPinnedApps(defaults: defaults)
        let localIgnoredApps = persistedIgnoredApps(defaults: defaults)
        let includedDefaultIgnoredAppIDs = persistedIncludedDefaultIgnoredAppIDs(defaults: defaults)
        let shouldHideIgnoredApps = hideIgnoredApps ?? defaults.object(forKey: DefaultsKey.volumeMixerHideIgnoredApps) as? Bool ?? true
        let shouldUseSmartFilter = smartFilter ?? defaults.object(forKey: DefaultsKey.volumeMixerSmartFilter) as? Bool ?? true
        let appsByPID = Dictionary(
            NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        let activeTargets = activeTargets(
            gains: gains,
            pinnedApps: pinnedApps,
            appsByPID: appsByPID
        )
        let activeKeys = Set(activeTargets.map(\.stableKey))
        let runningInactiveTargets = runningInactiveTargets(
            gains: gains,
            pinnedApps: pinnedApps,
            activeKeys: activeKeys,
            appsByPID: appsByPID
        )
        let runningInactiveKeys = Set(runningInactiveTargets.map(\.stableKey))
        let pinnedInactiveTargets = pinnedApps.values
            .filter {
                !activeKeys.contains($0.persistenceIdentifier)
                    && !runningInactiveKeys.contains($0.persistenceIdentifier)
            }
            .map { info in
                AppVolumeTarget(
                    processID: 0,
                    audioObjectIDs: [],
                    bundleIdentifier: info.bundleIdentifier,
                    displayName: info.displayName,
                    isActive: false,
                    isRunningOutput: false,
                    isPinned: true,
                    isIgnored: false,
                    isLocallyIgnored: false,
                    isDefaultIgnored: false,
                    gain: gains[info.persistenceIdentifier] ?? 1
                )
            }

        let playingActive = activeTargets
            .filter(\.isRunningOutput)
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        let pinnedIdleActive = activeTargets
            .filter { $0.isPinned && !$0.isRunningOutput }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        let pinnedInactive = (runningInactiveTargets.filter(\.isPinned) + pinnedInactiveTargets)
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        let unpinnedIdleActive = activeTargets
            .filter { !$0.isPinned && !$0.isRunningOutput }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        let unpinnedInactive = runningInactiveTargets
            .filter { !$0.isPinned }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        let allTargets = playingActive + pinnedIdleActive + pinnedInactive + unpinnedIdleActive + unpinnedInactive
        let annotatedTargets = allTargets.map {
            targetWithIgnoreState(
                $0,
                localIgnoredApps: localIgnoredApps,
                includedDefaultIgnoredAppIDs: includedDefaultIgnoredAppIDs,
                smartFilter: shouldUseSmartFilter
            )
        }
        guard shouldHideIgnoredApps else { return annotatedTargets }
        return annotatedTargets.filter { !$0.isIgnored }
    }

    public static func isSmartPinCandidate(_ target: AppVolumeTarget) -> Bool {
        if let bundleIdentifier = target.bundleIdentifier,
           smartPinBundlePrefixes.contains(where: { bundleIdentifier.hasPrefix($0) }) {
            return true
        }

        let displayName = target.displayName.lowercased()
        return smartPinNameTokens.contains { displayName.contains($0) }
    }

    public static func outputDevices() -> [AppVolumeOutputDevice] {
        let defaultOutputID = AudioDeviceKit.defaultOutputDeviceID()
        return AudioDeviceKit.outputDevices()
            .compactMap { device in
                guard let uid = AudioDeviceKit.uid(for: device.id), !uid.isEmpty else { return nil }
                return AppVolumeOutputDevice(
                    deviceID: device.id,
                    uid: uid,
                    name: device.name,
                    isDefault: device.id == defaultOutputID
                )
            }
            .sorted { lhs, rhs in
                if lhs.isDefault != rhs.isDefault {
                    return lhs.isDefault
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    public static func masterVolumeState() -> AppVolumeMasterVolumeState {
        guard let defaultOutputID = AudioDeviceKit.defaultOutputDeviceID() else {
            return AppVolumeMasterVolumeState(deviceName: "No Output Device")
        }

        let deviceName = AudioDeviceKit.outputDevices().first { $0.id == defaultOutputID }?.name ?? "Default Output"
        let volume = AudioDeviceKit.volume(for: defaultOutputID)
        let isMuted = AudioDeviceKit.isMuted(defaultOutputID)
        return AppVolumeMasterVolumeState(
            deviceID: defaultOutputID,
            deviceName: deviceName,
            volume: volume ?? 0,
            volumeSupported: volume != nil,
            isMuted: isMuted ?? false,
            muteSupported: isMuted != nil
        )
    }

    private static func activeTargets(
        gains: [String: Float],
        pinnedApps: [String: AppVolumePinnedAppInfo],
        appsByPID: [pid_t: NSRunningApplication]
    ) -> [AppVolumeTarget] {
        let myPID = ProcessInfo.processInfo.processIdentifier
        var discoveredByKey: [String: DiscoveredApp] = [:]

        for audioObjectID in processObjectIDs() {
            guard let pid = processID(for: audioObjectID), pid != myPID else { continue }
            let isRunning = boolProperty(kAudioProcessPropertyIsRunning, for: audioObjectID) ?? false
            guard isRunning else { continue }

            let directApp = appsByPID[pid]
            let resolvedApp = responsibleApp(for: pid, appsByPID: appsByPID) ?? directApp
            let identity = applicationIdentity(
                for: resolvedApp,
                fallbackPID: pid,
                fallbackBundleID: processBundleID(for: audioObjectID),
                appsByPID: appsByPID
            )

            let parentPID = identity.processID
            let bundleID = identity.bundleIdentifier
            let displayName = identity.displayName

            let isRunningOutput = boolProperty(kAudioProcessPropertyIsRunningOutput, for: audioObjectID) ?? false
            let subprocessBundleID = processBundleID(for: audioObjectID) ?? directApp?.bundleIdentifier
            let subprocessName = subprocessDisplayName(
                for: pid,
                audioObjectID: audioObjectID,
                bundleID: subprocessBundleID,
                runningApp: directApp
            )
            let subprocess = AppVolumeSubprocess(
                processID: pid,
                audioObjectID: audioObjectID,
                bundleIdentifier: subprocessBundleID,
                displayName: subprocessName,
                isRunningOutput: isRunningOutput
            )
            let key = AppVolumeTarget.stableKey(
                processID: parentPID,
                bundleIdentifier: bundleID,
                displayName: displayName
            )

            if var existing = discoveredByKey[key] {
                if !existing.subprocesses.contains(where: { $0.audioObjectID == audioObjectID }) {
                    existing.subprocesses.append(subprocess)
                    existing.subprocesses.sort { $0.audioObjectID < $1.audioObjectID }
                }
                existing.isRunningOutput = existing.isRunningOutput || isRunningOutput
                discoveredByKey[key] = existing
            } else {
                discoveredByKey[key] = DiscoveredApp(
                    processID: parentPID,
                    bundleIdentifier: bundleID,
                    displayName: displayName,
                    subprocesses: [subprocess],
                    isRunningOutput: isRunningOutput
                )
            }
        }

        return discoveredByKey.map { key, app in
            AppVolumeTarget(
                processID: app.processID,
                audioObjectIDs: app.subprocesses.map(\.audioObjectID),
                subprocesses: app.subprocesses,
                bundleIdentifier: app.bundleIdentifier,
                displayName: app.displayName,
                isActive: true,
                isRunningOutput: app.isRunningOutput,
                isPinned: pinnedApps[key] != nil,
                gain: gains[key] ?? 1
            )
        }
    }

    private static func runningInactiveTargets(
        gains: [String: Float],
        pinnedApps: [String: AppVolumePinnedAppInfo],
        activeKeys: Set<String>,
        appsByPID: [pid_t: NSRunningApplication]
    ) -> [AppVolumeTarget] {
        let myPID = ProcessInfo.processInfo.processIdentifier
        var targetsByKey: [String: AppVolumeTarget] = [:]

        for app in appsByPID.values {
            guard app.processIdentifier != myPID,
                  app.bundleURL?.pathExtension == "app" else {
                continue
            }

            let identity = applicationIdentity(
                for: app,
                fallbackPID: app.processIdentifier,
                fallbackBundleID: app.bundleIdentifier,
                appsByPID: appsByPID
            )

            let key = AppVolumeTarget.stableKey(
                processID: identity.processID,
                bundleIdentifier: identity.bundleIdentifier,
                displayName: identity.displayName
            )
            guard !activeKeys.contains(key), targetsByKey[key] == nil else { continue }

            targetsByKey[key] = AppVolumeTarget(
                processID: identity.processID,
                audioObjectIDs: [],
                bundleIdentifier: identity.bundleIdentifier,
                displayName: identity.displayName,
                isActive: false,
                isRunningOutput: false,
                isPinned: pinnedApps[key] != nil,
                gain: gains[key] ?? 1
            )
        }

        return Array(targetsByKey.values)
    }

    @MainActor
    public static func gain(for target: AppVolumeTarget) -> Float {
        gain(for: target, defaults: AppDefaults.shared)
    }

    public static func gain(for target: AppVolumeTarget, defaults: UserDefaults) -> Float {
        persistedGains(defaults: defaults)[target.stableKey] ?? 1
    }

    @MainActor
    public static func setGain(_ gain: Float, for target: AppVolumeTarget) {
        setGain(gain, for: target, defaults: AppDefaults.shared)
    }

    public static func setGain(
        _ gain: Float,
        for target: AppVolumeTarget,
        defaults: UserDefaults
    ) {
        var gains = persistedGains(defaults: defaults)
        gains[target.stableKey] = AppVolumeTarget.clampGain(gain)
        defaults.set(gains, forKey: DefaultsKey.volumeMixerAppVolumeGains)
    }

    public static func setGains(
        _ updates: [String: Float],
        defaults: UserDefaults
    ) {
        guard !updates.isEmpty else { return }
        var gains = persistedGains(defaults: defaults)
        for (key, gain) in updates {
            gains[key] = AppVolumeTarget.clampGain(gain)
        }
        defaults.set(gains, forKey: DefaultsKey.volumeMixerAppVolumeGains)
    }

    @MainActor
    public static func outputRouteUIDs(for target: AppVolumeTarget) -> [String] {
        outputRouteUIDs(for: target, defaults: AppDefaults.shared)
    }

    public static func outputRouteUIDs(for target: AppVolumeTarget, defaults: UserDefaults) -> [String] {
        persistedOutputRoutes(defaults: defaults)[target.stableKey] ?? []
    }

    @MainActor
    public static func setOutputRouteUIDs(_ outputUIDs: [String], for target: AppVolumeTarget) {
        setOutputRouteUIDs(outputUIDs, for: target, defaults: AppDefaults.shared)
    }

    public static func setOutputRouteUIDs(
        _ outputUIDs: [String],
        for target: AppVolumeTarget,
        defaults: UserDefaults
    ) {
        var routes = persistedOutputRoutes(defaults: defaults)
        let cleanedUIDs = Array(NSOrderedSet(array: outputUIDs).compactMap { $0 as? String })
        if cleanedUIDs.isEmpty {
            routes.removeValue(forKey: target.stableKey)
        } else {
            routes[target.stableKey] = cleanedUIDs
        }
        defaults.set(routes, forKey: DefaultsKey.volumeMixerOutputRoutes)
    }

    public static func persistedOutputRoutes(defaults: UserDefaults) -> [String: [String]] {
        defaults.dictionary(forKey: DefaultsKey.volumeMixerOutputRoutes) as? [String: [String]] ?? [:]
    }

    @MainActor
    public static func ignore(_ target: AppVolumeTarget) {
        ignore(target, defaults: AppDefaults.shared)
    }

    public static func ignore(_ target: AppVolumeTarget, defaults: UserDefaults) {
        var ignoredApps = persistedIgnoredApps(defaults: defaults)
        ignoredApps[target.stableKey] = AppVolumeIgnoredAppInfo(target: target)
        persistIgnoredApps(ignoredApps, defaults: defaults)
    }

    @MainActor
    public static func unignore(identifier: String) {
        unignore(identifier: identifier, defaults: AppDefaults.shared)
    }

    public static func unignore(identifier: String, defaults: UserDefaults) {
        var ignoredApps = persistedIgnoredApps(defaults: defaults)
        ignoredApps.removeValue(forKey: identifier)
        persistIgnoredApps(ignoredApps, defaults: defaults)
    }

    @MainActor
    public static func clearIgnoredApps() {
        clearIgnoredApps(defaults: AppDefaults.shared)
    }

    public static func clearIgnoredApps(defaults: UserDefaults) {
        persistIgnoredApps([:], defaults: defaults)
    }

    @MainActor
    public static func includeDefaultIgnoredApp(identifier: String) {
        includeDefaultIgnoredApp(identifier: identifier, defaults: AppDefaults.shared)
    }

    public static func includeDefaultIgnoredApp(identifier: String, defaults: UserDefaults) {
        var identifiers = persistedIncludedDefaultIgnoredAppIDs(defaults: defaults)
        identifiers.insert(identifier)
        persistIncludedDefaultIgnoredAppIDs(identifiers, defaults: defaults)
    }

    @MainActor
    public static func restoreDefaultIgnoredApp(identifier: String) {
        restoreDefaultIgnoredApp(identifier: identifier, defaults: AppDefaults.shared)
    }

    public static func restoreDefaultIgnoredApp(identifier: String, defaults: UserDefaults) {
        var identifiers = persistedIncludedDefaultIgnoredAppIDs(defaults: defaults)
        identifiers.remove(identifier)
        persistIncludedDefaultIgnoredAppIDs(identifiers, defaults: defaults)
    }

    @MainActor
    public static func clearDefaultIgnoredAppOverrides() {
        clearDefaultIgnoredAppOverrides(defaults: AppDefaults.shared)
    }

    public static func clearDefaultIgnoredAppOverrides(defaults: UserDefaults) {
        persistIncludedDefaultIgnoredAppIDs([], defaults: defaults)
    }

    public static func ignoredApps(
        defaults: UserDefaults,
        smartFilter: Bool
    ) -> [AppVolumeIgnoredAppInfo] {
        let local = Array(persistedIgnoredApps(defaults: defaults).values)
        let includedDefaultIgnoredAppIDs = persistedIncludedDefaultIgnoredAppIDs(defaults: defaults)
        let defaultsList: [AppVolumeIgnoredAppInfo] = smartFilter ? defaultIgnoredApps().map { info in
            guard includedDefaultIgnoredAppIDs.contains(info.id) else { return info }
            return AppVolumeIgnoredAppInfo(
                persistenceIdentifier: info.persistenceIdentifier,
                bundleIdentifier: info.bundleIdentifier,
                displayName: info.displayName,
                source: .shippedDefaultDisabled
            )
        } : []
        return (defaultsList + local)
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    public static func persistedIgnoredApps(defaults: UserDefaults) -> [String: AppVolumeIgnoredAppInfo] {
        guard let data = defaults.data(forKey: DefaultsKey.volumeMixerIgnoredApps),
              let decoded = try? JSONDecoder().decode([String: AppVolumeIgnoredAppInfo].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func persistIgnoredApps(
        _ ignoredApps: [String: AppVolumeIgnoredAppInfo],
        defaults: UserDefaults
    ) {
        if let data = try? JSONEncoder().encode(ignoredApps) {
            defaults.set(data, forKey: DefaultsKey.volumeMixerIgnoredApps)
        }
    }

    public static func persistedIncludedDefaultIgnoredAppIDs(defaults: UserDefaults) -> Set<String> {
        Set(defaults.stringArray(forKey: DefaultsKey.volumeMixerIncludedDefaultIgnoredApps) ?? [])
    }

    private static func persistIncludedDefaultIgnoredAppIDs(
        _ identifiers: Set<String>,
        defaults: UserDefaults
    ) {
        defaults.set(identifiers.sorted(), forKey: DefaultsKey.volumeMixerIncludedDefaultIgnoredApps)
    }

    @MainActor
    public static func pin(_ target: AppVolumeTarget) {
        pin(target, defaults: AppDefaults.shared)
    }

    public static func pin(_ target: AppVolumeTarget, defaults: UserDefaults) {
        var pinnedApps = persistedPinnedApps(defaults: defaults)
        pinnedApps[target.stableKey] = AppVolumePinnedAppInfo(target: target)
        persistPinnedApps(pinnedApps, defaults: defaults)
    }

    @MainActor
    public static func unpin(_ target: AppVolumeTarget) {
        unpin(identifier: target.stableKey, defaults: AppDefaults.shared)
    }

    @MainActor
    public static func unpin(identifier: String) {
        unpin(identifier: identifier, defaults: AppDefaults.shared)
    }

    public static func unpin(identifier: String, defaults: UserDefaults) {
        var pinnedApps = persistedPinnedApps(defaults: defaults)
        pinnedApps.removeValue(forKey: identifier)
        persistPinnedApps(pinnedApps, defaults: defaults)
    }

    public static func persistedPinnedApps(defaults: UserDefaults) -> [String: AppVolumePinnedAppInfo] {
        guard let data = defaults.data(forKey: DefaultsKey.volumeMixerPinnedApps),
              let decoded = try? JSONDecoder().decode([String: AppVolumePinnedAppInfo].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func persistPinnedApps(
        _ pinnedApps: [String: AppVolumePinnedAppInfo],
        defaults: UserDefaults
    ) {
        if let data = try? JSONEncoder().encode(pinnedApps) {
            defaults.set(data, forKey: DefaultsKey.volumeMixerPinnedApps)
        }
    }

    @MainActor
    public static func persistedGains() -> [String: Float] {
        persistedGains(defaults: AppDefaults.shared)
    }

    public static func persistedGains(defaults: UserDefaults) -> [String: Float] {
        guard let raw = defaults.dictionary(forKey: DefaultsKey.volumeMixerAppVolumeGains) else {
            return [:]
        }
        var gains: [String: Float] = [:]
        for (key, value) in raw {
            if let number = value as? NSNumber {
                gains[key] = AppVolumeTarget.clampGain(number.floatValue)
            } else if let float = value as? Float {
                gains[key] = AppVolumeTarget.clampGain(float)
            } else if let double = value as? Double {
                gains[key] = AppVolumeTarget.clampGain(Float(double))
            }
        }
        return gains
    }

    private static func targetWithIgnoreState(
        _ target: AppVolumeTarget,
        localIgnoredApps: [String: AppVolumeIgnoredAppInfo],
        includedDefaultIgnoredAppIDs: Set<String>,
        smartFilter: Bool
    ) -> AppVolumeTarget {
        let isLocallyIgnored = localIgnoredApps[target.stableKey] != nil
        let defaultIgnoredInfo = defaultIgnoredInfo(for: target)
        let defaultIgnored = smartFilter
            && defaultIgnoredInfo != nil
            && !includedDefaultIgnoredAppIDs.contains(defaultIgnoredInfo?.id ?? "")
        return AppVolumeTarget(
            processID: target.processID,
            audioObjectIDs: target.audioObjectIDs,
            subprocesses: target.subprocesses,
            bundleIdentifier: target.bundleIdentifier,
            displayName: target.displayName,
            isActive: target.isActive,
            isRunningOutput: target.isRunningOutput,
            isPinned: target.isPinned,
            isIgnored: isLocallyIgnored || defaultIgnored,
            isLocallyIgnored: isLocallyIgnored,
            isDefaultIgnored: defaultIgnored,
            gain: target.gain
        )
    }

    private static func defaultIgnoredApps() -> [AppVolumeIgnoredAppInfo] {
        let bundleEntries = defaultIgnoredBundlePrefixes.map { prefix, displayName in
            AppVolumeIgnoredAppInfo(
                persistenceIdentifier: "prefix:\(prefix)",
                bundleIdentifier: prefix,
                displayName: displayName,
                source: .shippedDefault
            )
        }
        let nameEntries = defaultIgnoredNamePrefixes.map { name, displayName in
            AppVolumeIgnoredAppInfo(
                persistenceIdentifier: "name-prefix:\(name)",
                bundleIdentifier: nil,
                displayName: displayName,
                source: .shippedDefault
            )
        }
        return bundleEntries + nameEntries
    }

    private static func defaultIgnoredInfo(for target: AppVolumeTarget) -> AppVolumeIgnoredAppInfo? {
        if let bundleID = target.bundleIdentifier {
            if let match = defaultIgnoredBundlePrefixes.first(where: { bundleID.hasPrefix($0.0) }) {
                return AppVolumeIgnoredAppInfo(
                    persistenceIdentifier: "prefix:\(match.0)",
                    bundleIdentifier: match.0,
                    displayName: match.1,
                    source: .shippedDefault
                )
            }
        }

        let lowercasedName = target.displayName.lowercased()
        if let match = defaultIgnoredNamePrefixes.first(where: { lowercasedName.hasPrefix($0.0) }) {
            return AppVolumeIgnoredAppInfo(
                persistenceIdentifier: "name-prefix:\(match.0)",
                bundleIdentifier: nil,
                displayName: match.1,
                source: .shippedDefault
            )
        }
        return nil
    }

    @available(macOS 14.2, *)
    public static func createPrivateTap(for target: AppVolumeTarget) throws -> AudioObjectID {
        guard !target.audioObjectIDs.isEmpty else {
            throw AppVolumeMixerError.noActiveAppAudio
        }
        let description = CATapDescription(stereoMixdownOfProcesses: target.audioObjectIDs)
        description.name = "DMonte \(target.displayName)"
        description.uuid = UUID()
        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else {
            throw AppVolumeMixerError.coreAudioStatus(status)
        }
        return tapID
    }

    @available(macOS 14.2, *)
    public static func destroyTap(_ tapID: AudioObjectID) {
        guard tapID != kAudioObjectUnknown else { return }
        AudioHardwareDestroyProcessTap(tapID)
    }

    private static var hasAudioCaptureUsageDescription: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSAudioCaptureUsageDescription") as? String != nil
    }

    private static func applicationIdentity(
        for runningApp: NSRunningApplication?,
        fallbackPID: pid_t,
        fallbackBundleID: String?,
        appsByPID: [pid_t: NSRunningApplication]
    ) -> ApplicationIdentity {
        guard let runningApp else {
            let displayName = fallbackBundleID?.isEmpty == false ? fallbackBundleID! : "Process \(fallbackPID)"
            return ApplicationIdentity(
                processID: fallbackPID,
                bundleIdentifier: fallbackBundleID,
                displayName: displayName
            )
        }

        let outerURL = runningApp.bundleURL.flatMap(outerApplicationURL(containing:))
        let outerRunningApp = outerURL.flatMap { outerURL in
            appsByPID.values.first { app in
                guard let bundleURL = app.bundleURL else { return false }
                return bundleURL.standardizedFileURL == outerURL.standardizedFileURL
            }
        }
        let bundle = outerURL.flatMap(Bundle.init(url:))
        let bundleID = outerRunningApp?.bundleIdentifier
            ?? bundle?.bundleIdentifier
            ?? runningApp.bundleIdentifier
            ?? fallbackBundleID
        let displayName = outerRunningApp?.localizedName
            ?? bundleDisplayName(bundle: bundle, fallbackURL: outerURL)
            ?? displayName(
                for: outerRunningApp?.processIdentifier ?? runningApp.processIdentifier,
                bundleID: bundleID,
                runningApp: runningApp
            )
        return ApplicationIdentity(
            processID: outerRunningApp?.processIdentifier ?? runningApp.processIdentifier,
            bundleIdentifier: bundleID,
            displayName: normalizedDisplayName(displayName, bundleID: bundleID)
        )
    }

    private static func outerApplicationURL(containing url: URL) -> URL {
        let standardizedURL = url.standardizedFileURL
        let components = standardizedURL.pathComponents
        guard let appIndex = components.firstIndex(where: { $0.hasSuffix(".app") }) else {
            return standardizedURL
        }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(components.prefix(appIndex + 1))))
    }

    private static func bundleDisplayName(bundle: Bundle?, fallbackURL: URL?) -> String? {
        if let displayName = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
           !displayName.isEmpty {
            return displayName
        }
        if let name = bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String,
           !name.isEmpty {
            return name
        }
        return fallbackURL?.deletingPathExtension().lastPathComponent
    }

    private static func displayName(
        for pid: pid_t,
        bundleID: String?,
        runningApp: NSRunningApplication?
    ) -> String {
        if let name = runningApp?.localizedName, !name.isEmpty {
            return normalizedDisplayName(name, bundleID: bundleID)
        }
        if let bundleID, !bundleID.isEmpty {
            return normalizedDisplayName(bundleID, bundleID: bundleID)
        }
        return "Process \(pid)"
    }

    private static func subprocessDisplayName(
        for pid: pid_t,
        audioObjectID: AudioObjectID,
        bundleID: String?,
        runningApp: NSRunningApplication?
    ) -> String {
        if let name = runningApp?.localizedName, !name.isEmpty {
            return normalizedDisplayName(name, bundleID: bundleID)
        }
        if let bundleID, !bundleID.isEmpty {
            return normalizedDisplayName(
                bundleID.components(separatedBy: ".").suffix(2).joined(separator: "."),
                bundleID: bundleID
            )
        }
        return "Audio object \(audioObjectID) · pid \(pid)"
    }

    private static func normalizedDisplayName(_ displayName: String, bundleID: String?) -> String {
        if let bundleID,
           let match = displayNameBundleRenames.first(where: { bundleID.hasPrefix($0.0) }) {
            return match.1
        }

        let lowercasedName = displayName.lowercased()
        if let match = displayNamePrefixRenames.first(where: { lowercasedName.hasPrefix($0.0) }) {
            return match.1
        }

        let helperTrimmedName = displayName
            .replacingOccurrences(of: "\\b[Hh]elper\\b", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return helperTrimmedName.isEmpty ? displayName : helperTrimmedName
    }

    private static func responsibleApp(
        for pid: pid_t,
        appsByPID: [pid_t: NSRunningApplication]
    ) -> NSRunningApplication? {
        if let responsiblePID = responsiblePID(for: pid),
           let app = appsByPID[responsiblePID],
           app.bundleURL?.pathExtension == "app" {
            return app
        }

        var currentPID = pid
        var visited = Set<pid_t>()
        while currentPID > 1, !visited.contains(currentPID) {
            visited.insert(currentPID)
            if let app = appsByPID[currentPID],
               app.bundleURL?.pathExtension == "app" {
                return app
            }
            guard let parentPID = parentPID(for: currentPID), parentPID != currentPID else {
                break
            }
            currentPID = parentPID
        }
        return nil
    }

    private static func responsiblePID(for pid: pid_t) -> pid_t? {
        let handle = UnsafeMutableRawPointer(bitPattern: -2)
        guard let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        let function = unsafeBitCast(symbol, to: ResponsibilityFunc.self)
        let responsiblePID = function(pid)
        return responsiblePID > 0 && responsiblePID != pid ? responsiblePID : nil
    }

    private static func parentPID(for pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else {
            return nil
        }
        return info.kp_eproc.e_ppid
    }

    private static func isSystemDaemon(bundleID: String?, name: String) -> Bool {
        let systemBundlePrefixes = [
            "com.apple.siri",
            "com.apple.Siri",
            "com.apple.assistant",
            "com.apple.audio",
            "com.apple.coreaudio",
            "com.apple.mediaremote",
            "com.apple.notificationcenter",
            "com.apple.NotificationCenter",
            "com.apple.UserNotifications",
            "com.apple.speech",
            "com.apple.corespeech",
            "com.apple.CoreSpeech"
        ]
        if let bundleID,
           systemBundlePrefixes.contains(where: { bundleID.hasPrefix($0) }) {
            return true
        }

        let systemNames = [
            "systemsoundserverd",
            "systemsoundserv",
            "coreaudiod",
            "audiomxd",
            "speechrecognitiond",
            "dictationd",
            "corespeech"
        ]
        let lowercasedName = name.lowercased()
        return systemNames.contains { lowercasedName.hasPrefix($0) }
    }

    private static func processObjectIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else {
            return []
        }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var ids = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        let status = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &dataSize, &ids)
        guard status == noErr else { return [] }
        return ids.filter { $0 != kAudioObjectUnknown }
    }

    private static func processID(for audioObjectID: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(audioObjectID, &address) else { return nil }
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(audioObjectID, &address, 0, nil, &size, &pid)
        guard status == noErr, pid > 0 else { return nil }
        return pid
    }

    private static func processBundleID(for audioObjectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(audioObjectID, &address) else { return nil }
        var bundleID: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &bundleID) { ptr -> OSStatus in
            AudioObjectGetPropertyData(audioObjectID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        let result = bundleID as String
        return result.isEmpty ? nil : result
    }

    private static func boolProperty(
        _ selector: AudioObjectPropertySelector,
        for audioObjectID: AudioObjectID
    ) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(audioObjectID, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(audioObjectID, &address, 0, nil, &size, &value)
        guard status == noErr else { return nil }
        return value != 0
    }
}

public enum AppVolumeMixerError: Error, Equatable, Sendable {
    case coreAudioStatus(OSStatus)
    case noDefaultOutputDevice
    case noActiveAppAudio
    case noRoutableSourceOutput
    case incompatibleOutputSampleRate
    case unsupportedOS

    public var message: String {
        switch self {
        case .coreAudioStatus(let status):
            return "CoreAudio error \(status)"
        case .noDefaultOutputDevice:
            return "No default output device"
        case .noActiveAppAudio:
            return "Open the app or play audio before starting processing"
        case .noRoutableSourceOutput:
            return "Cannot route this app from the current output device"
        case .incompatibleOutputSampleRate:
            return "This output (e.g. an HDMI TV) shares no sample rate with your other devices, so it can’t be routed"
        case .unsupportedOS:
            return "Requires macOS 14.2 or newer"
        }
    }
}
