import AppKit
import Combine

/// One editing session, handed to the editor sheet as its starting values. `id` is nil for a
/// snippet being created; `editorID` is fresh per session so SwiftUI tears the editor's own
/// `@State` down when the user switches from one snippet to another.
public struct SnippetEditorSession: Sendable {
    public let editorID = UUID()
    public let id: Snippet.ID?
    public let title: String
    public let body: String
    public let expandsPlaceholders: Bool

    public var isNew: Bool { id == nil }
}

/// View-model behind the Snippets popover. Owns the library store, the live search and selection,
/// the editing session, and the paste target (the app that was frontmost before the panel
/// appeared). Both the SwiftUI view and the app delegate's key monitor call into it.
@MainActor
public final class SnippetsController: ObservableObject {
    /// Also the `SingleInstanceGuard` identifier and the plist `CFBundleIdentifier`; pasted text
    /// is stamped with it so clipboard managers can attribute the write.
    public static let bundleIdentifier = "com.havokentity.mactools.snippets"

    public let store: SnippetsStore

    @Published public var searchText = ""
    @Published public private(set) var selectedID: Snippet.ID?
    @Published public private(set) var editorSession: SnippetEditorSession?
    /// True when a paste was attempted (or the panel was opened) without Accessibility access.
    /// The text still reaches the clipboard, so this drives an explanation rather than a failure.
    @Published public private(set) var needsAccessibility = false
    /// Bumped each time the panel is summoned so the view can refocus search and scroll to top.
    @Published public private(set) var showToken = 0

    /// The app to paste into — captured by the delegate before the panel takes focus.
    public var pasteTarget: NSRunningApplication? {
        didSet { pasteTargetName = pasteTarget?.localizedName }
    }

    /// Name of that app, published so the footer can say where ⏎ will land. Without it a paste
    /// into an app with no focused text field is indistinguishable from the panel merely closing,
    /// which is exactly how the "Return does nothing" report started.
    @Published public private(set) var pasteTargetName: String?
    /// Set by the delegate; dismisses the panel (returning focus) right before a paste.
    public var onRequestClose: (() -> Void)?

    private var storeObservation: AnyCancellable?

    public init() {
        store = SnippetsStore()
        // The store is a separate ObservableObject, so its edits would not redraw a view that
        // only observes the controller.
        storeObservation = store.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
    }

    // MARK: - Derived list

    /// Snippets matching the search field, in library order.
    public var filteredSnippets: [Snippet] {
        SnippetsKit.filter(store.snippets, query: searchText)
    }

    public var selectedSnippet: Snippet? {
        guard let selectedID else { return nil }
        return store.snippet(with: selectedID)
    }

    /// Whether the library is empty, as opposed to merely filtered down to nothing — the two need
    /// different empty states ("add your first snippet" vs "no matches").
    public var isLibraryEmpty: Bool {
        store.snippets.isEmpty
    }

    // MARK: - Lifecycle around showing the panel

    public func prepareForShow() {
        needsAccessibility = !ClipboardPaste.hasAccessibilityPermission
        // An open editor survives a reopen: the panel dismisses on any outside click, and
        // discarding half-typed snippet text because the user glanced at another window would
        // lose work that has no other copy.
        if editorSession == nil {
            searchText = ""
            selectFirst()
        }
        showToken &+= 1
    }

    public func selectFirst() {
        selectedID = filteredSnippets.first?.id
    }

    public func select(_ id: Snippet.ID) {
        selectedID = id
    }

    public func moveSelection(by delta: Int) {
        let items = filteredSnippets
        guard !items.isEmpty else { return }
        let currentIndex = items.firstIndex { $0.id == selectedID } ?? 0
        let nextIndex = min(max(currentIndex + delta, 0), items.count - 1)
        selectedID = items[nextIndex].id
    }

    private func ensureSelectionValid() {
        let items = filteredSnippets
        if let selectedID, items.contains(where: { $0.id == selectedID }) { return }
        selectedID = items.first?.id
    }

    // MARK: - Pasting

    /// Copies the snippet (placeholders resolved) and pastes it into the app the user came from.
    public func paste(_ snippet: Snippet) {
        // Checked *before* dismissing. Closing first and reporting afterwards means the banner is
        // set on a panel the user can no longer see, so a missing permission looks exactly like
        // "pressing Return just closes the window" — the failure is invisible and unexplained.
        guard ClipboardPaste.hasAccessibilityPermission else {
            needsAccessibility = true
            ClipboardPaste.promptForAccessibilityPermission()
            return
        }

        let text = SnippetsKit.pasteText(for: snippet)
        let target = pasteTarget
        // Dismiss first so focus is back in the target app before ⌘V is synthesized.
        onRequestClose?()
        let pasted = ClipboardPaste.pasteText(text, sourceBundleID: Self.bundleIdentifier, into: target)
        if !pasted {
            needsAccessibility = true
        }
    }

    /// Pastes the highlighted row — the top hit right after typing, since search reselects.
    public func pasteSelected() {
        guard let selectedSnippet else { return }
        paste(selectedSnippet)
    }

    // MARK: - Editing

    public func beginCreating() {
        editorSession = SnippetEditorSession(id: nil, title: "", body: "", expandsPlaceholders: true)
    }

    public func beginEditing(_ id: Snippet.ID) {
        guard let snippet = store.snippet(with: id) else { return }
        selectedID = id
        editorSession = SnippetEditorSession(
            id: snippet.id,
            title: snippet.title,
            body: snippet.body,
            expandsPlaceholders: snippet.expandsPlaceholders
        )
    }

    public func cancelEditing() {
        editorSession = nil
    }

    /// Applies the editor's values. A snippet with neither a name nor any text is discarded
    /// rather than saved: an empty row can be neither found nor usefully pasted.
    public func commitEditor(title: String, body: String, expandsPlaceholders: Bool) {
        guard let session = editorSession else { return }
        editorSession = nil

        let isBlank = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if let id = session.id {
            if isBlank {
                store.delete(id: id)
            } else {
                store.update(id: id, title: title, body: body, expandsPlaceholders: expandsPlaceholders)
            }
        } else if !isBlank {
            let created = store.add(title: title, body: body, expandsPlaceholders: expandsPlaceholders)
            // A fresh snippet is almost always the one the user wants next, and the search field
            // may be filtering it out — clear the query so the new row is actually visible.
            searchText = ""
            selectedID = created.id
        }

        ensureSelectionValid()
    }

    public func delete(_ id: Snippet.ID) {
        if editorSession?.id == id {
            editorSession = nil
        }
        store.delete(id: id)
        ensureSelectionValid()
    }

    /// Moves a snippet up (-1) or down (+1) the library.
    public func move(_ id: Snippet.ID, by offset: Int) {
        guard canMove(id, by: offset) else { return }
        store.move(id: id, by: offset)
    }

    /// Whether a move in that direction would do anything — drives the enabled state of the
    /// reorder buttons, and gates the ⌘↑/⌘↓ shortcuts so both agree. Reordering acts on the whole
    /// library, so it is suppressed while a search is hiding the neighbours the row would swap
    /// with: the row would appear to sit still while its real position shifted.
    public func canMove(_ id: Snippet.ID, by offset: Int) -> Bool {
        guard !isSearching, let index = store.snippets.firstIndex(where: { $0.id == id }) else { return false }
        return store.snippets.indices.contains(index + offset)
    }

    public var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Accessibility

    public func refreshAccessibilityState() {
        needsAccessibility = !ClipboardPaste.hasAccessibilityPermission
    }

    // MARK: - Key handling (called from the delegate's local key monitor)

    /// Returns true if the key was consumed; false lets it reach the focused control so the user
    /// can keep typing.
    public func handleKey(_ event: NSEvent) -> Bool {
        // Compare only the modifiers a shortcut is allowed to care about. Arrow keys always
        // report `.numericPad` and `.function` alongside whatever the user held, so an exact
        // `flags == .command` is never true for ⌘↑ / ⌘↓ — the reorder shortcuts fell through to
        // the plain-arrow cases below and moved the selection instead of the snippet.
        let meaningfulModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection(meaningfulModifiers)
        let isCommandOnly = flags == .command
        // ⌥⌘ for reorder rather than plain ⌘: bare ⌘↑ / ⌘↓ collide with Mission Control and
        // space-switching shortcuts on many setups, and a system shortcut is consumed before this
        // local monitor ever sees the event, so the app cannot win that race. Option steps aside.
        let isCommandOption = flags == [.command, .option]

        // While the editor is open every key belongs to it — arrows move the caret, Return
        // inserts a newline — except Escape, which cancels the session.
        if editorSession != nil {
            if event.keyCode == 53 {
                cancelEditing()
                return true
            }
            return false
        }

        switch Int(event.keyCode) {
        case 126 where isCommandOption: // ⌥⌘↑ move the selected snippet up
            if let selectedID { move(selectedID, by: -1) }
            return true
        case 125 where isCommandOption: // ⌥⌘↓ move the selected snippet down
            if let selectedID { move(selectedID, by: 1) }
            return true
        case 126: // up arrow
            moveSelection(by: -1)
            return true
        case 125: // down arrow
            moveSelection(by: 1)
            return true
        case 53: // escape
            onRequestClose?()
            return true
        case 36, 76: // return / keypad enter
            pasteSelected()
            return true
        default:
            break
        }

        if isCommandOnly, let characters = event.charactersIgnoringModifiers {
            if characters == "n" {
                beginCreating()
                return true
            }
            if characters == "e" {
                if let selectedID { beginEditing(selectedID) }
                return true
            }
        }

        return false
    }
}
