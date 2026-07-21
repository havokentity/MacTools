import AppKit
import CoreAudio
import SwiftUI

/// Drives the Audio Switcher popover: enumerates devices, tracks the current
/// defaults, and exposes volume / mute control for the active output device.
/// Refreshes live when audio hardware is added or removed.
@MainActor
public final class AudioSwitcherController: ObservableObject {
    /// Every attached device, each carrying its stable UID. Profiles are resolved
    /// against this list, so it is the one source of truth; the per-direction lists
    /// below are filtered views of it rather than separately published state that
    /// could drift.
    @Published public private(set) var devices: [AudioDevice] = []
    @Published public private(set) var defaultOutputID: AudioDeviceID?
    @Published public private(set) var defaultInputID: AudioDeviceID?
    @Published public var volume: Float = 0
    @Published public private(set) var volumeSupported: Bool = false
    @Published public var isMuted: Bool = false
    @Published public private(set) var muteSupported: Bool = false
    @Published public private(set) var profiles: [AudioDeviceProfile] = []

    public var outputDevices: [AudioDevice] { devices.filter { $0.hasOutput } }
    public var inputDevices: [AudioDevice] { devices.filter { $0.hasInput } }

    private let defaults: UserDefaults

    /// True while the user is dragging the volume slider. Our own `setVolume`
    /// fires the HAL volume listener, whose refresh would otherwise stamp the
    /// hardware's (quantised, slightly-lagged) reading back onto the value the
    /// slider is bound to, making the thumb stutter under the finger.
    private var isAdjustingVolume = false

    /// System-object listeners: the device list plus both defaults. Without the
    /// default-device ones the popover keeps showing — and writes volume/mute to —
    /// whichever device was default when it last refreshed, even though Control
    /// Center or System Settings has since moved playback elsewhere.
    private let listeners: [AudioPropertyListenerRegistration]
    private let outputStateListener: DefaultDeviceStateListener

    public init() {
        defaults = AppDefaults.shared
        // Install the listeners before `self` is fully initialized by capturing
        // only plain functions, then refresh on the main actor.
        listeners = [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDefaultInputDevice
        ].compactMap { selector in
            AudioPropertyListenerRegistration(
                objectID: AudioObjectID(kAudioObjectSystemObject),
                selector: selector,
                scope: kAudioObjectPropertyScopeGlobal
            ) {
                Task { @MainActor in
                    AudioSwitcherController.notifyHardwareChanged()
                }
            }
        }
        outputStateListener = DefaultDeviceStateListener(scope: kAudioObjectPropertyScopeOutput) {
            Task { @MainActor in
                AudioSwitcherController.notifyOutputStateChanged()
            }
        }
        profiles = AudioProfileStore.load(defaults: defaults)
        refresh()
        AudioSwitcherController.activeController = self
    }

    deinit {
        // `deinit` is nonisolated. The listener boxes are `Sendable` and remove the
        // CoreAudio registrations without touching any actor-isolated state.
        listeners.forEach { $0.remove() }
        outputStateListener.remove()
    }

    // A weak handle to the live controller so the (static) listener callbacks can
    // route refreshes back without capturing non-Sendable instance state.
    @MainActor private static weak var activeController: AudioSwitcherController?

    @MainActor private static func notifyHardwareChanged() {
        activeController?.refresh()
    }

    @MainActor private static func notifyOutputStateChanged() {
        // Volume/mute moved on the device we already track: no need to re-enumerate.
        activeController?.refreshVolumeAndMute()
    }

    /// Reloads the full device list, defaults, and volume/mute state.
    public func refresh() {
        // Enumerated through `AudioSwitcherKit` rather than `AudioDeviceKit` because
        // profiles need each device's UID, and only the former reads it. Guarded on an
        // actual change for the same reason `refreshVolumeAndMute` is: the HAL fires the
        // default-device notification liberally, and republishing an identical list just
        // re-renders the popover.
        let all = AudioSwitcherKit.devices()
        if devices != all { devices = all }
        defaultOutputID = AudioDeviceKit.defaultOutputDeviceID()
        defaultInputID = AudioDeviceKit.defaultInputDeviceID()
        // Volume/mute are properties of the default output device, so the
        // listener has to follow it whenever it changes.
        outputStateListener.observe(deviceID: defaultOutputID)
        refreshVolumeAndMute()
    }

    /// Re-reads volume and mute from the current default output.
    ///
    /// Every write is guarded on an actual change. These are `@Published`, and `@Published` does not
    /// dedupe: assigning the same value still fires `objectWillChange` and re-evaluates the whole
    /// popover. CoreAudio posts a VolumeScalar notification for *every* step of a slider drag, so
    /// unconditional writes here re-render the popover on each step — the `isAdjustingVolume` guard
    /// holds `volume` steady, but the redundant publishes alone are enough to make the drag stutter.
    private func refreshVolumeAndMute() {
        guard let outputID = defaultOutputID else {
            if volumeSupported { volumeSupported = false }
            if muteSupported { muteSupported = false }
            if volume != 0 { volume = 0 }
            if isMuted { isMuted = false }
            return
        }
        if let vol = AudioDeviceKit.volume(for: outputID) {
            if !volumeSupported { volumeSupported = true }
            // Don't yank the slider out from under an active drag.
            if !isAdjustingVolume, volume != vol {
                volume = vol
            }
        } else {
            if volumeSupported { volumeSupported = false }
            if !isAdjustingVolume, volume != 0 {
                volume = 0
            }
        }
        if let muted = AudioDeviceKit.isMuted(outputID) {
            if !muteSupported { muteSupported = true }
            if isMuted != muted { isMuted = muted }
        } else {
            if muteSupported { muteSupported = false }
            if isMuted { isMuted = false }
        }
    }

    public func selectOutput(_ device: AudioDevice) {
        AudioDeviceKit.setDefaultOutput(device.id)
        refresh()
    }

    public func selectInput(_ device: AudioDevice) {
        AudioDeviceKit.setDefaultInput(device.id)
        refresh()
    }

    // MARK: - Profiles

    /// Captures the live defaults as a named profile. Returns `nil` — and saves nothing
    /// — when the name is blank or neither current default exposes a UID we could pin
    /// to, so the caller can say why instead of showing a row that never works.
    @discardableResult
    public func saveProfile(named name: String) -> AudioDeviceProfile? {
        guard let profile = AudioDeviceProfile.capture(
            name: name,
            devices: devices,
            defaultOutputID: defaultOutputID,
            defaultInputID: defaultInputID
        ) else { return nil }
        profiles = AudioProfileStore.upsert(profile, defaults: defaults)
        return profile
    }

    /// How `profile` maps onto the hardware attached right now.
    public func resolution(for profile: AudioDeviceProfile) -> AudioProfileResolution {
        profile.resolve(against: devices)
    }

    /// Applies both halves of a profile, then re-reads state. Returns `false` without
    /// touching anything if some pinned device is absent: switching only the half that
    /// resolved would leave the user on a configuration they never asked for.
    @discardableResult
    public func applyProfile(_ profile: AudioDeviceProfile) -> Bool {
        let resolution = resolution(for: profile)
        guard resolution.isApplicable else { return false }
        if let outputID = resolution.outputDeviceID {
            AudioDeviceKit.setDefaultOutput(outputID)
        }
        if let inputID = resolution.inputDeviceID {
            AudioDeviceKit.setDefaultInput(inputID)
        }
        refresh()
        return true
    }

    public func renameProfile(id: UUID, to newName: String) {
        profiles = AudioProfileStore.rename(id: id, to: newName, defaults: defaults)
    }

    public func deleteProfile(id: UUID) {
        profiles = AudioProfileStore.remove(id: id, defaults: defaults)
    }

    /// The profile that already describes the live defaults, if any, so the popover can
    /// mark it the way it marks the selected device rows.
    public var activeProfileID: UUID? {
        let outputUID = uid(of: defaultOutputID)
        let inputUID = uid(of: defaultInputID)
        return profiles.first { $0.matchesDefaults(outputUID: outputUID, inputUID: inputUID) }?.id
    }

    /// The stable UID of a live device id. An empty UID is reported as `nil`: it cannot
    /// identify anything, so it must not compare equal to another UID-less device.
    private func uid(of deviceID: AudioDeviceID?) -> String? {
        guard let deviceID, let device = devices.first(where: { $0.id == deviceID }) else { return nil }
        return device.uid.isEmpty ? nil : device.uid
    }

    /// Applies a slider value to the current default output device.
    public func applyVolume(_ value: Float) {
        guard let outputID = defaultOutputID, volumeSupported else { return }
        AudioDeviceKit.setVolume(value, for: outputID)
    }

    /// The slider's `onEditingChanged`: while editing, the HAL listener's
    /// refresh must not overwrite the value being dragged. On release we
    /// re-read the hardware so the control reflects the true final level.
    public func setVolumeEditing(_ editing: Bool) {
        isAdjustingVolume = editing
        if !editing {
            refreshVolumeAndMute()
        }
    }

    public func toggleMute() {
        guard let outputID = defaultOutputID, muteSupported else { return }
        let newValue = !isMuted
        if AudioDeviceKit.setMuted(newValue, for: outputID) {
            isMuted = newValue
        }
    }
}

public struct AudioSwitcherPopoverView: View {
    @StateObject private var controller = AudioSwitcherController()
    private let onQuit: () -> Void

    /// Non-`nil` while the "save current setup" field is open; holds the draft name.
    @State private var draftProfileName: String?
    /// The profile being renamed, plus its draft name.
    @State private var renamingProfileID: UUID?
    @State private var renameText: String = ""
    /// Why the last save was refused, e.g. no addressable device to pin to.
    @State private var saveRefusalReason: String?
    /// Delete is armed on first click and performed on the second. A profile takes real
    /// effort to reconstruct, and the trash sits next to the row's apply target.
    @State private var pendingDeleteProfileID: UUID?
    @FocusState private var focusedField: ProfileField?

    private enum ProfileField: Hashable {
        case newProfile
        case rename(UUID)
    }

    public init(onQuit: @escaping () -> Void) {
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: AudioSwitcherSizing.sectionSpacing) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .padding(AudioSwitcherSizing.outerPadding)
        .frame(width: AudioSwitcherSizing.panelWidth, height: AudioSwitcherSizing.panelHeight)
        .frostedPanel(cornerRadius: 18)
        // The drag latch is only ever cleared by the slider's own `onEditingChanged(false)`. Dismiss
        // the popover mid-drag and that callback never arrives, so the latch stays set — and because
        // the controller is a `@StateObject` that outlives an open/close cycle, volume would stop
        // tracking the hardware for the rest of the process. Releasing it here also re-reads the
        // device, so the next open shows the true level rather than the value the drag left behind.
        .onDisappear {
            controller.setVolumeEditing(false)
            // The popover is a long-lived view that is merely hidden, so an abandoned
            // name field or a half-armed delete would still be sitting there on the next
            // open — including a red trash the user could hit by accident.
            draftProfileName = nil
            renamingProfileID = nil
            saveRefusalReason = nil
            pendingDeleteProfileID = nil
            focusedField = nil
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "hifispeaker.fill")
                .font(.system(size: AudioSwitcherSizing.titleSize, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text("Audio Switcher")
                .font(.system(size: AudioSwitcherSizing.titleSize, weight: .semibold))
                .foregroundStyle(Color.primary)
            Spacer()
            Button(action: { controller.refresh() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: AudioSwitcherSizing.bodySize, weight: .medium))
                    .foregroundStyle(Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Refresh devices")
        }
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AudioSwitcherSizing.sectionSpacing) {
                volumeSection
                profilesSection
                outputSection
                inputSection
            }
        }
        .frame(maxHeight: AudioSwitcherSizing.scrollMaxHeight)
    }

    private var volumeSection: some View {
        VStack(alignment: .leading, spacing: AudioSwitcherSizing.rowSpacing) {
            sectionHeader("OUTPUT VOLUME")
            if controller.volumeSupported {
                volumeControls
            } else {
                Text("Volume control not available for this device")
                    .font(.system(size: AudioSwitcherSizing.captionSize))
                    .foregroundStyle(Color.secondary)
                    .padding(.vertical, 4)
            }
        }
    }

    private var volumeControls: some View {
        HStack(spacing: 10) {
            Button(action: { controller.toggleMute() }) {
                Image(systemName: muteIconName)
                    .font(.system(size: AudioSwitcherSizing.bodySize, weight: .medium))
                    .foregroundStyle(controller.isMuted ? Color.red : Color.secondary)
                    .frame(width: 20)
            }
            .buttonStyle(.plain)
            .disabled(!controller.muteSupported)
            .help(controller.isMuted ? "Unmute" : "Mute")

            Slider(
                value: Binding(
                    get: { controller.volume },
                    set: { newValue in
                        controller.volume = newValue
                        controller.applyVolume(newValue)
                    }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    controller.setVolumeEditing(editing)
                }
            )

            Text("\(Int((controller.volume * 100).rounded()))%")
                .font(.system(size: AudioSwitcherSizing.captionSize).monospacedDigit())
                .foregroundStyle(Color.secondary)
                .frame(width: 38, alignment: .trailing)
        }
    }

    // MARK: - Profiles

    private var profilesSection: some View {
        VStack(alignment: .leading, spacing: AudioSwitcherSizing.rowSpacing) {
            HStack(spacing: 6) {
                sectionHeader("PROFILES")
                Spacer()
                Button(action: beginSavingProfile) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: AudioSwitcherSizing.bodySize, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("Save the current input and output as a profile")
            }

            if draftProfileName != nil {
                profileNameField(
                    text: Binding(
                        get: { draftProfileName ?? "" },
                        set: { draftProfileName = $0 }
                    ),
                    field: .newProfile,
                    placeholder: "Profile name",
                    onCommit: commitNewProfile,
                    onCancel: { draftProfileName = nil; saveRefusalReason = nil }
                )
            }

            if let saveRefusalReason {
                Text(saveRefusalReason)
                    .font(.system(size: AudioSwitcherSizing.captionSize))
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if controller.profiles.isEmpty {
                if draftProfileName == nil {
                    emptyRow("No saved profiles")
                }
            } else {
                ForEach(controller.profiles) { profile in
                    profileRow(profile)
                }
            }
        }
    }

    @ViewBuilder
    private func profileRow(_ profile: AudioDeviceProfile) -> some View {
        if renamingProfileID == profile.id {
            profileNameField(
                text: $renameText,
                field: .rename(profile.id),
                placeholder: profile.name,
                onCommit: { commitRename(of: profile) },
                onCancel: { renamingProfileID = nil }
            )
        } else {
            let resolution = controller.resolution(for: profile)
            HStack(spacing: 6) {
                Button(action: {
                    pendingDeleteProfileID = nil
                    controller.applyProfile(profile)
                }) {
                    profileRowLabel(profile, resolution: resolution)
                }
                .buttonStyle(.plain)
                .disabled(!resolution.isApplicable)
                .help(resolution.unavailableReason ?? "Switch to “\(profile.name)”")

                profileActionButton(symbol: "pencil", tint: .secondary, help: "Rename") {
                    pendingDeleteProfileID = nil
                    renameText = profile.name
                    renamingProfileID = profile.id
                    focusedField = .rename(profile.id)
                }
                profileActionButton(
                    symbol: pendingDeleteProfileID == profile.id ? "trash.fill" : "trash",
                    tint: pendingDeleteProfileID == profile.id ? .red : .secondary,
                    help: pendingDeleteProfileID == profile.id ? "Click again to delete" : "Delete profile"
                ) {
                    if pendingDeleteProfileID == profile.id {
                        controller.deleteProfile(id: profile.id)
                        pendingDeleteProfileID = nil
                    } else {
                        pendingDeleteProfileID = profile.id
                    }
                }
            }
        }
    }

    private func profileRowLabel(
        _ profile: AudioDeviceProfile,
        resolution: AudioProfileResolution
    ) -> some View {
        let isActive = controller.activeProfileID == profile.id
        return HStack(spacing: 8) {
            Image(systemName: isActive ? "checkmark.circle.fill" : profileIconName(for: resolution))
                .font(.system(size: AudioSwitcherSizing.checkmarkSize, weight: .medium))
                .foregroundStyle(profileIconColor(isActive: isActive, resolution: resolution))
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name)
                    .font(.system(size: AudioSwitcherSizing.bodySize, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(resolution.isApplicable ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(resolution.unavailableReason ?? resolution.deviceSummary)
                    .font(.system(size: AudioSwitcherSizing.captionSize))
                    .foregroundStyle(resolution.isApplicable ? Color.secondary : Color.orange)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, AudioSwitcherSizing.rowVerticalPadding)
        .padding(.horizontal, AudioSwitcherSizing.rowHorizontalPadding)
        .frame(minHeight: AudioSwitcherSizing.rowMinHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(isSelected: isActive))
    }

    private func profileIconName(for resolution: AudioProfileResolution) -> String {
        resolution.isApplicable ? "square.stack.3d.up" : "exclamationmark.triangle"
    }

    private func profileIconColor(isActive: Bool, resolution: AudioProfileResolution) -> Color {
        if isActive { return .accentColor }
        return resolution.isApplicable ? .secondary : .orange
    }

    private func profileActionButton(
        symbol: String,
        tint: Color,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: AudioSwitcherSizing.profileActionSize, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: AudioSwitcherSizing.iconButtonSize * 0.7, height: AudioSwitcherSizing.rowMinHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func profileNameField(
        text: Binding<String>,
        field: ProfileField,
        placeholder: String,
        onCommit: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: AudioSwitcherSizing.bodySize))
                .focused($focusedField, equals: field)
                .onSubmit(onCommit)
            Button(action: onCommit) {
                Image(systemName: "checkmark")
                    .font(.system(size: AudioSwitcherSizing.profileActionSize, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("Save")
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: AudioSwitcherSizing.profileActionSize, weight: .semibold))
                    .foregroundStyle(Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Cancel")
        }
    }

    private func beginSavingProfile() {
        pendingDeleteProfileID = nil
        renamingProfileID = nil
        saveRefusalReason = nil
        draftProfileName = suggestedProfileName()
        focusedField = .newProfile
    }

    /// Seeds the field with the current output's name — the thing the user is most
    /// likely to be naming the profile after — falling back to a numbered default.
    private func suggestedProfileName() -> String {
        if let output = controller.devices.first(where: { $0.id == controller.defaultOutputID }),
           !output.name.isEmpty,
           !controller.profiles.contains(where: { $0.name == output.name }) {
            return output.name
        }
        return "Profile \(controller.profiles.count + 1)"
    }

    private func commitNewProfile() {
        guard let name = draftProfileName else { return }
        if controller.saveProfile(named: name) != nil {
            draftProfileName = nil
            saveRefusalReason = nil
            focusedField = nil
        } else {
            saveRefusalReason = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Give the profile a name."
                : "Nothing to save: the current devices report no stable identifier."
        }
    }

    private func commitRename(of profile: AudioDeviceProfile) {
        controller.renameProfile(id: profile.id, to: renameText)
        renamingProfileID = nil
        focusedField = nil
    }

    // MARK: - Devices

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: AudioSwitcherSizing.rowSpacing) {
            sectionHeader("OUTPUT")
            if controller.outputDevices.isEmpty {
                emptyRow("No output devices")
            } else {
                ForEach(controller.outputDevices) { device in
                    deviceRow(
                        device: device,
                        isSelected: device.id == controller.defaultOutputID,
                        action: { controller.selectOutput(device) }
                    )
                }
            }
        }
    }

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: AudioSwitcherSizing.rowSpacing) {
            sectionHeader("INPUT")
            if controller.inputDevices.isEmpty {
                emptyRow("No input devices")
            } else {
                ForEach(controller.inputDevices) { device in
                    deviceRow(
                        device: device,
                        isSelected: device.id == controller.defaultInputID,
                        action: { controller.selectInput(device) }
                    )
                }
            }
        }
    }

    // MARK: - Row builders

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: AudioSwitcherSizing.sectionHeaderSize, weight: .semibold))
            .foregroundStyle(Color.secondary)
            .kerning(0.5)
    }

    private func emptyRow(_ message: String) -> some View {
        Text(message)
            .font(.system(size: AudioSwitcherSizing.bodySize))
            .foregroundStyle(Color.secondary)
            .padding(.vertical, AudioSwitcherSizing.rowVerticalPadding)
    }

    private func deviceRow(
        device: AudioDevice,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: AudioSwitcherSizing.checkmarkSize, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(device.name)
                    .font(.system(size: AudioSwitcherSizing.bodySize, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.vertical, AudioSwitcherSizing.rowVerticalPadding)
            .padding(.horizontal, AudioSwitcherSizing.rowHorizontalPadding)
            .frame(minHeight: AudioSwitcherSizing.rowMinHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground(isSelected: isSelected))
        }
        .buttonStyle(.plain)
    }

    private func rowBackground(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: AudioSwitcherSizing.rowCornerRadius, style: .continuous)
            .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("\(controller.outputDevices.count) out · \(controller.inputDevices.count) in")
                .font(.system(size: AudioSwitcherSizing.captionSize))
                .foregroundStyle(Color.secondary)
            Spacer()
            Button(action: onQuit) {
                Text("Quit")
                    .font(.system(size: AudioSwitcherSizing.bodySize, weight: .medium))
                    .foregroundStyle(Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Quit Audio Switcher")
        }
    }

    private var muteIconName: String {
        if controller.isMuted {
            return "speaker.slash.fill"
        }
        if controller.volume <= 0.001 {
            return "speaker.fill"
        }
        if controller.volume < 0.5 {
            return "speaker.wave.1.fill"
        }
        return "speaker.wave.2.fill"
    }
}
