import AppKit
import SwiftUI

/// The Focus Timer popover: a large MM:SS countdown inside a depleting progress ring, the current
/// phase, transport controls (Start/Pause, Reset, Skip), a completed-focus tally, and a settings
/// overlay for the durations. Content is scaled to match the menu-bar/display scale (same approach as
/// the other tools).
public struct FocusTimerPopoverView: View {
    @ObservedObject var controller: FocusTimerController
    var onQuit: () -> Void

    @State private var isShowingSettings = false
    private let scale = FocusTimerSizing.currentScale

    public init(controller: FocusTimerController, onQuit: @escaping () -> Void) {
        self.controller = controller
        self.onQuit = onQuit
    }

    private func s(_ value: CGFloat) -> CGFloat { value * scale }

    private var accent: Color { .red }

    /// The tint used for the current phase: the accent for focus, a calmer colour for breaks.
    private var phaseColor: Color {
        switch controller.phase {
        case .focus: return .red
        case .shortBreak: return .green
        case .longBreak: return .teal
        }
    }

    public var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                Divider().opacity(0.6)
                ring
                phaseLabel
                tallyRow
                Spacer(minLength: 0)
                controls
                footer
            }

            if isShowingSettings {
                PreferencesOverlay(cornerRadius: 18) {
                    FocusTimerSettingsView(
                        controller: controller,
                        onQuit: onQuit,
                        onClose: { isShowingSettings = false }
                    )
                }
            }
        }
        .frame(width: FocusTimerSizing.preferredSize().width, height: FocusTimerSizing.preferredSize().height)
        .frostedPanel(cornerRadius: 18)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: s(8)) {
            Image(systemName: "timer")
                .font(.system(size: s(15), weight: .semibold))
                .foregroundStyle(controller.isRunning ? phaseColor : Color.secondary)

            Text("Focus Timer")
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

    // MARK: - Ring + countdown

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.16), lineWidth: s(12))

            // Depletes as the phase elapses: the trimmed arc shrinks from full toward empty.
            Circle()
                .trim(from: 0, to: max(0.0001, 1 - controller.progress))
                .stroke(
                    phaseColor,
                    style: StrokeStyle(lineWidth: s(12), lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.25), value: controller.progress)

            VStack(spacing: s(2)) {
                Text(Self.formatTime(controller.remaining))
                    .font(.system(size: s(46), weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                Text(controller.isRunning ? "Running" : (controller.progress > 0 ? "Paused" : "Ready"))
                    .font(.system(size: s(11), weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: s(180), height: s(180))
        .padding(.top, s(16))
        .padding(.horizontal, s(16))
    }

    private var phaseLabel: some View {
        HStack(spacing: s(6)) {
            Circle()
                .fill(phaseColor)
                .frame(width: s(8), height: s(8))
            Text(controller.phase.title)
                .font(.system(size: s(15), weight: .bold))
                .foregroundStyle(phaseColor)
        }
        .padding(.top, s(12))
    }

    private var tallyRow: some View {
        Text("Completed focus sessions: \(controller.completedFocusCount)")
            .font(.system(size: s(11), weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.top, s(4))
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: s(12)) {
            transportButton(
                title: controller.isRunning ? "Pause" : "Start",
                systemImage: controller.isRunning ? "pause.fill" : "play.fill",
                prominent: true
            ) {
                if controller.isRunning {
                    controller.pause()
                } else {
                    controller.start()
                }
            }

            transportButton(title: "Reset", systemImage: "arrow.counterclockwise", prominent: false) {
                controller.reset()
            }

            transportButton(title: "Skip", systemImage: "forward.fill", prominent: false) {
                controller.skip()
            }
        }
        .padding(.horizontal, s(16))
        .padding(.top, s(10))
    }

    private func transportButton(
        title: String,
        systemImage: String,
        prominent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: s(4)) {
                Image(systemName: systemImage)
                    .font(.system(size: s(14), weight: .semibold))
                Text(title)
                    .font(.system(size: s(11), weight: .semibold))
            }
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .frame(maxWidth: .infinity)
            .frame(height: s(48))
            .background(
                RoundedRectangle(cornerRadius: s(10), style: .continuous)
                    .fill(prominent ? accent : Color.secondary.opacity(0.14))
            )
            .contentShape(RoundedRectangle(cornerRadius: s(10), style: .continuous))
        }
        .buttonStyle(.plain)
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

    // MARK: - Helpers

    /// Formats a remaining interval as MM:SS (rounding up so the display only shows 00:00 at the
    /// instant the phase truly ends). Public so the menu-bar status view can render the same string.
    public static func formatTime(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.up)))
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - Settings

private struct FocusTimerSettingsView: View {
    @ObservedObject var controller: FocusTimerController
    var onQuit: () -> Void
    var onClose: () -> Void

    @AppStorage(DefaultsKey.focusTimerFocusMinutes, store: AppDefaults.shared) private var focusMinutes = 25
    @AppStorage(DefaultsKey.focusTimerShortBreakMinutes, store: AppDefaults.shared) private var shortBreakMinutes = 5
    @AppStorage(DefaultsKey.focusTimerLongBreakMinutes, store: AppDefaults.shared) private var longBreakMinutes = 15
    @AppStorage(DefaultsKey.focusTimerLongBreakInterval, store: AppDefaults.shared) private var longBreakInterval = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Focus Timer Settings")
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

            stepperRow(title: "Focus", value: $focusMinutes, range: 1...120, unit: "min") {
                // Refresh the displayed time when idle so a new duration shows immediately.
                if !controller.isRunning {
                    controller.reset()
                }
            }

            stepperRow(title: "Short break", value: $shortBreakMinutes, range: 1...60, unit: "min") { }

            stepperRow(title: "Long break", value: $longBreakMinutes, range: 1...90, unit: "min") { }

            stepperRow(title: "Long break every", value: $longBreakInterval, range: 1...12, unit: "focus") { }

            Divider()

            Button(role: .destructive) {
                onClose()
                onQuit()
            } label: {
                Label("Quit Focus Timer", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()
        }
        .padding(20)
        .frame(width: 340, height: 320)
    }

    private func stepperRow(
        title: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        unit: String,
        onChange: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Text("\(value.wrappedValue) \(unit)")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Stepper("", value: value, in: range)
                .labelsHidden()
                .onChange(of: value.wrappedValue) { _, _ in
                    onChange()
                }
        }
    }
}
