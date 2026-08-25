import AppKit

/// A window that can become key/main even when borderless. Replaces the private
/// `KeyableWindow` subclasses previously duplicated in each window-style helper target.
final class HelperHostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Owns the centered main-window lifecycle shared by the window-style helper tools (QR,
/// Clean Drive, Dev Tools, Uninstaller, Video Downloader, Grab Text, Duplicate Finder,
/// Disk Analyzer): window creation, show (center-on-first-show, or near a status item),
/// distributed "showWindow" observation, the close-to-terminate hook, and termination
/// teardown.
@MainActor
public final class HelperWindowHost: NSObject, NSWindowDelegate {
    public enum Sizing {
        /// Fixed-size window: `contentMinSize`/`contentMaxSize` are re-pinned to the
        /// preferred size on every show (the preferred size can change with the screen).
        case fixed(preferredSize: @MainActor () -> NSSize)
        /// User-resizable window (Disk Analyzer): sized/positioned on first show only,
        /// afterwards whatever frame the user dragged it to is preserved; only the
        /// minimum content size is enforced.
        case resizable(initialSize: @MainActor () -> NSSize, minimumContentSize: NSSize)
    }

    public struct Configuration {
        public var title: String
        public var styleMask: NSWindow.StyleMask
        public var collectionBehavior: NSWindow.CollectionBehavior
        /// Hides the title bar chrome (transparent titlebar, hidden traffic lights) for
        /// windows created with a titled-style mask (Disk Analyzer).
        public var hidesTitleBarChrome: Bool
        public var cornerRadius: CGFloat
        public var sizing: Sizing

        public init(
            title: String,
            styleMask: NSWindow.StyleMask = [.borderless],
            collectionBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary],
            hidesTitleBarChrome: Bool = false,
            cornerRadius: CGFloat = 18,
            sizing: Sizing
        ) {
            self.title = title
            self.styleMask = styleMask
            self.collectionBehavior = collectionBehavior
            self.hidesTitleBarChrome = hidesTitleBarChrome
            self.cornerRadius = cornerRadius
            self.sizing = sizing
        }
    }

    public private(set) var window: NSWindow?

    /// Called when the window starts or stops being visible on screen: `show()` reveals it, and
    /// occlusion hides it (another window covers it, the app is hidden, the user switches Space),
    /// as does closing it.
    ///
    /// Exists because there is no view-side equivalent. `makeContent` runs exactly once, in
    /// `configureWindow()`, and the hosting controller is never torn down, so the root view's
    /// `onAppear` fires at launch and never again no matter how often the window is shown. A tool
    /// whose UI reports state macOS changes without announcing it — a TCC grant, Secure Event
    /// Input — has to re-read that state itself, and this is the edge to do it on.
    public var onVisibilityChanged: (@MainActor (Bool) -> Void)?

    private let configuration: Configuration
    private let makeContent: @MainActor () -> NSViewController
    private let onUserClosedWindow: @MainActor () -> Void
    private var hasPositionedWindow = false

    /// Last value handed to `onVisibilityChanged`, so it only ever sees changes.
    private var isVisibleOnScreen = false

    /// - Parameters:
    ///   - makeContent: builds the tool's hosting controller (called once, during
    ///     `configureWindow()`).
    ///   - onUserClosedWindow: invoked from `windowWillClose` — every tool decides for
    ///     itself whether closing the window terminates the app.
    public init(
        configuration: Configuration,
        makeContent: @escaping @MainActor () -> NSViewController,
        onUserClosedWindow: @escaping @MainActor () -> Void
    ) {
        self.configuration = configuration
        self.makeContent = makeContent
        self.onUserClosedWindow = onUserClosedWindow
    }

    // MARK: - Lifecycle

    public func configureWindow() {
        let windowSize: NSSize
        switch configuration.sizing {
        case .fixed(let preferredSize):
            windowSize = preferredSize()
        case .resizable(let initialSize, _):
            windowSize = initialSize()
        }

        let window = HelperHostWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: configuration.styleMask,
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .clear
        window.collectionBehavior = configuration.collectionBehavior
        if configuration.hidesTitleBarChrome {
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
        }

        let hostingController = makeContent()
        switch configuration.sizing {
        case .fixed:
            hostingController.view.frame = NSRect(origin: .zero, size: windowSize)
        case .resizable:
            hostingController.view.autoresizingMask = [.width, .height]
        }
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.cornerRadius = configuration.cornerRadius
        hostingController.view.layer?.cornerCurve = .continuous
        hostingController.view.layer?.masksToBounds = true
        window.contentViewController = hostingController

        switch configuration.sizing {
        case .fixed:
            window.contentMinSize = windowSize
            window.contentMaxSize = windowSize
        case .resizable(_, let minimumContentSize):
            window.contentMinSize = minimumContentSize
        }
        window.setContentSize(windowSize)
        window.delegate = self
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.level = .normal
        window.title = configuration.title
        self.window = window
    }

    /// Reveals the window: re-pins the size (fixed sizing), positions it on the first
    /// show — centered, or near `view` (a status-item button) when one is provided — and
    /// makes it key.
    public func show(relativeTo view: NSView? = nil) {
        guard let window else {
            return
        }

        switch configuration.sizing {
        case .fixed(let preferredSize):
            let windowSize = preferredSize()
            window.contentMinSize = windowSize
            window.contentMaxSize = windowSize

            if hasPositionedWindow {
                window.setContentSize(windowSize)
            } else {
                window.setFrame(Self.initialFrame(for: windowSize, near: view), display: true)
                hasPositionedWindow = true
            }
        case .resizable(let initialSize, _):
            // Only size/position on first show; afterwards preserve whatever size the
            // user has dragged the window to (or full screen).
            if !hasPositionedWindow {
                window.setFrame(Self.initialFrame(for: initialSize(), near: view), display: true)
                hasPositionedWindow = true
            }
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // Asserted rather than read back from `occlusionState`, which AppKit updates
        // asynchronously and would still report the window as hidden at this instant.
        updateVisibility(true)
    }

    // MARK: - Visibility

    private func updateVisibility(_ visible: Bool) {
        guard visible != isVisibleOnScreen else { return }
        isVisibleOnScreen = visible
        onVisibilityChanged?(visible)
    }

    private var windowIsOnScreen: Bool {
        guard let window else { return false }
        return window.isVisible && window.occlusionState.contains(.visible)
    }

    // MARK: - Show-notification observation

    /// Observes the tool's distributed "showWindow" notification (posted by the Toolbox or
    /// a `--open` relaunch) and reveals the window when it arrives.
    public func observeShowNotification(named name: Notification.Name) {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(showWindowFromNotification(_:)),
            name: name,
            object: nil
        )
    }

    @objc private func showWindowFromNotification(_ notification: Notification) {
        show()
    }

    // MARK: - Termination teardown

    public func tearDownForTermination() {
        DistributedNotificationCenter.default().removeObserver(self)

        window?.orderOut(nil)
        window?.delegate = nil
        window = nil
        updateVisibility(false)
    }

    // MARK: - NSWindowDelegate

    public func windowWillClose(_ notification: Notification) {
        // Before the tool's own hook, which may terminate the app: whatever the observer stops
        // (a poll, an observation) should stop while there is still someone to stop it.
        updateVisibility(false)
        onUserClosedWindow()
    }

    public func windowDidChangeOcclusionState(_ notification: Notification) {
        updateVisibility(windowIsOnScreen)
    }

    // Drop the rounded corners in full screen (where the content fills the whole display)
    // and restore them when returning to a windowed frame. Only resizable windows whose
    // collection behaviour allows full screen (Disk Analyzer) can ever trigger these.
    public func windowWillEnterFullScreen(_ notification: Notification) {
        window?.contentViewController?.view.layer?.cornerRadius = 0
    }

    public func windowDidExitFullScreen(_ notification: Notification) {
        window?.contentViewController?.view.layer?.cornerRadius = configuration.cornerRadius
    }

    // MARK: - Placement

    private static func initialFrame(for size: NSSize, near view: NSView?) -> NSRect {
        if let view, let window = view.window, let screen = window.screen ?? NSScreen.main {
            let viewFrameInWindow = view.convert(view.bounds, to: nil)
            let anchorFrame = window.convertToScreen(viewFrameInWindow)
            return HelperPanelPlacement.anchoredFrame(
                for: size,
                anchorFrame: anchorFrame,
                visibleFrame: screen.visibleFrame
            )
        }

        return HelperPanelPlacement.centeredFrame(
            for: size,
            visibleFrame: NSScreen.main?.visibleFrame ?? HelperPanelPlacement.fallbackVisibleFrame
        )
    }
}
