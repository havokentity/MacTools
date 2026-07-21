import CoreAudio
import Foundation

/// A saved (input, output) pairing the user can re-apply in one click — "Headset",
/// "Desk", "Meeting".
///
/// Devices are pinned by their CoreAudio UID, never by `AudioDeviceID`. The numeric
/// id is assigned by the HAL as it enumerates hardware and is recycled freely across
/// reboots and re-plugs, so a profile stored by id would eventually point at whatever
/// unrelated device inherited the number — and switching audio to the wrong device is
/// exactly the failure this feature must never produce. Names are stored alongside the
/// UID, but only so a *disconnected* device can still be named in the UI; they play no
/// part in matching.
public struct AudioDeviceProfile: Codable, Identifiable, Sendable, Equatable {

    /// One direction's pinned device: the stable UID plus the name the device had when
    /// the profile was captured.
    public struct DeviceRef: Codable, Sendable, Equatable {
        public let uid: String
        public var name: String

        public init(uid: String, name: String) {
            self.uid = uid
            self.name = name
        }
    }

    public let id: UUID
    public var name: String
    /// The pinned output device, or `nil` when the profile leaves playback untouched.
    public var output: DeviceRef?
    /// The pinned input device, or `nil` when the profile leaves capture untouched.
    public var input: DeviceRef?

    public init(id: UUID = UUID(), name: String, output: DeviceRef? = nil, input: DeviceRef? = nil) {
        self.id = id
        self.name = name
        self.output = output
        self.input = input
    }

    // MARK: - Capture

    /// Builds a profile from a snapshot of the current defaults, or `nil` if there is
    /// nothing worth saving.
    ///
    /// A direction is pinned only when the current default device is present in
    /// `devices` *and* exposes a non-empty UID; some virtual drivers publish no UID at
    /// all, and a leg pinned to an empty string could later match any other UID-less
    /// device. When neither direction survives that check the profile could never
    /// resolve to anything, so we refuse to create it rather than persist a permanently
    /// broken row. A blank name is refused for the same reason: it produces a row the
    /// user cannot identify.
    public static func capture(
        name: String,
        devices: [AudioDevice],
        defaultOutputID: AudioDeviceID?,
        defaultInputID: AudioDeviceID?,
        id: UUID = UUID()
    ) -> AudioDeviceProfile? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let output = deviceRef(for: defaultOutputID, in: devices)
        let input = deviceRef(for: defaultInputID, in: devices)
        guard output != nil || input != nil else { return nil }
        return AudioDeviceProfile(id: id, name: trimmed, output: output, input: input)
    }

    private static func deviceRef(for deviceID: AudioDeviceID?, in devices: [AudioDevice]) -> DeviceRef? {
        guard let deviceID,
              let device = devices.first(where: { $0.id == deviceID }),
              !device.uid.isEmpty else { return nil }
        return DeviceRef(uid: device.uid, name: device.name)
    }

    // MARK: - Resolution

    /// Maps this profile's pinned UIDs onto the devices currently attached.
    public func resolve(against devices: [AudioDevice]) -> AudioProfileResolution {
        AudioProfileResolution(
            output: Self.resolveLeg(output, in: devices, servingDirection: \.hasOutput),
            input: Self.resolveLeg(input, in: devices, servingDirection: \.hasInput)
        )
    }

    private static func resolveLeg(
        _ ref: DeviceRef?,
        in devices: [AudioDevice],
        servingDirection: KeyPath<AudioDevice, Bool>
    ) -> AudioProfileResolution.Leg {
        guard let ref else { return .unpinned }
        // A stored empty UID can only come from a corrupt or hand-edited blob. Treat it
        // as missing: falling through would let it match any UID-less device.
        guard !ref.uid.isEmpty else { return .missing(name: ref.name) }
        // Match on UID and nothing else. Two identical USB headsets report the same
        // name, so a name-based fallback would cheerfully pick the wrong one.
        guard let device = devices.first(where: { $0.uid == ref.uid }) else {
            return .missing(name: ref.name)
        }
        // The device is here but may have been reconfigured — an aggregate that lost a
        // sub-device, an interface switched to a capture-only mode. Setting it as the
        // default for a direction it no longer serves is a silent mis-switch.
        guard device[keyPath: servingDirection] else {
            return .wrongDirection(name: device.name)
        }
        return .resolved(deviceID: device.id, name: device.name)
    }

    /// Whether this profile describes the defaults that are already in force. Both
    /// pinned legs must match; an unpinned leg imposes no constraint because applying
    /// the profile would not have touched it.
    public func matchesDefaults(outputUID: String?, inputUID: String?) -> Bool {
        if let output, output.uid != outputUID { return false }
        if let input, input.uid != inputUID { return false }
        return output != nil || input != nil
    }
}

/// What a profile's pinned devices map to against the currently attached hardware.
///
/// This is deliberately richer than a bool: the popover has to explain *why* a profile
/// cannot be used, and "Bose QC isn't connected" is a very different message from
/// "Loopback has no output channels".
public struct AudioProfileResolution: Sendable, Equatable {

    /// The outcome for one direction.
    public enum Leg: Sendable, Equatable {
        /// The profile pins nothing here; applying it leaves this direction alone.
        case unpinned
        /// The pinned UID matched a connected device that still serves this direction.
        case resolved(deviceID: AudioDeviceID, name: String)
        /// No connected device carries the pinned UID.
        case missing(name: String)
        /// A device with the pinned UID is connected but no longer offers streams in
        /// this direction.
        case wrongDirection(name: String)
    }

    public let output: Leg
    public let input: Leg

    public init(output: Leg, input: Leg) {
        self.output = output
        self.input = input
    }

    /// `true` only when every pinned leg resolved. Applying is all-or-nothing: a
    /// half-applied "Meeting" that moved playback but left the mic on the laptop is
    /// worse than a profile that plainly refuses and says what is missing.
    public var isApplicable: Bool {
        Self.isSatisfied(output) && Self.isSatisfied(input)
    }

    /// The device to make the default output, or `nil` if this direction is unpinned or
    /// unresolved.
    public var outputDeviceID: AudioDeviceID? {
        if case .resolved(let deviceID, _) = output { return deviceID }
        return nil
    }

    /// The device to make the default input, or `nil` if this direction is unpinned or
    /// unresolved.
    public var inputDeviceID: AudioDeviceID? {
        if case .resolved(let deviceID, _) = input { return deviceID }
        return nil
    }

    /// A one-line explanation of why the profile cannot be applied, or `nil` when it
    /// can. Both directions are reported when both are broken, so unplugging a combined
    /// headset does not send the user hunting for a second problem after fixing the
    /// first.
    public var unavailableReason: String? {
        let parts = [
            Self.reason(for: output, direction: .output),
            Self.reason(for: input, direction: .input)
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "Studio Display · Shure MV7" — the device names for the pinned directions, using
    /// the live name when the device is attached so a renamed device reads correctly.
    public var deviceSummary: String {
        [Self.name(of: output), Self.name(of: input)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    // MARK: - Private

    private static func isSatisfied(_ leg: Leg) -> Bool {
        switch leg {
        case .unpinned, .resolved: return true
        case .missing, .wrongDirection: return false
        }
    }

    private enum Direction: String {
        case output = "Output"
        case input = "Input"

        var channelNoun: String {
            switch self {
            case .output: return "output"
            case .input: return "input"
            }
        }
    }

    private static func reason(for leg: Leg, direction: Direction) -> String? {
        switch leg {
        case .unpinned, .resolved:
            return nil
        case .missing(let name):
            return "\(direction.rawValue) “\(name)” isn’t connected"
        case .wrongDirection(let name):
            return "\(direction.rawValue) “\(name)” has no \(direction.channelNoun) channels"
        }
    }

    private static func name(of leg: Leg) -> String? {
        switch leg {
        case .unpinned:
            return nil
        case .resolved(_, let name), .missing(let name), .wrongDirection(let name):
            return name
        }
    }
}

/// Persists the user's saved device profiles as JSON in `UserDefaults`.
///
/// Every operation is pure with respect to CoreAudio and fully unit-testable. Mutators
/// return the resulting list so a caller holding an `@Published` copy stays in sync
/// without a second read of the defaults.
public enum AudioProfileStore {
    private static let key = DefaultsKey.audioSwitcherProfiles

    /// All saved profiles, in insertion order. Returns `[]` when nothing is stored or
    /// the stored blob is unreadable — a corrupt value is treated as "no profiles"
    /// rather than crashing a menu-bar helper at launch.
    public static func load(defaults: UserDefaults) -> [AudioDeviceProfile] {
        guard let data = defaults.data(forKey: key),
              let profiles = try? JSONDecoder().decode([AudioDeviceProfile].self, from: data) else {
            return []
        }
        return profiles
    }

    /// Overwrites the stored profiles with `profiles`.
    public static func save(_ profiles: [AudioDeviceProfile], defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: key)
    }

    /// Appends a new profile, or replaces the existing one with the same `id` in place
    /// so an edit does not reorder the list under the user's cursor.
    @discardableResult
    public static func upsert(_ profile: AudioDeviceProfile, defaults: UserDefaults) -> [AudioDeviceProfile] {
        var profiles = load(defaults: defaults)
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        save(profiles, defaults: defaults)
        return profiles
    }

    /// Renames a profile. A blank name is rejected and nothing is written: an unnamed
    /// row is unidentifiable, and silently accepting it would lose the old name too.
    @discardableResult
    public static func rename(id: UUID, to newName: String, defaults: UserDefaults) -> [AudioDeviceProfile] {
        var profiles = load(defaults: defaults)
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = profiles.firstIndex(where: { $0.id == id }) else { return profiles }
        profiles[index].name = trimmed
        save(profiles, defaults: defaults)
        return profiles
    }

    /// Removes the profile with the given `id`, if present.
    @discardableResult
    public static func remove(id: UUID, defaults: UserDefaults) -> [AudioDeviceProfile] {
        let profiles = load(defaults: defaults).filter { $0.id != id }
        save(profiles, defaults: defaults)
        return profiles
    }
}
