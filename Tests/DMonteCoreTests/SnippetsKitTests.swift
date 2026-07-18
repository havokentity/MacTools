import Foundation
import XCTest
@testable import DMonteCore

/// Covers the three things Snippets cannot get wrong: which snippets a search shows, what a
/// snippet actually pastes once placeholders are resolved, and that the library survives a quit.
/// Persistence is driven through a real `SnippetsStore` pointed at a temp directory, so the save
/// debounce, the flush-at-terminate path and the on-disk format are all exercised for real —
/// never the user's own Application Support.
final class SnippetsKitTests: XCTestCase {

    private func makeSnippet(_ title: String, _ body: String, expands: Bool = true) -> Snippet {
        Snippet(title: title, body: body, expandsPlaceholders: expands)
    }

    // MARK: - Filtering

    func testEmptyQueryReturnsEveryStoredSnippet() {
        let snippets = [makeSnippet("Address", "12 Baker St"), makeSnippet("Signature", "Regards")]

        XCTAssertEqual(SnippetsKit.filter(snippets, query: "").count, 2)
        XCTAssertEqual(SnippetsKit.filter(snippets, query: "   ").count, 2)
    }

    func testFilterMatchesTheTitleCaseInsensitively() {
        let snippets = [makeSnippet("Address", "12 Baker St"), makeSnippet("Signature", "Regards")]

        let matches = SnippetsKit.filter(snippets, query: "ADDR")

        XCTAssertEqual(matches.map(\.title), ["Address"])
    }

    /// Users search for a phrase they remember writing at least as often as for the name they
    /// filed it under, so the body is searched too.
    func testFilterMatchesTheBody() {
        let snippets = [makeSnippet("Address", "12 Baker St"), makeSnippet("Signature", "Kind regards")]

        let matches = SnippetsKit.filter(snippets, query: "baker")

        XCTAssertEqual(matches.map(\.title), ["Address"])
    }

    /// Filtering must not reshuffle: the list order is the user's own manual ordering, and the
    /// Return key pastes whatever ends up first.
    func testFilterPreservesLibraryOrder() {
        let snippets = [makeSnippet("One", "alpha"), makeSnippet("Two", "alpha"), makeSnippet("Three", "alpha")]

        let matches = SnippetsKit.filter(snippets, query: "alpha")

        XCTAssertEqual(matches.map(\.title), ["One", "Two", "Three"])
    }

    func testFilterReturnsNothingWhenNoSnippetMatches() {
        let snippets = [makeSnippet("Address", "12 Baker St")]

        XCTAssertTrue(SnippetsKit.filter(snippets, query: "invoice").isEmpty)
    }

    // MARK: - Placeholder expansion

    private var fixedDate: Date {
        // 2026-07-18 09:05:00 UTC — a value with distinct date and time components, so a
        // placeholder substituted with the wrong one is visible in the assertion.
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 18
        components.hour = 9
        components.minute = 5
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }

    private func expand(_ text: String) -> String {
        SnippetsKit.expandPlaceholders(
            in: text,
            date: fixedDate,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(identifier: "UTC") ?? .gmt
        )
    }

    func testDatePlaceholderIsReplaced() {
        let expanded = expand("Filed on {date}.")

        XCTAssertFalse(expanded.contains("{date}"))
        XCTAssertTrue(expanded.contains("2026"), "expected a rendered date, got \(expanded)")
    }

    func testTimePlaceholderIsReplaced() {
        let expanded = expand("Standup at {time}.")

        XCTAssertFalse(expanded.contains("{time}"))
        XCTAssertTrue(expanded.contains("9:05"), "expected a rendered time, got \(expanded)")
    }

    /// `{datetime}` must be substituted before `{date}`: replacing `{date}` first rewrites the
    /// "{date" prefix and leaves a stray "time}" behind.
    func testDateTimePlaceholderIsNotShreddedByTheDateReplacement() {
        let expanded = expand("{datetime}")

        XCTAssertFalse(expanded.contains("time}"), "left a stray token behind: \(expanded)")
        XCTAssertTrue(expanded.contains("2026"))
        XCTAssertTrue(expanded.contains("9:05"))
    }

    /// Unknown braces are pasted verbatim — silently eating them would corrupt code templates,
    /// and there is no error channel to report a "bad placeholder" through.
    func testUnknownPlaceholdersArePastedUnchanged() {
        XCTAssertEqual(expand("let x = {foo};"), "let x = {foo};")
    }

    func testTextWithoutBracesIsReturnedUnchanged() {
        XCTAssertEqual(expand("Kind regards"), "Kind regards")
    }

    func testPasteTextRespectsThePerSnippetOptOut() {
        let expanding = makeSnippet("Log", "Filed {date}", expands: true)
        let literal = makeSnippet("Template", "Filed {date}", expands: false)

        XCTAssertNotEqual(SnippetsKit.pasteText(for: expanding, date: fixedDate), "Filed {date}")
        XCTAssertEqual(SnippetsKit.pasteText(for: literal, date: fixedDate), "Filed {date}")
    }

    /// The editor's help text is generated from this list, so an undocumented token would be a
    /// token the user can never discover.
    func testEveryDocumentedPlaceholderIsActuallyExpanded() {
        for placeholder in SnippetsKit.placeholders {
            XCTAssertNotEqual(
                expand(placeholder.token), placeholder.token,
                "\(placeholder.token) is documented in the UI but is not substituted"
            )
        }
    }

    /// The row badge promises "this pastes a fresh date/time". Driving it off a bare `contains("{")`
    /// made that promise for any braces at all, so a pure code template was badged as date-bearing
    /// while pasting byte-for-byte what was typed. Badge and expansion must answer the same way.
    func testTheDateBadgeAgreesWithWhatExpansionActuallyDoes() {
        let cases = [
            makeSnippet("Log", "Filed {date}", expands: true),
            makeSnippet("Template", "let x = {foo};", expands: true),
            makeSnippet("Literal", "Filed {date}", expands: false),
            makeSnippet("Plain", "Kind regards", expands: true)
        ]

        for snippet in cases {
            let pasteChangesTheText = SnippetsKit.pasteText(for: snippet, date: fixedDate) != snippet.body
            XCTAssertEqual(
                snippet.pastesADifferentValueEachTime, pasteChangesTheText,
                "\(snippet.title): badge says \(snippet.pastesADifferentValueEachTime) but pasting changed the text: \(pasteChangesTheText)"
            )
        }
    }

    func testContainsPlaceholderIgnoresBracesThatAreNotTokens() {
        XCTAssertFalse(SnippetsKit.containsPlaceholder("let x = {foo};"))
        XCTAssertFalse(SnippetsKit.containsPlaceholder("no braces here"))
        XCTAssertTrue(SnippetsKit.containsPlaceholder("Filed {date}"))
        XCTAssertTrue(SnippetsKit.containsPlaceholder("At {datetime}"))
    }

    // MARK: - Row labels

    func testDisplayTitleFallsBackToTheFirstMeaningfulLineOfTheBody() {
        XCTAssertEqual(makeSnippet("", "12 Baker St\nLondon").displayTitle, "12 Baker St")
        XCTAssertEqual(makeSnippet("   ", "12 Baker St").displayTitle, "12 Baker St")
        // Leading blank lines are skipped rather than reported as an untitled snippet.
        XCTAssertEqual(makeSnippet("", "\n\n12 Baker St").displayTitle, "12 Baker St")
        XCTAssertEqual(makeSnippet("", "   ").displayTitle, "Untitled")
        XCTAssertEqual(makeSnippet("", "").displayTitle, "Untitled")
    }

    func testPreviewFlattensNewlinesIntoOneLine() {
        XCTAssertEqual(makeSnippet("Address", "12 Baker St\nLondon").previewText, "12 Baker St London")
    }

    /// Both row labels are single-line and the body is whatever the user pasted in, so a snippet
    /// holding a whole document must not hand a megabyte of text to a `lineLimit(1)` label.
    func testRowLabelsAreBoundedForAHugeBody() {
        let huge = String(repeating: "a", count: 2_000_000)
        let snippet = makeSnippet("", huge)

        XCTAssertLessThanOrEqual(snippet.previewText.count, 200)
        XCTAssertLessThanOrEqual(snippet.displayTitle.count, 200)
        XCTAssertTrue(snippet.previewText.hasPrefix("aaa"))
    }

    // MARK: - Reordering

    func testMovedShiftsTheSnippetWithinTheLibrary() {
        let snippets = [makeSnippet("A", "a"), makeSnippet("B", "b"), makeSnippet("C", "c")]

        XCTAssertEqual(SnippetsKit.moved(snippets, from: 2, by: -1).map(\.title), ["A", "C", "B"])
        XCTAssertEqual(SnippetsKit.moved(snippets, from: 0, by: 1).map(\.title), ["B", "A", "C"])
    }

    /// Wired straight to a button, so a move off either end must be a no-op rather than a crash.
    func testMovedIgnoresOutOfRangeMoves() {
        let snippets = [makeSnippet("A", "a"), makeSnippet("B", "b")]

        XCTAssertEqual(SnippetsKit.moved(snippets, from: 0, by: -1).map(\.title), ["A", "B"])
        XCTAssertEqual(SnippetsKit.moved(snippets, from: 1, by: 1).map(\.title), ["A", "B"])
        XCTAssertEqual(SnippetsKit.moved(snippets, from: 7, by: 1).map(\.title), ["A", "B"])
    }

    func testMovedByIDFindsTheRightRow() {
        let snippets = [makeSnippet("A", "a"), makeSnippet("B", "b"), makeSnippet("C", "c")]

        let reordered = SnippetsKit.moved(snippets, id: snippets[0].id, by: 2)

        XCTAssertEqual(reordered.map(\.title), ["B", "C", "A"])
    }

    // MARK: - Persistence

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnippetsKitTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testEncodeDecodeRoundTripPreservesEveryField() throws {
        let original = [
            makeSnippet("Address", "12 Baker St\nLondon", expands: false),
            makeSnippet("Log", "Filed {date}", expands: true)
        ]
        let url = try makeTemporaryDirectory()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let fileURL = url.appendingPathComponent("snippets.json")

        let data = try XCTUnwrap(SnippetsKit.encode(original))
        try data.write(to: fileURL)

        XCTAssertEqual(SnippetsKit.load(from: fileURL), original)
    }

    /// First launch: no file yet. That is the ordinary case, not an error, so it must load as an
    /// empty library rather than blowing up.
    func testLoadingAMissingFileYieldsAnEmptyLibrary() throws {
        let url = try makeTemporaryDirectory()

        XCTAssertTrue(SnippetsKit.load(from: url.appendingPathComponent("snippets.json")).isEmpty)
    }

    /// A truncated or hand-mangled file must not take the tool down with it.
    func testLoadingCorruptJSONYieldsAnEmptyLibrary() throws {
        let url = try makeTemporaryDirectory()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let fileURL = url.appendingPathComponent("snippets.json")
        try Data("{ not json".utf8).write(to: fileURL)

        XCTAssertTrue(SnippetsKit.load(from: fileURL).isEmpty)
    }

    /// A library written by a future build that adds a field must still load here, and a snippet
    /// missing the expansion flag must default to expanding rather than vanishing.
    func testDecodingToleratesMissingAndUnknownFields() throws {
        let json = """
        [{"id":"\(UUID().uuidString)","title":"Address","body":"12 Baker St","futureField":42}]
        """
        let decoded = try JSONDecoder().decode([Snippet].self, from: Data(json.utf8))

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.title, "Address")
        XCTAssertTrue(try XCTUnwrap(decoded.first).expandsPlaceholders)
    }

    /// The save is debounced and its task dies with the process, so a quit straight after an edit
    /// only keeps the snippet because `flushPendingSave()` runs at termination. This is the whole
    /// "survives quit" contract, driven through the real store.
    @MainActor
    func testLibrarySurvivesAQuitViaFlushPendingSave() throws {
        let directory = try makeTemporaryDirectory()

        let store = SnippetsStore(directory: directory)
        store.add(title: "Address", body: "12 Baker St", expandsPlaceholders: false)
        store.add(title: "Log", body: "Filed {date}", expandsPlaceholders: true)
        store.flushPendingSave()

        let reopened = SnippetsStore(directory: directory)

        XCTAssertEqual(reopened.snippets.map(\.title), ["Address", "Log"])
        XCTAssertEqual(reopened.snippets.first?.expandsPlaceholders, false)
    }

    @MainActor
    func testEditsAndDeletionsSurviveAReopen() throws {
        let directory = try makeTemporaryDirectory()

        let store = SnippetsStore(directory: directory)
        let keep = store.add(title: "Keep", body: "keep me", expandsPlaceholders: true)
        let drop = store.add(title: "Drop", body: "drop me", expandsPlaceholders: true)
        store.update(id: keep.id, title: "Kept", body: "edited", expandsPlaceholders: true)
        store.delete(id: drop.id)
        store.flushPendingSave()

        let reopened = SnippetsStore(directory: directory)

        XCTAssertEqual(reopened.snippets.map(\.title), ["Kept"])
        XCTAssertEqual(reopened.snippets.first?.body, "edited")
    }

    /// Reordering is persisted too — a library that re-sorts itself on the next launch would make
    /// the manual ordering pointless.
    @MainActor
    func testReorderSurvivesAReopen() throws {
        let directory = try makeTemporaryDirectory()

        let store = SnippetsStore(directory: directory)
        store.add(title: "A", body: "a", expandsPlaceholders: true)
        let second = store.add(title: "B", body: "b", expandsPlaceholders: true)
        store.move(id: second.id, by: -1)
        store.flushPendingSave()

        let reopened = SnippetsStore(directory: directory)

        XCTAssertEqual(reopened.snippets.map(\.title), ["B", "A"])
    }

    /// The store is the only writer, and a stale snapshot landing after a newer one would
    /// resurrect deleted snippets — so a flush must never regress what is already on disk.
    @MainActor
    func testFlushAfterNoFurtherEditsDoesNotRegressTheFile() throws {
        let directory = try makeTemporaryDirectory()

        let store = SnippetsStore(directory: directory)
        let snippet = store.add(title: "A", body: "a", expandsPlaceholders: true)
        store.flushPendingSave()
        store.delete(id: snippet.id)
        store.flushPendingSave()
        store.flushPendingSave()

        XCTAssertTrue(SnippetsStore(directory: directory).snippets.isEmpty)
    }
}
