import Foundation

/// One saved snippet: a short name the user searches by, and the text that gets pasted.
///
/// The library is an ordered array, and that order is the user's own (drag-free move up/down),
/// so there is deliberately no sort key here — position in the array *is* the ordering.
public struct Snippet: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var body: String
    /// Whether `{date}`/`{time}`/`{datetime}` in `body` are replaced at paste time. Per-snippet
    /// rather than global so a snippet whose text legitimately contains those braces (a code
    /// template, say) can opt out without disabling expansion everywhere.
    public var expandsPlaceholders: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        body: String,
        expandsPlaceholders: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.expandsPlaceholders = expandsPlaceholders
        self.createdAt = createdAt
    }

    /// Decoded field-by-field with defaults instead of the synthesized initializer: a library
    /// written by a future build that adds a field must still load in an older one, and — more
    /// importantly — one unreadable field must not throw away every snippet the user owns. Only
    /// `id` is load-bearing; everything else degrades to an empty/sensible value.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        expandsPlaceholders = try container.decodeIfPresent(Bool.self, forKey: .expandsPlaceholders) ?? true
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    /// The name shown in the list. A snippet saved without a title would otherwise render as a
    /// blank row the user cannot aim at, so fall back to the first line of its text.
    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let firstLine = body.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let trimmedLine = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmedLine.isEmpty ? "Untitled" : trimmedLine
    }

    /// One-line flattened preview of the text for the list row.
    public var previewText: String {
        body
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Pure snippet logic — filtering, placeholder expansion, reordering and the JSON round-trip.
/// Deliberately synchronous, non-isolated and side-effect free apart from the two file helpers,
/// which take an explicit URL so tests never touch the user's Application Support.
public enum SnippetsKit {
    /// The complete placeholder vocabulary. This is a *substitution list*, not a templating
    /// language — no arguments, no conditionals, no custom formats — because anything richer
    /// becomes a syntax the user has to learn and the tool has to document and version.
    /// `descriptions` is what the editor shows, so the UI can never drift from what is supported.
    public static let placeholders: [(token: String, description: String)] = [
        ("{date}", "Today’s date"),
        ("{time}", "The current time"),
        ("{datetime}", "Date and time")
    ]

    // MARK: - Filtering

    /// Snippets matching `query`, in library order. An empty (or whitespace-only) query returns
    /// everything. Matching is case- and diacritic-insensitive across both the title and the
    /// body: users search for a phrase they remember writing at least as often as for the name
    /// they filed it under.
    public static func filter(_ snippets: [Snippet], query: String) -> [Snippet] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return snippets }

        return snippets.filter { snippet in
            matches(trimmed, in: snippet.title) || matches(trimmed, in: snippet.body)
        }
    }

    private static func matches(_ query: String, in text: String) -> Bool {
        text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    // MARK: - Placeholder expansion

    /// Replaces the documented placeholders in `text` with `date`, rendered in the user's locale
    /// and time zone via the shared `.short`/`.medium` styles — a snippet is pasted into a human
    /// conversation, so it should read the way that human's Mac writes dates.
    ///
    /// Unknown braces are left exactly as typed: silently eating `{foo}` would corrupt code and
    /// templates that legitimately contain braces, and there is no error channel here to report
    /// it through.
    public static func expandPlaceholders(in text: String, date: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        guard text.contains("{") else { return text }

        let dateText = string(from: date, dateStyle: .medium, timeStyle: .none, locale: locale, timeZone: timeZone)
        let timeText = string(from: date, dateStyle: .none, timeStyle: .short, locale: locale, timeZone: timeZone)
        let dateTimeText = string(from: date, dateStyle: .medium, timeStyle: .short, locale: locale, timeZone: timeZone)

        // {datetime} first: replacing {date} ahead of it would rewrite the "{date" prefix of
        // "{datetime}" and leave the stray "time}" behind.
        return text
            .replacingOccurrences(of: "{datetime}", with: dateTimeText)
            .replacingOccurrences(of: "{date}", with: dateText)
            .replacingOccurrences(of: "{time}", with: timeText)
    }

    /// The text a snippet actually pastes: its body, with placeholders resolved only when the
    /// snippet opted in.
    public static func pasteText(for snippet: Snippet, date: Date = Date()) -> String {
        guard snippet.expandsPlaceholders else { return snippet.body }
        return expandPlaceholders(in: snippet.body, date: date)
    }

    private static func string(
        from date: Date,
        dateStyle: DateFormatter.Style,
        timeStyle: DateFormatter.Style,
        locale: Locale,
        timeZone: TimeZone
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        return formatter.string(from: date)
    }

    // MARK: - Reordering

    /// `snippets` with the snippet at `index` moved `offset` places (negative = towards the top).
    /// Out-of-range indices and moves that would fall off either end return the array unchanged,
    /// so the caller can wire this straight to a button without bounds-checking first.
    public static func moved(_ snippets: [Snippet], from index: Int, by offset: Int) -> [Snippet] {
        guard snippets.indices.contains(index) else { return snippets }
        let destination = index + offset
        guard snippets.indices.contains(destination), destination != index else { return snippets }

        var reordered = snippets
        let moving = reordered.remove(at: index)
        reordered.insert(moving, at: destination)
        return reordered
    }

    /// `snippets` with the snippet identified by `id` moved `offset` places.
    public static func moved(_ snippets: [Snippet], id: Snippet.ID, by offset: Int) -> [Snippet] {
        guard let index = snippets.firstIndex(where: { $0.id == id }) else { return snippets }
        return moved(snippets, from: index, by: offset)
    }

    // MARK: - Persistence primitives

    /// JSON for the library, or nil when encoding fails. Nil rather than a throw so the writer
    /// can simply skip a bad write instead of surfacing an error the user cannot act on.
    public static func encode(_ snippets: [Snippet]) -> Data? {
        let encoder = JSONEncoder()
        // Stable key order keeps the file diffable and its byte-identical-write check meaningful.
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(snippets)
    }

    /// The library stored at `url`, or `[]` when the file is absent or unreadable. A missing file
    /// is the ordinary first-launch case, not an error worth reporting.
    public static func load(from url: URL) -> [Snippet] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Snippet].self, from: data) else {
            return []
        }
        return decoded
    }
}
