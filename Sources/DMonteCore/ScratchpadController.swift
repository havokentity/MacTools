import AppKit

public extension DefaultsKey {
    /// UUID string of the note that was open when the panel last closed, so reopening lands the
    /// user back where they were. A stale id (note deleted elsewhere) falls back to the first note.
    static let scratchpadSelectedNoteID = "tool.scratchpad.selectedNoteID"

    /// Editor point size. The integrator registers a default of `13`.
    static let scratchpadFontSize = "tool.scratchpad.fontSize"
}

/// Owns the Scratchpad's notes and their persistence.
///
/// Losing typed text is this tool's only unacceptable failure, so saves are layered: every edit
/// schedules a debounced background write, and `flushPendingSaves()` forces everything to disk
/// when the panel closes and again at termination. Writes go through `ScratchpadNoteWriter`,
/// which serializes them and drops any snapshot older than one already on disk — the debounced
/// tasks are independent and unordered, so without that a slow large-note write could land after
/// a newer one and resurrect deleted text.
@MainActor
public final class ScratchpadController: ObservableObject {
    /// All notes, oldest-first. Never empty: the UI always has something to edit.
    @Published public private(set) var notes: [ScratchpadNote] = []

    @Published public private(set) var selectedNoteID: UUID?

    /// Size of the note being edited. Recomputed on a short debounce off the main actor, because
    /// counting graphemes in a very large note on every keystroke is exactly the kind of O(n)
    /// main-thread work that makes typing feel sticky.
    @Published public private(set) var counts: ScratchpadCounts = .empty

    /// Inline status line — this tool never raises an alert.
    @Published public private(set) var statusMessage: String?

    /// True while the selected note's last clear can still be taken back.
    @Published public private(set) var canUndoClear = false

    /// Set by the first press of Delete Note; the second press within the same selection commits.
    /// Deleting notes is destructive and there are no alerts in this suite, so the confirmation
    /// lives in the button itself.
    @Published public private(set) var pendingDeleteNoteID: UUID?

    private let directory: URL

    /// Persisted-settings store. Defaults to the app-wide shared suite in production; tests
    /// inject an isolated suite so they never touch the user's real preferences.
    private let defaults: UserDefaults

    private let writer = ScratchpadNoteWriter()

    private var saveTasks: [UUID: Task<Void, Never>] = [:]
    private var saveGeneration: UInt64 = 0
    private var countTask: Task<Void, Never>?

    /// Text removed by Clear, kept per note for the lifetime of the process. Keyed by note so
    /// switching away and back does not silently forfeit the undo.
    private var clearedBodies: [UUID: String] = [:]

    /// - Parameters:
    ///   - directory: storage location. Defaults to Application Support; tests pass a temporary
    ///     directory so they never touch the user's real notes.
    ///   - defaults: preferences store, defaulting to the shared suite.
    public init(directory: URL? = nil, defaults: UserDefaults = AppDefaults.shared) {
        self.defaults = defaults

        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            self.directory = base.appendingPathComponent("DMonteScratchpad", isDirectory: true)
        }

        ScratchpadKit.prepareDirectory(self.directory)
        load()
    }

    // MARK: - Public API

    /// Body of the note currently being edited; empty string when there somehow is no selection.
    public var activeText: String {
        guard let index = activeIndex else { return "" }
        return notes[index].body
    }

    public var activeNote: ScratchpadNote? {
        guard let index = activeIndex else { return nil }
        return notes[index]
    }

    /// Editor point size, clamped to a range that stays legible in the panel.
    public var fontSize: CGFloat {
        let stored = defaults.integer(forKey: DefaultsKey.scratchpadFontSize)
        return CGFloat(min(20, max(11, stored == 0 ? 13 : stored)))
    }

    public func setFontSize(_ size: CGFloat) {
        defaults.set(Int(size), forKey: DefaultsKey.scratchpadFontSize)
        objectWillChange.send()
    }

    /// Records an edit from the text view.
    public func updateText(_ newText: String) {
        guard let index = activeIndex, notes[index].body != newText else { return }

        // Typing after a clear means the user has moved on; offering to restore the old body at
        // that point would silently overwrite what they just wrote.
        if canUndoClear {
            clearedBodies[notes[index].id] = nil
            canUndoClear = false
        }

        apply(body: newText, at: index)
        statusMessage = nil
    }

    public func selectNote(_ id: UUID) {
        guard id != selectedNoteID, notes.contains(where: { $0.id == id }) else { return }

        // Switching is a natural commit point, and the note being left may still be sitting on an
        // unfired debounce.
        flushPendingSaves()

        selectedNoteID = id
        defaults.set(id.uuidString, forKey: DefaultsKey.scratchpadSelectedNoteID)
        pendingDeleteNoteID = nil
        statusMessage = nil
        canUndoClear = clearedBodies[id] != nil
        refreshCounts()
    }

    /// Adds an empty note and selects it.
    public func addNote() {
        flushPendingSaves()

        let note = ScratchpadNote(title: ScratchpadKit.uniqueTitle(
            ScratchpadKit.untitledTitle,
            existing: notes.map(\.title)
        ))
        notes.append(note)
        selectedNoteID = note.id
        defaults.set(note.id.uuidString, forKey: DefaultsKey.scratchpadSelectedNoteID)
        pendingDeleteNoteID = nil
        canUndoClear = false
        statusMessage = nil
        refreshCounts()

        // Written immediately rather than debounced: an empty new note has nothing to lose to a
        // crash, but a note file that never appears would make the switcher lie after a relaunch.
        writeNow(note)
    }

    /// Renames the selected note, de-duplicating against the others.
    public func renameSelectedNote(to raw: String) {
        guard let index = activeIndex else { return }

        let others = notes.enumerated().filter { $0.offset != index }.map(\.element.title)
        let title = ScratchpadKit.uniqueTitle(raw, existing: others)
        guard notes[index].title != title else { return }

        notes[index].title = title
        notes[index].modified = Date()
        scheduleSave(notes[index])
    }

    /// Two-step delete of the selected note. The first call arms the confirmation and returns
    /// without touching anything; the second commits.
    public func deleteSelectedNote() {
        guard let index = activeIndex else { return }
        let note = notes[index]

        guard pendingDeleteNoteID == note.id else {
            pendingDeleteNoteID = note.id
            statusMessage = "Press again to delete “\(note.title)”."
            return
        }

        pendingDeleteNoteID = nil
        saveTasks[note.id]?.cancel()
        saveTasks[note.id] = nil
        clearedBodies[note.id] = nil
        notes.remove(at: index)
        writer.delete(id: note.id, in: directory)

        // The editor needs a note to point at, so the last one deleted is replaced by a fresh
        // blank rather than leaving the panel with nothing to show.
        if notes.isEmpty {
            let replacement = ScratchpadNote(title: ScratchpadKit.untitledTitle)
            notes.append(replacement)
            writeNow(replacement)
        }

        let next = notes[min(index, notes.count - 1)]
        selectedNoteID = next.id
        defaults.set(next.id.uuidString, forKey: DefaultsKey.scratchpadSelectedNoteID)
        canUndoClear = clearedBodies[next.id] != nil
        statusMessage = "Deleted “\(note.title)”."
        refreshCounts()
    }

    /// Copies the whole note to the clipboard.
    public func copyAll() {
        let text = activeText
        guard !text.isEmpty else {
            statusMessage = "Nothing to copy yet."
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        statusMessage = "Copied to the clipboard."
    }

    /// Empties the selected note, keeping the removed text so `undoClear()` can put it back.
    public func clearActiveNote() {
        guard let index = activeIndex, !notes[index].body.isEmpty else { return }

        clearedBodies[notes[index].id] = notes[index].body
        apply(body: "", at: index)
        canUndoClear = true
        pendingDeleteNoteID = nil
        statusMessage = "Cleared — you can still undo this."
    }

    public func undoClear() {
        guard let index = activeIndex, let restored = clearedBodies[notes[index].id] else { return }

        apply(body: restored, at: index)
        clearedBodies[notes[index].id] = nil
        canUndoClear = false
        statusMessage = "Restored."
    }

    /// Forces every pending debounced write to disk right now.
    ///
    /// The debounced tasks are detached and die with the process, so without this the last 400ms
    /// of typing never reaches disk — quitting straight after a burst of edits would lose exactly
    /// the words the user just wrote. Every note is written, not only the dirty ones: the set is
    /// small, and a redundant write costs far less than a missed one.
    public func flushPendingSaves() {
        saveTasks.values.forEach { $0.cancel() }
        saveTasks.removeAll()

        saveGeneration &+= 1
        let generation = saveGeneration
        for note in notes {
            writer.write(note, to: directory, generation: generation)
        }
    }

    // MARK: - Private

    private var activeIndex: Int? {
        guard let selectedNoteID else { return nil }
        return notes.firstIndex { $0.id == selectedNoteID }
    }

    private func load() {
        notes = ScratchpadKit.loadNotes(from: directory)

        if notes.isEmpty {
            // First run (or a wiped directory): start with one note so the editor is usable
            // immediately instead of presenting an empty switcher and no place to type.
            let first = ScratchpadNote(title: "Notes")
            notes.append(first)
            writeNow(first)
        }

        let storedID = defaults.string(forKey: DefaultsKey.scratchpadSelectedNoteID)
            .flatMap(UUID.init(uuidString:))
        selectedNoteID = notes.first(where: { $0.id == storedID })?.id ?? notes[0].id
        canUndoClear = false
        refreshCounts()
    }

    /// Applies a new body to the note at `index` and starts the debounced save plus the count
    /// refresh. The single funnel for body changes so no path can update text without saving it.
    private func apply(body: String, at index: Int) {
        notes[index].body = body
        notes[index].modified = Date()
        scheduleSave(notes[index])
        refreshCounts()
    }

    private func scheduleSave(_ note: ScratchpadNote) {
        saveTasks[note.id]?.cancel()
        saveGeneration &+= 1
        let generation = saveGeneration
        let directory = self.directory
        let writer = self.writer

        // Task.detached takes a @Sendable closure, so it does NOT inherit this method's
        // @MainActor isolation — the encode and write run on a background executor and a very
        // large note can never stall the keystroke that triggered it.
        saveTasks[note.id] = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            writer.write(note, to: directory, generation: generation)
        }
    }

    /// Undebounced write for structural changes (a note appearing or being replaced), where the
    /// file's existence — not its contents — is what the UI has already committed to.
    private func writeNow(_ note: ScratchpadNote) {
        saveGeneration &+= 1
        writer.write(note, to: directory, generation: saveGeneration)
    }

    private func refreshCounts() {
        countTask?.cancel()
        let text = activeText

        countTask = Task { [weak self] in
            // Short enough to read as live, long enough that a fast typist counts once per pause
            // rather than once per keystroke.
            try? await Task.sleep(nanoseconds: 120_000_000)
            if Task.isCancelled { return }

            let computed = await Task.detached(priority: .userInitiated) {
                ScratchpadKit.counts(for: text)
            }.value

            if Task.isCancelled { return }
            self?.counts = computed
        }
    }
}

/// Serializes note writes and drops any snapshot older than one already written for the same
/// note. The controller's debounced save tasks are independent and unordered: a large note can
/// still be encoding when a newer, smaller snapshot of it is written, and the older atomic
/// rename would then land last and resurrect text the user deleted. The generation is claimed
/// inside the queue, so `flushPendingSaves()` cannot race an in-flight write either. Encoding
/// stays outside the queue; only the file operations are serialized.
final class ScratchpadNoteWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.havokentity.mactools.scratchpad.note-write", qos: .utility)
    private var lastWrittenGeneration: [UUID: UInt64] = [:]

    func write(_ note: ScratchpadNote, to directory: URL, generation: UInt64) {
        guard let data = ScratchpadKit.encode(note) else { return }
        queue.sync {
            guard generation > (lastWrittenGeneration[note.id] ?? 0) else { return }
            lastWrittenGeneration[note.id] = generation
            ScratchpadKit.writeEncodedNote(data, id: note.id, to: directory)
        }
    }

    /// Deletes a note's file and permanently retires its generation, so a debounced write that
    /// was already in flight when the user deleted the note cannot recreate the file behind them.
    func delete(id: UUID, in directory: URL) {
        queue.sync {
            lastWrittenGeneration[id] = .max
            ScratchpadKit.deleteNote(id: id, in: directory)
        }
    }
}
