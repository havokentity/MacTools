import Foundation
import XCTest
@testable import DMonteCore

/// Covers the promises the File Shelf makes about the files it is holding: that a bookmark still
/// finds a file after it has been renamed or moved, that a file which is genuinely gone shows up
/// as unavailable instead of vanishing from the list, that dropping the same file twice does not
/// produce two rows, and that the shelf survives a relaunch.
///
/// Bookmarks are exercised for real against files in a temporary directory rather than through a
/// stub, because "does a bookmark actually follow a rename?" is the entire reason this tool stores
/// bookmarks instead of paths — a fake resolver would assert nothing about that.
final class FileShelfKitTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileShelfKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        try super.tearDownWithError()
    }

    @discardableResult
    private func makeFile(named name: String, contents: String = "shelf") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// A shelf item that resolves to nothing, built without touching the file system. Used for the
    /// pure ordering/de-duplication tests, where the file system would only add noise.
    private func makeUnresolvableItem(named name: String, shelved: Date = Date()) -> ShelfItem {
        ShelfItem(
            file: ShelvedFile(
                bookmark: Data(),
                displayName: name,
                lastKnownPath: "/nowhere/\(name)",
                shelved: shelved
            ),
            url: nil,
            availability: .unresolvable,
            identity: nil
        )
    }

    private func makeItem(identity: String, name: String) -> ShelfItem {
        ShelfItem(
            file: ShelvedFile(
                bookmark: Data(),
                displayName: name,
                lastKnownPath: "/somewhere/\(name)",
                shelved: Date()
            ),
            url: URL(fileURLWithPath: "/somewhere/\(name)"),
            availability: .available,
            identity: identity
        )
    }

    // MARK: - Badge

    /// An empty shelf must not hold menu-bar width open for a permanent "0".
    func testBadgeIsAbsentWhenTheShelfIsEmpty() {
        XCTAssertNil(FileShelfKit.badgeTitle(for: 0))
        XCTAssertNil(FileShelfKit.badgeTitle(for: -1))
    }

    func testBadgeCountsUpToTheCapAndThenSaysSo() {
        XCTAssertEqual(FileShelfKit.badgeTitle(for: 1), "1")
        XCTAssertEqual(FileShelfKit.badgeTitle(for: 42), "42")
        XCTAssertEqual(FileShelfKit.badgeTitle(for: FileShelfKit.maximumBadgeCount), "99")
        XCTAssertEqual(FileShelfKit.badgeTitle(for: FileShelfKit.maximumBadgeCount + 1), "99+")
    }

    // MARK: - Identity

    /// De-duplication compares files, not spellings. `/tmp` is a symlink to `/private/tmp` on
    /// every Mac, so the same file reached both ways has to come out as one identity or a drop
    /// from Finder and a drop from a terminal-launched app would produce two rows.
    func testIdentityIsTheSameThroughASymlinkedPath() throws {
        let real = try makeFile(named: "target.txt")
        let linkDirectory = directory.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkDirectory, withDestinationURL: directory)
        let viaLink = linkDirectory.appendingPathComponent("target.txt")

        XCTAssertEqual(FileShelfKit.identity(for: real), FileShelfKit.identity(for: viaLink))
    }

    /// Renaming is exactly the kind of tidying people do while a file is parked on the shelf, so
    /// the identity has to travel with the file rather than with its name.
    func testIdentitySurvivesARename() throws {
        let original = try makeFile(named: "before.txt")
        let before = FileShelfKit.identity(for: original)

        let renamed = directory.appendingPathComponent("after.txt")
        try FileManager.default.moveItem(at: original, to: renamed)

        XCTAssertEqual(FileShelfKit.identity(for: renamed), before)
    }

    func testDifferentFilesHaveDifferentIdentities() throws {
        let first = try makeFile(named: "one.txt")
        let second = try makeFile(named: "two.txt")

        XCTAssertNotEqual(FileShelfKit.identity(for: first), FileShelfKit.identity(for: second))
    }

    // MARK: - Bookmarks

    func testBookmarkRoundTripsToTheSameFile() throws {
        let url = try makeFile(named: "round-trip.txt")

        let bookmark = try XCTUnwrap(FileShelfKit.bookmarkData(for: url))
        let resolved = try XCTUnwrap(FileShelfKit.resolve(bookmark))

        XCTAssertEqual(
            resolved.url.resolvingSymlinksInPath().path,
            url.resolvingSymlinksInPath().path
        )
    }

    /// The headline promise of storing bookmarks instead of paths: rename the file in Finder and
    /// the shelf entry still points at it, under its new name.
    func testAShelvedEntryFollowsTheFileThroughARename() throws {
        let original = try makeFile(named: "draft.txt")
        let item = FileShelfKit.makeItem(for: original)

        let renamed = directory.appendingPathComponent("final.txt")
        try FileManager.default.moveItem(at: original, to: renamed)

        let resolved = FileShelfKit.resolveItem(item.file)

        XCTAssertEqual(resolved.availability, .available)
        XCTAssertEqual(resolved.displayName, "final.txt")
        XCTAssertEqual(
            resolved.url?.resolvingSymlinksInPath().path,
            renamed.resolvingSymlinksInPath().path
        )
    }

    /// Moving a file to another folder is the other half of the same promise.
    func testAShelvedEntryFollowsTheFileIntoAnotherFolder() throws {
        let original = try makeFile(named: "moving.txt")
        let item = FileShelfKit.makeItem(for: original)

        let subdirectory = directory.appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        let moved = subdirectory.appendingPathComponent("moving.txt")
        try FileManager.default.moveItem(at: original, to: moved)

        let resolved = FileShelfKit.resolveItem(item.file)

        XCTAssertEqual(resolved.availability, .available)
        XCTAssertEqual(
            resolved.url?.resolvingSymlinksInPath().path,
            moved.resolvingSymlinksInPath().path
        )
    }

    /// Bookmark data that is simply not bookmark data. This is the deterministic form of "the
    /// bookmark no longer resolves": the entry must survive as an unavailable row, keeping the
    /// name and path it was shelved under so the user can still see what they lost.
    func testAnUnresolvableBookmarkBecomesAnUnavailableEntryRatherThanDisappearing() {
        let file = ShelvedFile(
            bookmark: Data([0x00, 0x01, 0x02, 0x03]),
            displayName: "gone.txt",
            lastKnownPath: "/Users/somebody/Documents/gone.txt"
        )

        let resolved = FileShelfKit.resolveItem(file)

        XCTAssertEqual(resolved.availability, .unresolvable)
        XCTAssertFalse(resolved.isAvailable)
        XCTAssertNil(resolved.url)
        XCTAssertNil(resolved.identity)
        // The row still has something to say for itself.
        XCTAssertEqual(resolved.displayName, "gone.txt")
        XCTAssertEqual(resolved.displayPath, "/Users/somebody/Documents/gone.txt")
    }

    /// Empty bookmark data is what a file that could not be bookmarked at all leaves behind, and
    /// it must not resolve to anything.
    func testEmptyBookmarkDataDoesNotResolve() {
        XCTAssertNil(FileShelfKit.resolve(Data()))
    }

    /// A file that is deleted while it sits on the shelf must never be silently pruned: the row
    /// is what tells the user the thing they parked is gone.
    func testADeletedFileStaysOnTheShelfAsAnUnavailableEntry() throws {
        let url = try makeFile(named: "doomed.txt")
        let item = FileShelfKit.makeItem(for: url)
        XCTAssertTrue(item.isAvailable)

        try FileManager.default.removeItem(at: url)

        let resolved = FileShelfKit.resolveItem(item.file)

        XCTAssertFalse(resolved.isAvailable, "A deleted file must read as unavailable, not as available")
        XCTAssertNotEqual(resolved.availability, .available)
        XCTAssertNil(resolved.identity, "An entry with no file behind it must not be able to collide with anything")
        XCTAssertEqual(resolved.displayName, "doomed.txt")
    }

    /// The two unavailable states mean different things to the user — `.missing` is "come back
    /// when the disk is plugged in", `.unresolvable` is "shelve it again, this one is not coming
    /// back" — and they have to stay told apart.
    ///
    /// It is tempting to read "the bookmark did not resolve" as `.unresolvable`, but resolution
    /// fails identically for a real bookmark whose file is gone or whose volume is unmounted
    /// (`.withoutMounting` makes sure of the second). Calling that junk would tell someone who
    /// merely unplugged an external disk that the row is dead, and they would remove an entry that
    /// was about to start working again by itself.
    func testABookmarkThatCannotBeFollowedIsMissingRatherThanJunk() throws {
        let url = try makeFile(named: "on-a-disk-that-left.txt")
        let item = FileShelfKit.makeItem(for: url)
        try FileManager.default.removeItem(at: url)

        let resolved = FileShelfKit.resolveItem(item.file)

        XCTAssertEqual(
            resolved.availability, .missing,
            "A bookmark that still names a file is recoverable, so it must not be reported as unrecoverable"
        )
    }

    /// …and the converse, so the distinction is not simply always `.missing`: bytes that are not
    /// bookmark data at all name nothing, and only re-shelving fixes that.
    func testDataThatIsNotABookmarkAtAllIsUnresolvableRatherThanMissing() {
        let junk = ShelvedFile(
            bookmark: Data([0x01, 0x02, 0x03, 0x04, 0x05]),
            displayName: "corrupt.txt",
            lastKnownPath: "/Users/somebody/Documents/corrupt.txt"
        )
        let never = ShelvedFile(
            bookmark: Data(),
            displayName: "never-bookmarked.txt",
            lastKnownPath: "/Users/somebody/Documents/never-bookmarked.txt"
        )

        XCTAssertEqual(FileShelfKit.resolveItem(junk).availability, .unresolvable)
        XCTAssertEqual(FileShelfKit.resolveItem(never).availability, .unresolvable)
    }

    // MARK: - Adding and ordering

    /// Newest first: the shelf is read from the top, and the thing just dropped is the thing most
    /// likely to be dragged straight back out.
    func testAddingPutsTheNewestEntryFirst() {
        var items: [ShelfItem] = []
        items = FileShelfKit.adding(makeItem(identity: "1:1", name: "first.txt"), to: items)
        items = FileShelfKit.adding(makeItem(identity: "1:2", name: "second.txt"), to: items)
        items = FileShelfKit.adding(makeItem(identity: "1:3", name: "third.txt"), to: items)

        XCTAssertEqual(items.map(\.displayName), ["third.txt", "second.txt", "first.txt"])
    }

    /// A multi-file drag arrives as an ordered list, and the order the user assembled is the order
    /// they expect to see — first file selected at the top, not reversed.
    func testAddingABatchPreservesTheOrderTheFilesWereDroppedIn() {
        let batch = [
            makeItem(identity: "1:1", name: "a.txt"),
            makeItem(identity: "1:2", name: "b.txt"),
            makeItem(identity: "1:3", name: "c.txt")
        ]

        let items = FileShelfKit.adding(batch, to: [])

        XCTAssertEqual(items.map(\.displayName), ["a.txt", "b.txt", "c.txt"])
    }

    /// The same file dropped twice is one row, not two.
    func testAddingTheSameFileTwiceKeepsASingleRow() throws {
        let url = try makeFile(named: "twice.txt")

        var items = FileShelfKit.adding(FileShelfKit.makeItem(for: url), to: [])
        items = FileShelfKit.adding(FileShelfKit.makeItem(for: url), to: items)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].displayName, "twice.txt")
    }

    /// …and it is still one row when the second drop names the file differently, because the file
    /// was renamed in between. The shelf follows files, so it has to de-duplicate on files too.
    func testAddingAFileAgainUnderANewNameStillKeepsASingleRow() throws {
        let original = try makeFile(named: "before.txt")
        var items = FileShelfKit.adding(FileShelfKit.makeItem(for: original), to: [])

        let renamed = directory.appendingPathComponent("after.txt")
        try FileManager.default.moveItem(at: original, to: renamed)

        // Re-resolve first, exactly as the store does on every popover open, so the shelved row
        // knows the file's new location before the second drop is compared against it.
        items = items.map { FileShelfKit.resolveItem($0.file) }
        items = FileShelfKit.adding(FileShelfKit.makeItem(for: renamed), to: items)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].displayName, "after.txt")
    }

    /// Re-dropping something already shelved moves it back to the top — a drop that appeared to do
    /// nothing at all reads as a drop that was not registered — but keeps the original row's id so
    /// the list does not churn.
    func testRedroppingAnExistingFileMovesItToTheTopAndKeepsItsIdentity() {
        var items = FileShelfKit.adding(makeItem(identity: "1:1", name: "old.txt"), to: [])
        let originalID = items[0].id
        items = FileShelfKit.adding(makeItem(identity: "1:2", name: "new.txt"), to: items)
        XCTAssertEqual(items.map(\.displayName), ["new.txt", "old.txt"])

        items = FileShelfKit.adding(makeItem(identity: "1:1", name: "old.txt"), to: items)

        XCTAssertEqual(items.map(\.displayName), ["old.txt", "new.txt"])
        XCTAssertEqual(items[0].id, originalID, "A re-drop must reuse the existing row rather than mint a new identity")
    }

    /// Two entries that both failed to resolve are not "the same file" just because neither could
    /// be found; collapsing them would hide one of the two things the user actually lost.
    func testEntriesWithoutAnIdentityNeverCollapseIntoEachOther() {
        var items = FileShelfKit.adding(makeUnresolvableItem(named: "one.txt"), to: [])
        items = FileShelfKit.adding(makeUnresolvableItem(named: "two.txt"), to: items)

        XCTAssertEqual(items.count, 2)
    }

    /// The cap is applied from the bottom, so an add never fails — the oldest entry makes room.
    func testTheOldestEntryFallsOffOnceTheShelfIsFull() {
        var items: [ShelfItem] = []
        for index in 0..<(FileShelfKit.maximumCount + 5) {
            items = FileShelfKit.adding(makeItem(identity: "1:\(index)", name: "file-\(index).txt"), to: items)
        }

        XCTAssertEqual(items.count, FileShelfKit.maximumCount)
        XCTAssertEqual(items.first?.displayName, "file-\(FileShelfKit.maximumCount + 4).txt")
        XCTAssertEqual(items.last?.displayName, "file-5.txt")
    }

    func testRemovingTakesOnlyTheNamedRow() throws {
        var items = FileShelfKit.adding(makeItem(identity: "1:1", name: "keep.txt"), to: [])
        items = FileShelfKit.adding(makeItem(identity: "1:2", name: "drop.txt"), to: items)
        let doomed = try XCTUnwrap(items.first { $0.displayName == "drop.txt" }).id

        let remaining = FileShelfKit.removing(id: doomed, from: items)

        XCTAssertEqual(remaining.map(\.displayName), ["keep.txt"])
    }

    // MARK: - Persistence

    /// The on-disk round trip, including the bookmark bytes: a shelf that did not survive a quit
    /// would be a scratch list, not a shelf.
    func testTheShelfSurvivesAWriteAndLoadRoundTrip() throws {
        let first = try makeFile(named: "one.txt")
        let second = try makeFile(named: "two.txt")
        var items = FileShelfKit.adding(FileShelfKit.makeItem(for: first), to: [])
        items = FileShelfKit.adding(FileShelfKit.makeItem(for: second), to: items)

        let shelfFile = directory.appendingPathComponent("shelf.json")
        XCTAssertTrue(FileShelfKit.write(items.map(\.file), to: shelfFile))

        let reloaded = FileShelfKit.load(from: shelfFile)

        XCTAssertEqual(reloaded.map(\.id), items.map(\.id))
        XCTAssertEqual(reloaded.map(\.displayName), ["two.txt", "one.txt"])

        // The bookmarks have to come back usable, not merely present: a shelf that reloads rows
        // which no longer resolve is indistinguishable from one that lost them.
        let resolved = reloaded.map { FileShelfKit.resolveItem($0) }
        XCTAssertEqual(resolved.map(\.availability), [.available, .available])
    }

    /// A shelf file that is missing (first launch) or corrupt is an empty shelf, never a crash.
    func testLoadingAMissingOrCorruptShelfYieldsAnEmptyShelf() throws {
        let missing = directory.appendingPathComponent("not-there.json")
        XCTAssertTrue(FileShelfKit.load(from: missing).isEmpty)

        let corrupt = directory.appendingPathComponent("corrupt.json")
        try Data("{ this is not json".utf8).write(to: corrupt)
        XCTAssertTrue(FileShelfKit.load(from: corrupt).isEmpty)
    }
}
