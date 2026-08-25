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

    /// Rewrites `url` the way a Mac app saves it: the new contents are written alongside and then
    /// swapped into place. This is what TextEdit, Preview, Xcode and anything built on NSDocument
    /// do, and the reason it matters here is that the swap gives the file a brand-new inode while
    /// leaving its path and its bookmark alone.
    private func safeSave(_ url: URL, contents: String) throws {
        let staging = url.deletingLastPathComponent()
            .appendingPathComponent("safe-save-\(UUID().uuidString)")
        try Data(contents.utf8).write(to: staging)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: staging)
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

    /// The same re-drop, but with the file saved in between — which is the case that actually
    /// happens, since the reason to shelve something is usually that you are still working on it.
    ///
    /// A safe save replaces the file with a fresh inode, so the identity cached on the shelf row
    /// stops matching the file the row's bookmark still points at. Dropping straight onto the
    /// menu-bar icon never opens the popover, so nothing has re-resolved the shelf since it was
    /// last looked at; if `shelve` trusted those cached identities it would find no match and add
    /// a second permanent row for a file that is already there.
    func testRedroppingAFileThatWasSavedInTheMeantimeStillLeavesOneRow() throws {
        let store = makeStore()
        let url = try makeFile(named: "report.txt")
        XCTAssertEqual(store.shelve(urls: [url]), 1)
        let identityWhenShelved = try XCTUnwrap(store.items[0].identity)

        try safeSave(url, contents: "edited in some app")
        XCTAssertNotEqual(
            FileShelfKit.identity(for: url), identityWhenShelved,
            "This test is only meaningful if the safe save really did move the file to a new inode"
        )

        // Deliberately no refresh(): a drop onto the menu-bar icon never opens the popover.
        XCTAssertEqual(store.shelve(urls: [url]), 0, "The file was already shelved, so no row was gained")

        XCTAssertEqual(store.items.count, 1, "An edited file must collapse onto its existing row, not fork off a new one")
        XCTAssertEqual(store.items[0].displayName, "report.txt")
        XCTAssertNotNil(store.statusMessage, "The user has to be told the drop landed on something already shelved")
    }

    /// The other half of the same problem: a file that moved while the popover was closed is still
    /// the same file, and re-dropping it must not leave two rows behind either.
    func testRedroppingAFileThatWasRenamedInTheMeantimeStillLeavesOneRow() throws {
        let store = makeStore()
        let original = try makeFile(named: "before.txt")
        XCTAssertEqual(store.shelve(urls: [original]), 1)

        let renamed = filesDirectory.appendingPathComponent("after.txt")
        try FileManager.default.moveItem(at: original, to: renamed)

        XCTAssertEqual(store.shelve(urls: [renamed]), 0)

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items[0].displayName, "after.txt")
    }

    func testShelvingSeveralFilesKeepsTheDroppedOrder() throws {
        let store = makeStore()
        let first = try makeFile(named: "a.txt")
        let second = try makeFile(named: "b.txt")
        let third = try makeFile(named: "c.txt")

        XCTAssertEqual(store.shelve(urls: [first, second, third]), 3)

        XCTAssertEqual(store.items.map(\.displayName), ["a.txt", "b.txt", "c.txt"])
    }

    /// A shelf holds files. The popover's drop path asks `NSItemProvider` for "a URL" and gets back
    /// whichever representation the provider preferred, so a drag carrying both a file and a web
    /// address can hand over the web address — and that must not become a row.
    ///
    /// The damage is not a harmlessly broken entry. A URL is reduced to its path when it is
    /// shelved, and the path of `https://example.com/tmp` is `/tmp`, which exists on every Mac:
    /// unfiltered, the row would be reported as *available* and would carry the identity of the
    /// local `/tmp`, so a later genuine drop of that folder would collapse onto a web link.
    func testAWebAddressIsNotShelvedEvenWhenItsPathExistsLocally() throws {
        let store = makeStore()

        let link = try XCTUnwrap(URL(string: "https://example.com/tmp"))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: link.standardizedFileURL.path),
            "This test is only meaningful while the link's path names something that really exists"
        )

        XCTAssertEqual(store.shelve(urls: [link]), 0)
        XCTAssertTrue(store.items.isEmpty, "A web address must never take a row on a file shelf")
    }

    /// …and a mixed drop still shelves the half that was real, rather than refusing the lot.
    func testAMixedDropShelvesTheFilesAndDiscardsTheRest() throws {
        let store = makeStore()
        let file = try makeFile(named: "real.txt")
        let link = try XCTUnwrap(URL(string: "https://example.com/tmp"))

        XCTAssertEqual(store.shelve(urls: [link, file]), 1)

        XCTAssertEqual(store.items.map(\.displayName), ["real.txt"])
    }

    // MARK: - Drop collection

    /// The whole point of batching a multi-file drop is that it waits for the slowest provider —
    /// which is only safe because the wait ends.
    ///
    /// An `NSItemProvider` in a drag from another application is that application's promise to
    /// call back, and nothing here can make it keep that promise: a wedged loader, or a source app
    /// that dies before its reply lands, simply never answers. Without the deadline the batch's
    /// outstanding count never reaches zero and *every* file in the drag is silently discarded,
    /// including the ones that arrived perfectly.
    func testADropWhoseProviderNeverAnswersStillShelvesTheOnesThatDid() async throws {
        let store = makeStore()
        let arrived = try makeFile(named: "arrived.txt")

        let collector = DroppedURLCollector(expected: 2, store: store)
        collector.startDeadline(after: 0.1)
        collector.accept(arrived, at: 0)
        // Slot 1 is the provider that never calls back.

        XCTAssertTrue(store.items.isEmpty, "Nothing may be shelved while the batch is still expecting an answer")

        try await Task.sleep(nanoseconds: 600_000_000)

        XCTAssertEqual(
            store.items.map(\.displayName), ["arrived.txt"],
            "A batch that timed out must still hand over everything that did arrive"
        )
    }

    /// The deadline is a backstop, not a second delivery: a batch that completed normally must not
    /// be shelved again when the clock runs out.
    func testTheDeadlineDoesNotReshelveABatchThatAlreadyCompleted() async throws {
        let store = makeStore()
        let first = try makeFile(named: "one.txt")
        let second = try makeFile(named: "two.txt")

        let collector = DroppedURLCollector(expected: 2, store: store)
        collector.startDeadline(after: 0.1)
        collector.accept(first, at: 0)
        collector.accept(second, at: 1)

        XCTAssertEqual(store.items.map(\.displayName), ["one.txt", "two.txt"])
        store.clearStatus()

        try await Task.sleep(nanoseconds: 600_000_000)

        XCTAssertEqual(store.items.map(\.displayName), ["one.txt", "two.txt"])
        XCTAssertNil(
            store.statusMessage,
            "A second delivery would re-shelve the same files and announce them as already on the shelf"
        )
    }

    /// A provider is allowed to answer twice. Counting the second answer would run the outstanding
    /// count past zero, and the batch would be shelved short — or never.
    func testAProviderThatAnswersTwiceDoesNotShortenTheBatch() throws {
        let store = makeStore()
        let first = try makeFile(named: "one.txt")
        let second = try makeFile(named: "two.txt")

        let collector = DroppedURLCollector(expected: 2, store: store)
        collector.startDeadline(after: 5)
        collector.accept(first, at: 0)
        collector.accept(first, at: 0)

        XCTAssertTrue(store.items.isEmpty, "The second file has not answered yet, so the batch is not complete")

        collector.accept(second, at: 1)

        XCTAssertEqual(store.items.map(\.displayName), ["one.txt", "two.txt"])
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
