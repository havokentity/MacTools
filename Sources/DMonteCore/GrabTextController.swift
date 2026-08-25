import AppKit
import Carbon.HIToolbox
import Combine
import Foundation

public extension DefaultsKey {
    /// The global shortcut that starts a capture, as `WindowShortcut.storageValue`
    /// ("keyCode,modifiers"), or `GrabTextShortcutStore.disabledStorageValue` when the user has
    /// deliberately cleared it.
    ///
    /// Intentionally *not* given a registered default: an absent value has to keep meaning "never
    /// customized, use whatever the built-in default is today", which is what lets the default
    /// change later without stranding everyone who never opened the setting. Registering a value
    /// would make the key permanently present and erase that distinction.
    static let grabTextCaptureShortcut = "tool.grabText.captureShortcut"
}

/// Reads and writes Grab Text's single capture shortcut. Pure data in/out over a `UserDefaults`,
/// so the fallback and disable semantics are testable against a scratch suite.
public struct GrabTextShortcutStore {
    /// ⌃⌥G — the built-in combination. ⌃⌥ follows Window Manager's choice of a prefix that apps
    /// rarely claim, and G is free there because no window action uses a letter other than C.
    public static let defaultShortcut = WindowShortcut(keyCode: HotKeyCode.g, modifiers: HotKeyModifier.controlOption)

    /// Persisted in place of a "keyCode,modifiers" pair when the user clears the shortcut. A
    /// sentinel rather than removing the key, because an absent key already means "use the
    /// default" and "off" has to stay distinguishable from it.
    public static let disabledStorageValue = "off"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The shortcut that should actually be registered: the user's override, the built-in default
    /// when they never chose one, or nil when they turned the hotkey off.
    public func effectiveShortcut() -> WindowShortcut? {
        guard let raw = defaults.string(forKey: DefaultsKey.grabTextCaptureShortcut) else {
            return Self.defaultShortcut
        }
        if raw == Self.disabledStorageValue { return nil }
        // An unparseable value is corruption, not intent — falling back to the default beats
        // silently leaving the user with no hotkey and no explanation.
        return WindowShortcut(storageValue: raw) ?? Self.defaultShortcut
    }

    public func save(_ shortcut: WindowShortcut) {
        defaults.set(shortcut.storageValue, forKey: DefaultsKey.grabTextCaptureShortcut)
    }

    /// Records that the user wants no capture hotkey at all.
    public func disable() {
        defaults.set(Self.disabledStorageValue, forKey: DefaultsKey.grabTextCaptureShortcut)
    }

    /// Drops the override (and any disable), restoring the built-in default.
    public func reset() {
        defaults.removeObject(forKey: DefaultsKey.grabTextCaptureShortcut)
    }
}

/// Outcome of assigning Grab Text's capture shortcut. There is no conflict case: the tool owns a
/// single shortcut, so the only combination it could clash with is its own.
public enum GrabTextShortcutAssignment: Equatable, Sendable {
    case assigned
    /// The combination lacks ⌘⌃⌥ (and isn't a bare function key), so it would swallow typing.
    case needsModifiers
}

/// The user-facing wording for a failed capture-hotkey registration.
///
/// Split out of the views because `registrationFailure` is not one story. Only
/// `eventHotKeyExistsErr` means another app got to the combination first; the other values that
/// reach the UI — `-1` (an error `GlobalHotKey` did not classify), `-2` (a stale Carbon id we
/// failed to release), `-3` (the shared Carbon event handler would not install) — are failures on
/// our side of the line. Telling the user "another app has it" for those sends them hunting for a
/// culprit that does not exist and pressing a different combination that fails the same way, so
/// the blame is only assigned when the status actually supports it. The code is always shown:
/// it is the one thing that makes a bug report about this actionable.
public enum GrabTextHotKeyFailure {
    /// `eventHotKeyExistsErr` (-9878) — the only status that genuinely means another process
    /// already owns the combination exclusively.
    public static let alreadyTakenStatus = Int32(eventHotKeyExistsErr)

    /// The one-liner under the Grab Text button, where space is tight.
    public static func hint(status: Int32) -> String {
        if status == alreadyTakenStatus {
            return "The capture shortcut is already claimed by another app (error \(status)) — pick a different one in Settings."
        }
        return "macOS refused the capture shortcut (error \(status)) — try a different one in Settings."
    }

    /// The longer sentence in the settings sheet, where the fix is one click away.
    public static func detail(status: Int32) -> String {
        if status == alreadyTakenStatus {
            return "macOS refused this shortcut (error \(status)) — another app already owns it exclusively. Pick a different combination."
        }
        return "macOS refused to register this shortcut (error \(status)). Try a different combination — if every combination fails, reopening Grab Text usually clears it."
    }
}

/// Claims one global hotkey and returns an object whose lifetime keeps the claim alive (releasing
/// it unregisters — `GlobalHotKey` does that in `deinit`). Injectable because the failure path is
/// the entire point of `registrationFailure`, and `RegisterEventHotKey` can neither be made to
/// fail on demand nor be safely left behind in a headless test run.
public typealias GrabTextHotKeyRegistrar = @MainActor (
    _ shortcut: WindowShortcut,
    _ id: UInt32,
    _ handler: @escaping @Sendable () -> Void
) throws -> AnyObject

/// Owns everything Grab Text does: the capture/OCR run, the recognized text and status line, the
/// "copy automatically" preference, and the global capture hotkey.
///
/// One controller rather than view state because the capture now has two entry points — the window
/// button and the global hotkey — and they must share the same in-flight guard. With the state
/// living in the SwiftUI view, a hotkey press while the window was closed had nothing to check
/// against and would start a second `screencapture -i`.
@MainActor
public final class GrabTextController: ObservableObject {
    /// Whether a capture is running (the region selector is up, or Vision is still working).
    @Published public private(set) var isGrabbing = false

    /// Text from the most recent successful grab; empty until there is one.
    @Published public private(set) var recognizedText = ""

    /// The sentence shown where the result would be, when there is no result.
    @Published public private(set) var statusMessage = GrabTextController.idleMessage

    /// Whether a successful grab copies straight to the clipboard. Persisted on change.
    @Published public var copyAutomatically: Bool {
        didSet {
            guard copyAutomatically != oldValue else { return }
            defaults.set(copyAutomatically, forKey: DefaultsKey.grabTextCopyAutomatically)
        }
    }

    /// The capture shortcut, or nil when the user turned it off.
    @Published public private(set) var shortcut: WindowShortcut?

    /// The OSStatus from the last failed registration attempt, or nil when the hotkey is live (or
    /// deliberately off). Surfaced in the settings sheet: a hotkey another app already owns must
    /// look broken, not merely silent.
    @Published public private(set) var registrationFailure: Int32?

    /// Whether macOS Secure Event Input is currently suppressing every global hotkey. Registration
    /// still succeeds in that state, so without this the shortcut would look fine and do nothing.
    @Published public private(set) var secureInputBlocked = false

    /// Whether this process currently holds the Screen Recording grant that screen capture needs.
    @Published public private(set) var hasScreenRecordingAccess: Bool

    /// Whether the current result is still only in this window — recognized, but never put on the
    /// clipboard because "copy automatically" was off. The window renders the status line *beside*
    /// the text on the strength of this, since the result box shows the text instead of the status
    /// once there is one, and a sentence written to `statusMessage` there would never be seen.
    @Published public private(set) var resultNeedsCopying = false

    /// Called after a hotkey-started grab whose result the user still has to see or act on — a
    /// failure, a missing permission, or text that wasn't auto-copied. A hotkey grab deliberately
    /// leaves the window closed, so this is the only way that outcome reaches the user.
    public var onHotKeyResultNeedsAttention: (() -> Void)?

    /// Carbon id for the single capture hotkey. Any constant works (ids are per-process).
    static let hotKeyID: UInt32 = 1

    static let idleMessage = "Drag to select a region of the screen to grab its text."

    private let defaults: UserDefaults
    private let store: GrabTextShortcutStore
    private let capture: GrabTextCapture
    private let screenRecordingAccess: @Sendable () -> Bool
    private let secureInput: @MainActor () -> Bool
    private let registrar: GrabTextHotKeyRegistrar

    /// Held only to keep the Carbon registration alive; releasing it unregisters.
    private var hotKey: AnyObject?

    /// Re-reads the environment while the window is on screen; nil when it isn't. See
    /// `beginEnvironmentMonitoring(interval:)`.
    private var environmentTimer: Timer?

    /// Whether a hotkey grab has already pulled the window forward to report the missing Screen
    /// Recording grant. Re-armed the moment the grant comes back, so a later revocation is
    /// announced again.
    private var hasAnnouncedMissingScreenRecording = false

    /// Whether the owner has asked for a live hotkey. Assigning a shortcut re-registers only when
    /// it is true, so a controller that was never asked to claim a hotkey (every unit test, and any
    /// future embedding that only wants the OCR) never touches Carbon as a side effect.
    private var wantsHotKey = false

    public init(
        defaults: UserDefaults? = nil,
        capture: @escaping GrabTextCapture = GrabTextCapturer.grabRegion,
        screenRecordingAccess: @escaping @Sendable () -> Bool = { ScreenRecordingAccess.isGranted },
        secureInput: @escaping @MainActor () -> Bool = { SecureInputState.isBlockingHotKeys },
        registrar: @escaping GrabTextHotKeyRegistrar = GrabTextController.registerGlobalHotKey
    ) {
        let resolvedDefaults = defaults ?? AppDefaults.shared
        self.defaults = resolvedDefaults
        self.store = GrabTextShortcutStore(defaults: resolvedDefaults)
        self.capture = capture
        self.screenRecordingAccess = screenRecordingAccess
        self.secureInput = secureInput
        self.registrar = registrar
        // Default to copying: the tool's whole point is getting text onto the clipboard, and the
        // key may be unregistered in a scratch suite, where `bool(forKey:)` would read false.
        self.copyAutomatically = resolvedDefaults.object(forKey: DefaultsKey.grabTextCopyAutomatically) == nil
            ? true
            : resolvedDefaults.bool(forKey: DefaultsKey.grabTextCopyAutomatically)
        self.shortcut = store.effectiveShortcut()
        self.hasScreenRecordingAccess = screenRecordingAccess()
    }

    // No `deinit` teardown for `environmentTimer`: under Swift 6 a nonisolated deinit may not
    // touch a @MainActor, non-Sendable property (the same constraint WindowManagerController
    // documents). The timer captures only `[weak self]`, so it cannot keep the controller alive,
    // and it is invalidated deterministically on the main actor when the window leaves the screen.

    // MARK: - Hotkey

    /// The production registrar: a real Carbon claim through `GlobalHotKey`. Public only because
    /// it is the default value of a public initializer's parameter.
    public static func registerGlobalHotKey(
        _ shortcut: WindowShortcut,
        id: UInt32,
        handler: @escaping @Sendable () -> Void
    ) throws -> AnyObject {
        try GlobalHotKey.register(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, id: id, handler: handler)
    }

    /// Claims (or re-claims) the capture hotkey. Safe to call repeatedly: the old registration is
    /// released first, which `GlobalHotKey` requires before the same id can be re-used.
    public func registerHotKey() {
        wantsHotKey = true
        hotKey = nil
        registrationFailure = nil
        secureInputBlocked = secureInput()

        guard let shortcut else { return } // deliberately off

        do {
            hotKey = try registrar(shortcut, Self.hotKeyID) { [weak self] in
                // Carbon dispatches hotkey events on the main run loop, so this already *is* the
                // main actor's thread. Asserting that instead of hopping through a Task starts the
                // capture synchronously with the key press, which keeps the in-flight guard exact:
                // a second press cannot slip past `isGrabbing` while a hop is still queued.
                MainActor.assumeIsolated {
                    _ = self?.startGrab(source: .hotKey)
                }
            }
        } catch let error as GlobalHotKeyRegistrationError {
            registrationFailure = Self.statusCode(for: error)
        } catch {
            registrationFailure = -1
        }
    }

    /// Releases the hotkey and stops wanting one (termination). Clearing `wantsHotKey` matters:
    /// without it, a later `assignShortcut` would silently re-claim a hotkey the owner has
    /// already torn down.
    public func unregisterHotKey() {
        wantsHotKey = false
        hotKey = nil
        registrationFailure = nil
    }

    /// Releases the hotkey for the duration of a shortcut recording without forgetting that we
    /// want it back — pair with `resumeHotKeyAfterRecording()`.
    public func suspendHotKeyForRecording() {
        hotKey = nil
    }

    public func resumeHotKeyAfterRecording() {
        if wantsHotKey { registerHotKey() }
    }

    /// Re-reads the state that can change behind our back: Secure Input and the Screen Recording
    /// grant. Neither posts a notification, so the only way to have it right is to look again.
    public func refreshEnvironment() {
        secureInputBlocked = secureInput()
        updateScreenRecordingAccess()
    }

    /// How often the environment is re-read while the window is on screen. Matches Window
    /// Manager's permission poll; both reads are cheap local lookups.
    public static let environmentPollInterval: TimeInterval = 1.0

    /// Starts re-reading the environment on a timer, and reads it once immediately. Pair with
    /// `endEnvironmentMonitoring()`; the owner drives both from the window's on-screen visibility.
    ///
    /// A poll rather than a view lifecycle hook because there is no view lifecycle to hang this
    /// on: `HelperWindowHost` builds the hosting controller once and never tears it down, so the
    /// root view's `onAppear` fires at launch and never again however many times the window is
    /// shown. Sampling only at launch leaves the hint permanently wrong in both directions — no
    /// warning while Secure Input silently eats every press, or a warning that outlives the
    /// stuck `loginwindow` that caused it. And a poll rather than a notification because macOS
    /// announces neither of these two states.
    public func beginEnvironmentMonitoring(interval: TimeInterval = GrabTextController.environmentPollInterval) {
        refreshEnvironment()

        environmentTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            // Timers fire on the run loop that scheduled them, which is the main one here.
            MainActor.assumeIsolated {
                self?.refreshEnvironment()
            }
        }
        environmentTimer = timer
        // Common modes so the hint keeps updating while a menu is open or the window is dragged.
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Stops the environment poll — the window is off screen, so nobody can read the hint.
    public func endEnvironmentMonitoring() {
        environmentTimer?.invalidate()
        environmentTimer = nil
    }

    /// Re-reads the Screen Recording grant. Regaining it re-arms the one-shot hotkey announcement:
    /// a grant that is given and later revoked has to be reported again.
    private func updateScreenRecordingAccess() {
        let granted = screenRecordingAccess()
        hasScreenRecordingAccess = granted
        if granted { hasAnnouncedMissingScreenRecording = false }
    }

    private static func statusCode(for error: GlobalHotKeyRegistrationError) -> Int32 {
        switch error {
        case .duplicateID: -2
        case .eventHandlerUnavailable: -3
        case .registrationFailed(let status): status
        }
    }

    // MARK: - Shortcut customization

    /// Assigns and persists a new capture shortcut, re-registering live. Refuses combinations that
    /// would swallow ordinary typing.
    @discardableResult
    public func assignShortcut(_ shortcut: WindowShortcut) -> GrabTextShortcutAssignment {
        guard shortcut.isUsableGlobally else { return .needsModifiers }
        store.save(shortcut)
        self.shortcut = store.effectiveShortcut()
        if wantsHotKey { registerHotKey() }
        return .assigned
    }

    /// Turns the capture hotkey off entirely.
    public func disableShortcut() {
        store.disable()
        shortcut = store.effectiveShortcut()
        if wantsHotKey { registerHotKey() }
    }

    /// Restores the built-in default shortcut.
    public func resetShortcut() {
        store.reset()
        shortcut = store.effectiveShortcut()
        if wantsHotKey { registerHotKey() }
    }

    // MARK: - Capture

    /// Where a capture was started from. It only changes what happens with the *result*: a hotkey
    /// grab runs with no window on screen, so anything the user still has to read has to pull the
    /// window forward, while a window grab is already being watched.
    public enum GrabSource: Equatable, Sendable {
        case window
        case hotKey
    }

    /// Starts one capture, or does nothing if one is already running.
    ///
    /// Returns the task performing the capture, or nil when the request was ignored. The return
    /// value is what makes the in-flight guard observable — to tests, and to any caller that wants
    /// to await the result.
    @discardableResult
    public func startGrab(source: GrabSource = .window) -> Task<Void, Never>? {
        // Never two at once. The hotkey can be pressed again while the region selector from the
        // previous press is still up; a second `screencapture -i` would fight the first for the
        // crosshair and leave its temp file behind.
        guard !isGrabbing else { return nil }

        isGrabbing = true
        recognizedText = ""
        resultNeedsCopying = false
        statusMessage = "Drag to select the region containing text…"

        return Task {
            let outcome = await self.capture()
            self.finish(outcome, source: source)
        }
    }

    private func finish(_ outcome: GrabTextOutcome, source: GrabSource) {
        isGrabbing = false

        // Whether the user has to look at this. A hotkey grab that quietly landed on the clipboard
        // is the success case and must stay invisible; everything else has to surface somewhere.
        var needsAttention = true

        switch outcome {
        case .cancelled:
            statusMessage = "Grab cancelled. Press Grab Text to try again."
            needsAttention = false // they cancelled it; they know
        case .needsScreenRecordingPermission:
            statusMessage = Self.permissionMessage
            // Say this once, not on every press. While the grant is missing, an Esc-cancel is
            // indistinguishable from a capture TCC blocked (see `GrabTextKit.classifyCapture`),
            // so surfacing it every time would steal activation from whatever the user was typing
            // in each time they dismissed the crosshair — the precise interruption the shortcut
            // exists to avoid. The preflight can also disagree with reality (it is read in this
            // process while `screencapture` runs in another), which makes "every time" a way to
            // be repeatedly wrong. Once is enough to send them to Settings; the window stays open
            // behind them with the explanation on it.
            needsAttention = !hasAnnouncedMissingScreenRecording
            hasAnnouncedMissingScreenRecording = true
        case .failure(let reason):
            statusMessage = reason
        case .success(let text):
            if text.isEmpty {
                statusMessage = "No text found in that region. Try again."
            } else {
                recognizedText = text
                if copyAutomatically {
                    Self.copyToPasteboard(text)
                    statusMessage = "Copied to clipboard."
                    needsAttention = false
                } else {
                    // Nothing was copied, so the text exists only in the window — which a hotkey
                    // grab left closed. Showing it is the only way the grab isn't wasted, and
                    // `resultNeedsCopying` is what gets this sentence rendered next to the result
                    // rather than behind it.
                    resultNeedsCopying = true
                    statusMessage = "Grabbed \(text.count) characters. Press Copy to put them on the clipboard."
                }
            }
        }

        // After the switch: regaining the grant re-arms the announcement above, so this must not
        // run before the branch that consumes it.
        updateScreenRecordingAccess()

        if source == .hotKey, needsAttention {
            onHotKeyResultNeedsAttention?()
        }
    }

    /// Puts the current result on the clipboard (the window's Copy button).
    public func copyRecognizedText() {
        guard !recognizedText.isEmpty else { return }
        Self.copyToPasteboard(recognizedText)
        resultNeedsCopying = false
        statusMessage = "Copied to clipboard."
    }

    /// Asks for the Screen Recording grant and re-reads it.
    public func requestScreenRecordingAccess() {
        ScreenRecordingAccess.request()
        updateScreenRecordingAccess()
    }

    static let permissionMessage = """
        macOS is withholding Screen Recording access, so nothing usable could be captured. \
        Grant it in System Settings › Privacy & Security › Screen Recording, then try again.
        """

    private static func copyToPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}
