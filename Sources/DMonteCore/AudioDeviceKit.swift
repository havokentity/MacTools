import CoreAudio
import Foundation

/// A pure CoreAudio wrapper with no SwiftUI/AppKit dependencies so it can be
/// unit-tested. All functions are best-effort and tolerant of headless / CI
/// environments where no audio hardware is present (they return empty arrays,
/// `nil`, or no-op rather than crashing).
public enum AudioDeviceKit {

    /// A discovered audio device with its capability flags.
    public struct AudioDevice: Identifiable, Sendable, Equatable {
        public let id: AudioDeviceID
        public let name: String
        public let hasOutput: Bool
        public let hasInput: Bool

        public init(id: AudioDeviceID, name: String, hasOutput: Bool, hasInput: Bool) {
            self.id = id
            self.name = name
            self.hasOutput = hasOutput
            self.hasInput = hasInput
        }
    }

    // MARK: - Enumeration

    /// Returns every audio device known to the system, annotated with whether it
    /// exposes output and/or input streams. Returns an empty array if the
    /// hardware list is unavailable.
    public static func allDevices() -> [AudioDevice] {
        let deviceIDs = deviceIDList()
        var result: [AudioDevice] = []
        result.reserveCapacity(deviceIDs.count)
        for id in deviceIDs {
            let output = hasStreams(id, scope: kAudioObjectPropertyScopeOutput)
            let input = hasStreams(id, scope: kAudioObjectPropertyScopeInput)
            // Skip devices that are neither input nor output (e.g. aggregate
            // placeholders with no streams in either direction).
            guard output || input else { continue }
            let name = deviceName(id) ?? "Unknown Device"
            result.append(AudioDevice(id: id, name: name, hasOutput: output, hasInput: input))
        }
        return result
    }

    /// Output-capable devices only.
    public static func outputDevices() -> [AudioDevice] {
        allDevices().filter { $0.hasOutput }
    }

    /// Input-capable devices only.
    public static func inputDevices() -> [AudioDevice] {
        allDevices().filter { $0.hasInput }
    }

    /// Persistent CoreAudio UID for a device, or `nil` if unavailable.
    public static func uid(for deviceID: AudioDeviceID) -> String? {
        deviceUID(deviceID)
    }

    // MARK: - Defaults (getters)

    /// The current default output device, or `nil` if none is set / available.
    public static func defaultOutputDeviceID() -> AudioDeviceID? {
        defaultDeviceID(selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    /// The current default input device, or `nil` if none is set / available.
    public static func defaultInputDeviceID() -> AudioDeviceID? {
        defaultDeviceID(selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    // MARK: - Defaults (setters)

    /// Sets the default output device. Also updates the "system output" device
    /// (used for alert sounds) to keep the two consistent. Returns `true` on
    /// success.
    @discardableResult
    public static func setDefaultOutput(_ deviceID: AudioDeviceID) -> Bool {
        let ok = setDefaultDeviceID(deviceID, selector: kAudioHardwarePropertyDefaultOutputDevice)
        // System output is a best-effort secondary set; ignore its failure.
        _ = setDefaultDeviceID(deviceID, selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
        return ok
    }

    /// Sets the default input device. Returns `true` on success.
    @discardableResult
    public static func setDefaultInput(_ deviceID: AudioDeviceID) -> Bool {
        setDefaultDeviceID(deviceID, selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    // MARK: - Volume

    /// The volume of a device in `0...1` for the given direction, or `nil` if the
    /// device exposes no readable volume control there. Tries the main element
    /// first, then averages per-channel scalars as a fallback.
    ///
    /// `scope` defaults to output because that was this function's only behaviour
    /// before input devices needed it; input gain lives on a genuinely different
    /// property, so a device can answer for one scope and not the other.
    public static func volume(
        for deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput
    ) -> Float? {
        if let main = volumeScalar(deviceID, scope: scope, element: kAudioObjectPropertyElementMain) {
            return clamp01(main)
        }
        // Fall back to per-channel: average channels 1 and 2 if present.
        var values: [Float] = []
        for channel: AudioObjectPropertyElement in [1, 2] {
            if let v = volumeScalar(deviceID, scope: scope, element: channel) {
                values.append(v)
            }
        }
        guard !values.isEmpty else { return nil }
        let avg = values.reduce(0, +) / Float(values.count)
        return clamp01(avg)
    }

    /// Sets the volume of a device for the given direction, clamped to `0...1`.
    /// Writes to the main element if settable, otherwise writes each settable
    /// per-channel scalar. Returns `true` if at least one element was updated.
    @discardableResult
    public static func setVolume(
        _ value: Float,
        for deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput
    ) -> Bool {
        let target = clamp01(value)
        if setVolumeScalar(target, deviceID: deviceID, scope: scope, element: kAudioObjectPropertyElementMain) {
            return true
        }
        var didSet = false
        for channel: AudioObjectPropertyElement in [1, 2] {
            if setVolumeScalar(target, deviceID: deviceID, scope: scope, element: channel) {
                didSet = true
            }
        }
        return didSet
    }

    // MARK: - Mute

    /// Whether the device is muted in the given direction, or `nil` if no mute
    /// control exists there. A `nil` answer is the honest "this device cannot be
    /// muted" signal — plenty of USB interfaces and aggregate devices expose no
    /// input mute at all — and callers are expected to disable their control
    /// rather than pretend the write succeeded.
    public static func isMuted(
        _ deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput
    ) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted)
        guard status == noErr else { return nil }
        return muted != 0
    }

    /// Whether the device's mute state for the given direction can actually be
    /// *written*. A device can advertise a readable mute property that is
    /// nonetheless read-only, in which case a UI that only checked `isMuted`
    /// would offer a mute button that silently does nothing.
    public static func isMuteSettable(
        _ deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var isSettable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(deviceID, &address, &isSettable) == noErr else { return false }
        return isSettable.boolValue
    }

    /// Sets the device's mute state for the given direction. Returns `true` on
    /// success. Setting the mute property is a device-control write, not audio
    /// capture, so it needs no microphone TCC grant even in the input scope.
    @discardableResult
    public static func setMuted(
        _ muted: Bool,
        for deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var isSettable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(deviceID, &address, &isSettable) == noErr,
              isSettable.boolValue else { return false }
        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value)
        return status == noErr
    }

    // MARK: - Private helpers

    private static func deviceIDList() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        )
        guard sizeStatus == noErr, dataSize > 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids
        )
        guard status == noErr else { return [] }
        return ids
    }

    private static func deviceName(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &name) { ptr -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        let result = name as String
        return result.isEmpty ? nil : result
    }

    private static func deviceUID(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &uid) { ptr -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        let result = uid as String
        return result.isEmpty ? nil : result
    }

    /// Reads the stream configuration for a scope and reports whether the device
    /// has at least one channel in that direction.
    private static func hasStreams(_ deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return false }

        let bufferList = AudioBufferList.allocate(maximumBuffers: Int(dataSize) / MemoryLayout<AudioBuffer>.size + 1)
        defer { free(bufferList.unsafeMutablePointer) }

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferList.unsafeMutablePointer)
        guard status == noErr else { return false }

        for buffer in bufferList where buffer.mNumberChannels > 0 {
            return true
        }
        return false
    }

    private static func defaultDeviceID(selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != 0, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    @discardableResult
    private static func setDefaultDeviceID(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &value
        )
        return status == noErr
    }

    private static func volumeScalar(
        _ deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Float? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: scope,
            mElement: element
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        guard status == noErr else { return nil }
        return volume
    }

    @discardableResult
    private static func setVolumeScalar(
        _ value: Float,
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: scope,
            mElement: element
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var isSettable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(deviceID, &address, &isSettable) == noErr,
              isSettable.boolValue else { return false }
        var volume: Float32 = clamp01(value)
        let size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &volume)
        return status == noErr
    }

    private static func clamp01(_ value: Float) -> Float {
        min(1, max(0, value))
    }
}
