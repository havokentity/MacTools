import AppKit
import SwiftUI

/// Captures the next keyDown while the user records a custom shortcut. A local NSEvent monitor
/// sees the panel's key events (the popover panel can become key); Esc cancels; the event is
/// swallowed so the recorded keystroke doesn't also type into the UI.
///
/// The "which slot am I recording" token is `AnyHashable` rather than one tool's enum because more
/// than one tool records shortcuts and they disagree about what a slot is — Window Manager has one
/// per `WindowAction`, Grab Text has exactly one. Sharing the recorder keeps the parts that are
/// easy to get wrong (Esc handling, the auto-cancel when the panel resigns key, bracketing the
/// live Carbon hotkeys around the capture) in a single place instead of copied per tool.
@MainActor
final class ShortcutRecorder: ObservableObject {
    /// The slot currently being recorded, or nil when idle.
    @Published private(set) var recordingToken: AnyHashable?

    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var onResumeHotKeys: (() -> Void)?

    /// Whether `token` is the slot currently being recorded.
    func isRecording<Token: Hashable>(_ token: Token) -> Bool {
        recordingToken == AnyHashable(token)
    }

    /// Starts recording for `token`. `onCapture` receives the captured shortcut, or nil when
    /// the user cancels with Esc. Recording also auto-cancels when the popover panel resigns
    /// key (it is ordered out without tearing down the SwiftUI hierarchy, so `onDisappear`
    /// alone can't be relied on to clean the monitor up).
    ///
    /// `suspendHotKeys`/`resumeHotKeys` bracket the capture: the tool's global hotkeys are released
    /// while recording so Carbon doesn't swallow a combination the recorder is trying to read
    /// (otherwise pressing e.g. ⌃⌥→ just fires Right Half and the monitor never sees it), and are
    /// re-registered on every exit path (capture, Esc, or the panel losing key).
    func begin<Token: Hashable>(
        for token: Token,
        suspendHotKeys: @escaping () -> Void = {},
        resumeHotKeys: @escaping () -> Void = {},
        onCapture: @escaping (WindowShortcut?) -> Void
    ) {
        cancel() // ends any prior recording (running its own resume) before we suspend again
        onResumeHotKeys = resumeHotKeys
        recordingToken = AnyHashable(token)
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
        recordingToken = nil
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
