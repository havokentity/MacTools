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
    /// Inline status line for the OCR action ("Copy Text from Image"); nil when there is nothing
    /// to report. This tool has no alerts, so every OCR outcome — including failure — surfaces
    /// here or nowhere.
    @Published public private(set) var ocrStatus: String?
    /// The image entry whose OCR run is in flight, so its row can show a spinner. nil when idle.
    @Published public private(set) var ocrEntryID: ClipboardEntry.ID?

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
        // A result from a previous visit describes an entry the user is no longer looking at,
        // and the row it belongs to may not even be on screen — stale, so drop it. A run still
        // in flight is not stale: clearing its caption would leave a row spinning with nothing
        // on screen to say why.
        if ocrEntryID == nil {
            ocrStatus = nil
        }
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

    // MARK: - OCR

    /// Recognizes the text in an image entry's backing file and puts it on the clipboard.
    ///
    /// Vision's accurate recognizer is far too slow to run inline — a full-screen screenshot
    /// costs the better part of a second — so the work goes to a detached task and the row shows
    /// a spinner meanwhile. Nothing is written to the pasteboard unless there is text to write:
    /// clearing it for a blank result would destroy whatever the user had copied and replace it
    /// with nothing.
    public func extractText(from entry: ClipboardEntry) {
        guard entry.kind == .image else { return }
        // One run at a time. Recognition is CPU-hungry, and two runs racing would leave the
        // status line describing whichever finished last rather than the row the user clicked.
        // The UI disables every trigger while `ocrEntryID != nil`, so reaching this guard means
        // a non-UI caller raced us; dropping the request silently is right only because the
        // user cannot get here by clicking.
        guard ocrEntryID == nil else { return }

        guard let fileName = entry.imageFileName else {
            ocrStatus = ClipboardOCRKit.statusMessage(for: .imageUnavailable)
            return
        }
        let imageURL = store.imagesURL(for: fileName)

        ocrEntryID = entry.id
        ocrStatus = ClipboardOCRKit.inProgressMessage

        // Deliberately not retained for cancellation: a run the user already paid the CPU for
        // should still land on the clipboard even if the panel closes underneath it, and the
        // detached child wouldn't honour cancellation anyway.
        Task { [weak self] in
            // Task.detached's closure is @Sendable, so it does not inherit this class's
            // @MainActor isolation — recognition genuinely leaves the main thread.
            let outcome = await Task.detached(priority: .userInitiated) {
                ClipboardOCRKit.recognize(imageURL: imageURL)
            }.value

            // Land the text before touching `self`: the user already paid for the recognition,
            // so it belongs on the clipboard even if this controller went away while Vision was
            // working. Only the status line is worth dropping in that case.
            if case let .text(text) = outcome {
                ClipboardPaste.copyRecognizedText(text)
            }

            guard let self else { return }
            self.ocrEntryID = nil
            self.ocrStatus = ClipboardOCRKit.statusMessage(for: outcome)
        }
    }

    /// Hides the OCR status line. It otherwise persists until the panel is next summoned, so a
    /// result stays readable while the user keeps working in the list.
    public func dismissOCRStatus() {
        ocrStatus = nil
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
