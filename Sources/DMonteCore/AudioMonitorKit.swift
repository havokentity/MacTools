import Accelerate
import AVFoundation
import CoreAudio
import Foundation
import os.lock

/// Microphone authorization gate for input monitoring. Capturing a hardware
/// input device is treated by macOS as microphone use, so the first monitor
/// must obtain consent.
public enum AudioMonitorPermission {
    /// Whether the running binary declares a microphone usage string. Without it,
    /// any audio-input access aborts the process via TCC, so input monitoring is
    /// unavailable (notably in `swift run` builds — use the packaged app).
    public static var hasUsageDescription: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil
    }

    /// Resolves to `true` when the app may capture audio input, prompting once
    /// if permission has not yet been decided.
    public static func ensureMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            // macOS aborts the process (TCC SIGABRT) the moment it accesses the
            // microphone — via `requestAccess` OR the actual CoreAudio capture —
            // if the running binary has no `NSMicrophoneUsageDescription`. That
            // key only exists in the packaged Info.plist, not in a `swift run`
            // build, so refuse rather than crash when it's absent.
            guard hasUsageDescription else { return false }
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
        default:
            return false
        }
    }
}

/// Opt-in diagnostics for the input monitor. Enable with
/// `DMONTE_MONITOR_DEBUG=1 swift run DMonteAudioRouter`; messages go to stderr.
enum MonitorDebug {
    static let enabled: Bool = ProcessInfo.processInfo.environment["DMONTE_MONITOR_DEBUG"] == "1"

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        FileHandle.standardError.write(Data(("‹monitor› " + message() + "\n").utf8))
    }
}

/// Why an input monitor could not be started.
public enum AudioMonitorError: Error, Equatable, Sendable {
    /// The input or output device UID no longer resolves to a live device.
    case deviceUnavailable
    /// The chosen input and output share no common sample rate.
    case incompatibleSampleRate
    /// CoreAudio rejected the operation with this status code.
    case coreAudio(OSStatus)

    public var message: String {
        switch self {
        case .deviceUnavailable:
            return "That input or output device is no longer available"
        case .incompatibleSampleRate:
            return "The input and output share no common sample rate"
        case .coreAudio(let status):
            return "CoreAudio error \(status)"
        }
    }
}

/// Process-wide ownership of the nominal sample rates monitors force on their
/// devices. Each monitor's render loop is a raw sample copy that assumes its
/// devices stay at the rate chosen when it started, so a device another monitor
/// is already driving must not be retuned: `pinnedRate` reports that rate as a
/// hard constraint on the next monitor's rate choice, and a device's original
/// rate is put back only once the last monitor using it stops.
final class MonitorSampleRateRegistry: @unchecked Sendable {
    static let shared = MonitorSampleRateRegistry()

    private struct Entry {
        /// The rate live monitors require this device to stay at.
        let rate: Double
        /// The rate to put back when the last monitor releases the device; `nil`
        /// when the device already ran at `rate` and nothing was changed.
        let originalRate: Double?
        var count: Int
    }

    private let lock = NSLock()
    private var entries: [AudioObjectID: Entry] = [:]

    /// The rate a live monitor is already holding `deviceID` at, if any.
    func pinnedRate(for deviceID: AudioObjectID) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return entries[deviceID]?.rate
    }

    /// Claims `deviceIDs` at `rate` for one monitor, retuning only those no other
    /// monitor already holds. Balance every call with `release`.
    func acquire(deviceIDs: [AudioObjectID], rate: Double) {
        lock.lock()
        defer { lock.unlock() }
        for deviceID in deviceIDs {
            if var entry = entries[deviceID] {
                entry.count += 1
                entries[deviceID] = entry
                continue
            }
            var originalRate: Double?
            // Pin the rate the device actually ends up running at, not the one we
            // asked for: a fixed-rate device can refuse the change, and publishing
            // the requested rate would then hand the next monitor a rate the
            // hardware is not on — the very mismatch this registry exists to stop.
            var heldRate = rate
            if let current = CoreAudioSampleRate.nominalSampleRate(for: deviceID) {
                if abs(current - rate) <= 1 {
                    heldRate = current
                } else if CoreAudioSampleRate.setNominalSampleRate(rate, for: deviceID) {
                    originalRate = current
                } else {
                    heldRate = current
                }
            }
            entries[deviceID] = Entry(rate: heldRate, originalRate: originalRate, count: 1)
        }
    }

    /// Drops one monitor's claim, restoring the original rate of each device no
    /// monitor is driving any more.
    func release(deviceIDs: [AudioObjectID]) {
        lock.lock()
        defer { lock.unlock() }
        for deviceID in deviceIDs {
            guard var entry = entries[deviceID] else { continue }
            entry.count -= 1
            guard entry.count <= 0 else {
                entries[deviceID] = entry
                continue
            }
            entries.removeValue(forKey: deviceID)
            if let originalRate = entry.originalRate {
                _ = CoreAudioSampleRate.setNominalSampleRate(originalRate, for: deviceID)
            }
        }
    }
}

/// Plays a hardware **input** device through a chosen **output** device in real
/// time — the macOS equivalent of Windows' "Listen to this device". It builds a
/// private aggregate of the two devices and runs an `AudioDeviceIOProc` that
/// copies the input's samples to the output (scaled by a monitor gain), aligning
/// their sample rates first via `CoreAudioSampleRate` so a 44.1 kHz mic into a
/// 48 kHz output doesn't break.
///
/// One engine drives one monitor; the controller owns several for simultaneous
/// monitors. Capturing an input device requires microphone permission, so the UI
/// requests it before starting.
public final class AudioMonitorEngine: @unchecked Sendable {
    /// Gain shared between the main thread (writer, via `setGain`) and the
    /// realtime IO proc (reader). Same handoff as
    /// `AppVolumeMixerAudioEngine.RenderState` (see the rationale there): the
    /// writer locks an `os_unfair_lock` unconditionally, the render thread only
    /// *tries* it — a realtime thread must never block — and falls back to the
    /// last gain it successfully read.
    private final class RenderState: @unchecked Sendable {
        /// Where the monitored input device's buffers start in the aggregate's
        /// input buffer list. Fixed at `start()`, so the render thread reads it
        /// without synchronization.
        let inputBufferIndex: Int
        private var gain: Float
        /// Read and written only by the realtime IO proc thread.
        private var lastRenderGain: Float
        /// Heap-allocated so the lock has a stable address; an inline struct
        /// stored property could be moved/copied by Swift value semantics.
        private let lock: UnsafeMutablePointer<os_unfair_lock>

        init(gain: Float, inputBufferIndex: Int) {
            self.inputBufferIndex = inputBufferIndex
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

    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var renderState: RenderState?
    private var renderStatePointer: UnsafeMutableRawPointer?
    /// Devices this engine holds a claim on in `MonitorSampleRateRegistry`.
    private var acquiredSampleRateDevices: [AudioObjectID] = []

    public private(set) var inputUID: String = ""
    public private(set) var outputUID: String = ""

    public init() {}

    deinit { stop() }

    public var isRunning: Bool { ioProcID != nil }

    public func start(inputUID: String, outputUID: String, gain: Float) throws {
        stop()
        guard let inputID = AudioRouterKit.deviceID(forUID: inputUID),
              let outputID = AudioRouterKit.deviceID(forUID: outputUID) else {
            throw AudioMonitorError.deviceUnavailable
        }

        // Align rates before building the aggregate (see CoreAudioSampleRate).
        let deviceIDs = CoreAudioSampleRate.uniqued([inputID, outputID])
        let registry = MonitorSampleRateRegistry.shared
        let rateSets = deviceIDs.map { deviceID -> [Double] in
            // Retuning a device another monitor is already driving would break
            // that monitor, so its live rate is the only candidate here.
            if let pinned = registry.pinnedRate(for: deviceID) { return [pinned] }
            return CoreAudioSampleRate.availableNominalSampleRates(for: deviceID)
        }
        let preferred = registry.pinnedRate(for: outputID)
            ?? CoreAudioSampleRate.nominalSampleRate(for: outputID)
        guard let chosen = CoreAudioSampleRate.chooseCommonSampleRate(
            preferred: preferred,
            deviceSupportedRates: rateSets
        ) else {
            throw AudioMonitorError.incompatibleSampleRate
        }
        registry.acquire(deviceIDs: deviceIDs, rate: chosen)
        acquiredSampleRateDevices = deviceIDs

        // The aggregate exposes every sub-device's input streams in sub-device
        // list order, and the output device is listed first — so its own input
        // streams (a headset's mic, a loopback device's capture side) sit ahead
        // of the monitored device's buffers in the IO proc's input list.
        let inputBufferIndex = inputID == outputID ? 0 : Self.inputBufferCount(for: outputID)

        MonitorDebug.log("start input id=\(inputID) uid='\(inputUID)' rate=\(CoreAudioSampleRate.nominalSampleRate(for: inputID).map { String($0) } ?? "nil") supported=\(CoreAudioSampleRate.availableNominalSampleRates(for: inputID))")
        MonitorDebug.log("  output id=\(outputID) uid='\(outputUID)' rate=\(CoreAudioSampleRate.nominalSampleRate(for: outputID).map { String($0) } ?? "nil")")
        MonitorDebug.log("  chosenRate=\(chosen) devices=\(deviceIDs) inputBufferIndex=\(inputBufferIndex)")

        do {
            let aggregateID = try Self.createAggregate(inputUID: inputUID, outputUID: outputUID)
            _ = CoreAudioSampleRate.setNominalSampleRate(chosen, for: aggregateID)
            MonitorDebug.log("  aggregate id=\(aggregateID) rate=\(CoreAudioSampleRate.nominalSampleRate(for: aggregateID).map { String($0) } ?? "nil")")

            let state = RenderState(gain: Self.clampGain(gain), inputBufferIndex: inputBufferIndex)
            let statePointer = Unmanaged.passRetained(state).toOpaque()
            var ioProcID: AudioDeviceIOProcID?
            let createStatus = AudioDeviceCreateIOProcID(aggregateID, Self.ioProc, statePointer, &ioProcID)
            guard createStatus == noErr, let ioProcID else {
                Unmanaged<RenderState>.fromOpaque(statePointer).release()
                Self.destroyAggregate(aggregateID)
                throw AudioMonitorError.coreAudio(createStatus)
            }
            let startStatus = AudioDeviceStart(aggregateID, ioProcID)
            MonitorDebug.log("  ioProc create=\(createStatus) AudioDeviceStart=\(startStatus) → \(startStatus == noErr ? "RUNNING" : "FAILED")")
            guard startStatus == noErr else {
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
                Unmanaged<RenderState>.fromOpaque(statePointer).release()
                Self.destroyAggregate(aggregateID)
                throw AudioMonitorError.coreAudio(startStatus)
            }

            self.aggregateID = aggregateID
            self.ioProcID = ioProcID
            self.renderState = state
            self.renderStatePointer = statePointer
            self.inputUID = inputUID
            self.outputUID = outputUID
        } catch {
            releaseSampleRates()
            throw error
        }
    }

    public func setGain(_ gain: Float) {
        renderState?.setGain(Self.clampGain(gain))
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
            Self.destroyAggregate(aggregateID)
        }
        releaseSampleRates()

        aggregateID = AudioObjectID(kAudioObjectUnknown)
        ioProcID = nil
        renderState = nil
        renderStatePointer = nil
    }

    private func releaseSampleRates() {
        MonitorSampleRateRegistry.shared.release(deviceIDs: acquiredSampleRateDevices)
        acquiredSampleRateDevices = []
    }

    static func clampGain(_ value: Float) -> Float { min(1, max(0, value)) }

    /// How many buffers a device exposes on its input scope. The aggregate's IO
    /// proc receives its sub-devices' input streams concatenated in sub-device
    /// list order, so the output device's count is where the monitored input
    /// device's own buffers begin.
    static func inputBufferCount(for deviceID: AudioObjectID) -> Int {
        guard deviceID != kAudioObjectUnknown else { return 0 }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return 0 }

        let bufferList = AudioBufferList.allocate(
            maximumBuffers: Int(dataSize) / MemoryLayout<AudioBuffer>.size + 1
        )
        defer { free(bufferList.unsafeMutablePointer) }

        guard AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &dataSize, bufferList.unsafeMutablePointer
        ) == noErr else { return 0 }
        return bufferList.count
    }

    // MARK: - Aggregate

    private static func createAggregate(inputUID: String, outputUID: String) throws -> AudioObjectID {
        let uid = "com.havokentity.mactools.audiorouter.monitor." + UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "DMonte Monitor",
            kAudioAggregateDeviceUIDKey: uid,
            // Private: this is an internal plumbing device, not something the
            // user should see or pick in Sound settings.
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            // The output device owns the clock; the input is drift-compensated.
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceClockDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID, kAudioSubDeviceDriftCompensationKey: false],
                [kAudioSubDeviceUIDKey: inputUID, kAudioSubDeviceDriftCompensationKey: true]
            ]
        ]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
        guard status == noErr, aggregateID != kAudioObjectUnknown else {
            throw AudioMonitorError.coreAudio(status)
        }
        return aggregateID
    }

    private static func destroyAggregate(_ aggregateID: AudioObjectID) {
        guard aggregateID != kAudioObjectUnknown else { return }
        AudioHardwareDestroyAggregateDevice(aggregateID)
    }

    // MARK: - Render

    /// Diagnostic render-callback counter (used by `MonitorDebug`).
    nonisolated(unsafe) private static var renderCallCount: UInt64 = 0

    private static let ioProc: AudioDeviceIOProc = { _, _, inputData, _, outputData, _, clientData in
        guard let clientData else { return noErr }
        let state = Unmanaged<RenderState>.fromOpaque(clientData).takeUnretainedValue()
        render(
            inputData: inputData,
            outputData: outputData,
            inputBufferIndex: state.inputBufferIndex,
            gain: state.renderGain()
        )
        return noErr
    }

    /// Plays the monitored input's buffer (`inputBufferIndex` locates it among
    /// the aggregate's input buffers) out through the listening device's buffer,
    /// mapping channels per-frame so a mono mic, a stereo line-in, or any other
    /// channel count lands correctly on the output (the old byte-copy assumed
    /// identical layouts, which produced noise on a channel mismatch). Sample
    /// rates are reconciled before the IOProc runs, so frame counts line up.
    static func render(
        inputData: UnsafePointer<AudioBufferList>,
        outputData: UnsafeMutablePointer<AudioBufferList>,
        inputBufferIndex: Int,
        gain: Float
    ) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        let outputs = UnsafeMutableAudioBufferListPointer(outputData)

        func zeroAllOutputs() {
            for index in 0..<outputs.count {
                let output = outputs[index]
                if let data = output.mData, output.mDataByteSize > 0 {
                    memset(data, 0, Int(output.mDataByteSize))
                }
            }
        }

        guard inputBufferIndex >= 0, inputBufferIndex < inputs.count else {
            zeroAllOutputs()
            return
        }
        let inBuffer = inputs[inputBufferIndex]
        guard let inData = inBuffer.mData else {
            zeroAllOutputs()
            return
        }
        let inChannels = max(1, Int(inBuffer.mNumberChannels))
        let inFrames = Int(inBuffer.mDataByteSize) / (MemoryLayout<Float32>.size * inChannels)
        let inSamples = inData.assumingMemoryBound(to: Float32.self)

        if MonitorDebug.enabled {
            renderCallCount &+= 1
            if renderCallCount % 100 == 1 {
                let outBuf = outputs.first
                MonitorDebug.log("render #\(renderCallCount) in: ch=\(inChannels) frames=\(inFrames) bytes=\(inBuffer.mDataByteSize) peak=\(String(format: "%.3f", peak(inSamples, count: inFrames * inChannels))) out: bufs=\(outputs.count) ch=\(outBuf?.mNumberChannels ?? 0) bytes=\(outBuf?.mDataByteSize ?? 0) gain=\(gain)")
            }
        }

        // Play the captured input ONLY to the listening device's buffer (the
        // aggregate lists the output device first / as the main sub-device).
        // Every other output buffer is silenced — critically, this avoids
        // writing the signal back into a loopback input device (e.g. BlackHole),
        // which has its own output streams in the aggregate and would otherwise
        // feed the captured audio straight back to its input → runaway echo.
        for index in 0..<outputs.count {
            var output = outputs[index]
            guard let outData = output.mData else { continue }

            guard index == 0, gain > .ulpOfOne else {
                memset(outData, 0, Int(output.mDataByteSize))
                outputs[index] = output
                continue
            }

            let outChannels = max(1, Int(output.mNumberChannels))
            let outFrames = Int(output.mDataByteSize) / (MemoryLayout<Float32>.size * outChannels)
            let outSamples = outData.assumingMemoryBound(to: Float32.self)
            let frames = min(inFrames, outFrames)

            for frame in 0..<frames {
                let inBase = frame * inChannels
                let outBase = frame * outChannels
                for channel in 0..<outChannels {
                    // Map output channel to an input channel: straight through
                    // when present, otherwise reuse the last input channel (so a
                    // mono source fills every output channel).
                    let sourceChannel = channel < inChannels ? channel : inChannels - 1
                    outSamples[outBase + channel] = inSamples[inBase + sourceChannel] * gain
                }
            }
            // Silence any output frames we didn't fill (input underrun).
            if outFrames > frames {
                let filledSamples = frames * outChannels
                memset(
                    outData.advanced(by: filledSamples * MemoryLayout<Float32>.size),
                    0,
                    (outFrames - frames) * outChannels * MemoryLayout<Float32>.size
                )
            }
            outputs[index] = output
        }
    }

    private static func peak(_ samples: UnsafePointer<Float32>, count: Int) -> Float {
        var maxValue: Float = 0
        for index in 0..<count {
            let magnitude = abs(samples[index])
            if magnitude > maxValue { maxValue = magnitude }
        }
        return maxValue
    }
}
