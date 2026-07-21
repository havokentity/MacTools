import AppKit

/// A transparent overlay that turns a menu-bar status item's button into a file drop target.
///
/// `NSStatusBarButton` is created by AppKit — we never get to subclass it — and `NSView`'s
/// dragging-destination methods are overrides, not delegate callbacks, so there is no way to make
/// the button itself accept a drag. Covering it with a child view that registers for file URLs is
/// the way in.
///
/// The catch is that the child would otherwise swallow the click that opens the popover, so every
/// mouse event it receives is handed straight back to the button underneath. The button then runs
/// its normal tracking loop and fires its target/action exactly as if this view were not here,
/// which keeps left-click-to-open and right-click-to-quit working unchanged.
@MainActor
public final class StatusItemFileDropView: NSView {
    /// Called on the main actor with the file URLs of a completed drop.
    public var onDrop: (([URL]) -> Void)?

    /// Called as the drag enters and leaves, so the icon can show that it is a live target.
    public var onDragTargetingChanged: ((Bool) -> Void)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("StatusItemFileDropView is created in code only")
    }

    /// Installs the overlay over `button`, sized to follow it. Returns the view so the caller can
    /// keep hold of it; the button owns it as a subview either way.
    @discardableResult
    public static func install(over button: NSStatusBarButton) -> StatusItemFileDropView {
        let dropView = StatusItemFileDropView(frame: button.bounds)
        dropView.autoresizingMask = [.width, .height]
        button.addSubview(dropView)
        return dropView
    }

    // MARK: - Mouse pass-through

    // Every one of these hands the event back to the button underneath. Without them the overlay
    // is a dead zone over the icon and the tool cannot be opened at all.

    /// This helper is `LSUIElement` and never becomes the active app, so *every* click on its
    /// menu-bar icon is a first-mouse click.
    ///
    /// The overlay wins hit-testing over the button it covers, and `NSView` answers `false` here by
    /// default where `NSStatusBarButton` answers `true`. When AppKit asks the hit view and gets
    /// `false`, it spends the mouse-down on activating the application instead of delivering it —
    /// so `mouseDown(with:)` below is never called, the pass-through never runs, and the popover
    /// does not open. The other two status-button subviews in this package override this for the
    /// same reason.
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    public override func mouseDown(with event: NSEvent) {
        superview?.mouseDown(with: event)
    }

    public override func rightMouseDown(with event: NSEvent) {
        superview?.rightMouseDown(with: event)
    }

    public override func mouseUp(with event: NSEvent) {
        superview?.mouseUp(with: event)
    }

    public override func rightMouseUp(with event: NSEvent) {
        superview?.rightMouseUp(with: event)
    }

    // MARK: - Dragging destination

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !Self.fileURLs(from: sender).isEmpty else { return [] }
        onDragTargetingChanged?(true)
        // `.copy` describes the drag cursor, not what happens to the file: shelving records a
        // bookmark and never touches the bytes. `.link` would be closer to the truth but reads to
        // the source app as "make an alias", which is not what is being asked for either.
        return .copy
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragTargetingChanged?(false)
    }

    public override func draggingEnded(_ sender: NSDraggingInfo) {
        onDragTargetingChanged?(false)
    }

    public override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !Self.fileURLs(from: sender).isEmpty
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = Self.fileURLs(from: sender)
        onDragTargetingChanged?(false)
        guard !urls.isEmpty else { return false }

        onDrop?(urls)
        return true
    }

    /// The file URLs carried by a drag, in the order the source assembled them.
    ///
    /// `urlReadingFileURLsOnly` is what keeps a dragged web link or a text selection from arriving
    /// as a shelf entry pointing at nothing.
    static func fileURLs(from sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options)
        return (objects as? [URL]) ?? []
    }
}
