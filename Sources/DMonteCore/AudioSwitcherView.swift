import AppKit
import CoreAudio
import SwiftUI

/// Drives the Audio Switcher popover: enumerates devices, tracks the current
/// defaults, and exposes volume / mute control for the active output device.
/// Refreshes live when audio hardware is added or removed.
@MainActor
public final class AudioSwitcherController: ObservableObject {
    @Published public private(set) var outputDevices: [AudioDeviceKit.AudioDevice] = []
    @Published public private(set) var inputDevices: [AudioDeviceKit.AudioDevice] = []
    @Published public private(set) var defaultOutputID: AudioDeviceID?
    @Published public private(set) var defaultInputID: AudioDeviceID?
    @Published public var volume: Float = 0
    @Published public private(set) var volumeSupported: Bool = false
    @Published public var isMuted: Bool = false
    @Published public private(set) var muteSupported: Bool = false

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
        let all = AudioDeviceKit.allDevices()
        outputDevices = all.filter { $0.hasOutput }
        inputDevices = all.filter { $0.hasInput }
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

    public func selectOutput(_ device: AudioDeviceKit.AudioDevice) {
        AudioDeviceKit.setDefaultOutput(device.id)
        refresh()
    }

    public func selectInput(_ device: AudioDeviceKit.AudioDevice) {
        AudioDeviceKit.setDefaultInput(device.id)
        refresh()
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
        .onDisappear { controller.setVolumeEditing(false) }
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
        device: AudioDeviceKit.AudioDevice,
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
