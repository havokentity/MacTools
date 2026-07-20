import AppKit
import SwiftUI

/// The floating Mic Control popover: a hero mute button for the default input
/// device, an input-gain slider where the hardware offers one, and a footer with
/// settings/quit. Content is scaled to match the menu-bar/display scale so it fits
/// the scaled panel (same approach as the other tools).
public struct MicControlPopoverView: View {
    @ObservedObject var controller: MicControlController
    var onQuit: () -> Void

    @State private var isShowingSettings = false
    private let scale = MicControlSizing.currentScale

    public init(controller: MicControlController, onQuit: @escaping () -> Void) {
        self.controller = controller
        self.onQuit = onQuit
    }

    private func s(_ value: CGFloat) -> CGFloat { value * scale }

    /// Red for muted — the one state a user must spot instantly — and a calm green
    /// for live. The unusable states stay grey so they never read as "armed".
    private var accent: Color {
        switch controller.state {
        case .muted:
            return .red
        case .live:
            return Color(red: 0.00, green: 0.55, blue: 0.22)
        case .unsupported, .noDevice:
            return .secondary
        }
    }

    public var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                Divider().opacity(0.6)
                heroToggle
                Divider().opacity(0.6)
                gainSection
                Spacer(minLength: 0)
                footer
            }

            if isShowingSettings {
                PreferencesOverlay(cornerRadius: 18) {
                    MicControlSettingsView(
                        controller: controller,
                        onQuit: onQuit,
                        onClose: { isShowingSettings = false }
                    )
                }
            }
        }
        .frame(width: MicControlSizing.preferredSize().width, height: MicControlSizing.preferredSize().height)
        .frostedPanel(cornerRadius: 18)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: s(8)) {
            Image(systemName: MicControlKit.trayGlyphName(for: controller.state))
                .font(.system(size: s(15), weight: .semibold))
                .foregroundStyle(accent)

            Text("Mic Control")
                .font(.system(size: s(15), weight: .bold))
                .foregroundStyle(.primary.opacity(0.9))

            Spacer()

            Button {
                controller.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: s(13), weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Re-read the default input device")

            Button {
                isShowingSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: s(14), weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, s(16))
        .padding(.top, s(14))
        .padding(.bottom, s(10))
    }

    // MARK: - Hero toggle

    private var heroToggle: some View {
        Button {
            controller.toggleMute()
        } label: {
            VStack(spacing: s(8)) {
                ZStack {
                    Circle()
                        .fill(accent.opacity(0.15))
                        .frame(width: s(80), height: s(80))

                    Image(systemName: MicControlKit.trayGlyphName(for: controller.state))
                        .font(.system(size: s(34), weight: .semibold))
                        .foregroundStyle(accent)
                        .symbolRenderingMode(.hierarchical)
                }

                Text(MicControlKit.title(for: controller.state))
                    .font(.system(size: s(15), weight: .bold))
                    .foregroundStyle(accent)

                Text(MicControlKit.subtitle(for: controller.state, deviceName: controller.deviceName))
                    .font(.system(size: s(11), weight: .medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, s(16))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, s(16))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!MicControlKit.canToggle(controller.state))
        .help(MicControlKit.actionTitle(for: controller.state))
    }

    // MARK: - Input gain

    private var gainSection: some View {
        VStack(alignment: .leading, spacing: s(8)) {
            Text("INPUT LEVEL")
                .font(.system(size: s(10), weight: .bold))
                .foregroundStyle(.secondary)

            if controller.gainSupported {
                gainControls
            } else {
                // Honest, not hidden: the row stays so the panel doesn't reflow,
                // and the sentence says why the slider isn't there.
                Text("This device doesn’t expose an adjustable input level.")
                    .font(.system(size: s(11)))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, s(16))
        .padding(.top, s(12))
        .padding(.bottom, s(10))
    }

    private var gainControls: some View {
        HStack(spacing: s(10)) {
            Image(systemName: "mic")
                .font(.system(size: s(12), weight: .semibold))
                .foregroundStyle(.secondary)

            Slider(
                value: Binding(
                    get: { controller.gain },
                    set: { newValue in
                        controller.gain = newValue
                        controller.applyGain(newValue)
                    }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    controller.setGainEditing(editing)
                }
            )

            Text(MicControlKit.gainPercentLabel(controller.gain))
                .font(.system(size: s(11), weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: s(38), alignment: .trailing)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()

            Button {
                onQuit()
            } label: {
                Label("Quit", systemImage: "power")
                    .font(.system(size: s(12), weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, s(16))
        .padding(.top, s(8))
        .padding(.bottom, s(14))
    }
}

// MARK: - Settings

private struct MicControlSettingsView: View {
    @ObservedObject var controller: MicControlController
    var onQuit: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Mic Control Settings")
                    .font(.system(size: 16, weight: .bold))
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }

            HStack {
                Text("Input device")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(controller.deviceName ?? "None")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Text("Mic Control mutes whichever device macOS is using as the default input, so every app that listens to it goes quiet at once. It changes the device’s mute switch rather than recording, so it never asks for microphone access. Pick a different input in System Settings › Sound and the menu bar follows it.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Button(role: .destructive) {
                onClose()
                onQuit()
            } label: {
                Label("Quit Mic Control", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()
        }
        .padding(20)
        .frame(width: MicControlSizing.settingsSize().width, height: MicControlSizing.settingsSize().height)
    }
}
