import CoreAudio
import Foundation

/// The spec-facing CoreAudio entry point for the **Audio Router** tool.
///
/// Where `AudioSwitcherKit` flips the *default* device and `AppVolumeMixerKit`
/// re-routes a single app, `AudioRouterKit` builds standing **virtual routing
/// devices** out of the hardware you already have — the macOS equivalent of a
/// "virtual audio cable":
///
/// * an **aggregate** device combines several inputs (and/or a virtual loopback
///   driver such as BlackHole) into one capture endpoint, and
/// * a **multi-output** device mirrors playback to several outputs at once
///   (e.g. speakers *and* a loopback driver so an app can both hear and stream).
///
/// App→app routing additionally needs a userspace loopback *driver* (CoreAudio
/// exposes no API to synthesize one); this kit detects BlackHole and treats it
/// as just another sub-device. Everything here is best-effort and tolerant of
/// headless / CI machines with no audio hardware (it returns `[]`, `nil`, or a
/// `.failure` rather than crashing).
public enum AudioRouterKit {

    /// UID prefix stamped onto every device this tool creates, so the tool can
    /// later enumerate and clean up only its own devices without touching
    /// aggregates the user (or another app) made.
    public static let uidPrefix = "com.havokentity.mactools.audiorouter."

    /// Substring used to recognise the BlackHole loopback driver by name.
    public static let loopbackDriverName = "BlackHole"

    // MARK: - Model

    /// Whether a router device combines sources into one capture endpoint, or
    /// mirrors playback across several outputs.
    public enum RouterMode: String, Codable, Sendable, CaseIterable {
        /// A combined capture device (CoreAudio "aggregate", `IsStacked = false`).
        case aggregate
        /// A mirrored playback device (CoreAudio "multi-output", `IsStacked = true`).
        case multiOutput

        /// The `kAudioAggregateDeviceIsStackedKey` value for this mode.
        public var isStacked: Bool { self == .multiOutput }
    }

    /// A declarative description of a virtual routing device to create. Pure
    /// value type — building it touches no hardware, which keeps the dictionary
    /// construction unit-testable.
    public struct RouterDeviceSpec: Sendable, Equatable, Codable {
        /// User-visible device name (shown in Sound settings and every app).
        public let name: String
        /// Persistent CoreAudio UID; carries `uidPrefix` so the tool owns it.
        public let uid: String
        public let mode: RouterMode
        /// UIDs of the hardware (and/or loopback) sub-devices to bundle.
        public let subDeviceUIDs: [String]
        /// UID of the sub-device whose clock is authoritative; `nil` uses the
        /// first sub-device. Drift compensation is enabled on every *other*
        /// sub-device so independent clocks stay in sync.
        public let clockMasterUID: String?

        public init(
            name: String,
            uid: String,
            mode: RouterMode,
            subDeviceUIDs: [String],
            clockMasterUID: String? = nil
        ) {
            self.name = name
            self.uid = uid
            self.mode = mode
            self.subDeviceUIDs = subDeviceUIDs
            self.clockMasterUID = clockMasterUID
        }
    }

    /// Why a create/destroy operation could not be completed.
    public enum RouterError: Error, Equatable {
        /// The spec listed no sub-devices to bundle.
        case noSubDevices
        /// The spec's name was empty or whitespace-only.
        case emptyName
        /// CoreAudio rejected the operation with this status code.
        case coreAudio(OSStatus)
    }

    // MARK: - Loopback driver detection

    /// Every device whose name looks like the BlackHole loopback driver. These
    /// are the bridges that make true app→app routing possible.
    public static func loopbackDevices() -> [AudioDevice] {
        AudioSwitcherKit.devices().filter {
            $0.name.localizedCaseInsensitiveContains(loopbackDriverName)
        }
    }

    /// Whether a loopback driver is installed and visible to CoreAudio.
    public static func isLoopbackDriverInstalled() -> Bool {
        !loopbackDevices().isEmpty
    }

    // MARK: - Enumeration

    /// Devices this tool created previously (recognised by `uidPrefix`), so they
    /// can be listed for editing or removal. Survives relaunches because the
    /// devices are persisted by CoreAudio, not by the app.
    public static func routerDevices() -> [AudioDevice] {
        AudioSwitcherKit.devices().filter { $0.uid.hasPrefix(uidPrefix) }
    }

    /// Candidate sub-devices a router can bundle: every real device plus any
    /// loopback driver, excluding devices this tool already created (you can't
    /// nest a router inside itself).
    public static func availableSubDevices(matching mode: RouterMode) -> [AudioDevice] {
        AudioSwitcherKit.devices().filter { device in
            guard !device.uid.hasPrefix(uidPrefix), !device.uid.isEmpty else { return false }
            switch mode {
            case .aggregate: return device.hasInput || device.hasOutput
            case .multiOutput: return device.hasOutput
            }
        }
    }

    // MARK: - UID generation

    /// A fresh, collision-resistant UID for a new router device.
    public static func makeUID() -> String {
        uidPrefix + UUID().uuidString
    }

    // MARK: - Description building (pure)

    /// Builds the description dictionary passed to
    /// `AudioHardwareCreateAggregateDevice`. Kept pure (no CoreAudio calls) so
    /// the mapping from a `RouterDeviceSpec` to CoreAudio keys is unit-testable.
    public static func aggregateDescription(for spec: RouterDeviceSpec) -> [String: Any] {
        let master = spec.clockMasterUID ?? spec.subDeviceUIDs.first
        let subList: [[String: Any]] = spec.subDeviceUIDs.map { uid in
            [
                kAudioSubDeviceUIDKey: uid,
                // Drift-compensate every sub-device except the clock master so
                // devices on independent clocks don't slowly desync.
                kAudioSubDeviceDriftCompensationKey: uid != master
            ]
        }

        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: spec.name,
            kAudioAggregateDeviceUIDKey: spec.uid,
            kAudioAggregateDeviceIsStackedKey: spec.mode.isStacked,
            // Persist the device so it behaves like a real "virtual cable":
            // visible to every app and surviving relaunches until removed.
            kAudioAggregateDeviceIsPrivateKey: false,
            kAudioAggregateDeviceSubDeviceListKey: subList
        ]
        if let master, !master.isEmpty {
            description[kAudioAggregateDeviceMainSubDeviceKey] = master
            description[kAudioAggregateDeviceClockDeviceKey] = master
        }
        return description
    }

    // MARK: - Create / destroy

    /// Creates the virtual routing device described by `spec`. Returns the new
    /// `AudioDeviceID` on success.
    public static func createDevice(_ spec: RouterDeviceSpec) -> Result<AudioDeviceID, RouterError> {
        guard !spec.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.emptyName)
        }
        guard !spec.subDeviceUIDs.isEmpty else {
            return .failure(.noSubDevices)
        }

        let description = aggregateDescription(for: spec) as CFDictionary
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            return .failure(.coreAudio(status))
        }
        return .success(deviceID)
    }

    /// Destroys a previously created router device by UID. Returns `true` if the
    /// device was found and removed. A missing device is treated as already-gone
    /// and reported as failure so callers can surface a stale-list refresh.
    @discardableResult
    public static func destroyDevice(uid: String) -> Bool {
        guard let deviceID = deviceID(forUID: uid) else { return false }
        return AudioHardwareDestroyAggregateDevice(deviceID) == noErr
    }

    /// Convenience: destroy every device this tool ever created. Returns the
    /// number successfully removed.
    @discardableResult
    public static func destroyAllRouterDevices() -> Int {
        routerDevices().reduce(0) { count, device in
            destroyDevice(uid: device.uid) ? count + 1 : count
        }
    }

    // MARK: - UID → device resolution

    /// Resolves a persistent UID to its live `AudioDeviceID`, or `nil` if no
    /// device currently carries that UID.
    public static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID = uid as CFString
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var outSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let inSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { inPtr -> OSStatus in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                inSize,
                inPtr,
                &outSize,
                &deviceID
            )
        }
        guard status == noErr, deviceID != kAudioObjectUnknown, deviceID != 0 else { return nil }
        return deviceID
    }
}
