import Foundation

/// One note in the Scratchpad: a title, its plain-text body, and the two timestamps the UI
/// orders and labels by. Persisted as a single self-contained file so no note depends on any
/// other note's file being readable.
public struct ScratchpadNote: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID

    /// Display name in the switcher. Sanitized and de-duplicated through `ScratchpadKit` before
    /// it is ever stored, so the UI can render it verbatim.
    public var title: String

    /// The note's full plain text. Deliberately not truncated anywhere — this is the only copy.
    public var body: String

    /// Creation instant. Notes are ordered by this rather than by `modified` so the switcher
    /// never reshuffles under the user's finger while they are typing into one of the chips.
    public let created: Date

    public var modified: Date

    public init(
        id: UUID = UUID(),
        title: String,
        body: String = "",
        created: Date = Date(),
        modified: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.created = created
        self.modified = modified
    }
}

/// Live size readout for the note being edited.
public struct ScratchpadCounts: Sendable, Equatable {
    public let words: Int

    /// Grapheme clusters, NOT UTF-16 units: a flag or a skin-toned family emoji is one character
    /// to the person who typed it, and reporting 11 for "👨‍👩‍👧‍👦" would be nonsense.
    public let characters: Int

    public let lines: Int

    public static let empty = ScratchpadCounts(words: 0, characters: 0, lines: 0)

    public init(words: Int, characters: Int, lines: Int) {
        self.words = words
        self.characters = characters
        self.lines = lines
    }
}

/// Pure, UI-free storage and text-measurement layer behind DMonte Scratchpad. Every function
/// here is synchronous and side-effect free apart from the explicitly file-touching ones, so the
/// controller can hop the expensive parts off the main actor with `Task.detached` and the test
/// target can exercise all of it against a temporary directory.
///
/// Storage shape: one JSON file per note, named after the note's UUID. A single file per note is
/// the whole point — losing notes is this tool's only unacceptable failure, and a single shared
/// index file would mean one bad write takes every note with it.
public enum ScratchpadKit {
    /// Longest title the switcher can show without the chips collapsing into ellipses. Titles are
    /// clipped here rather than in the view so what is stored is what is displayed.
    public static let maximumTitleLength = 40

    /// Name used when a note has no usable title of its own.
    public static let untitledTitle = "Untitled"

    // MARK: - Counting

    /// Words, characters and lines for `text`.
    ///
    /// Words are runs separated by Unicode whitespace, which is the definition a Latin-script
    /// writer expects. It under-counts scripts that do not space their words (Chinese, Japanese,
    /// Thai); a word count is an approximation everywhere, and the character count beside it is
    /// exact, so this stays simple rather than pulling in a locale-aware tokenizer.
    public static func counts(for text: String) -> ScratchpadCounts {
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        // An empty document is zero lines; anything else has one more line than it has newlines.
        // `isNewline` on Character treats CRLF as the single grapheme cluster it is, so text
        // pasted from Windows does not double-count.
        let lines = text.isEmpty
            ? 0
            : text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count

        return ScratchpadCounts(words: words, characters: text.count, lines: lines)
    }

    // MARK: - Naming

    /// Collapses a raw, user-typed title into something a one-line chip can render: whitespace
    /// runs (including pasted newlines) become single spaces, and the result is clipped to
    /// `maximumTitleLength` *characters* so clipping never splits an emoji in half.
    public static func sanitizedTitle(_ raw: String) -> String {
        let collapsed = raw
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return untitledTitle }
        return String(collapsed.prefix(maximumTitleLength))
    }

    /// Sanitizes `raw`, then appends " 2", " 3", … until it no longer collides with `existing`.
    /// Comparison is case-insensitive because two chips reading "Notes" and "notes" are the same
    /// note as far as anyone scanning the switcher is concerned.
    public static func uniqueTitle(_ raw: String, existing: [String]) -> String {
        let base = sanitizedTitle(raw)
        let taken = Set(existing.map { $0.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }

        var suffix = 2
        while true {
            let candidate = "\(base) \(suffix)"
            if !taken.contains(candidate.lowercased()) { return candidate }
            suffix += 1
        }
    }

    // MARK: - Storage

    /// File name a note is stored under. Derived from the UUID rather than the title so renaming
    /// a note never has to move a file — a rename that failed halfway would otherwise be able to
    /// leave two files claiming the same note.
    public static func fileName(for id: UUID) -> String {
        "\(id.uuidString).json"
    }

    /// Creates `directory` if needed, restricted to the current user. Notes routinely hold
    /// half-written messages and pasted credentials, so 0700 is the right default. Returns false
    /// only when the directory could not be created at all.
    @discardableResult
    public static func prepareDirectory(_ directory: URL) -> Bool {
        let ownerOnly: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: ownerOnly
        )
        // Re-asserted separately: createDirectory only applies its attributes to directories it
        // actually creates, so a directory from an earlier build would keep its old mode.
        try? FileManager.default.setAttributes(ownerOnly, ofItemAtPath: directory.path)
        return FileManager.default.fileExists(atPath: directory.path)
    }

    /// Loads every note in `directory`, ordered oldest-first.
    ///
    /// A file that fails to decode is never discarded. If its bytes are still readable text the
    /// note is salvaged with its raw contents as the body and a "Recovered" title, so a partial
    /// write costs the user some JSON punctuation in their note rather than the note itself; if
    /// even that fails the file is skipped and left untouched on disk for manual rescue. Either
    /// way one damaged file cannot stop the remaining notes from loading.
    public static func loadNotes(from directory: URL) -> [ScratchpadNote] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var notes: [ScratchpadNote] = []
        for url in contents where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url) else { continue }

            if let note = try? decoder.decode(ScratchpadNote.self, from: data) {
                notes.append(note)
                continue
            }

            if let salvaged = salvage(data, at: url) {
                notes.append(salvaged)
            }
        }

        return notes.sorted { $0.created < $1.created }
    }

    /// Best-effort rescue of a note file whose JSON no longer parses. The id is taken from the
    /// file name so a subsequent save overwrites the damaged file rather than leaving a duplicate
    /// behind; unreadable bytes yield `nil` and the caller leaves the file alone.
    private static func salvage(_ data: Data, at url: URL) -> ScratchpadNote? {
        // Salvage only works when the file name yields the note's real identity, because that is
        // what makes the next save repair *this* file. Inventing an id for a foreign .json instead
        // would recover it under a fresh UUID, write that to a new file, and leave the original in
        // place — so it would be recovered again on every launch, multiplying notes the user has
        // no way to get rid of. Anything we cannot identify is left untouched on disk.
        guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { return nil }
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }

        // The file's modification date is the closest thing to a real timestamp still available.
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()

        return ScratchpadNote(
            id: id,
            title: "Recovered Note",
            body: text,
            created: modified,
            modified: modified
        )
    }

    /// Encodes a note for storage. Separated from the write so the (potentially large) encode can
    /// happen outside the writer's serial queue.
    public static func encode(_ note: ScratchpadNote) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(note)
    }

    /// Writes already-encoded note bytes atomically, so an interrupted save leaves the previous
    /// contents intact instead of a half-written file. Returns whether the bytes reached disk.
    @discardableResult
    public static func writeEncodedNote(_ data: Data, id: UUID, to directory: URL) -> Bool {
        let url = directory.appendingPathComponent(fileName(for: id))
        guard (try? data.write(to: url, options: .atomic)) != nil else { return false }
        // Notes hold whatever the user parked in them; keep the file owner-only (0600).
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return true
    }

    /// Encode-and-write convenience used by tests and by the non-debounced paths.
    @discardableResult
    public static func save(_ note: ScratchpadNote, to directory: URL) -> Bool {
        guard let data = encode(note) else { return false }
        return writeEncodedNote(data, id: note.id, to: directory)
    }

    /// Removes a note's file. Missing files are not an error — the caller's intent was for the
    /// note to be gone.
    public static func deleteNote(id: UUID, in directory: URL) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName(for: id)))
    }
}
