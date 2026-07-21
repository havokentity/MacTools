import AppKit
import SwiftUI

/// Captures the next keyDown while the user records a custom shortcut. A local NSEvent monitor
/// sees the panel's key events (the popover panel can become key); Esc cancels; the event is
/// swallowed so the recorded keystroke doesn't also type into the UI.
@MainActor
final class ShortcutRecorder: ObservableObject {
    /// The action currently being recorded, or nil when idle.
    @Published private(set) var recordingAction: WindowAction?

    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var onResumeHotKeys: (() -> Void)?

    /// Starts recording for `action`. `onCapture` receives the captured shortcut, or nil when
    /// the user cancels with Esc. Recording also auto-cancels when the popover panel resigns
    /// key (it is ordered out without tearing down the SwiftUI hierarchy, so `onDisappear`
    /// alone can't be relied on to clean the monitor up).
    ///
    /// `suspendHotKeys`/`resumeHotKeys` bracket the capture: the global snap hotkeys are released
    /// while recording so Carbon doesn't swallow a combination the recorder is trying to read
    /// (otherwise pressing e.g. ⌃⌥→ just fires Right Half and the monitor never sees it), and are
    /// re-registered on every exit path (capture, Esc, or the panel losing key).
    func begin(
        for action: WindowAction,
        suspendHotKeys: @escaping () -> Void = {},
        resumeHotKeys: @escaping () -> Void = {},
        onCapture: @escaping (WindowShortcut?) -> Void
    ) {
        cancel() // ends any prior recording (running its own resume) before we suspend again
        onResumeHotKeys = resumeHotKeys
        recordingAction = action
        suspendHotKeys()
        NSApp.keyWindow?.makeFirstResponder(nil)
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cancel()
            }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            let escapeKeyCode: UInt16 = 53
            if event.keyCode == escapeKeyCode, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                self.end()
                onCapture(nil)
            } else {
                let shortcut = Self.shortcut(from: event)
                self.end()
                onCapture(shortcut)
            }
            return nil // swallow the keystroke
        }
    }

    static func shortcut(from event: NSEvent) -> WindowShortcut {
        WindowShortcut(
            keyCode: normalizedKeyCode(UInt32(event.keyCode)),
            modifiers: carbonModifiers(from: event.modifierFlags)
        )
    }

    static func normalizedKeyCode(_ keyCode: UInt32) -> UInt32 {
        keyCode == HotKeyCode.keypadEnter ? HotKeyCode.returnKey : keyCode
    }

    /// Stops recording without capturing.
    func cancel() {
        end()
    }

    private func end() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        recordingAction = nil
        // Re-register the global hotkeys we released for capture — after the local monitor is gone,
        // and on every exit path. Cleared first so a re-entrant begin() can't double-resume.
        let resume = onResumeHotKeys
        onResumeHotKeys = nil
        resume?()
    }

    /// AppKit modifier flags → Carbon modifier mask (the format `RegisterEventHotKey` wants).
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        let device = flags.intersection(.deviceIndependentFlagsMask)
        if device.contains(.command) { mask |= HotKeyModifier.command }
        if device.contains(.shift) { mask |= HotKeyModifier.shift }
        if device.contains(.option) { mask |= HotKeyModifier.option }
        if device.contains(.control) { mask |= HotKeyModifier.control }
        return mask
    }
}

/// The Window Manager popover: a grid of snap tiles that resize the target app's focused window
/// (the app snapshotted when the popover opened — shown as "Will snap: X"), an
/// Accessibility-permission banner when the grant is missing, and a collapsible
/// keyboard-shortcuts section where every action's shortcut can be remapped.
public struct WindowManagerPopoverView: View {
    @ObservedObject var controller: WindowManagerController
    @StateObject private var recorder = ShortcutRecorder()
    @State private var shortcutsExpanded = false
    @State private var shortcutNotice: String?
    var onQuit: () -> Void

    private let scale = WindowManagerSizing.currentScale

    public init(controller: WindowManagerController, onQuit: @escaping () -> Void) {
        self.controller = controller
        self.onQuit = onQuit
    }

    private func s(_ value: CGFloat) -> CGFloat { value * scale }

    // Tile groups, laid out top to bottom.
    private let halves: [WindowAction] = [.leftHalf, .rightHalf, .topHalf, .bottomHalf]
    private let corners: [WindowAction] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
    private let thirds: [WindowAction] = [.leftThird, .centerThird, .rightThird, .firstTwoThirds, .lastTwoThirds]
    private let sizing: [WindowAction] = [.maximize, .almostMaximize, .center]
    private let displays: [WindowAction] = [.nextDisplay, .restorePrevious]

    public var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: s(14)) {
                    if !controller.hasAccessibility {
                        permissionBanner
                    }
                    targetAffordance
                    section("Halves", halves, columns: 4)
                    section("Corners", corners, columns: 4)
                    cornerChordHint
                    section("Thirds", thirds, columns: 5)
                    section("Size", sizing, columns: 3)
                    section("Display & Undo", displays, columns: 2)
                    displayActionHint
                    resultFeedback
                    shortcutSection
                }
                .padding(.horizontal, s(16))
                .padding(.vertical, s(12))
            }
        }
        .frame(width: WindowManagerSizing.preferredSize().width, height: WindowManagerSizing.preferredSize().height)
        .frostedPanel(cornerRadius: 18)
        .onAppear { controller.refreshPermission() }
        .onDisappear { recorder.cancel() }
    }

    private var header: some View {
        HStack(spacing: s(8)) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: s(15), weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text("Window Manager")
                .font(.system(size: s(15), weight: .bold))
                .foregroundStyle(.primary.opacity(0.9))
            Spacer()
            Button(action: onQuit) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: s(15), weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Quit Window Manager")
        }
        .padding(.horizontal, s(16))
        .padding(.top, s(14))
        .padding(.bottom, s(10))
    }

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: s(6)) {
            Label("Accessibility access needed", systemImage: "lock.shield")
                .font(.system(size: s(12), weight: .semibold))
                .foregroundStyle(.orange)
            Text("Window Manager moves other apps' windows, which macOS gates behind Accessibility. Grant access, then the snaps and shortcuts activate.")
                .font(.system(size: s(11)))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Accessibility Settings") {
                controller.requestPermission()
            }
            .font(.system(size: s(12), weight: .medium))
        }
        .padding(s(10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: s(8)).fill(Color.orange.opacity(0.12)))
    }

    /// Names the window the tiles will act on (the target snapshotted at popover-open). Makes
    /// the cross-display wrong-target failure mode visible *before* anything moves, not only
    /// after via "Snapped X".
    @ViewBuilder
    private var targetAffordance: some View {
        if controller.hasAccessibility, let target = controller.popoverTargetName {
            HStack(spacing: s(5)) {
                Image(systemName: "scope")
                    .font(.system(size: s(9), weight: .semibold))
                Text("Will snap: \(target)")
                    .font(.system(size: s(10), weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
        }
    }

    /// Explains the corner chord: two perpendicular half-snap shortcuts pressed in quick
    /// succession snap to the corner between them (⌃⌥→ then ⌃⌥↑ = top-right).
    private var cornerChordHint: some View {
        HStack(alignment: .top, spacing: s(5)) {
            Image(systemName: "sparkles")
                .font(.system(size: s(8), weight: .semibold))
            Text("Tip: tap two half-snap shortcuts in a row — e.g. Right then Up — to snap to that corner.")
                .font(.system(size: s(9)))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.tertiary)
    }

    /// "Restore" on its own reads as "restore what?", and "Next Display" gives no clue that the
    /// window keeps its proportions rather than its coordinates. One line spells out both.
    private var displayActionHint: some View {
        HStack(alignment: .top, spacing: s(5)) {
            Image(systemName: "info.circle")
                .font(.system(size: s(8), weight: .semibold))
            Text("Next Display keeps the window's relative place and proportions on the new screen. Restore undoes the last arrange.")
                .font(.system(size: s(9)))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.tertiary)
    }

    private func section(_ title: String, _ actions: [WindowAction], columns: Int) -> some View {
        VStack(alignment: .leading, spacing: s(6)) {
            Text(title)
                .font(.system(size: s(11), weight: .bold))
                .foregroundStyle(.secondary)
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: s(6)), count: columns),
                spacing: s(6)
            ) {
                ForEach(actions) { action in
                    tile(action)
                }
            }
        }
    }

    private func tile(_ action: WindowAction) -> some View {
        Button {
            controller.apply(action)
        } label: {
            VStack(spacing: s(4)) {
                Image(systemName: action.symbol)
                    .font(.system(size: s(17), weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Text(action.title)
                    .font(.system(size: s(8.5), weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, s(8))
            .background(RoundedRectangle(cornerRadius: s(8), style: .continuous).fill(Color.primary.opacity(0.06)))
            .contentShape(RoundedRectangle(cornerRadius: s(8), style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!controller.hasAccessibility)
        .opacity(controller.hasAccessibility ? 1 : 0.5)
        .help(controller.shortcut(for: action).map { "\(action.title)  \($0.displayString)" } ?? action.title)
    }

    /// Transient feedback for the last apply, including *which* app's window was snapped —
    /// when the wrong window moves, naming the target is what makes the problem visible.
    @ViewBuilder
    private var resultFeedback: some View {
        switch controller.lastResult {
        case .success(let appName):
            Text("Snapped \(appName ?? "the focused window")")
                .font(.system(size: s(9.5)))
                .foregroundStyle(.secondary)
        case .noFocusedWindow:
            Text("No focused window to arrange.")
                .font(.system(size: s(9.5)))
                .foregroundStyle(.orange)
        case .noOtherDisplay:
            Text("Only one display — the window stayed put.")
                .font(.system(size: s(9.5)))
                .foregroundStyle(.secondary)
        case .nothingToRestore:
            Text("Nothing to restore — arrange this window first.")
                .font(.system(size: s(9.5)))
                .foregroundStyle(.secondary)
        case .failed:
            Text("The focused window couldn't be moved — its app may not allow it.")
                .font(.system(size: s(9.5)))
                .foregroundStyle(.orange)
        case .needsPermission, nil:
            EmptyView()
        }
    }

    // MARK: - Shortcuts

    private var shortcutSection: some View {
        VStack(alignment: .leading, spacing: s(6)) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    shortcutsExpanded.toggle()
                }
                if !shortcutsExpanded {
                    recorder.cancel()
                    shortcutNotice = nil
                }
            } label: {
                HStack(spacing: s(5)) {
                    Image(systemName: shortcutsExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: s(9), weight: .bold))
                        .foregroundStyle(.secondary)
                    Text("Keyboard Shortcuts")
                        .font(.system(size: s(11), weight: .bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !shortcutsExpanded {
                        Text(collapsedShortcutSummary)
                            .font(.system(size: s(9)))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if shortcutsExpanded {
                if controller.secureInputBlocked {
                    secureInputNotice
                }
                if let shortcutNotice {
                    Text(shortcutNotice)
                        .font(.system(size: s(9.5)))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: s(3)) {
                    ForEach(WindowAction.allCases) { action in
                        shortcutRow(action)
                    }
                }

                HStack {
                    Text("Click a shortcut, then press the new keys. Esc cancels.")
                        .font(.system(size: s(9)))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Reset to Defaults") {
                        recorder.cancel()
                        shortcutNotice = nil
                        controller.resetShortcutsToDefaults()
                    }
                    .font(.system(size: s(10), weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
                .padding(.top, s(2))
            }
        }
    }

    private var collapsedShortcutSummary: String {
        if controller.secureInputBlocked { return "blocked by macOS Secure Input" }
        if !controller.registrationFailures.isEmpty { return "\(controller.registrationFailures.count) need attention" }
        return "⌃⌥ + arrows · customizable"
    }

    private var secureInputNotice: some View {
        Text("macOS Secure Input is blocking all global shortcuts right now (a password field, the lock screen, or a stuck loginwindow). They resume automatically when it ends; if it persists, lock and unlock the screen or restart.")
            .font(.system(size: s(9.5)))
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .padding(s(8))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: s(6)).fill(Color.orange.opacity(0.12)))
    }

    private func shortcutRow(_ action: WindowAction) -> some View {
        let isRecording = recorder.recordingAction == action
        let failed = controller.registrationFailures[action] != nil

        return VStack(alignment: .leading, spacing: s(1)) {
            HStack(spacing: s(8)) {
                Text(action.title)
                    .font(.system(size: s(10.5)))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(1)
                Spacer()
                Button {
                    beginRecording(action)
                } label: {
                    Text(isRecording ? "Press keys…" : (controller.shortcut(for: action)?.displayString ?? "Set"))
                        .font(.system(size: s(10.5), weight: .medium, design: isRecording ? .default : .rounded))
                        .foregroundStyle(isRecording ? Color.accentColor : (failed ? .orange : .primary.opacity(0.8)))
                        .padding(.horizontal, s(8))
                        .padding(.vertical, s(2.5))
                        .background(
                            RoundedRectangle(cornerRadius: s(5), style: .continuous)
                                .fill(isRecording ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.07))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: s(5), style: .continuous)
                                .strokeBorder(isRecording ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help("Click to record a new shortcut for \(action.title)")
            }
            if failed && !isRecording {
                Text("In use by macOS or another app — click to change.")
                    .font(.system(size: s(8.5)))
                    .foregroundStyle(.orange)
            }
        }
    }

    private func beginRecording(_ action: WindowAction) {
        shortcutNotice = nil
        if recorder.recordingAction == action {
            recorder.cancel()
            return
        }
        recorder.begin(
            for: action,
            suspendHotKeys: { controller.suspendHotKeysForRecording() },
            resumeHotKeys: { controller.resumeHotKeysAfterRecording() }
        ) { shortcut in
            guard let shortcut else { return } // Esc — cancelled
            switch controller.assignShortcut(shortcut, to: action) {
            case .assigned:
                shortcutNotice = nil
            case .conflict(let holder):
                shortcutNotice = "\(shortcut.displayString) is already used by \(holder.title). Pick a different combination."
            case .needsModifiers:
                shortcutNotice = "Add at least one of ⌘ ⌃ ⌥ (function keys may stand alone)."
            }
        }
    }
}
