import AppKit
import CoreAudio
import SwiftUI

/// A `Sendable` box that owns the CoreAudio device-list listener registration and
/// knows how to tear it down. Kept separate from the `@MainActor` controller so it
/// can be released from the controller's nonisolated `deinit` without touching
/// actor-isolated, non-`Sendable` state.
private final class DevicesListenerRegistration: @unchecked Sendable {
    private let block: AudioObjectPropertyListenerBlock
    private var installed = false

    init?(onChange: @escaping @Sendable () -> Void) {
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            // CoreAudio invokes this on the dispatch queue we supply (main).
            onChange()
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
        guard status == noErr else { return nil }
        self.block = block
        self.installed = true
    }

    func remove() {
        guard installed else { return }
        installed = false
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
    }
}

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

    private let listener: DevicesListenerRegistration?

    public init() {
        // Install the device-list listener before `self` is fully initialized by
        // capturing only a plain function, then refresh on the main actor.
        listener = DevicesListenerRegistration {
            Task { @MainActor in
                AudioSwitcherController.notifyDeviceListChanged()
            }
        }
        refresh()
        AudioSwitcherController.activeController = self
    }

    deinit {
        // `deinit` is nonisolated. The listener box is `Sendable` and removes the
        // CoreAudio registration without touching any actor-isolated state.
        listener?.remove()
    }

    // A weak handle to the live controller so the (static) listener callback can
    // route refreshes back without capturing non-Sendable instance state.
    @MainActor private static weak var activeController: AudioSwitcherController?

    @MainActor private static func notifyDeviceListChanged() {
        activeController?.refresh()
    }

    /// Reloads the full device list, defaults, and volume/mute state.
    public func refresh() {
        let all = AudioDeviceKit.allDevices()
        outputDevices = all.filter { $0.hasOutput }
        inputDevices = all.filter { $0.hasInput }
        defaultOutputID = AudioDeviceKit.defaultOutputDeviceID()
        defaultInputID = AudioDeviceKit.defaultInputDeviceID()
        refreshVolumeAndMute()
    }

    private func refreshVolumeAndMute() {
        guard let outputID = defaultOutputID else {
            volumeSupported = false
            muteSupported = false
            volume = 0
            isMuted = false
            return
        }
        if let vol = AudioDeviceKit.volume(for: outputID) {
            volumeSupported = true
            volume = vol
        } else {
            volumeSupported = false
            volume = 0
        }
        if let muted = AudioDeviceKit.isMuted(outputID) {
            muteSupported = true
            isMuted = muted
        } else {
            muteSupported = false
            isMuted = false
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
                in: 0...1
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
