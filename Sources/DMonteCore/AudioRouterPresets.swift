import Foundation

/// A saved routing recipe: a name, a mode, and the sub-device UIDs to bundle.
///
/// A preset is *device-independent* — it stores which devices to combine, not a
/// live `AudioDeviceID`. Applying it mints a fresh device UID and builds the
/// device anew, so a preset stays valid across reboots and re-plugging hardware.
public struct RouterPreset: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var mode: AudioRouterKit.RouterMode
    public var subDeviceUIDs: [String]
    public var clockMasterUID: String?

    public init(
        id: UUID = UUID(),
        name: String,
        mode: AudioRouterKit.RouterMode,
        subDeviceUIDs: [String],
        clockMasterUID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.subDeviceUIDs = subDeviceUIDs
        self.clockMasterUID = clockMasterUID
    }

    /// A concrete, ready-to-create spec for this preset with a fresh device UID.
    public func makeSpec() -> AudioRouterKit.RouterDeviceSpec {
        AudioRouterKit.RouterDeviceSpec(
            name: name,
            uid: AudioRouterKit.makeUID(),
            mode: mode,
            subDeviceUIDs: subDeviceUIDs,
            clockMasterUID: clockMasterUID
        )
    }
}

/// Persists the user's saved routing presets as JSON in `UserDefaults`.
/// Every operation is pure with respect to CoreAudio and fully unit-testable.
public enum RouterPresetStore {
    private static let key = DefaultsKey.audioRouterPresets

    /// All saved presets, in insertion order. Returns `[]` if none are stored or
    /// the stored blob is unreadable (corruption is treated as "no presets"
    /// rather than crashing).
    public static func load(defaults: UserDefaults) -> [RouterPreset] {
        guard let data = defaults.data(forKey: key),
              let presets = try? JSONDecoder().decode([RouterPreset].self, from: data) else {
            return []
        }
        return presets
    }

    /// Overwrites the stored presets with `presets`.
    public static func save(_ presets: [RouterPreset], defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        defaults.set(data, forKey: key)
    }

    /// Inserts a new preset, or replaces the existing one with the same `id`.
    public static func upsert(_ preset: RouterPreset, defaults: UserDefaults) {
        var presets = load(defaults: defaults)
        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index] = preset
        } else {
            presets.append(preset)
        }
        save(presets, defaults: defaults)
    }

    /// Removes the preset with the given `id`, if present.
    public static func remove(id: UUID, defaults: UserDefaults) {
        let presets = load(defaults: defaults).filter { $0.id != id }
        save(presets, defaults: defaults)
    }
}
