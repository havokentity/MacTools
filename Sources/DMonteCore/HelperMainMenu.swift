import AppKit

/// Installs the minimal main menu an agent app needs for text editing to work.
///
/// `LSUIElement` apps have no visible menu bar, which makes it easy to conclude they do not need
/// a main menu at all. They do: AppKit dispatches ⌘C / ⌘V / ⌘X / ⌘A / ⌘Z by matching the event
/// against the **main menu's key equivalents** before anything else sees it. With no main menu
/// there is nothing to match, so those shortcuts are silently dead in every text field the tool
/// presents — the field accepts typing, and copy and paste do nothing at all.
///
/// The menu is never drawn (there is no menu bar to draw it in); it exists purely so the key
/// equivalents resolve. The items use `nil` targets so each one travels the responder chain and
/// lands on whichever text view is focused.
@MainActor
public enum HelperMainMenu {

    /// Idempotent: a helper that calls this twice, or one that already built its own menu, keeps
    /// the menu it has.
    public static func installEditMenuIfNeeded() {
        guard NSApp.mainMenu == nil else { return }

        let mainMenu = NSMenu()

        // An application menu has to be first — AppKit treats item 0 as the app menu and will not
        // look for key equivalents in it. Without this placeholder the Edit menu would occupy that
        // slot and its shortcuts would go unmatched, which is the bug this type exists to fix.
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        // Selectors are built from strings rather than `#selector`: `copy(_:)` and friends are
        // declared on several AppKit classes plus `NSObject.copy()`, so the literal is both
        // unambiguous and exactly what the responder chain matches on.
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: Selector(("cut:")), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: Selector(("copy:")), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: Selector(("paste:")), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: "Paste and Match Style",
            action: Selector(("pasteAsPlainText:")),
            keyEquivalent: "V"
        )
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All", action: Selector(("selectAll:")), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }
}
