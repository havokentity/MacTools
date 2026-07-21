import Foundation
import XCTest
@testable import DMonteCore

/// Covers the behaviour that decides whether the Scratchpad loses someone's notes: that an edit
/// survives a flush and a relaunch, that a clear can be taken back, and that deleting one note
/// leaves the rest alone. Each test gets its own temporary directory and its own `UserDefaults`
/// suite, so neither the user's real notes nor their real preferences are ever touched.
@MainActor
final class ScratchpadControllerTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScratchpadControllerTests-\(UUID().uuidString)", isDirectory: true)
        suiteName = "com.havokentity.mactools.tests.scratchpad.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        directory = nil
        defaults = nil
        suiteName = nil
        try super.tearDownWithError()
    }

    private func makeController() -> ScratchpadController {
        ScratchpadController(directory: directory, defaults: defaults)
    }

    // MARK: - Startup

    /// An empty panel with no note to type into would be a dead end on first launch.
    func testFirstLaunchStartsWithOneSelectedNote() {
        let controller = makeController()

        XCTAssertEqual(controller.notes.count, 1)
        XCTAssertEqual(controller.selectedNoteID, controller.notes.first?.id)
    }

    // MARK: - Autosave

    /// The load-bearing test for the whole tool: text typed and then flushed must be on disk,
    /// and must come back when the controller is rebuilt.
    func testEditsSurviveAFlushAndAReload() {
        let controller = makeController()
        controller.updateText("remember the milk")
        controller.flushPendingSaves()

        let reloaded = makeController()

        XCTAssertEqual(reloaded.activeText, "remember the milk")
    }

    /// Flushing writes every note, not just the one on screen — the note left behind by a switch
    /// may still be holding an unfired debounce.
    func testEditsToSeveralNotesAllSurviveOneFlush() {
        let controller = makeController()
        controller.updateText("first note")
        controller.addNote()
        controller.updateText("second note")
        controller.flushPendingSaves()

        let bodies = makeController().notes.map(\.body)

        XCTAssertEqual(bodies.count, 2)
        XCTAssertTrue(bodies.contains("first note"))
        XCTAssertTrue(bodies.contains("second note"))
    }

    func testUnicodeSurvivesTheControllerRoundTrip() {
        let body = "👨‍👩‍👧‍👦 नमस्ते — “quoted”"
        let controller = makeController()
        controller.updateText(body)
        controller.flushPendingSaves()

        XCTAssertEqual(makeController().activeText, body)
    }

    /// Selecting another note is a commit point; a quit immediately afterwards must not lose the
    /// note the user just navigated away from.
    func testSwitchingNotesCommitsTheOneBeingLeft() throws {
        let controller = makeController()
        let firstID = try XCTUnwrap(controller.selectedNoteID)
        controller.updateText("left behind")

        controller.addNote()

        XCTAssertNotEqual(controller.selectedNoteID, firstID)
        // Read straight from disk, with no flush of our own: the switch itself must have
        // committed the note being left.
        XCTAssertTrue(ScratchpadKit.loadNotes(from: directory).contains { $0.body == "left behind" })
    }

    /// The selected note is remembered so reopening the panel lands where the user left off.
    func testSelectionIsRestoredOnReload() {
        let controller = makeController()
        controller.addNote()
        let expected = controller.selectedNoteID
        controller.flushPendingSaves()

        XCTAssertEqual(makeController().selectedNoteID, expected)
    }

    // MARK: - Clear and undo

    func testClearEmptiesTheNoteAndOffersAnUndo() {
        let controller = makeController()
        controller.updateText("valuable")

        controller.clearActiveNote()

        XCTAssertEqual(controller.activeText, "")
        XCTAssertTrue(controller.canUndoClear)
    }

    func testUndoClearRestoresTheExactText() {
        let controller = makeController()
        controller.updateText("valuable 👍")
        controller.clearActiveNote()

        controller.undoClear()

        XCTAssertEqual(controller.activeText, "valuable 👍")
        XCTAssertFalse(controller.canUndoClear)
    }

    /// Once the user starts writing again, restoring the old body would clobber the new one — so
    /// the offer is withdrawn rather than left as a trap.
    func testTypingAfterAClearWithdrawsTheUndoOffer() {
        let controller = makeController()
        controller.updateText("old")
        controller.clearActiveNote()

        controller.updateText("new")

        XCTAssertFalse(controller.canUndoClear)
        controller.undoClear()
        XCTAssertEqual(controller.activeText, "new")
    }

    /// The undo is kept per note for the whole session, so glancing at another note and coming
    /// back does not quietly forfeit it.
    func testUndoSurvivesASwitchAwayAndBack() throws {
        let controller = makeController()
        let firstID = try XCTUnwrap(controller.selectedNoteID)
        controller.updateText("valuable")
        controller.clearActiveNote()

        controller.addNote()
        XCTAssertFalse(controller.canUndoClear)
        controller.selectNote(firstID)

        XCTAssertTrue(controller.canUndoClear)
        controller.undoClear()
        XCTAssertEqual(controller.activeText, "valuable")
    }

    func testClearingAnAlreadyEmptyNoteOffersNothingToUndo() {
        let controller = makeController()

        controller.clearActiveNote()

        XCTAssertFalse(controller.canUndoClear)
    }

    // MARK: - Delete

    /// The first press only arms the confirmation; the note is still there.
    func testFirstDeletePressOnlyArmsTheConfirmation() {
        let controller = makeController()
        controller.addNote()
        controller.updateText("still wanted")

        controller.deleteSelectedNote()

        XCTAssertEqual(controller.notes.count, 2)
        XCTAssertEqual(controller.pendingDeleteNoteID, controller.selectedNoteID)
        XCTAssertEqual(controller.activeText, "still wanted")
    }

    func testSecondDeletePressRemovesOnlyThatNote() {
        let controller = makeController()
        controller.updateText("keep me")
        controller.addNote()
        controller.updateText("delete me")

        controller.deleteSelectedNote()
        controller.deleteSelectedNote()
        controller.flushPendingSaves()

        XCTAssertEqual(controller.notes.count, 1)
        XCTAssertEqual(controller.activeText, "keep me")
        XCTAssertEqual(ScratchpadKit.loadNotes(from: directory).map(\.body), ["keep me"])
    }

    /// A deleted note must not come back when the switcher's own selection changes rebuild it.
    func testDeletingTheLastNoteLeavesAFreshEmptyOne() {
        let controller = makeController()
        controller.updateText("goodbye")

        controller.deleteSelectedNote()
        controller.deleteSelectedNote()
        controller.flushPendingSaves()

        XCTAssertEqual(controller.notes.count, 1)
        XCTAssertEqual(controller.activeText, "")
        XCTAssertEqual(ScratchpadKit.loadNotes(from: directory).map(\.body), [""])
    }

    /// An arm that survives a whole editing session is not a confirmation. Without this, a user
    /// who armed a delete, kept writing, and pressed Delete again much later would lose the note
    /// on that single press.
    func testTypingDisarmsAnArmedDelete() {
        let controller = makeController()
        controller.addNote()
        controller.updateText("valuable work")
        controller.deleteSelectedNote()
        XCTAssertNotNil(controller.pendingDeleteNoteID, "Precondition: the first press armed it")

        controller.updateText("valuable work, continued")

        XCTAssertNil(controller.pendingDeleteNoteID)
        // The next press must only re-arm, leaving both notes intact.
        controller.deleteSelectedNote()
        XCTAssertEqual(controller.notes.count, 2)
        XCTAssertEqual(controller.activeText, "valuable work, continued")
    }

    // MARK: - Failed saves

    /// The one failure this tool must never hide: if the bytes did not reach disk, the user has
    /// to be told while they can still copy the text out somewhere else.
    func testASaveThatCannotReachDiskIsReportedNotSwallowed() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A regular file standing where the store directory should be: every write below it fails.
        let blocker = directory.appendingPathComponent("blocker")
        try Data("not a directory".utf8).write(to: blocker)

        let controller = ScratchpadController(
            directory: blocker.appendingPathComponent("notes", isDirectory: true),
            defaults: defaults
        )

        // updateText clears the status line, so anything left afterwards came from the flush.
        controller.updateText("must not vanish quietly")
        controller.flushPendingSaves()

        XCTAssertNotNil(controller.statusMessage)
        XCTAssertTrue(controller.statusMessage?.contains("save") == true,
                      "The warning must name the problem, got: \(controller.statusMessage ?? "nil")")
    }

    // MARK: - Renaming

    func testRenamingDeduplicatesAgainstTheOtherNotes() throws {
        let controller = makeController()
        controller.renameSelectedNote(to: "Ideas")
        controller.addNote()

        controller.renameSelectedNote(to: "Ideas")

        XCTAssertEqual(controller.activeNote?.title, "Ideas 2")
    }

    /// Renaming compares against the *other* notes only, so re-committing a note's own name is a
    /// no-op rather than a slow march to "Ideas 2", "Ideas 3", …
    func testRenamingANoteToItsOwnNameChangesNothing() {
        let controller = makeController()
        controller.renameSelectedNote(to: "Ideas")

        controller.renameSelectedNote(to: "Ideas")

        XCTAssertEqual(controller.activeNote?.title, "Ideas")
    }

    func testRenameSurvivesAReload() {
        let controller = makeController()
        controller.renameSelectedNote(to: "  Shopping   list ")
        controller.flushPendingSaves()

        XCTAssertEqual(makeController().activeNote?.title, "Shopping list")
    }

    // MARK: - Corrupt storage

    /// The store-level guarantee seen from the controller: one damaged file costs at most that
    /// one note's formatting, never the others.
    func testACorruptNoteFileDoesNotStopTheOthersFromOpening() {
        let controller = makeController()
        controller.updateText("healthy")
        controller.flushPendingSaves()

        let corruptID = UUID()
        try? Data("{\"body\":\"truncated".utf8)
            .write(to: directory.appendingPathComponent(ScratchpadKit.fileName(for: corruptID)))

        let reloaded = makeController()

        XCTAssertEqual(reloaded.notes.count, 2)
        XCTAssertTrue(reloaded.notes.contains { $0.body == "healthy" })
        XCTAssertTrue(reloaded.notes.contains { $0.title == "Recovered Note" })
    }

    // MARK: - Write ordering

    /// The writer's whole reason to exist: a snapshot that lost the race must never land on top of
    /// newer text, and a note the user deleted must stay deleted even if a write was already in
    /// flight. Both are dropped early now, so this also guards the pre-encode shortcut.
    func testStaleSnapshotsAreDroppedWithoutOverwritingNewerText() throws {
        ScratchpadKit.prepareDirectory(directory)
        let writer = ScratchpadNoteWriter()
        let note = ScratchpadNote(title: "Ideas", body: "newer")

        XCTAssertTrue(writer.write(note, to: directory, generation: 5))

        var stale = note
        stale.body = "older"
        XCTAssertTrue(writer.write(stale, to: directory, generation: 3), "a superseded snapshot is not a failure")
        XCTAssertEqual(ScratchpadKit.loadNotes(from: directory).first?.body, "newer")

        writer.delete(id: note.id, in: directory)
        XCTAssertTrue(writer.write(note, to: directory, generation: 9))
        XCTAssertTrue(ScratchpadKit.loadNotes(from: directory).isEmpty, "a deleted note must not come back")
    }
}
