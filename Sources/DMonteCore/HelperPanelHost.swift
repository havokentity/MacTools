import AppKit

/// A borderless panel whose key/main capability is configured per tool. Replaces the
/// private `KeyablePanel` subclasses previously duplicated in each helper app target.
final class HelperHostPanel: NSPanel {
    var canBecomeKeyOverride = true
    var canBecomeMainOverride = true

    override var canBecomeKey: Bool { canBecomeKeyOverride }
    override var canBecomeMain: Bool { canBecomeMainOverride }
}

/// Owns the floating panel (popover) lifecycle shared by the menu-bar helper tools:
/// panel creation, show/close/toggle, positioning near the status item with screen-edge
/// clamping, the outside-click global monitor dance (including the 0.12 s delayed install),
/// distributed "showWindow" observation, and termination teardown.
///
/// The helpers historically grew several slightly different flavours of this code; the
/// `Configuration` knobs exist to preserve each tool's exact behaviour rather than
/// harmonize them. Per-tool work that genuinely differs (Clipboard's paste-target capture,
/// its key monitor, ...) hangs off the `onWillShow`/`onDidShow`/`onDidClose` hooks.
@MainActor
public final class HelperPanelHost: NSObject {
    /// How the SwiftUI content is wrapped, preserving each tool's historic choice of
    /// `NSHostingController` (content view controller) vs `NSHostingView` (content view).
    public enum Content {
        case viewController(@MainActor () -> NSViewController)
        case view(@MainActor () -> NSView)
    }

    /// When the panel is built: eagerly during `configure()` (Calendar/Clipboard/... and
    /// System Monitor) or lazily on first show (Audio Switcher/Volume Mixer/Color
    /// Picker/Maintenance).
    public enum Creation {
        case onConfigure
        case onFirstShow
    }

    /// How the panel is (re)sized on each show.
    public enum Sizing {
        /// Re-read the preferred size and `setContentSize` before positioning.
        case preferred(@MainActor () -> NSSize)
        /// Same, but also pin `contentMinSize`/`contentMaxSize` (System Monitor).
        case preferredPinned(@MainActor () -> NSSize)
        /// The panel keeps the size it was created with (Audio Switcher/Volume
        /// Mixer/Color Picker).
        case fixedAtCreation(NSSize)
        /// Sized from the SwiftUI content's fitting size at creation; `layoutIfNeeded`
        /// before reading the frame on show (Maintenance).
        case fittingContent
    }

    /// Activation/ordering sequence used when revealing the panel.
    public enum Activation {
        /// `NSApp.activate(ignoringOtherApps: true)` then `makeKeyAndOrderFront`.
        case activateThenOrderFront
        /// `makeKeyAndOrderFront` then `NSApp.activate(ignoringOtherApps: true)`.
        case orderFrontThenActivate
        /// `orderFrontRegardless()` then `NSApp.activate(ignoringOtherApps: false)`
        /// (System Monitor — the panel never takes key focus).
        case orderFrontRegardless
    }

    /// When the outside-click global monitor is installed after a show.
    public enum OutsideClickInstall {
        /// 0.12 s after the show so the opening click on the status item does not
        /// immediately dismiss the panel; skipped if the panel is closed again first.
        case delayedAfterOpeningClick
        /// Installed synchronously as part of the show.
        case immediate
    }

    /// How the panel is positioned relative to the status-item anchor view.
    public enum Positioning {
        /// Convert the anchor view's bounds to screen coordinates, clamp to the visible
        /// frame, apply with `setFrame`; fall back to a frame centered on the main screen
        /// when the anchor/window/screen cannot be resolved.
        case anchoredFrameOrCentered(gap: CGFloat)
        /// Audio Switcher/Volume Mixer historic variant: the anchor button's bounds are
        /// converted via its window without the view-to-window step, the button's own
        /// screen is required (no `NSScreen.main` fallback), and the panel is simply left
        /// where it is when the anchor cannot be resolved. Applied with `setFrameOrigin`.
        case anchoredOriginRawBounds(gap: CGFloat)
        /// Color Picker historic variant: aborts the entire show when the anchor
        /// button/window is missing; clamps only when a screen is known. Applied with
        /// `setFrameOrigin`.
        case anchoredOriginOrAbort(gap: CGFloat)
        /// Maintenance historic variant: falls back to the top-right corner of the main
        /// screen when the anchor cannot be resolved. Applied with `setFrameOrigin`.
        case anchoredOriginOrTopRight(gap: CGFloat)
    }

    public struct Configuration {
        public var styleMask: NSWindow.StyleMask
        public var level: NSWindow.Level
        /// `nil` leaves AppKit's default untouched (Color Picker never set one).
        public var collectionBehavior: NSWindow.CollectionBehavior?
        public var canBecomeKey: Bool
        public var canBecomeMain: Bool
        /// For the `Bool?` knobs, `nil` means "do not touch the AppKit default" —
        /// preserving the tools that historically never set the property.
        public var isFloatingPanel: Bool?
        public var hidesOnDeactivate: Bool?
        public var isReleasedWhenClosed: Bool?
        public var isMovable: Bool?
        public var isMovableByWindowBackground: Bool?
        /// Hides the title bar chrome (transparent titlebar, hidden traffic lights) for
        /// panels created with a titled-style mask (Color Picker).
        public var hidesTitleBarChrome: Bool
        /// Rounds + clips the hosting view's layer; `nil` skips the treatment entirely
        /// (Color Picker's content draws its own shape).
        public var cornerRadius: CGFloat?
        public var creation: Creation
        public var sizing: Sizing
        public var activation: Activation
        public var clickMonitorInstall: OutsideClickInstall
        public var positioning: Positioning

        public init(
            styleMask: NSWindow.StyleMask = [.borderless],
            level: NSWindow.Level = .floating,
            collectionBehavior: NSWindow.CollectionBehavior? = [.canJoinAllSpaces, .fullScreenAuxiliary],
            canBecomeKey: Bool = true,
            canBecomeMain: Bool = true,
            isFloatingPanel: Bool? = true,
            hidesOnDeactivate: Bool? = false,
            isReleasedWhenClosed: Bool? = false,
            isMovable: Bool? = nil,
            isMovableByWindowBackground: Bool? = nil,
            hidesTitleBarChrome: Bool = false,
            cornerRadius: CGFloat? = 18,
            creation: Creation = .onConfigure,
            sizing: Sizing,
            activation: Activation = .activateThenOrderFront,
            clickMonitorInstall: OutsideClickInstall = .delayedAfterOpeningClick,
            positioning: Positioning = .anchoredFrameOrCentered(gap: 8)
        ) {
            self.styleMask = styleMask
            self.level = level
            self.collectionBehavior = collectionBehavior
            self.canBecomeKey = canBecomeKey
            self.canBecomeMain = canBecomeMain
            self.isFloatingPanel = isFloatingPanel
            self.hidesOnDeactivate = hidesOnDeactivate
            self.isReleasedWhenClosed = isReleasedWhenClosed
            self.isMovable = isMovable
            self.isMovableByWindowBackground = isMovableByWindowBackground
            self.hidesTitleBarChrome = hidesTitleBarChrome
            self.cornerRadius = cornerRadius
            self.creation = creation
            self.sizing = sizing
            self.activation = activation
            self.clickMonitorInstall = clickMonitorInstall
            self.positioning = positioning
        }
    }

    public private(set) var panel: NSPanel?

    /// Runs at the start of every show, before sizing/positioning (Clipboard captures the
    /// paste target here).
    public var onWillShow: (@MainActor () -> Void)?
    /// Runs right after the panel is ordered front, before the outside-click monitor is
    /// scheduled (Clipboard installs its key monitor here).
    public var onDidShow: (@MainActor () -> Void)?
    /// Runs after the panel is ordered out and the outside-click monitor removed.
    public var onDidClose: (@MainActor () -> Void)?

    private let configuration: Configuration
    private let content: Content
    private let anchorView: @MainActor () -> NSView?
    private var outsideClickMonitor: Any?

    public init(
        configuration: Configuration,
        content: Content,
        anchorView: @escaping @MainActor () -> NSView?
    ) {
        self.configuration = configuration
        self.content = content
        self.anchorView = anchorView
    }

    // MARK: - Lifecycle

    /// Builds the panel up front when the tool uses eager creation; no-op for lazy tools.
    public func configure() {
        if case .onConfigure = configuration.creation {
            _ = ensurePanel()
        }
    }

    public var isPanelVisible: Bool {
        panel?.isVisible == true
    }

    /// Whether the panel's current frame intersects any screen's visible frame (System
    /// Monitor re-shows the panel when a display layout change strands it off screen).
    public func isPanelOnVisibleScreen() -> Bool {
        guard let panel else {
            return false
        }

        return NSScreen.screens.contains { screen in
            screen.visibleFrame.intersects(panel.frame)
        }
    }

    public func toggle() {
        if isPanelVisible {
            close()
        } else {
            show()
        }
    }

    public func show() {
        let panel = ensurePanel()

        onWillShow?()

        let placementSize: NSSize
        switch configuration.sizing {
        case .preferred(let preferredSize):
            let size = preferredSize()
            panel.setContentSize(size)
            placementSize = size
        case .preferredPinned(let preferredSize):
            let size = preferredSize()
            panel.contentMinSize = size
            panel.contentMaxSize = size
            panel.setContentSize(size)
            placementSize = size
        case .fixedAtCreation:
            placementSize = panel.frame.size
        case .fittingContent:
            panel.layoutIfNeeded()
            placementSize = panel.frame.size
        }

        guard position(panel, size: placementSize) else {
            return
        }

        switch configuration.activation {
        case .activateThenOrderFront:
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        case .orderFrontThenActivate:
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        case .orderFrontRegardless:
            panel.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: false)
        }

        onDidShow?()

        switch configuration.clickMonitorInstall {
        case .delayedAfterOpeningClick:
            installOutsideClickMonitorAfterOpeningClick()
        case .immediate:
            installOutsideClickMonitorIfNeeded(requirePanelVisible: false)
        }
    }

    public func close() {
        panel?.orderOut(nil)
        removeOutsideClickMonitor()
        onDidClose?()
    }

    // MARK: - Show-notification observation

    /// Observes the tool's distributed "showWindow" notification (posted by the Toolbox or
    /// a `--open` relaunch) and reveals the panel when it arrives.
    public func observeShowNotification(named name: Notification.Name) {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(showFromNotification(_:)),
            name: name,
            object: nil
        )
    }

    public func stopObservingShowNotifications() {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func showFromNotification(_ notification: Notification) {
        show()
    }

    // MARK: - Termination teardown

    /// Orders the panel out and releases it. Delegates compose this with
    /// `removeOutsideClickMonitor()`/`stopObservingShowNotifications()` in
    /// `applicationWillTerminate` to mirror their historic teardown.
    public func dismissForTermination() {
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: - Outside-click monitor

    /// Removes the global outside-click monitor if installed. Safe to call repeatedly;
    /// add/remove stay symmetric so the handle can never leak a stale monitor.
    public func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    private func installOutsideClickMonitorAfterOpeningClick() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.installOutsideClickMonitorIfNeeded(requirePanelVisible: true)
        }
    }

    private func installOutsideClickMonitorIfNeeded(requirePanelVisible: Bool) {
        if requirePanelVisible {
            guard panel?.isVisible == true else {
                return
            }
        }

        // Idempotent: show() can run while the panel is already visible (e.g. the
        // second-instance `--open` distributed-notification path). Re-adding without this
        // guard would overwrite the handle and permanently leak the previous global
        // monitor.
        guard outsideClickMonitor == nil else {
            return
        }

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    // MARK: - Panel creation

    private func ensurePanel() -> NSPanel {
        if let panel {
            return panel
        }

        let panel = makePanel()
        self.panel = panel
        return panel
    }

    private func makePanel() -> NSPanel {
        // Build the content first: the fitting-content sizing mode needs the laid-out
        // SwiftUI view to know how big the panel's content rect should be.
        let contentViewController: NSViewController?
        let contentView: NSView
        switch content {
        case .viewController(let makeViewController):
            let viewController = makeViewController()
            contentViewController = viewController
            contentView = viewController.view
        case .view(let makeView):
            contentViewController = nil
            contentView = makeView()
        }

        let initialSize: NSSize
        switch configuration.sizing {
        case .preferred(let preferredSize), .preferredPinned(let preferredSize):
            initialSize = preferredSize()
        case .fixedAtCreation(let size):
            initialSize = size
        case .fittingContent:
            contentView.layoutSubtreeIfNeeded()
            initialSize = contentView.fittingSize
        }

        if let cornerRadius = configuration.cornerRadius {
            contentView.wantsLayer = true
            contentView.layer?.cornerRadius = cornerRadius
            contentView.layer?.cornerCurve = .continuous
            contentView.layer?.masksToBounds = true
        }

        let panel = HelperHostPanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: configuration.styleMask,
            backing: .buffered,
            defer: false
        )
        panel.canBecomeKeyOverride = configuration.canBecomeKey
        panel.canBecomeMainOverride = configuration.canBecomeMain
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = configuration.level
        if let collectionBehavior = configuration.collectionBehavior {
            panel.collectionBehavior = collectionBehavior
        }
        if let isFloatingPanel = configuration.isFloatingPanel {
            panel.isFloatingPanel = isFloatingPanel
        }
        if let hidesOnDeactivate = configuration.hidesOnDeactivate {
            panel.hidesOnDeactivate = hidesOnDeactivate
        }
        if let isReleasedWhenClosed = configuration.isReleasedWhenClosed {
            panel.isReleasedWhenClosed = isReleasedWhenClosed
        }
        if let isMovable = configuration.isMovable {
            panel.isMovable = isMovable
        }
        if let isMovableByWindowBackground = configuration.isMovableByWindowBackground {
            panel.isMovableByWindowBackground = isMovableByWindowBackground
        }
        if configuration.hidesTitleBarChrome {
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.standardWindowButton(.closeButton)?.isHidden = true
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
        }

        if let contentViewController {
            switch configuration.sizing {
            case .preferred, .preferredPinned:
                contentViewController.view.frame = NSRect(origin: .zero, size: initialSize)
            case .fixedAtCreation, .fittingContent:
                break
            }
            panel.contentViewController = contentViewController
        } else {
            panel.contentView = contentView
        }

        switch configuration.sizing {
        case .preferred:
            panel.setContentSize(initialSize)
        case .preferredPinned:
            panel.contentMinSize = initialSize
            panel.contentMaxSize = initialSize
            panel.setContentSize(initialSize)
        case .fixedAtCreation, .fittingContent:
            break
        }

        return panel
    }

    // MARK: - Positioning

    /// Positions the panel for a show. Returns `false` when the show must be aborted
    /// (Color Picker's historic missing-anchor behaviour).
    private func position(_ panel: NSPanel, size: NSSize) -> Bool {
        let anchor = anchorView()

        switch configuration.positioning {
        case .anchoredFrameOrCentered(let gap):
            let frame: NSRect
            // `isAnchorReady` and not merely `anchor != nil`: a status button that exists but has
            // not been laid out reports a zero-sized frame at the screen origin, and anchoring to
            // that puts the panel in a corner of the wrong display. Centred is the honest answer
            // until the real frame is available.
            if let anchor, Self.isAnchorReady(anchor), let window = anchor.window,
               let screen = window.screen ?? NSScreen.main {
                frame = HelperPanelPlacement.anchoredFrame(
                    for: size,
                    anchorFrame: Self.anchorFrameOnScreen(for: anchor, in: window),
                    visibleFrame: screen.visibleFrame,
                    gap: gap
                )
            } else {
                frame = HelperPanelPlacement.centeredFrame(
                    for: size,
                    visibleFrame: NSScreen.main?.visibleFrame ?? HelperPanelPlacement.fallbackVisibleFrame
                )
            }
            panel.setFrame(frame, display: true)
            return true

        case .anchoredOriginRawBounds(let gap):
            guard let anchor, let window = anchor.window, let screen = window.screen else {
                // Historic behaviour: leave the panel wherever it is, but still show it.
                return true
            }
            let frame = HelperPanelPlacement.anchoredFrame(
                for: size,
                anchorFrame: window.convertToScreen(anchor.bounds),
                visibleFrame: screen.visibleFrame,
                gap: gap
            )
            panel.setFrameOrigin(frame.origin)
            return true

        case .anchoredOriginOrAbort(let gap):
            guard let anchor, let window = anchor.window else {
                return false
            }
            let anchorFrame = Self.anchorFrameOnScreen(for: anchor, in: window)
            let origin: NSPoint
            if let screen = window.screen ?? NSScreen.main {
                origin = HelperPanelPlacement.anchoredFrame(
                    for: size,
                    anchorFrame: anchorFrame,
                    visibleFrame: screen.visibleFrame,
                    gap: gap
                ).origin
            } else {
                origin = HelperPanelPlacement.unclampedAnchoredOrigin(for: size, anchorFrame: anchorFrame, gap: gap)
            }
            panel.setFrameOrigin(origin)
            return true

        case .anchoredOriginOrTopRight(let gap):
            guard let anchor, let window = anchor.window, let screen = window.screen ?? NSScreen.main else {
                if let mainScreen = NSScreen.main {
                    panel.setFrameOrigin(
                        HelperPanelPlacement.topRightOrigin(for: size, visibleFrame: mainScreen.visibleFrame)
                    )
                }
                return true
            }
            let frame = HelperPanelPlacement.anchoredFrame(
                for: size,
                anchorFrame: Self.anchorFrameOnScreen(for: anchor, in: window),
                visibleFrame: screen.visibleFrame,
                gap: gap
            )
            panel.setFrameOrigin(frame.origin)
            return true
        }
    }

    private static func anchorFrameOnScreen(for view: NSView, in window: NSWindow) -> NSRect {
        let viewFrameInWindow = view.convert(view.bounds, to: nil)
        return window.convertToScreen(viewFrameInWindow)
    }

    /// Whether the anchor has been placed in the menu bar yet.
    ///
    /// Size alone is not the signal. A status item's button reports its real size (29 × 22)
    /// immediately while its window still sits at the screen origin, so a frame that looks
    /// perfectly valid can describe a point nowhere near the menu bar. Anchoring to it puts the
    /// panel relative to (0, 0) — the bottom-left corner of whichever display owns that point,
    /// which on a multi-display Mac is not even the display with the menu bar.
    ///
    /// The real test is position: a status item lives *above* its screen's visible frame, in the
    /// menu bar strip. Until the anchor is up there, it has not been placed.
    static func isAnchorReady(_ view: NSView?) -> Bool {
        guard let view, let window = view.window else { return false }
        let frame = anchorFrameOnScreen(for: view, in: window)
        guard frame.width > 0, frame.height > 0 else { return false }

        let screen = window.screen
            ?? NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) })
            ?? NSScreen.main
        guard let screen else { return false }
        return frame.midY > screen.visibleFrame.maxY
    }

    /// `show()`, but only once the anchor is actually in the menu bar.
    ///
    /// Polls on a short timer rather than re-dispatching immediately: twenty `async` hops elapse
    /// in microseconds and would expire long before the status bar has placed anything, which is
    /// the same as not waiting at all. Gives up after `timeout` and shows regardless — an
    /// unanchored panel is a cosmetic problem, a panel that never appears is a broken tool.
    public func showWhenAnchored(timeout: TimeInterval = 2, pollInterval: TimeInterval = 0.02) {
        guard !Self.isAnchorReady(anchorView()), timeout > 0 else {
            show()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) { [weak self] in
            self?.showWhenAnchored(timeout: timeout - pollInterval, pollInterval: pollInterval)
        }
    }
}
