import Foundation
import XCTest
@testable import DMonteCore

/// Covers `ScratchpadKit`: the per-note file storage, the naming/dedup rules the switcher relies
/// on, and the counting logic. Every disk test runs against its own temporary directory created
/// in `setUpWithError` and torn down afterwards — the real Application Support notes are the one
/// thing this tool must never risk.
final class ScratchpadKitTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScratchpadKitTests-\(UUID().uuidString)", isDirectory: true)
        XCTAssertTrue(ScratchpadKit.prepareDirectory(directory))
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        try super.tearDownWithError()
    }

    // MARK: - Counting

    func testCountsForPlainProse() {
        let counts = ScratchpadKit.counts(for: "the quick brown fox")

        XCTAssertEqual(counts.words, 4)
        XCTAssertEqual(counts.characters, 19)
        XCTAssertEqual(counts.lines, 1)
    }

    func testEmptyTextCountsAsNothingAtAll() {
        let counts = ScratchpadKit.counts(for: "")

        XCTAssertEqual(counts.words, 0)
        XCTAssertEqual(counts.characters, 0)
        // Zero, not one: an untouched note claiming "1 line" reads as though it already holds
        // something.
        XCTAssertEqual(counts.lines, 0)
    }

    /// The whole point of counting `Character`s. A ZWJ family emoji is 11 UTF-16 units and 1
    /// grapheme cluster; reporting 11 characters for one typed glyph would be nonsense.
    func testEmojiCountsAsOneCharacterNotItsUTF16Length() {
        let family = "👨‍👩‍👧‍👦"
        XCTAssertEqual(family.utf16.count, 11, "Precondition: this emoji really is a multi-unit cluster")

        XCTAssertEqual(ScratchpadKit.counts(for: family).characters, 1)
    }

    func testCombiningMarksAndFlagsCountAsSingleCharacters() {
        // "é" written as e + combining acute, and a regional-indicator flag pair.
        let text = "e\u{0301}🇮🇳"

        XCTAssertEqual(ScratchpadKit.counts(for: text).characters, 2)
    }

    func testEmojiSeparatedByWhitespaceStillCountAsWords() {
        let counts = ScratchpadKit.counts(for: "ship it 🚀 🎉")

        XCTAssertEqual(counts.words, 4)
    }

    /// Text pasted from Windows arrives with CRLF endings. Swift treats "\r\n" as one grapheme
    /// cluster, so it must not be counted as two line breaks.
    func testCarriageReturnLineFeedCountsAsOneLineBreak() {
        let counts = ScratchpadKit.counts(for: "first\r\nsecond")

        XCTAssertEqual(counts.lines, 2)
    }

    func testBlankLinesAreCounted() {
        let counts = ScratchpadKit.counts(for: "first\n\nthird")

        XCTAssertEqual(counts.lines, 3)
        XCTAssertEqual(counts.words, 2)
    }

    func testRunsOfWhitespaceDoNotInflateTheWordCount() {
        let counts = ScratchpadKit.counts(for: "  spaced   out \n\t words  ")

        XCTAssertEqual(counts.words, 3)
    }

    // MARK: - Naming

    func testSanitizedTitleCollapsesWhitespaceAndPastedNewlines() {
        XCTAssertEqual(ScratchpadKit.sanitizedTitle("  Meeting \n  notes  "), "Meeting notes")
    }

    func testBlankTitleFallsBackToUntitled() {
        XCTAssertEqual(ScratchpadKit.sanitizedTitle("   \n\t "), ScratchpadKit.untitledTitle)
    }

    /// Clipping is by `Character`, so a long title ending in an emoji can never be cut in half
    /// into a replacement glyph.
    func testLongTitleIsClippedByCharactersNotUnits() {
        let raw = String(repeating: "🙂", count: 60)

        let title = ScratchpadKit.sanitizedTitle(raw)

        XCTAssertEqual(title.count, ScratchpadKit.maximumTitleLength)
        XCTAssertEqual(title, String(repeating: "🙂", count: ScratchpadKit.maximumTitleLength))
    }

    func testUniqueTitleLeavesANonCollidingNameAlone() {
        XCTAssertEqual(ScratchpadKit.uniqueTitle("Ideas", existing: ["Notes", "Todo"]), "Ideas")
    }

    func testUniqueTitleSuffixesCollisionsUntilFree() {
        let existing = ["Untitled", "Untitled 2"]

        XCTAssertEqual(ScratchpadKit.uniqueTitle("Untitled", existing: existing), "Untitled 3")
    }

    /// Two chips reading "Notes" and "notes" are indistinguishable at a glance, so dedup ignores
    /// case rather than letting the switcher show what looks like the same note twice.
    func testUniqueTitleTreatsCaseVariantsAsCollisions() {
        XCTAssertEqual(ScratchpadKit.uniqueTitle("notes", existing: ["Notes"]), "notes 2")
    }

    // MARK: - Persistence round-trips

    func testSavedNoteRoundTripsThroughDisk() {
        let note = ScratchpadNote(title: "Ideas", body: "line one\nline two")

        XCTAssertTrue(ScratchpadKit.save(note, to: directory))
        let loaded = ScratchpadKit.loadNotes(from: directory)

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, note.id)
        XCTAssertEqual(loaded.first?.title, "Ideas")
        XCTAssertEqual(loaded.first?.body, "line one\nline two")
    }

    /// Notes routinely hold emoji and non-Latin scripts; a lossy encode would silently mangle
    /// them, and the user would only find out long after the original was gone.
    func testUnicodeBodySurvivesTheRoundTripByteForByte() {
        let body = "नमस्ते 👨‍👩‍👧‍👦 — “curly” ✅\ntab\there"
        let note = ScratchpadNote(title: "Unicode 🌍", body: body)

        ScratchpadKit.save(note, to: directory)
        let loaded = ScratchpadKit.loadNotes(from: directory).first

        XCTAssertEqual(loaded?.body, body)
        XCTAssertEqual(loaded?.title, "Unicode 🌍")
        XCTAssertEqual(ScratchpadKit.counts(for: loaded?.body ?? "").characters,
                       ScratchpadKit.counts(for: body).characters)
    }

    func testResavingANoteReplacesItRatherThanAddingAnother() {
        var note = ScratchpadNote(title: "Ideas", body: "first")
        ScratchpadKit.save(note, to: directory)

        note.body = "second"
        ScratchpadKit.save(note, to: directory)

        let loaded = ScratchpadKit.loadNotes(from: directory)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.body, "second")
    }

    /// The switcher must not reshuffle while the user types, so ordering is by creation date.
    func testNotesLoadOldestFirstRegardlessOfWriteOrder() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let oldest = ScratchpadNote(title: "Oldest", created: base, modified: base)
        let middle = ScratchpadNote(title: "Middle", created: base.addingTimeInterval(60), modified: base)
        let newest = ScratchpadNote(title: "Newest", created: base.addingTimeInterval(120), modified: base)

        // Deliberately written newest-first.
        [newest, middle, oldest].forEach { ScratchpadKit.save($0, to: directory) }

        XCTAssertEqual(ScratchpadKit.loadNotes(from: directory).map(\.title), ["Oldest", "Middle", "Newest"])
    }

    func testDeletingANoteLeavesTheOthersUntouched() {
        let kept = ScratchpadNote(title: "Kept", body: "still here")
        let doomed = ScratchpadNote(title: "Doomed", body: "not for long")
        ScratchpadKit.save(kept, to: directory)
        ScratchpadKit.save(doomed, to: directory)

        ScratchpadKit.deleteNote(id: doomed.id, in: directory)

        let loaded = ScratchpadKit.loadNotes(from: directory)
        XCTAssertEqual(loaded.map(\.title), ["Kept"])
    }

    func testLoadingAnEmptyOrMissingDirectoryYieldsNoNotes() {
        XCTAssertTrue(ScratchpadKit.loadNotes(from: directory).isEmpty)
        XCTAssertTrue(ScratchpadKit.loadNotes(from: directory.appendingPathComponent("nope")).isEmpty)
    }

    /// Notes are stored per file precisely so this holds. A shared index would have made the
    /// damaged note's neighbours unreadable too.
    func testStrayNonNoteFilesAreIgnored() {
        let note = ScratchpadNote(title: "Real", body: "hello")
        ScratchpadKit.save(note, to: directory)
        try? Data("junk".utf8).write(to: directory.appendingPathComponent("README.txt"))

        XCTAssertEqual(ScratchpadKit.loadNotes(from: directory).map(\.title), ["Real"])
    }

    // MARK: - Corrupt-note recovery

    func testACorruptNoteDoesNotPreventTheOthersFromLoading() {
        let healthy = ScratchpadNote(title: "Healthy", body: "intact")
        ScratchpadKit.save(healthy, to: directory)

        let corruptID = UUID()
        let corruptURL = directory.appendingPathComponent(ScratchpadKit.fileName(for: corruptID))
        try? Data("{\"id\":\"\(corruptID.uuidString)\",\"body\":\"half a fi".utf8).write(to: corruptURL)

        let loaded = ScratchpadKit.loadNotes(from: directory)

        XCTAssertEqual(loaded.count, 2)
        XCTAssertTrue(loaded.contains { $0.id == healthy.id && $0.body == "intact" })
    }

    /// A truncated file's bytes are still the user's words, so they are salvaged into a note
    /// rather than dropped. Reusing the file's UUID means the next save repairs the file in
    /// place instead of leaving a second copy behind.
    func testATruncatedNoteIsSalvagedUnderItsOwnIdentity() {
        let corruptID = UUID()
        let rawText = "{\"id\":\"\(corruptID.uuidString)\",\"body\":\"remember the milk"
        let corruptURL = directory.appendingPathComponent(ScratchpadKit.fileName(for: corruptID))
        try? Data(rawText.utf8).write(to: corruptURL)

        let loaded = ScratchpadKit.loadNotes(from: directory)

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, corruptID)
        XCTAssertEqual(loaded.first?.title, "Recovered Note")
        XCTAssertTrue(loaded.first?.body.contains("remember the milk") == true)
    }

    /// Bytes that are not text at all cannot be shown to anyone, so the file is skipped — and
    /// deliberately left on disk, because deleting a file we failed to understand is exactly the
    /// data loss this tool exists to avoid.
    func testUndecodableBytesAreSkippedAndTheFileIsLeftOnDisk() {
        let healthy = ScratchpadNote(title: "Healthy", body: "intact")
        ScratchpadKit.save(healthy, to: directory)

        let binaryURL = directory.appendingPathComponent(ScratchpadKit.fileName(for: UUID()))
        try? Data([0xFF, 0xFE, 0xFF, 0xFE]).write(to: binaryURL)

        let loaded = ScratchpadKit.loadNotes(from: directory)

        XCTAssertEqual(loaded.map(\.title), ["Healthy"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: binaryURL.path))
    }

    /// A `.json` file the tool did not write has no identity to recover it under. Salvaging it
    /// under an invented UUID would write a *second* file and leave the original in place, so the
    /// same stray file would be recovered again on every launch and the note count would climb
    /// forever with nothing the user could delete. It must be left alone instead.
    func testAForeignJSONFileIsLeftAloneRatherThanDuplicatingEveryLoad() throws {
        let healthy = ScratchpadNote(title: "Healthy", body: "intact")
        ScratchpadKit.save(healthy, to: directory)
        let stray = directory.appendingPathComponent("notes.json")
        try Data("{\"not\":\"one of ours\"".utf8).write(to: stray)

        let first = ScratchpadKit.loadNotes(from: directory)
        let second = ScratchpadKit.loadNotes(from: directory)

        XCTAssertEqual(first.map(\.title), ["Healthy"])
        XCTAssertEqual(second.map(\.title), ["Healthy"], "loading twice must not accumulate notes")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stray.path), "an unrecognised file is never deleted")
    }

    /// A save that cannot reach disk has to say so — the controller turns this into a visible
    /// warning, and silence would let someone type into a note that is not being persisted.
    func testWritingIntoAnUnwritableLocationReportsFailure() throws {
        // A regular file where a directory is expected: writes below it fail with ENOTDIR, with
        // no dependence on the test runner's uid (a root runner would ignore chmod).
        let blocker = directory.appendingPathComponent("blocker")
        try Data("not a directory".utf8).write(to: blocker)

        let unwritable = blocker.appendingPathComponent("notes", isDirectory: true)

        XCTAssertFalse(ScratchpadKit.prepareDirectory(unwritable))
        XCTAssertFalse(ScratchpadKit.save(ScratchpadNote(title: "Doomed", body: "text"), to: unwritable))
    }

    /// Rewriting a salvaged note must land on the same file, leaving exactly one note behind.
    func testSavingASalvagedNoteRepairsItsFileInPlace() {
        let corruptID = UUID()
        let corruptURL = directory.appendingPathComponent(ScratchpadKit.fileName(for: corruptID))
        try? Data("{\"body\":\"partial".utf8).write(to: corruptURL)

        guard var salvaged = ScratchpadKit.loadNotes(from: directory).first else {
            return XCTFail("Expected the damaged note to be salvaged")
        }
        salvaged.body = "repaired"
        ScratchpadKit.save(salvaged, to: directory)

        let reloaded = ScratchpadKit.loadNotes(from: directory)
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.body, "repaired")
    }
}
