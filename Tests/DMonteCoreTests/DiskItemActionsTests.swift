import AppKit
import XCTest
@testable import DMonteCore

final class DiskItemActionsTests: XCTestCase {
    private func file(name: String = "big.bin", path: String = "/Volumes/Data/big.bin", size: UInt64 = 4096) -> DiskNode {
        DiskNode(path: path, name: name, isDirectory: false, size: size, children: [])
    }

    private func folder(name: String = "Renders", path: String = "/Volumes/Data/Renders", size: UInt64 = 1_073_741_824) -> DiskNode {
        DiskNode(path: path, name: name, isDirectory: true, size: size, children: [])
    }

    // MARK: - Policy

    func testAnOrdinaryRowOnASettledTreeAllowsAllThreeActions() {
        let node = file()

        for action in DiskItemAction.allCases {
            let availability = DiskItemActionPolicy.availability(
                of: action,
                for: node,
                isScanRoot: false,
                isScanInProgress: false
            )
            XCTAssertEqual(availability, .allowed, "\(action) should be offered on a normal row")
        }
    }

    func testTheUnaccountedPlaceholderOffersNothingAtAll() {
        // This row carries the volume root's path, so every action would act on the
        // whole volume — a Move to Trash aimed at the mount point. It has to be
        // refused before it ever reaches the filesystem.
        let placeholder = DiskNode(
            path: "/",
            name: DiskScanner.unaccountedNodeName,
            isDirectory: false,
            size: 12_000_000,
            children: [],
            isSynthetic: true
        )

        for action in DiskItemAction.allCases {
            let availability = DiskItemActionPolicy.availability(
                of: action,
                for: placeholder,
                isScanRoot: false,
                isScanInProgress: false
            )
            XCTAssertFalse(availability.isAllowed, "\(action) must never run against the placeholder")
            XCTAssertNotNil(availability.reason)
        }
    }

    func testTheReconciledPlaceholderIsFlaggedSyntheticByTheScanner() {
        // The policy above is only as good as this flag: the placeholder and the
        // root are indistinguishable by path.
        let child = DiskNode(path: "/Users", name: "Users", isDirectory: true, size: 400, children: [])
        let root = DiskNode(path: "/", name: "Macintosh HD", isDirectory: true, size: 400, children: [child])

        let reconciled = DiskScanner.reconciled(root: root, usedBytes: 1000)
        let placeholder = reconciled.children.first { $0.name == DiskScanner.unaccountedNodeName }

        XCTAssertEqual(placeholder?.size, 600)
        XCTAssertEqual(placeholder?.path, "/", "the placeholder really does borrow the root's path")
        XCTAssertEqual(placeholder?.isSynthetic, true)
        XCTAssertEqual(reconciled.isSynthetic, false, "the root itself is a real directory")
        XCTAssertEqual(child.isSynthetic, false)
    }

    func testTheVolumeBeingAnalyzedCannotBeTrashedButCanStillBeRevealedAndCopied() {
        let root = folder(name: "Data", path: "/Volumes/Data")

        XCTAssertFalse(
            DiskItemActionPolicy.availability(of: .moveToTrash, for: root, isScanRoot: true, isScanInProgress: false).isAllowed
        )
        XCTAssertEqual(
            DiskItemActionPolicy.availability(of: .revealInFinder, for: root, isScanRoot: true, isScanInProgress: false),
            .allowed
        )
        XCTAssertEqual(
            DiskItemActionPolicy.availability(of: .copyPath, for: root, isScanRoot: true, isScanInProgress: false),
            .allowed
        )
    }

    func testTrashingIsHeldBackWhileAScanIsStillWalkingTheVolume() {
        // The scan in flight would keep measuring a directory that had moved out
        // from under it and then commit a tree built from both halves.
        let node = folder()

        let trash = DiskItemActionPolicy.availability(of: .moveToTrash, for: node, isScanRoot: false, isScanInProgress: true)
        XCTAssertFalse(trash.isAllowed)
        XCTAssertEqual(trash.reason, "A scan is still running on this volume. Let it finish before moving anything to the Trash.")

        // Reading a path is harmless mid-scan, so those two stay available.
        XCTAssertEqual(
            DiskItemActionPolicy.availability(of: .revealInFinder, for: node, isScanRoot: false, isScanInProgress: true),
            .allowed
        )
        XCTAssertEqual(
            DiskItemActionPolicy.availability(of: .copyPath, for: node, isScanRoot: false, isScanInProgress: true),
            .allowed
        )
    }

    func testAvailabilityExposesItsReasonOnlyWhenItRefuses() {
        XCTAssertNil(DiskItemActionAvailability.allowed.reason)
        XCTAssertTrue(DiskItemActionAvailability.allowed.isAllowed)

        let refusal = DiskItemActionAvailability.unavailable(reason: "nope")
        XCTAssertEqual(refusal.reason, "nope")
        XCTAssertFalse(refusal.isAllowed)
    }

    // MARK: - Trashing

    func testTrashingSomethingThatIsNoLongerThereReportsItAsAlreadyGone() {
        // The row a user right-clicks can be minutes old; Finder may have removed
        // the item in between. That must produce a message, not a crash and not
        // silence.
        let missing = NSTemporaryDirectory() + "dmonte-disk-analyzer-missing-\(UUID().uuidString)"

        let result = DiskItemTrasher.moveToTrash(path: missing)

        guard case .failure(let failure) = result else {
            return XCTFail("a path that does not exist cannot be trashed")
        }
        XCTAssertEqual(failure, .alreadyGone)
    }

    func testAVanishedItemIsRecognisedFromTheThrownErrorToo() {
        // The item can also disappear between the existence check and the call, so
        // the same condition is classified out of whatever trashItem throws.
        XCTAssertEqual(
            DiskItemTrasher.failure(from: NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)),
            .alreadyGone
        )
        XCTAssertEqual(
            DiskItemTrasher.failure(from: NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)),
            .alreadyGone
        )
        XCTAssertEqual(
            DiskItemTrasher.failure(from: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))),
            .alreadyGone
        )
    }

    func testARealRefusalIsPassedThroughVerbatim() {
        let denied = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteNoPermissionError,
            userInfo: [NSLocalizedDescriptionKey: "You don't have permission."]
        )

        XCTAssertEqual(DiskItemTrasher.failure(from: denied), .systemRefused("You don't have permission."))
    }

    func testAPermissionErrorIsNotMistakenForAMissingFile() {
        // The two are handled very differently — one prunes the row, the other
        // leaves the tree alone — so they must not collapse into each other.
        let denied = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        XCTAssertNotEqual(DiskItemTrasher.failure(from: denied), .alreadyGone)
    }

    // MARK: - Existence

    func testTheExistenceProbeSeesARealFileAndNotAMissingOne() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dmonte-disk-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("present.txt")
        try Data("hello".utf8).write(to: file)

        XCTAssertTrue(DiskItemProbe.exists(atPath: file.path))
        XCTAssertTrue(DiskItemProbe.exists(atPath: directory.path))
        XCTAssertFalse(DiskItemProbe.exists(atPath: directory.appendingPathComponent("absent.txt").path))
        XCTAssertFalse(DiskItemProbe.exists(atPath: ""))
    }

    func testADanglingSymlinkCountsAsPresentBecauseItIsARealDirectoryEntry() throws {
        // FileManager.fileExists follows the link and would call this gone, which
        // would leave a row nobody could reveal, copy or trash.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dmonte-disk-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let link = directory.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: directory.appendingPathComponent("never-existed")
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: link.path))
        XCTAssertTrue(DiskItemProbe.exists(atPath: link.path))
    }

    // MARK: - Wording

    func testTheConfirmationForAFolderSaysEverythingInsideItGoesToo() {
        let node = folder(name: "Renders", path: "/Volumes/Data/Renders", size: 1_073_741_824)

        let prompt = DiskItemActionMessage.trashPrompt(for: node)

        XCTAssertEqual(prompt.title, "Move \u{201C}Renders\u{201D} to the Trash?")
        XCTAssertTrue(prompt.detail.hasPrefix("/Volumes/Data/Renders"), "the full path is the disambiguator")
        XCTAssertTrue(prompt.detail.contains("everything inside it"))
        XCTAssertTrue(prompt.detail.contains(UInt64(1_073_741_824).diskBytesString))
    }

    func testTheConfirmationForAFileDoesNotClaimToTakeAnythingWithIt() {
        let node = file(name: "clip.mov", path: "/Volumes/Data/clip.mov", size: 5_000_000)

        let prompt = DiskItemActionMessage.trashPrompt(for: node)

        XCTAssertEqual(prompt.title, "Move \u{201C}clip.mov\u{201D} to the Trash?")
        XCTAssertFalse(prompt.detail.contains("everything inside it"))
        XCTAssertTrue(prompt.detail.contains(UInt64(5_000_000).diskBytesString))
    }

    func testAnAlreadyGoneItemIsExplainedRatherThanReportedAsAFailure() {
        let message = DiskItemActionMessage.trashFailed(name: "clip.mov", failure: .alreadyGone)

        XCTAssertTrue(message.contains("already deleted or moved"))
        XCTAssertTrue(message.contains("Removed it from the results"), "the row vanishing needs explaining")
    }

    func testARefusalQuotesTheSystemReason() {
        let message = DiskItemActionMessage.trashFailed(name: "clip.mov", failure: .systemRefused("Volume is read-only."))

        XCTAssertEqual(message, "Couldn't move clip.mov to the Trash: Volume is read-only.")
    }

    func testSuccessNamesTheSpaceThatCameOffTheTotals() {
        let message = DiskItemActionMessage.trashSucceeded(name: "Renders", bytes: 1_073_741_824)

        XCTAssertTrue(message.contains("Renders"))
        XCTAssertTrue(message.contains(UInt64(1_073_741_824).diskBytesString))
    }

    // MARK: - Copy Path

    func testCopyPathPutsTheFullPathOnTheClipboard() {
        // A private pasteboard so the suite never touches the real clipboard.
        let pasteboard = NSPasteboard(name: .init("com.havokentity.mactools.tests.disk-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        XCTAssertTrue(DiskItemPathCopier.copy(path: "/Volumes/Data/Renders", to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "/Volumes/Data/Renders")
    }

    func testCopyPathRefusesAnEmptyPathInsteadOfBlankingTheClipboard() {
        let pasteboard = NSPasteboard(name: .init("com.havokentity.mactools.tests.disk-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        pasteboard.setString("keep me", forType: .string)

        XCTAssertFalse(DiskItemPathCopier.copy(path: "", to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "keep me")
    }
}
