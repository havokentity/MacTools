import AppKit

/// Configures a menu-bar `NSStatusItem`'s own button as the icon host, rather than adding a
/// custom subview to it.
///
/// Two earlier bugs both trace back to the custom-subview approach:
///   • The button was left with no image/title of its own, so when the menu bar got crowded
///     during normal use macOS treated it as empty and culled it — the icon "disappeared."
///   • A hand-drawn image blitted into a subview via `NSImage.draw(in:)` keeps its baked color,
///     so the toolbox glyph rendered solid black instead of the adaptive template white the
///     SF-symbol tools get.
///
/// Driving the button natively fixes both: a template image is auto-tinted (white on a dark
/// menu bar), gets the standard rollover highlight for free, and is AppKit-managed content that
/// the menu bar won't drop. `target`/`action` (set by the caller) handle the click.
public enum StatusBarButtonContent {
    private final class MenuAction: NSObject {
        private let action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func performAction() {
            action()
        }
    }

    /// Installs a static template icon on the status item's button.
    /// - Parameters:
    ///   - image: the icon; forced to template so AppKit tints + highlights it.
    ///   - item: the status item whose button hosts the icon.
    ///   - toolTip: hover tooltip.
    ///   - target/action: click handler wired to the button itself.
    @MainActor
    public static func install(
        image: NSImage,
        in item: NSStatusItem,
        toolTip: String,
        target: AnyObject,
        action: Selector
    ) {
        guard let button = item.button else { return }
        image.isTemplate = true
        button.image = image
        button.imagePosition = .imageOnly
        button.toolTip = toolTip
        button.target = target
        button.action = action
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// Installs a button driven by a live string (e.g. Focus Timer's countdown). Pass the icon
    /// used when `title` is empty/idle. Call `updateTitle` again whenever the value changes.
    @MainActor
    public static func install(
        title: String?,
        idleImage: NSImage,
        in item: NSStatusItem,
        toolTip: String,
        target: AnyObject,
        action: Selector
    ) {
        guard let button = item.button else { return }
        idleImage.isTemplate = true
        button.toolTip = toolTip
        button.target = target
        button.action = action
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateTitle(title, idleImage: idleImage, in: item)
    }

    /// Switches the button between a text title and the idle icon. AppKit tints/highlights both.
    @MainActor
    public static func updateTitle(_ title: String?, idleImage: NSImage, in item: NSStatusItem) {
        guard let button = item.button else { return }
        if let title, !title.isEmpty {
            button.image = nil
            button.title = title
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.imagePosition = .noImage
        } else {
            idleImage.isTemplate = true
            button.title = ""
            button.image = idleImage
            button.imagePosition = .imageOnly
        }
    }

    /// Draws an icon with a short count badge beside it (File Shelf's "how many files are parked
    /// here?"). Unlike `updateTitle`, the icon stays: the badge annotates the tool, it does not
    /// replace it, and a bare number in the menu bar says nothing about which tool it belongs to.
    ///
    /// Pass `nil`/empty to drop back to the icon alone, so an empty shelf does not hold menu-bar
    /// width open for a permanent "0".
    @MainActor
    public static func updateBadge(_ badge: String?, image: NSImage, in item: NSStatusItem) {
        guard let button = item.button else { return }
        image.isTemplate = true
        button.image = image

        if let badge, !badge.isEmpty {
            button.title = badge
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            button.imagePosition = .imageLeading
            // Without this the glyph and the number sit flush against each other and read as one
            // smudge at menu-bar size.
            button.imageHugsTitle = true
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
        }
    }

    /// Shows a lightweight context menu for a status item on right-click or control+left-click
    /// (the canonical macOS right-click equivalent, and the only option on some trackpad
    /// configurations) while preserving the plain left-click action used by popovers/windows.
    ///
    /// Callers wire the button with `sendAction(on: [.leftMouseUp, .rightMouseUp])` (see the
    /// `install` helpers above), so a control+left-click reaches this function as a left-mouse
    /// event carrying `.control` in its modifier flags rather than as a right-mouse event.
    @MainActor
    public static func popUpQuitMenuIfNeeded(
        for item: NSStatusItem?,
        additionalItems: [(title: String, action: () -> Void)] = [],
        quitTitle: String = "Quit",
        action: @escaping () -> Void
    ) -> Bool {
        guard let event = NSApp.currentEvent,
              let item,
              let button = item.button else {
            return false
        }

        let isRightClick = event.type == .rightMouseDown || event.type == .rightMouseUp
        let isControlLeftClick = (event.type == .leftMouseDown || event.type == .leftMouseUp)
            && event.modifierFlags.contains(.control)
        guard isRightClick || isControlLeftClick else {
            return false
        }

        let menu = NSMenu()
        for additionalItem in additionalItems {
            let handler = MenuAction(action: additionalItem.action)
            let menuItem = NSMenuItem(title: additionalItem.title, action: #selector(MenuAction.performAction), keyEquivalent: "")
            menuItem.target = handler
            menuItem.representedObject = handler
            menu.addItem(menuItem)
        }
        if !additionalItems.isEmpty {
            menu.addItem(.separator())
        }

        let handler = MenuAction(action: action)
        let quitItem = NSMenuItem(title: quitTitle, action: #selector(MenuAction.performAction), keyEquivalent: "")
        quitItem.target = handler
        quitItem.representedObject = handler
        menu.addItem(quitItem)
        menu.popUp(positioning: nil, at: NSPoint(x: button.bounds.midX, y: button.bounds.minY), in: button)
        return true
    }
}
