import CoreAudio
import Foundation

/// A discovered audio device with its capability flags and stable UID.
///
/// This is the spec-facing model for the Audio Switcher tool. It mirrors the
/// internal `AudioDeviceKit.AudioDevice` but additionally carries the device's
/// persistent `uid` (the value CoreAudio exposes via
/// `kAudioDevicePropertyDeviceUID`), which survives reboots and re-enumeration.
public struct AudioDevice: Identifiable, Sendable, Equatable {
    /// The transient CoreAudio device id. `AudioDeviceID` is `UInt32`, hence `Sendable`.
    public let id: AudioDeviceID
    /// Human-readable device name (falls back to a placeholder if unavailable).
    public let name: String
    /// Persistent device UID, or an empty string if CoreAudio does not expose one.
    public let uid: String
    /// `true` if the device exposes at least one output stream.
    public let hasOutput: Bool
    /// `true` if the device exposes at least one input stream.
    public let hasInput: Bool

    public init(id: AudioDeviceID, name: String, uid: String, hasOutput: Bool, hasInput: Bool) {
        self.id = id
        self.name = name
        self.uid = uid
        self.hasOutput = hasOutput
        self.hasInput = hasInput
    }
}

/// The spec-facing CoreAudio entry point for the Audio Switcher tool.
///
/// It is a thin, allocation-free facade over `AudioDeviceKit`: enumeration is
/// re-implemented here so each `AudioDevice` can carry its `uid`, while the
/// default get/set operations delegate to the already-tested `AudioDeviceKit`
/// helpers. Every call is best-effort and tolerant of headless / CI machines
/// with no audio hardware (returns `[]`, `nil`, or `false` rather than crashing).
public enum AudioSwitcherKit {

    // MARK: - Enumeration

    /// Every audio device known to the system that exposes input and/or output
    /// streams, each annotated with its capability flags and `uid`.
    public static func devices() -> [AudioDevice] {
        AudioDeviceKit.allDevices().map { device in
            AudioDevice(
                id: device.id,
                name: device.name,
                uid: deviceUID(device.id) ?? "",
                hasOutput: device.hasOutput,
                hasInput: device.hasInput
            )
        }
    }

    // MARK: - Defaults (getters)

    /// The current default output device id, or `nil` if none is set / available.
    public static func defaultOutputID() -> AudioDeviceID? {
        AudioDeviceKit.defaultOutputDeviceID()
    }

    /// The current default input device id, or `nil` if none is set / available.
    public static func defaultInputID() -> AudioDeviceID? {
        AudioDeviceKit.defaultInputDeviceID()
    }

    // MARK: - Defaults (setters)

    /// Makes `id` the default output device (and the system alert-output device).
    /// Returns `true` on success.
    @discardableResult
    public static func setDefaultOutput(_ id: AudioDeviceID) -> Bool {
        AudioDeviceKit.setDefaultOutput(id)
    }

    /// Makes `id` the default input device. Returns `true` on success.
    @discardableResult
    public static func setDefaultInput(_ id: AudioDeviceID) -> Bool {
        AudioDeviceKit.setDefaultInput(id)
    }

    // MARK: - Private helpers

    /// Reads `kAudioDevicePropertyDeviceUID` for a device, or `nil` if absent.
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
}
