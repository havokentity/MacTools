import SwiftUI

public struct FocusTimerPopoverView: View {
    @ObservedObject var controller: FocusTimerController
    var onQuit: () -> Void
    @State private var showSettings = false

    public init(controller: FocusTimerController, onQuit: @escaping () -> Void) {
        self.controller = controller
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(spacing: s(14)) {
            header
            timerDial
            phaseInfo
            controlRow
            if showSettings {
                settingsArea
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(s(18))
        .frame(width: s(320), height: s(440))
        .frostedPanel(cornerRadius: 18)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: s(8)) {
            Image(systemName: "timer")
                .font(.system(size: s(15), weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text("Focus Timer")
                .font(.system(size: s(15), weight: .semibold))
                .foregroundStyle(Color.primary)
            Spacer()
            Button(action: { showSettings.toggle() }) {
                Image(systemName: "gearshape")
                    .font(.system(size: s(13), weight: .semibold))
                    .foregroundStyle(showSettings ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            Button(action: onQuit) {
                Image(systemName: "power")
                    .font(.system(size: s(12), weight: .semibold))
                    .foregroundStyle(Color.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Timer dial (depleting progress ring + MM:SS)

    private var timerDial: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: s(10))
            Circle()
                .trim(from: 0, to: CGFloat(1 - controller.progress))
                .stroke(
                    phaseColor,
                    style: StrokeStyle(lineWidth: s(10), lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.2), value: controller.progress)
            VStack(spacing: s(2)) {
                Text(timeString(controller.remaining))
                    .font(.system(size: s(40), weight: .bold, design: .rounded))
                    .foregroundStyle(Color.primary)
                    .monospacedDigit()
                Text(controller.isRunning ? "Running" : "Paused")
                    .font(.system(size: s(11), weight: .medium))
                    .foregroundStyle(Color.secondary)
            }
        }
        .frame(width: s(170), height: s(170))
        .padding(.top, s(4))
    }

    private var phaseInfo: some View {
        VStack(spacing: s(4)) {
            Text(controller.phase.displayName)
                .font(.system(size: s(16), weight: .semibold))
                .foregroundStyle(phaseColor)
            Text("\(controller.completedFocusCount) focus session\(controller.completedFocusCount == 1 ? "" : "s") today")
                .font(.system(size: s(11)))
                .foregroundStyle(Color.secondary)
        }
    }

    // MARK: - Controls

    private var controlRow: some View {
        HStack(spacing: s(10)) {
            Button(action: { controller.reset() }) {
                controlLabel(icon: "arrow.counterclockwise", tint: Color.secondary)
            }
            .buttonStyle(.plain)

            Button(action: { toggleRun() }) {
                primaryControlLabel
            }
            .buttonStyle(.plain)

            Button(action: { controller.skip() }) {
                controlLabel(icon: "forward.end", tint: Color.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private var primaryControlLabel: some View {
        HStack(spacing: s(6)) {
            Image(systemName: controller.isRunning ? "pause.fill" : "play.fill")
                .font(.system(size: s(13), weight: .bold))
            Text(controller.isRunning ? "Pause" : "Start")
                .font(.system(size: s(14), weight: .semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, s(10))
        .background(
            RoundedRectangle(cornerRadius: s(10), style: .continuous)
                .fill(controller.isRunning ? Color.orange.opacity(0.85) : Color.green.opacity(0.85))
        )
        .foregroundStyle(Color.white)
    }

    private func controlLabel(icon: String, tint: Color) -> some View {
        Image(systemName: icon)
            .font(.system(size: s(14), weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: s(44), height: s(40))
            .background(
                RoundedRectangle(cornerRadius: s(10), style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
    }

    // MARK: - Settings

    private var settingsArea: some View {
        VStack(spacing: s(8)) {
            stepperRow(
                title: "Focus",
                value: Binding(get: { controller.focusMinutes }, set: { controller.focusMinutes = $0 }),
                range: 1...90,
                suffix: "min"
            )
            stepperRow(
                title: "Short break",
                value: Binding(get: { controller.shortBreakMinutes }, set: { controller.shortBreakMinutes = $0 }),
                range: 1...30,
                suffix: "min"
            )
            stepperRow(
                title: "Long break",
                value: Binding(get: { controller.longBreakMinutes }, set: { controller.longBreakMinutes = $0 }),
                range: 1...60,
                suffix: "min"
            )
            stepperRow(
                title: "Sessions / long break",
                value: Binding(get: { controller.sessionsBeforeLongBreak }, set: { controller.sessionsBeforeLongBreak = $0 }),
                range: 1...10,
                suffix: ""
            )
        }
        .padding(s(12))
        .background(
            RoundedRectangle(cornerRadius: s(12), style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private func stepperRow(title: String, value: Binding<Int>, range: ClosedRange<Int>, suffix: String) -> some View {
        HStack(spacing: s(6)) {
            Text(title)
                .font(.system(size: s(12)))
                .foregroundStyle(Color.primary)
            Spacer()
            Text(suffix.isEmpty ? "\(value.wrappedValue)" : "\(value.wrappedValue) \(suffix)")
                .font(.system(size: s(12), weight: .semibold, design: .rounded))
                .foregroundStyle(Color.secondary)
                .monospacedDigit()
            Stepper("", value: value, in: range)
                .labelsHidden()
        }
    }

    private var footer: some View {
        Text(controller.isRunning
            ? "Stay focused — auto-advances on completion"
            : "Press Start to begin a focus session")
            .font(.system(size: s(11)))
            .foregroundStyle(Color.secondary)
            .multilineTextAlignment(.center)
    }

    // MARK: - Helpers

    private func toggleRun() {
        if controller.isRunning {
            controller.pause()
        } else {
            controller.start()
        }
    }

    private var phaseColor: Color {
        switch controller.phase {
        case .focus: return Color.accentColor
        case .shortBreak: return Color.green
        case .longBreak: return Color.blue
        }
    }

    private func timeString(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.up)))
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func s(_ value: CGFloat) -> CGFloat {
        value * FocusTimerSizing.currentScale
    }
}
