import AppKit
import SwiftUI

/// The floating Keep Awake popover: a prominent on/off control, a "keep display on" toggle, a row
/// of duration presets, and a footer with a settings/quit affordance. Content is scaled to match
/// the menu-bar/display scale so it fits the scaled panel (same approach as the other tools).
public struct KeepAwakePopoverView: View {
    @ObservedObject var controller: KeepAwakeController
    var onQuit: () -> Void

    @State private var isShowingSettings = false
    private let scale = KeepAwakeSizing.currentScale

    /// Duration presets. `nil` means indefinitely.
    private let presets: [DurationPreset] = [
        DurationPreset(title: "Indefinitely", seconds: nil),
        DurationPreset(title: "15 min", seconds: 15 * 60),
        DurationPreset(title: "30 min", seconds: 30 * 60),
        DurationPreset(title: "1 hour", seconds: 60 * 60),
        DurationPreset(title: "2 hours", seconds: 2 * 60 * 60),
        DurationPreset(title: "5 hours", seconds: 5 * 60 * 60)
    ]

    public init(controller: KeepAwakeController, onQuit: @escaping () -> Void) {
        self.controller = controller
        self.onQuit = onQuit
    }

    private func s(_ value: CGFloat) -> CGFloat { value * scale }

    private var accent: Color { .brown }

    public var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                Divider().opacity(0.6)
                heroToggle
                displayToggleRow
                Divider().opacity(0.6)
                durationGrid
                Spacer(minLength: 0)
                footer
            }

            if isShowingSettings {
                PreferencesOverlay(cornerRadius: 18) {
                    KeepAwakeSettingsView(
                        controller: controller,
                        onQuit: onQuit,
                        onClose: { isShowingSettings = false }
                    )
                }
            }
        }
        .frame(width: KeepAwakeSizing.preferredSize().width, height: KeepAwakeSizing.preferredSize().height)
        .frostedPanel(cornerRadius: 18)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: s(8)) {
            Image(systemName: controller.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                .font(.system(size: s(15), weight: .semibold))
                .foregroundStyle(controller.isActive ? accent : Color.secondary)

            Text("Keep Awake")
                .font(.system(size: s(15), weight: .bold))
                .foregroundStyle(.primary.opacity(0.9))

            Spacer()

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
            controller.toggle()
        } label: {
            VStack(spacing: s(8)) {
                ZStack {
                    Circle()
                        .fill((controller.isActive ? accent : Color.secondary).opacity(0.15))
                        .frame(width: s(80), height: s(80))

                    Image(systemName: controller.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                        .font(.system(size: s(34), weight: .semibold))
                        .foregroundStyle(controller.isActive ? accent : Color.secondary)
                        .symbolRenderingMode(.hierarchical)
                }

                Text(controller.isActive ? "Keep Awake: On" : "Keep Awake: Off")
                    .font(.system(size: s(15), weight: .bold))
                    .foregroundStyle(controller.isActive ? accent : .secondary)

                Text(statusSubtitle)
                    .font(.system(size: s(11), weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, s(16))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var statusSubtitle: String {
        guard controller.isActive else {
            return "Your Mac can sleep normally"
        }
        if let remaining = controller.remaining {
            return "Awake for \(Self.formatRemaining(remaining))"
        }
        return "Awake until you turn this off"
    }

    // MARK: - Display toggle

    private var displayToggleRow: some View {
        HStack(spacing: s(10)) {
            Image(systemName: "display")
                .font(.system(size: s(13), weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: s(18))

            Text("Keep display on too")
                .font(.system(size: s(13), weight: .semibold))

            Spacer()

            GreenSwitch(isOn: Binding(
                get: { controller.keepDisplayOn },
                set: { controller.setKeepDisplayOn($0) }
            ))
        }
        .padding(.horizontal, s(16))
        .padding(.bottom, s(12))
    }

    // MARK: - Duration presets

    private var durationGrid: some View {
        VStack(alignment: .leading, spacing: s(8)) {
            Text("DURATION")
                .font(.system(size: s(10), weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.top, s(12))

            LazyVGrid(columns: columns, spacing: s(8)) {
                ForEach(presets) { preset in
                    durationButton(preset)
                }
            }
        }
        .padding(.horizontal, s(16))
        .padding(.bottom, s(10))
    }

    private var columns: [GridItem] {
        [
            GridItem(.flexible(), spacing: s(8)),
            GridItem(.flexible(), spacing: s(8)),
            GridItem(.flexible(), spacing: s(8))
        ]
    }

    private func durationButton(_ preset: DurationPreset) -> some View {
        Button {
            AppDefaults.shared.set(preset.seconds ?? 0, forKey: DefaultsKey.keepAwakeLastDuration)
            controller.activate(duration: preset.seconds)
        } label: {
            Text(preset.title)
                .font(.system(size: s(12), weight: .semibold))
                .foregroundStyle(isSelected(preset) ? Color.white : .primary)
                .frame(maxWidth: .infinity)
                .frame(height: s(34))
                .background(
                    RoundedRectangle(cornerRadius: s(8), style: .continuous)
                        .fill(isSelected(preset) ? accent : Color.secondary.opacity(0.14))
                )
                .contentShape(RoundedRectangle(cornerRadius: s(8), style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// A preset is "selected" only while a session matching it is active.
    private func isSelected(_ preset: DurationPreset) -> Bool {
        guard controller.isActive else { return false }
        if preset.seconds == nil {
            return controller.remaining == nil
        }
        // A timed preset is shown selected while any countdown is running.
        return controller.remaining != nil
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if controller.isActive {
                Button {
                    controller.deactivate()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.system(size: s(12), weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

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

    // MARK: - Helpers

    static func formatRemaining(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

private struct DurationPreset: Identifiable {
    let title: String
    let seconds: TimeInterval?
    var id: String { title }
}

// MARK: - Settings

private struct KeepAwakeSettingsView: View {
    @ObservedObject var controller: KeepAwakeController
    var onQuit: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Keep Awake Settings")
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

            settingRow(title: "Keep display on too") {
                GreenSwitch(isOn: Binding(
                    get: { controller.keepDisplayOn },
                    set: { controller.setKeepDisplayOn($0) }
                ))
            }

            Text("When on, your screen stays lit as well as the system staying awake. Otherwise only idle system sleep is prevented; the display may still dim and sleep.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Button(role: .destructive) {
                onClose()
                onQuit()
            } label: {
                Label("Quit Keep Awake", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()
        }
        .padding(20)
        .frame(width: 320, height: 230)
    }

    private func settingRow<Trailing: View>(title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            trailing()
        }
    }
}
