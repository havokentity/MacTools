import AppKit
import Combine

/// View-model that drives the clipboard popover. Owns the store + monitor, the live search /
/// type-filter / selection state, and the paste target (the app that was frontmost before the
/// panel appeared). Both the SwiftUI view and the app delegate's key monitor call into it.
@MainActor
public final class ClipboardController: ObservableObject {
    public let store: ClipboardStore
    public let monitor: ClipboardMonitor

    @Published public var searchText = ""
    @Published public var typeFilter: ClipboardKind?
    @Published public var selectedID: ClipboardEntry.ID?
    @Published public private(set) var isPaused = false
    @Published public var needsAccessibility = false
    /// Bumped each time the panel is summoned so the view can refocus search + scroll to top.
    @Published public private(set) var showToken = 0

    /// The app to paste into — captured by the delegate before the panel takes focus.
    public var pasteTarget: NSRunningApplication?
    /// Set by the delegate; dismisses the panel (returning focus) right before a paste.
    public var onRequestClose: (() -> Void)?

    private var storeObservation: AnyCancellable?

    public init() {
        store = ClipboardStore()
        monitor = ClipboardMonitor(store: store)
        storeObservation = store.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
    }

    public func startCapturing() {
        monitor.start()
    }

    // MARK: - Derived list

    public var filteredEntries: [ClipboardEntry] {
        var items = store.entries

        if let typeFilter {
            items = items.filter { $0.kind == typeFilter }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            items = items.filter { Self.fuzzyMatches(query, in: $0.searchableText) }
        }

        return items.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned }
            return lhs.date > rhs.date
        }
    }

    public var selectedEntry: ClipboardEntry? {
        guard let selectedID else { return nil }
        return store.entries.first { $0.id == selectedID }
    }

    // MARK: - Lifecycle around showing the panel

    public func prepareForShow() {
        searchText = ""
        typeFilter = nil
        needsAccessibility = !ClipboardPaste.hasAccessibilityPermission
        selectFirst()
        showToken &+= 1
    }

    public func selectFirst() {
        selectedID = filteredEntries.first?.id
    }

    private func ensureSelectionValid() {
        let items = filteredEntries
        if let selectedID, items.contains(where: { $0.id == selectedID }) { return }
        selectedID = items.first?.id
    }

    public func moveSelection(by delta: Int) {
        let items = filteredEntries
        guard !items.isEmpty else { return }
        let currentIndex = items.firstIndex { $0.id == selectedID } ?? 0
        let nextIndex = min(max(currentIndex + delta, 0), items.count - 1)
        selectedID = items[nextIndex].id
    }

    // MARK: - Actions

    public func pasteSelected(asPlainText: Bool) {
        guard let entry = selectedEntry else { return }
        performPaste(entry, asPlainText: asPlainText)
    }

    public func pasteEntry(at index: Int) {
        let items = filteredEntries
        guard items.indices.contains(index) else { return }
        performPaste(items[index], asPlainText: false)
    }

    public func paste(_ entry: ClipboardEntry, asPlainText: Bool) {
        performPaste(entry, asPlainText: asPlainText)
    }

    private func performPaste(_ entry: ClipboardEntry, asPlainText: Bool) {
        let target = pasteTarget
        onRequestClose?()
        let pasted = ClipboardPaste.paste(entry, store: store, asPlainText: asPlainText, into: target)
        if !pasted {
            needsAccessibility = true
        }
    }

    public func togglePinSelected() {
        guard let selectedID else { return }
        store.togglePin(selectedID)
    }

    public func togglePin(_ id: ClipboardEntry.ID) {
        store.togglePin(id)
    }

    public func deleteSelected() {
        guard let selectedID else { return }
        let items = filteredEntries
        let index = items.firstIndex { $0.id == selectedID }
        store.delete(selectedID)
        let remaining = filteredEntries
        if let index {
            self.selectedID = remaining[safe: min(index, remaining.count - 1)]?.id
        } else {
            self.selectedID = remaining.first?.id
        }
    }

    public func delete(_ id: ClipboardEntry.ID) {
        store.delete(id)
        ensureSelectionValid()
    }

    public func togglePause() {
        monitor.isPaused.toggle()
        isPaused = monitor.isPaused
    }

    public func clearAll() {
        store.clear(includingPinned: false)
        ensureSelectionValid()
    }

    // MARK: - Key handling (called from the delegate's local key monitor)

    /// Returns true if the key was consumed (selection/paste/dismiss); false lets it reach the
    /// search field so the user can keep typing.
    public func handleKey(_ event: NSEvent) -> Bool {
        // Normalize away Caps Lock so exact modifier checks aren't defeated by it.
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)
        let isCommandOnly = flags == .command

        switch Int(event.keyCode) {
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
            pasteSelected(asPlainText: flags.contains(.option) || flags.contains(.shift))
            return true
        case 51 where isCommandOnly: // ⌘⌫ delete entry
            deleteSelected()
            return true
        default:
            break
        }

        if isCommandOnly {
            if let characters = event.charactersIgnoringModifiers {
                if characters == "p" {
                    togglePinSelected()
                    return true
                }
                if let number = Int(characters), (1...9).contains(number) {
                    pasteEntry(at: number - 1)
                    return true
                }
            }
        }

        return false
    }

    private static func fuzzyMatches(_ query: String, in target: String) -> Bool {
        if target.contains(query) { return true }
        // Subsequence match: every query char appears in order.
        var searchIndex = query.startIndex
        for character in target where searchIndex < query.endIndex && character == query[searchIndex] {
            searchIndex = query.index(after: searchIndex)
        }
        return searchIndex == query.endIndex
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
