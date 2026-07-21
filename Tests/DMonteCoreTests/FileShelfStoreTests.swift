import Foundation
import XCTest
@testable import DMonteCore

/// Drives the real `FileShelfStore` — the same code the popover talks to — against a temporary
/// directory and its own `UserDefaults` suite, so neither the user's real shelf nor their real
/// preferences are ever touched.
///
/// The store is where "shelving does not copy bytes" and "the shelf survives a quit" actually have
/// to be true, so both are asserted here rather than only at the pure-logic layer.
@MainActor
final class FileShelfStoreTests: XCTestCase {
    private var directory: URL!
    private var filesDirectory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileShelfStoreTests-\(UUID().uuidString)", isDirectory: true)
        directory = root.appendingPathComponent("shelf", isDirectory: true)
        filesDirectory = root.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: filesDirectory, withIntermediateDirectories: true)

        suiteName = "com.havokentity.mactools.tests.fileshelf.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
        }
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        directory = nil
        filesDirectory = nil
        defaults = nil
        suiteName = nil
        try super.tearDownWithError()
    }

    private func makeStore() -> FileShelfStore {
        FileShelfStore(directory: directory, defaults: defaults)
    }

    @discardableResult
    private func makeFile(named name: String, contents: String = "payload") throws -> URL {
        let url = filesDirectory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    // MARK: - Shelving

    func testShelvingAFileAddsOneRow() throws {
        let store = makeStore()
        let url = try makeFile(named: "report.pdf")

        XCTAssertEqual(store.shelve(urls: [url]), 1)

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items[0].displayName, "report.pdf")
        XCTAssertTrue(store.items[0].isAvailable)
    }

    /// The single most important thing this tool must not do. A shelf that copied bytes would
    /// silently double the disk usage of every large file someone parked on it.
    func testShelvingDoesNotCopyTheFileAnywhere() throws {
        let store = makeStore()
        let url = try makeFile(named: "big.bin", contents: String(repeating: "x", count: 4096))

        store.shelve(urls: [url])

        let shelfContents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []

        XCTAssertEqual(
            shelfContents.map(\.lastPathComponent), ["shelf.json"],
            "The shelf directory must hold nothing but its index — never a copy of a shelved file"
        )
        // And the entry still points at the original, not at some duplicate.
        XCTAssertEqual(
            store.items[0].url?.resolvingSymlinksInPath().path,
            url.resolvingSymlinksInPath().path
        )
    }

    func testShelvingTheSameFileTwiceStillLeavesOneRow() throws {
        let store = makeStore()
        let url = try makeFile(named: "duplicate.txt")

        XCTAssertEqual(store.shelve(urls: [url]), 1)
        XCTAssertEqual(store.shelve(urls: [url]), 0, "A re-drop adds no rows, so it must not report one")

        XCTAssertEqual(store.items.count, 1)
        XCTAssertNotNil(store.statusMessage, "A drop that changed nothing has to say so, or it reads as ignored")
    }

    func testShelvingSeveralFilesKeepsTheDroppedOrder() throws {
        let store = makeStore()
        let first = try makeFile(named: "a.txt")
        let second = try makeFile(named: "b.txt")
        let third = try makeFile(named: "c.txt")

        XCTAssertEqual(store.shelve(urls: [first, second, third]), 3)

        XCTAssertEqual(store.items.map(\.displayName), ["a.txt", "b.txt", "c.txt"])
    }

    // MARK: - Availability

    /// The rule the feature turns on: an entry whose file is gone is shown as unavailable, never
    /// quietly dropped.
    func testAnEntryWhoseFileIsDeletedStaysOnTheShelfAsUnavailable() throws {
        let store = makeStore()
        let url = try makeFile(named: "temporary.txt")
        store.shelve(urls: [url])

        try FileManager.default.removeItem(at: url)
        store.refresh()

        XCTAssertEqual(store.items.count, 1, "A deleted file must not make its shelf row disappear")
        XCTAssertFalse(store.items[0].isAvailable)
        XCTAssertEqual(store.items[0].displayName, "temporary.txt")
    }

    /// Reveal has nothing to reveal for an unavailable row, so it reports that instead of opening
    /// a Finder window on a path that is not there.
    func testRevealingAnUnavailableEntryReportsItRatherThanOpeningFinder() throws {
        let store = makeStore()
        let url = try makeFile(named: "vanishing.txt")
        store.shelve(urls: [url])
        try FileManager.default.removeItem(at: url)
        store.refresh()

        store.revealInFinder(id: store.items[0].id)

        XCTAssertNotNil(store.statusMessage)
    }

    // MARK: - Removal

    func testRemovingTakesTheRowButLeavesTheFileAlone() throws {
        let store = makeStore()
        let url = try makeFile(named: "keep-me.txt")
        store.shelve(urls: [url])

        store.remove(id: store.items[0].id)

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "Taking a file off the shelf must never delete it"
        )
    }

    /// Clearing is the one action here with nothing to undo, so with confirmation on the first
    /// press only arms it.
    func testClearAllNeedsASecondPressWhenConfirmationIsOn() throws {
        let store = makeStore()
        store.setConfirmsClearAll(true)
        store.shelve(urls: [try makeFile(named: "one.txt"), try makeFile(named: "two.txt")])

        store.requestClearAll()

        XCTAssertTrue(store.isConfirmingClearAll)
        XCTAssertEqual(store.items.count, 2, "The arming press must not have cleared anything yet")

        store.confirmClearAll()

        XCTAssertFalse(store.isConfirmingClearAll)
        XCTAssertTrue(store.items.isEmpty)
    }

    func testClearAllIsImmediateWhenConfirmationIsOff() throws {
        let store = makeStore()
        store.setConfirmsClearAll(false)
        store.shelve(urls: [try makeFile(named: "one.txt")])

        store.requestClearAll()

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(store.isConfirmingClearAll)
    }

    /// An armed clear authorises the list the user was looking at. Removing a row changes that
    /// list, so the arming has to be dropped rather than carried onto a different shelf.
    func testRemovingARowDisarmsAPendingClear() throws {
        let store = makeStore()
        store.setConfirmsClearAll(true)
        store.shelve(urls: [try makeFile(named: "one.txt"), try makeFile(named: "two.txt")])
        store.requestClearAll()
        XCTAssertTrue(store.isConfirmingClearAll)

        store.remove(id: store.items[0].id)

        XCTAssertFalse(store.isConfirmingClearAll)
        XCTAssertEqual(store.items.count, 1)
    }

    /// Turning confirmation off must not fire the press that is already pending.
    func testTurningConfirmationOffDisarmsAPendingClear() throws {
        let store = makeStore()
        store.setConfirmsClearAll(true)
        store.shelve(urls: [try makeFile(named: "one.txt")])
        store.requestClearAll()
        XCTAssertTrue(store.isConfirmingClearAll)

        store.setConfirmsClearAll(false)

        XCTAssertFalse(store.isConfirmingClearAll)
        XCTAssertEqual(store.items.count, 1, "Changing a setting must never be a destructive action")
    }

    // MARK: - Persistence

    /// A second store over the same directory is what a relaunch looks like.
    func testTheShelfSurvivesARelaunch() throws {
        let first = try makeFile(named: "one.txt")
        let second = try makeFile(named: "two.txt")

        let original = makeStore()
        original.shelve(urls: [first, second])
        XCTAssertEqual(original.items.count, 2)

        let relaunched = makeStore()

        XCTAssertEqual(relaunched.items.map(\.displayName), ["one.txt", "two.txt"])
        XCTAssertTrue(relaunched.items.allSatisfy(\.isAvailable))
    }

    /// …and it survives one while the file is being renamed underneath it, which is the whole
    /// reason a bookmark is stored rather than a path.
    func testARelaunchFindsAFileThatWasRenamedInTheMeantime() throws {
        let original = try makeFile(named: "before.txt")

        let store = makeStore()
        store.shelve(urls: [original])

        let renamed = filesDirectory.appendingPathComponent("after.txt")
        try FileManager.default.moveItem(at: original, to: renamed)

        let relaunched = makeStore()

        XCTAssertEqual(relaunched.items.count, 1)
        XCTAssertTrue(relaunched.items[0].isAvailable)
        XCTAssertEqual(relaunched.items[0].displayName, "after.txt")
    }

    func testAnEmptiedShelfStaysEmptyAcrossARelaunch() throws {
        let store = makeStore()
        store.setConfirmsClearAll(false)
        store.shelve(urls: [try makeFile(named: "one.txt")])
        store.requestClearAll()

        XCTAssertTrue(makeStore().items.isEmpty)
    }
}
