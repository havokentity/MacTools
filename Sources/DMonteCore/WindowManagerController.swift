import AppKit
import ApplicationServices
import Combine
import os

/// Outcome of applying a window action, so the UI can show a precise message.
public enum WindowApplyResult: Equatable, Sendable {
    /// The window moved; carries the localized name of the app whose window was snapped so the
    /// UI can show *which* window was acted on (the wrong-target failure mode is otherwise
    /// invisible to the user).
    case success(appName: String?)
    case needsPermission
    case noFocusedWindow
    /// "Move to next display" on a Mac with only one display. A distinct outcome rather than
    /// `.failed`: nothing went wrong, there is simply nowhere to move to, and the window is
    /// deliberately left untouched.
    case noOtherDisplay
    /// "Restore" with nothing remembered for this window — it hasn't been arranged yet in this
    /// session, or its restore point was already consumed.
    case nothingToRestore
    case failed
}

/// Outcome of assigning a custom shortcut.
public enum ShortcutAssignment: Equatable, Sendable {
    case assigned
    /// The shortcut is already bound to another action in this tool.
    case conflict(WindowAction)
    /// The shortcut lacks ⌘⌃⌥ (and isn't a bare function key), so it would swallow typing.
    case needsModifiers
}

/// Drives the Window Manager: tracks Accessibility permission, registers the global snap
/// shortcuts, and applies a `WindowAction` to the target app's focused window through the
/// Accessibility API. The geometry itself comes from the pure `WindowManagerKit`.
///
/// Target selection: hotkey-triggered snaps act on the live frontmost app. Popover-triggered
/// snaps act on a target snapshotted when the popover began to show — see `popoverWillShow()`
/// for the cross-display activation shift that makes the live frontmost wrong by tile-click time.
@MainActor
public final class WindowManagerController: NSObject, ObservableObject {
    /// Whether this process is trusted for Accessibility (required to move other apps' windows).
    @Published public private(set) var hasAccessibility = false

    /// The most recent apply outcome, for transient UI feedback.
    @Published public private(set) var lastResult: WindowApplyResult?

    /// Localized name of the app the open popover will snap (the "Will snap: X" affordance), or
    /// nil when no popover session is active or no target could be resolved.
    @Published public private(set) var popoverTargetName: String?

    /// Effective shortcuts (user overrides over defaults), keyed by action.
    @Published public private(set) var shortcuts: [WindowAction: WindowShortcut] = [:]

    /// Actions whose hotkey could not be registered, with the failing OSStatus. Shown inline on
    /// the shortcut rows ("in use by macOS or another app").
    @Published public private(set) var registrationFailures: [WindowAction: Int32] = [:]

    /// Whether macOS Secure Event Input is currently suppressing all global hotkeys (password
    /// fields, lock screen, or a stuck loginwindow). Registration succeeds but no events arrive.
    @Published public private(set) var secureInputBlocked = false

    private var hotKeys: [GlobalHotKey] = []

    /// The half-snap most recently fired by a hotkey, for corner-chord detection (⌃⌥→ then ⌃⌥↑ =
    /// top-right). Popover tile clicks never touch this — a click is always a single action.
    private var chordState: WindowManagerKit.ChordState?

    /// Pre-action frames for the `restorePrevious` undo. Bounded LRU (see `WindowFrameMemory`), and
    /// process-local: window numbers don't survive a relaunch, so persisting it would restore the
    /// wrong window.
    private var frameMemory = WindowFrameMemory()

    private var permissionTimer: Timer?
    private var windowSelectionMonitor: Any?
    private let shortcutStore: WindowShortcutStore

    /// The target snapshotted at popover-show time; the popover's tiles snap this target, never
    /// the live frontmost. Stores pid + focused-window frame, not live object references: the
    /// running app is re-resolved at apply time and the window frame is used as a fingerprint
    /// when an app has multiple windows.
    private var popoverTarget: TargetSnapshot?

    /// History of non-suite app activations, so resolving the popover target can find "the app
    /// that was active *before* the status-item click" — the click's own spurious activation can
    /// land before we run (see `popoverWillShow()`). The tracker's session freezes the history
    /// while the popover is open; `targetApplication()` uses the pid snapshot during it.
    private let activationTracker: ActivationTracker

    private struct TargetSnapshot {
        let pid: pid_t
        let appName: String?
        let windowSnapshot: ActivationTracker.WindowSnapshot?

        init(app: NSRunningApplication, windowSnapshot: ActivationTracker.WindowSnapshot? = nil) {
            self.pid = app.processIdentifier
            self.appName = app.localizedName
            self.windowSnapshot = windowSnapshot
        }

        var app: NSRunningApplication? {
            ActivationTracker.liveApp(pid)
        }
    }

    private static let log = Logger(subsystem: "com.havokentity.mactools.windowmanager", category: "snap")

    /// Bundle-id prefix shared by the Toolbox and every helper. Snaps never target our own
    /// windows: when the Toolbox is frontmost (e.g. right after launching this helper with
    /// `--open`), the user means the window *underneath*, not the Toolbox.
    private static let suiteBundlePrefix = "com.havokentity.mactools"

    /// How long an AX call may block before we give up, so one hung app can't beachball us.
    private static let axMessagingTimeoutSeconds: Float = 3.0

    /// Tighter bound for the *speculative* focused-window snapshot taken on the main actor after
    /// every click and every activation: a fingerprint an app can't produce in a quarter second is
    /// one to drop rather than stall the Carbon hotkey callbacks and the popover for. Dropping it
    /// is cheap there — the entry is only a guess at a target the user may never snap, and apply
    /// falls back to the live focused window exactly as when no snapshot was recorded.
    ///
    /// Deliberately NOT used by `resolvePopoverTarget()`, which runs once per popover open (not per
    /// event, so the latency argument doesn't apply) and whose snapshot is load-bearing rather than
    /// speculative: it is the fingerprint that re-finds the user's exact window after the menu-bar
    /// click shifts focus across displays. Losing it there to a slow-but-healthy app (Unity,
    /// Electron) silently reinstates the cross-display wrong-window bug it exists to prevent, so
    /// that path keeps the full `axMessagingTimeoutSeconds` budget.
    private static let axSnapshotTimeoutSeconds: Float = 0.25

    /// Settle time between writing a frame and verifying it, per attempt. Apps that process AX
    /// geometry asynchronously (Electron) need a beat before the read-back reflects reality;
    /// the live-diagnosed failure was already visible at +0 ms, so this is generosity, not a fix.
    private static let frameVerifyDelayMicroseconds: useconds_t = 80_000

    /// Apps flagged with this attribute (VoiceOver and UI-automation clients set it) animate
    /// AX position changes, and a size set issued mid-animation is acknowledged with `.success`
    /// and then silently dropped. Diagnosed live against Claude Desktop: pos→size→pos returned
    /// three successes, the window moved but kept its size — exactly the reported bug. Rectangle
    /// works around it the same way: clear the flag around the writes, restore it after.
    private static let enhancedUserInterfaceAttribute = "AXEnhancedUserInterface"

    /// Private but widely implemented AX attribute that bridges AX windows to Quartz window ids.
    /// It lets popover snaps re-find the exact selected window after the menu-bar click changes
    /// focus within the target app.
    private static let windowNumberAttribute = "AXWindowNumber"

    public init(defaults: UserDefaults? = nil) {
        let store = WindowShortcutStore(defaults: defaults ?? AppDefaults.shared)
        shortcutStore = store
        shortcuts = store.effectiveShortcuts()
        hasAccessibility = AXIsProcessTrusted()
        secureInputBlocked = SecureInputState.isBlockingHotKeys
        // Suite apps never qualify as targets: activating our own Toolbox/helpers says nothing
        // about which window the user wants snapped.
        activationTracker = ActivationTracker(
            logger: WindowManagerController.log,
            excluding: { WindowManagerController.isSuiteApplication($0) },
            windowSnapshot: { WindowManagerController.focusedWindowSnapshot(of: $0) }
        )
        super.init()
        startWindowSelectionMonitor()
    }

    // No `deinit` cleanup: under Swift 6 a nonisolated deinit may not touch the @MainActor,
    // non-Sendable `permissionTimer` (same constraint as FocusTimer/KeepAwake). The timer is a
    // repeating poll that captures only `[weak self]`, so it cannot keep the controller alive;
    // it is invalidated deterministically on the main actor once permission is granted, and the
    // controller is app-lifetime in practice. The activation tracker's workspace observer is
    // likewise left in place (see ActivationTracker).

    // MARK: - Popover target session

    /// Snapshots the snap target for a popover session. MUST be called when the panel *begins*
    /// to show, as part of handling the status-item click.
    ///
    /// Why a snapshot, and why a history: with "Displays have separate Spaces" enabled, clicking
    /// a status item in display X's menu bar makes X the active display, and macOS re-activates
    /// the topmost app *on X*. By tile-click time the frontmost app is therefore the top app on
    /// the popover's display, not the app the user was working in — the reported "snapped Unity
    /// instead of Claude" cross-display bug. Worse, the spurious activation's timing relative to
    /// this code is not fixed (both orders were observed live on the reporting machine):
    /// - cold click (menu bar of an inactive display): the status-item action fired first and
    ///   the spurious activation landed ~300 ms *later* — freezing the session target here
    ///   absorbs it;
    /// - warm click (display already active, pointer already on the bar): the spurious
    ///   activation landed ~30–70 ms *before* the action — the frontmost app is already wrong
    ///   when we run, so `ActivationTracker.resolveTarget()` skips history entries younger than
    ///   its suspicious-activation window and targets the app the user was in before the click.
    /// The session freezes the resolved target until `popoverDidClose()`; hotkey snaps (no
    /// popover session) keep using the live frontmost app.
    public func popoverWillShow() {
        let candidate = resolvePopoverTarget()
        popoverTarget = candidate
        activationTracker.beginSession()
        popoverTargetName = candidate?.appName
        Self.log.info("popover target: \(candidate?.appName ?? "none", privacy: .public)")
    }

    /// The app the user was meaningfully working in at popover-open (the tracker's history
    /// resolution, including the suspicious-activation skip). Falls back to the live frontmost
    /// app (never one of ours) when no history exists yet, e.g. right after launch.
    private func resolvePopoverTarget() -> TargetSnapshot? {
        if let entry = activationTracker.resolveTargetEntry(), let target = ActivationTracker.liveApp(entry.pid) {
            return TargetSnapshot(
                app: target,
                windowSnapshot: entry.windowSnapshot
                    ?? Self.focusedWindowSnapshot(of: target, timeout: Self.axMessagingTimeoutSeconds)
            )
        }

        if let frontmost = NSWorkspace.shared.frontmostApplication, !Self.isSuiteApplication(frontmost) {
            Self.log.debug("resolve: no history, frontmost \(frontmost.localizedName ?? "?", privacy: .public)")
            return TargetSnapshot(
                app: frontmost,
                windowSnapshot: Self.focusedWindowSnapshot(of: frontmost, timeout: Self.axMessagingTimeoutSeconds)
            )
        }
        Self.log.debug("resolve: no history, topmost-other fallback")
        return topmostOtherApplication().map {
            TargetSnapshot(
                app: $0,
                windowSnapshot: Self.focusedWindowSnapshot(of: $0, timeout: Self.axMessagingTimeoutSeconds)
            )
        }
    }

    /// Ends the popover session: snaps go back to live frontmost resolution (hotkeys).
    public func popoverDidClose() {
        activationTracker.endSession()
        popoverTarget = nil
        popoverTargetName = nil
    }

    private func startWindowSelectionMonitor() {
        windowSelectionMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                self?.recordCurrentWindowSelection()
            }
        }
    }

    /// Recorded even when the fingerprint doesn't come back inside the speculative budget: the
    /// `isUserSelection` flag is what exempts this entry from `resolve()`'s suspicious-activation
    /// peel, so a slow AX server must cost us the snapshot, never the entry.
    private func recordCurrentWindowSelection() {
        guard !activationTracker.isSessionActive,
              let app = NSWorkspace.shared.frontmostApplication,
              !Self.isSuiteApplication(app) else { return }

        activationTracker.record(
            ActivationTracker.Entry(
                pid: app.processIdentifier,
                name: app.localizedName,
                at: Date(),
                windowSnapshot: Self.focusedWindowSnapshot(of: app),
                isUserSelection: true
            )
        )
    }

    // MARK: - Permission

    /// Refreshes the cached permission flag (the system grant can change while we run) and
    /// reconciles hotkey registration with it:
    /// - false → true (grant detected at popover-open or via polling): register.
    /// - true → false (revoked): release every hotkey so the combos aren't swallowed while unusable.
    /// - still true but keys are missing or some failed earlier (e.g. the conflicting app quit):
    ///   re-attempt, so opening the popover doubles as a retry.
    public func refreshPermission() {
        let trusted = AXIsProcessTrusted()
        secureInputBlocked = SecureInputState.isBlockingHotKeys
        if trusted != hasAccessibility {
            hasAccessibility = trusted
        }
        if trusted {
            if hotKeys.isEmpty || !registrationFailures.isEmpty {
                registerHotKeys()
            }
        } else if !hotKeys.isEmpty || !registrationFailures.isEmpty {
            unregisterHotKeys()
        }
    }

    /// Shows the system Accessibility prompt and opens the relevant Settings pane. Also starts a
    /// light poll so the UI updates (and hotkeys register) as soon as the grant is given, since the
    /// system sends no notification for it.
    public func requestPermission() {
        let key = "AXTrustedCheckOptionPrompt"
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        startPermissionPolling()
    }

    private func startPermissionPolling() {
        permissionTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshPermission()
                if self.hasAccessibility {
                    self.permissionTimer?.invalidate()
                    self.permissionTimer = nil
                }
            }
        }
        permissionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: - Hotkeys

    /// Registers the effective (user-customized, defaults as fallback) global shortcuts. Each
    /// action gets a unique Carbon hotkey id so the registrations don't collide. Safe to call
    /// repeatedly — it releases the old set first (required: `GlobalHotKey` refuses an id that is
    /// still live) and rebuilds. Failures are recorded per action instead of vanishing.
    public func registerHotKeys() {
        hotKeys.removeAll() // releases old registrations (deinit frees each Carbon id) before re-claiming
        registrationFailures = [:]

        var nextID: UInt32 = 1
        for action in WindowAction.allCases {
            guard let shortcut = shortcuts[action] else { continue }
            let keyCodes = Self.registrationKeyCodes(for: shortcut).filter { keyCode in
                keyCode == shortcut.keyCode || actionUsing(WindowShortcut(keyCode: keyCode, modifiers: shortcut.modifiers), excluding: action) == nil
            }
            for keyCode in keyCodes {
                let id = nextID
                nextID += 1
                do {
                    let key = try GlobalHotKey.register(keyCode: keyCode, modifiers: shortcut.modifiers, id: id) { [weak self] in
                        Task { @MainActor in
                            self?.applyHotKey(action)
                        }
                    }
                    hotKeys.append(key)
                } catch let error as GlobalHotKeyRegistrationError {
                    if keyCode == shortcut.keyCode {
                        registrationFailures[action] = Self.statusCode(for: error)
                    }
                } catch {
                    if keyCode == shortcut.keyCode {
                        registrationFailures[action] = -1
                    }
                }
            }
        }
        secureInputBlocked = SecureInputState.isBlockingHotKeys
    }

    private static func registrationKeyCodes(for shortcut: WindowShortcut) -> [UInt32] {
        switch shortcut.keyCode {
        case HotKeyCode.returnKey:
            return [HotKeyCode.returnKey, HotKeyCode.keypadEnter]
        case HotKeyCode.keypadEnter:
            return [HotKeyCode.keypadEnter, HotKeyCode.returnKey]
        default:
            return [shortcut.keyCode]
        }
    }

    /// Releases every registered hotkey (used when Accessibility is revoked: holding combos we
    /// can't act on would swallow the user's keystrokes for nothing).
    public func unregisterHotKeys() {
        hotKeys.removeAll()
        registrationFailures = [:]
    }

    /// Releases the global hotkeys so the shortcut recorder's local key monitor can capture any
    /// combination — including ones this tool (or another app) currently claims, which Carbon would
    /// otherwise intercept before the recorder ever sees them. Balance with
    /// `resumeHotKeysAfterRecording()`; registration failures are left intact for the UI and are
    /// rebuilt on resume.
    public func suspendHotKeysForRecording() {
        hotKeys.removeAll()
    }

    /// Re-registers the global hotkeys after recording ends (capture, cancel, or the panel losing
    /// focus). Reflects any shortcut just assigned.
    public func resumeHotKeysAfterRecording() {
        if hasAccessibility { registerHotKeys() }
    }

    private static func statusCode(for error: GlobalHotKeyRegistrationError) -> Int32 {
        switch error {
        case .duplicateID: -2
        case .eventHandlerUnavailable: -3
        case .registrationFailed(let status): status
        }
    }

    // MARK: - Shortcut customization

    /// The effective shortcut for an action (user override, else built-in default).
    public func shortcut(for action: WindowAction) -> WindowShortcut? {
        shortcuts[action]
    }

    /// The action currently holding `shortcut`, if any (used for duplicate prevention).
    public func actionUsing(_ shortcut: WindowShortcut, excluding excluded: WindowAction? = nil) -> WindowAction? {
        shortcuts.first { action, existing in action != excluded && existing == shortcut }?.key
    }

    /// Assigns a custom shortcut, persists it, and re-registers the hotkeys live. Refuses
    /// duplicates within the tool and modifier-less non-function keys.
    @discardableResult
    public func assignShortcut(_ shortcut: WindowShortcut, to action: WindowAction) -> ShortcutAssignment {
        guard shortcut.isUsableGlobally else { return .needsModifiers }
        if let holder = actionUsing(shortcut, excluding: action) { return .conflict(holder) }

        shortcutStore.save(shortcut, for: action)
        shortcuts = shortcutStore.effectiveShortcuts()
        if hasAccessibility { registerHotKeys() }
        return .assigned
    }

    /// Drops every custom shortcut and re-registers the built-in defaults.
    public func resetShortcutsToDefaults() {
        shortcutStore.reset()
        shortcuts = shortcutStore.effectiveShortcuts()
        if hasAccessibility { registerHotKeys() }
    }

    // MARK: - Apply

    /// Hotkey entry point. Half-snaps participate in corner chords — a second perpendicular half
    /// fired within `WindowManagerKit.cornerChordWindow` snaps to the corner between them (⌃⌥→ then
    /// ⌃⌥↑ = top-right) instead of doing two halves. Every other action applies directly. The
    /// popover tiles call `apply(_:)` straight, so a tile click is always a single action.
    func applyHotKey(_ action: WindowAction) {
        guard WindowManagerKit.halfSnaps.contains(action) else {
            chordState = nil
            apply(action)
            return
        }
        let now = Date()
        switch WindowManagerKit.resolveChord(previous: chordState, current: action, now: now) {
        case .corner(let corner):
            chordState = nil
            apply(corner)
        case .half(let half):
            chordState = WindowManagerKit.ChordState(action: half, at: now)
            apply(half)
        }
    }

    /// Applies `action` to the target app's focused window. Returns the outcome and also
    /// publishes it to `lastResult`.
    @discardableResult
    public func apply(_ action: WindowAction) -> WindowApplyResult {
        lastResult = applyResult(for: action)
        return lastResult ?? .failed
    }

    private func applyResult(for action: WindowAction) -> WindowApplyResult {
        guard AXIsProcessTrusted() else {
            hasAccessibility = false
            return .needsPermission
        }
        hasAccessibility = true

        guard let target = targetApplication(), let targetApp = target.app else {
            return .noFocusedWindow
        }
        let appElement = AXUIElementCreateApplication(targetApp.processIdentifier)
        // Bound how long a hung app may block us; without this a beachballing app freezes the
        // helper (and the popover) for the system default of several seconds per call.
        AXUIElementSetMessagingTimeout(appElement, Self.axMessagingTimeoutSeconds)
        guard let window = target.windowSnapshot.flatMap({ Self.window(in: appElement, matching: $0) }) ?? Self.focusedWindow(of: appElement) else {
            return .noFocusedWindow
        }

        guard let currentFrame = Self.frame(of: window) else {
            return .failed
        }
        let identity = WindowIdentity(pid: targetApp.processIdentifier, windowNumber: Self.windowNumber(of: window))

        // Pick the screen the window mostly lives on, then compute the target in AX (top-left)
        // space. The pure matcher gets the real screens as plain rects; if the window overlaps no
        // screen at all, fall back to the primary screen (never NSScreen.main — when a snap tile
        // is clicked, the key window is our own popover, so NSScreen.main is the popover's screen,
        // not anything to do with the target window).
        let areas = NSScreen.screens.map { Self.axRect(fromCocoa: $0.visibleFrame) }
        guard !areas.isEmpty else { return .failed }
        let areaIndex = WindowManagerKit.areaIndex(forWindow: currentFrame, in: areas) ?? 0
        let axArea = areas[areaIndex]

        let targetFrame: CGRect
        switch action {
        case .nextDisplay:
            guard let destination = WindowManagerKit.nextAreaIndex(after: areaIndex, in: areas) else {
                return .noOtherDisplay
            }
            targetFrame = WindowManagerKit.frame(movingWindow: currentFrame, from: axArea, to: areas[destination])
        case .restorePrevious:
            guard let remembered = frameMemory.frame(for: identity) else {
                return .nothingToRestore
            }
            // The display the frame was captured on may since have been unplugged or rearranged,
            // which would strand the window in coordinates no screen covers. Clamp into whichever
            // screen the remembered frame still belongs to, falling back to the window's current
            // screen when it belongs to none.
            let host = WindowManagerKit.areaIndex(forWindow: remembered, in: areas).map { areas[$0] } ?? axArea
            targetFrame = WindowManagerKit.clamped(remembered, into: host)
        default:
            guard let frame = WindowManagerKit.frame(for: action, in: axArea) else {
                return .failed
            }
            targetFrame = frame
        }

        let result = setFrameVerified(targetFrame, on: window, appElement: appElement, appName: targetApp.localizedName)

        // Only a landed move changes what "before the last action" means, so the restore point is
        // updated after verification, never before: a snap the app refused must not consume or
        // overwrite the undo the user still has.
        if case .success = result {
            if action == .restorePrevious {
                frameMemory.forget(identity)
            } else {
                frameMemory.remember(currentFrame, for: identity)
            }
        }
        return result
    }

    /// Writes `target` to the window and verifies it landed, retrying with alternating set
    /// orderings (`WindowManagerKit.frameSetAttempts`). Writing blind is not enough: the sets can
    /// all return `.success` while the app drops the size (live-diagnosed against Claude Desktop
    /// with `AXEnhancedUserInterface` set — the window moved but kept its size). Reads back after
    /// each attempt and only reports success when the achieved frame matches within
    /// `WindowManagerKit.frameMatchTolerance`.
    private func setFrameVerified(_ target: CGRect, on window: AXUIElement, appElement: AXUIElement, appName: String?) -> WindowApplyResult {
        // Clear AXEnhancedUserInterface for the duration of the writes (restore after): while it
        // is set, the app animates position changes and silently drops size changes that arrive
        // mid-animation. With it cleared, the same writes apply exactly, first try.
        let hadEnhancedUI = isEnhancedUserInterfaceEnabled(appElement)
        if hadEnhancedUI {
            setEnhancedUserInterface(false, on: appElement)
        }
        defer {
            if hadEnhancedUI {
                setEnhancedUserInterface(true, on: appElement)
            }
        }

        var achieved: CGRect?
        for order in WindowManagerKit.frameSetAttempts {
            let results = performFrameSets(target, on: window, order: order)
            if results.contains(.apiDisabled) {
                return .needsPermission
            }
            // Tiny settle so apps that apply geometry asynchronously finish before the read-back.
            usleep(Self.frameVerifyDelayMicroseconds)
            guard let now = Self.frame(of: window) else {
                return .failed
            }
            achieved = now
            if WindowManagerKit.frameMatches(now, target: target) {
                return .success(appName: appName)
            }
        }

        Self.log.debug("Snap failed verification: target \(target.debugDescription, privacy: .public), achieved \(achieved?.debugDescription ?? "nil", privacy: .public), app \(appName ?? "?", privacy: .public)")
        return .failed
    }

    /// One write pass in the given order. Both orders write the redundant first attribute again
    /// at the end: moving first lets a window cross to a smaller display before its final size is
    /// set (position-first), and sizing first survives apps that drop a size issued after a move
    /// (size-first).
    private func performFrameSets(_ target: CGRect, on window: AXUIElement, order: WindowManagerKit.FrameSetOrder) -> [AXError] {
        switch order {
        case .positionFirst:
            return [
                setPosition(target.origin, on: window),
                setSize(target.size, on: window),
                setPosition(target.origin, on: window)
            ]
        case .sizeFirst:
            return [
                setSize(target.size, on: window),
                setPosition(target.origin, on: window),
                setSize(target.size, on: window)
            ]
        }
    }

    private func isEnhancedUserInterfaceEnabled(_ appElement: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, Self.enhancedUserInterfaceAttribute as CFString, &ref) == .success else {
            return false
        }
        return (ref as? Bool) == true
    }

    /// Best-effort: some apps (Chromium) apply the new value while returning a non-success code,
    /// so the result is deliberately ignored.
    private func setEnhancedUserInterface(_ enabled: Bool, on appElement: AXUIElement) {
        AXUIElementSetAttributeValue(
            appElement,
            Self.enhancedUserInterfaceAttribute as CFString,
            enabled ? kCFBooleanTrue : kCFBooleanFalse
        )
    }

    // MARK: - Target selection

    /// The app whose focused window should be snapped.
    ///
    /// While the popover is open, that is the app snapshotted at popover-show time — the live
    /// frontmost is untrustworthy then, because opening the popover from another display's menu
    /// bar makes macOS re-activate whatever is topmost on *that* display (see
    /// `popoverWillShow()`). Hotkey snaps (no popover session) use the live frontmost app.
    ///
    /// One of our own apps (Toolbox/helpers) qualifies only while it owns a standard window: the
    /// window-style helpers (the Disk Usage Analyzer's resizable window) are as snappable as any
    /// other app's, but our menu-bar UI is all borderless panels, and right after the Toolbox
    /// launches this helper with `--open` the Toolbox itself is frontmost — snapping *its* panel
    /// on the primary display while the user's window on another display stays put is exactly the
    /// "moves the wrong window" bug. In that case we target the topmost ordinary window owned by
    /// any other app instead.
    private func targetApplication() -> TargetSnapshot? {
        if activationTracker.isSessionActive, let snapshot = popoverTarget {
            return snapshot // non-suite by construction (popoverWillShow filters)
        }
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return nil }
        if !Self.isSuiteApplication(frontmost) || Self.ownsStandardWindow(frontmost) {
            return TargetSnapshot(app: frontmost)
        }
        return topmostOtherApplication().map { TargetSnapshot(app: $0) }
    }

    private static func isSuiteApplication(_ app: NSRunningApplication) -> Bool {
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return true }
        return app.bundleIdentifier?.hasPrefix(suiteBundlePrefix) == true
    }

    /// Whether `app`'s focused window is an ordinary window rather than a panel. Only asked of our
    /// own apps, to separate the helpers that put up a real window from the popovers and the
    /// Toolbox, whose borderless panels must fall through to the window underneath.
    private static func ownsStandardWindow(_ app: NSRunningApplication) -> Bool {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, axMessagingTimeoutSeconds)
        guard let window = focusedWindow(of: appElement) else { return false }
        return subrole(of: window) == kAXStandardWindowSubrole
    }

    /// Walks the on-screen window list front-to-back and returns the owner of the first
    /// normal-layer window that doesn't belong to this suite. Only layer and owner PID are read,
    /// neither of which requires Screen Recording permission.
    private func topmostOtherApplication() -> NSRunningApplication? {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for entry in windowList {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let app = NSRunningApplication(processIdentifier: pid),
                  !Self.isSuiteApplication(app) else { continue }
            return app
        }
        return nil
    }

    // MARK: - Accessibility element access

    /// Fingerprints `app`'s focused window. `timeout` defaults to the tight speculative bound used
    /// by the per-click/per-activation callers; `resolvePopoverTarget()` passes the full messaging
    /// timeout because there the snapshot is load-bearing (see `axSnapshotTimeoutSeconds`).
    private static func focusedWindowSnapshot(
        of app: NSRunningApplication,
        timeout: Float = WindowManagerController.axSnapshotTimeoutSeconds
    ) -> ActivationTracker.WindowSnapshot? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, timeout)
        guard let window = focusedWindow(of: appElement, timeout: timeout) else { return nil }
        return ActivationTracker.WindowSnapshot(frame: frame(of: window), number: windowNumber(of: window))
    }

    private static func focusedWindow(of appElement: AXUIElement, timeout: Float = WindowManagerController.axMessagingTimeoutSeconds) -> AXUIElement? {
        var windowRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef)
        guard status == .success, let windowRef,
              CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { return nil }
        let window = windowRef as! AXUIElement
        AXUIElementSetMessagingTimeout(window, timeout)
        return window
    }

    private static func window(in appElement: AXUIElement, matching snapshot: ActivationTracker.WindowSnapshot) -> AXUIElement? {
        if let number = snapshot.number, let window = window(in: appElement, matchingNumber: number) {
            return window
        }
        if let frame = snapshot.frame, let window = window(in: appElement, matchingFrame: frame) {
            return window
        }
        return nil
    }

    private static func window(in appElement: AXUIElement, matchingNumber targetNumber: Int) -> AXUIElement? {
        windows(of: appElement).first { windowNumber(of: $0) == targetNumber }
    }

    private static func window(in appElement: AXUIElement, matchingFrame targetFrame: CGRect) -> AXUIElement? {
        windows(of: appElement).first { window in
            guard let frame = frame(of: window) else { return false }
            return WindowManagerKit.frameMatches(frame, target: targetFrame, tolerance: 4)
        }
    }

    private static func windows(of appElement: AXUIElement) -> [AXUIElement] {
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return [] }

        for window in windows {
            AXUIElementSetMessagingTimeout(window, axMessagingTimeoutSeconds)
        }
        return windows
    }

    private static func windowNumber(of window: AXUIElement) -> Int? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, windowNumberAttribute as CFString, &ref) == .success,
              let ref else { return nil }
        if let int = ref as? Int { return int }
        return (ref as? NSNumber)?.intValue
    }

    private static func subrole(of window: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        guard let position = axValue(window, kAXPositionAttribute, type: .cgPoint, as: CGPoint.self),
              let size = axValue(window, kAXSizeAttribute, type: .cgSize, as: CGSize.self) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    @discardableResult
    private func setPosition(_ point: CGPoint, on window: AXUIElement) -> AXError {
        var value = point
        guard let axValue = AXValueCreate(.cgPoint, &value) else { return .failure }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, axValue)
    }

    @discardableResult
    private func setSize(_ size: CGSize, on window: AXUIElement) -> AXError {
        var value = size
        guard let axValue = AXValueCreate(.cgSize, &value) else { return .failure }
        return AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, axValue)
    }

    /// Reads an AXValue attribute and unwraps it to a concrete CG type.
    private static func axValue<T>(_ element: AXUIElement, _ attribute: String, type: AXValueType, as: T.Type) -> T? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        let axValue = ref as! AXValue
        guard AXValueGetType(axValue) == type else { return nil }
        let result = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { result.deallocate() }
        guard AXValueGetValue(axValue, type, result) else { return nil }
        return result.pointee
    }

    // MARK: - Coordinate conversion (Cocoa bottom-left ↔ AX top-left)

    /// Converts a Cocoa global rect (origin bottom-left of the primary screen, y up) to AX/Quartz
    /// global space (origin top-left of the primary screen, y down). `nonisolated` so the pure
    /// geometry is callable (and testable) off the main actor; it only reads the primary screen's
    /// height, which is safe to touch from any thread. The math itself lives in
    /// `WindowManagerKit.axRect(fromCocoa:primaryScreenHeight:)`.
    nonisolated static func axRect(fromCocoa rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? rect.height
        return WindowManagerKit.axRect(fromCocoa: rect, primaryScreenHeight: primaryHeight)
    }
}
