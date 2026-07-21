import XCTest
@testable import DMonteCore

/// The arithmetic behind "this is no longer on disk, so stop counting it".
///
/// Every one of these assertions is about a total the user reads off the screen and
/// acts on: if a parent's size does not shrink by exactly what left it, the analyzer
/// is telling people to delete space they have already freed.
final class DiskTreeMutationTests: XCTestCase {
    /// root (100)
    ///   docs (70)
    ///     archive.zip (50)
    ///     notes.txt (20)
    ///   logs (30)
    ///     today.log (30)
    private struct Fixture {
        let archive: DiskNode
        let notes: DiskNode
        let docs: DiskNode
        let todayLog: DiskNode
        let logs: DiskNode
        let root: DiskNode

        init() {
            archive = DiskNode(path: "/root/docs/archive.zip", name: "archive.zip", isDirectory: false, size: 50, children: [])
            notes = DiskNode(path: "/root/docs/notes.txt", name: "notes.txt", isDirectory: false, size: 20, children: [])
            docs = DiskNode(path: "/root/docs", name: "docs", isDirectory: true, size: 70, children: [archive, notes])
            todayLog = DiskNode(path: "/root/logs/today.log", name: "today.log", isDirectory: false, size: 30, children: [])
            logs = DiskNode(path: "/root/logs", name: "logs", isDirectory: true, size: 30, children: [todayLog])
            root = DiskNode(path: "/root", name: "root", isDirectory: true, size: 100, children: [docs, logs])
        }
    }

    // MARK: - Removing a leaf

    func testRemovingALeafShrinksEveryAncestorByExactlyItsSize() {
        let tree = Fixture()

        guard let removal = DiskTreeMutator.removing(tree.notes, from: tree.root) else {
            return XCTFail("notes.txt is in the tree, so the removal must succeed")
        }

        XCTAssertEqual(removal.root.size, 80, "the root loses the 20 bytes that left it")
        XCTAssertEqual(removal.replacedAncestors.map(\.new.name), ["root", "docs"], "ancestors come back root first")

        let newDocs = removal.root.children.first { $0.name == "docs" }
        XCTAssertEqual(newDocs?.size, 50)
        XCTAssertEqual(newDocs?.children.map(\.name), ["archive.zip"], "the removed row is gone from its parent")
    }

    func testRemovingALeafLeavesUntouchedSubtreesIdentical() {
        // Only the chain down to the removed node is rebuilt. Everything else is
        // carried over by reference, which is what lets the tree index be patched
        // instead of rebuilt and what keeps the expanded-rows set meaningful.
        let tree = Fixture()

        guard let removal = DiskTreeMutator.removing(tree.notes, from: tree.root) else {
            return XCTFail("notes.txt is in the tree, so the removal must succeed")
        }

        let newLogs = removal.root.children.first { $0.name == "logs" }
        XCTAssertTrue(newLogs === tree.logs, "an unaffected sibling keeps its identity")

        let newDocs = removal.root.children.first { $0.name == "docs" }
        XCTAssertTrue(newDocs?.children.first === tree.archive, "a surviving child keeps its identity")
        XCTAssertFalse(newDocs === tree.docs, "the resized ancestor is a new object")
    }

    // MARK: - Removing a whole subtree

    func testRemovingADirectoryTakesItsWholeSubtreeOutOfTheTotals() {
        let tree = Fixture()

        guard let removal = DiskTreeMutator.removing(tree.docs, from: tree.root) else {
            return XCTFail("docs is in the tree, so the removal must succeed")
        }

        XCTAssertEqual(removal.root.size, 30, "the root loses the folder's entire 70 bytes, not just its own")
        XCTAssertEqual(removal.root.children.map(\.name), ["logs"])
        XCTAssertEqual(removal.replacedAncestors.map(\.new.name), ["root"], "only the root sat above docs")
    }

    func testRemovingADirectoryLeavesNoneOfItsDescendantsReachable() {
        let tree = Fixture()

        guard let removal = DiskTreeMutator.removing(tree.docs, from: tree.root) else {
            return XCTFail("docs is in the tree, so the removal must succeed")
        }

        XCTAssertNil(DiskTreeMutator.ancestorPath(to: tree.archive, from: removal.root))
        XCTAssertNil(DiskTreeMutator.ancestorPath(to: tree.notes, from: removal.root))
        XCTAssertNil(DiskTreeMutator.ancestorPath(to: tree.docs, from: removal.root))
        XCTAssertNotNil(DiskTreeMutator.ancestorPath(to: tree.todayLog, from: removal.root))
    }

    // MARK: - Removing the largest child

    func testRemovingTheLargestChildResortsTheDirectoriesItShrank() {
        // docs (70) outranks logs (30) only because of archive.zip. Take that away
        // and docs is the smaller of the two, so the biggest-first order the treemap
        // and the tree pane both read has to be restored.
        let tree = Fixture()

        guard let removal = DiskTreeMutator.removing(tree.archive, from: tree.root) else {
            return XCTFail("archive.zip is in the tree, so the removal must succeed")
        }

        XCTAssertEqual(removal.root.size, 50)
        XCTAssertEqual(removal.root.children.map(\.name), ["logs", "docs"], "the shrunken folder drops below its sibling")
        XCTAssertEqual(removal.root.children.map(\.size), [30, 20])

        let newDocs = removal.root.children.first { $0.name == "docs" }
        XCTAssertEqual(newDocs?.size, 20)
        XCTAssertEqual(newDocs?.children.map(\.name), ["notes.txt"])
    }

    func testRemovingTheLargestChildOfTheRootKeepsTheRestOfTheTreeExact() {
        let tree = Fixture()

        guard let removal = DiskTreeMutator.removing(tree.docs, from: tree.root) else {
            return XCTFail("docs is in the tree, so the removal must succeed")
        }

        let sum = removal.root.children.reduce(UInt64(0)) { $0 + $1.size }
        XCTAssertEqual(sum, removal.root.size, "the root still equals the sum of what is left under it")
    }

    // MARK: - Refusals

    func testRemovingTheRootIsRefused() {
        let tree = Fixture()
        XCTAssertNil(DiskTreeMutator.removing(tree.root, from: tree.root), "a scan has to keep its root")
    }

    func testRemovingANodeFromAnotherTreeIsRefused() {
        let tree = Fixture()
        let stranger = DiskNode(path: "/elsewhere/file", name: "file", isDirectory: false, size: 5, children: [])

        XCTAssertNil(DiskTreeMutator.removing(stranger, from: tree.root))
    }

    func testRemovingMatchesByIdentityNotByPath() {
        // The reconciliation placeholder deliberately carries the volume root's
        // path, so path-string matching would let a Trash aimed at the placeholder
        // land on the root instead.
        let placeholder = DiskNode(
            path: "/root",
            name: DiskScanner.unaccountedNodeName,
            isDirectory: false,
            size: 25,
            children: [],
            isSynthetic: true
        )
        let real = DiskNode(path: "/root/big.bin", name: "big.bin", isDirectory: false, size: 75, children: [])
        let root = DiskNode(path: "/root", name: "root", isDirectory: true, size: 100, children: [real, placeholder])

        guard let removal = DiskTreeMutator.removing(placeholder, from: root) else {
            return XCTFail("the placeholder is a child of the root, so it is removable from the tree")
        }

        XCTAssertEqual(removal.root.children.map(\.name), ["big.bin"], "the identical path must not confuse the search")
        XCTAssertEqual(removal.root.size, 75)
    }

    func testAnAncestorSmallerThanTheNodeItLosesClampsAtZeroInsteadOfWrapping() {
        // Sizes are UInt64, so a tree that disagrees with itself would otherwise
        // underflow into an 18-exabyte folder on screen.
        let child = DiskNode(path: "/root/huge", name: "huge", isDirectory: false, size: 500, children: [])
        let root = DiskNode(path: "/root", name: "root", isDirectory: true, size: 100, children: [child])

        guard let removal = DiskTreeMutator.removing(child, from: root) else {
            return XCTFail("huge is a child of the root, so the removal must succeed")
        }

        XCTAssertEqual(removal.root.size, 0)
    }

    func testDeepChainShrinksEveryLevel() {
        let leaf = DiskNode(path: "/a/b/c/leaf", name: "leaf", isDirectory: false, size: 40, children: [])
        let c = DiskNode(path: "/a/b/c", name: "c", isDirectory: true, size: 40, children: [leaf])
        let b = DiskNode(path: "/a/b", name: "b", isDirectory: true, size: 60, children: [c])
        let a = DiskNode(path: "/a", name: "a", isDirectory: true, size: 90, children: [b])

        guard let removal = DiskTreeMutator.removing(leaf, from: a) else {
            return XCTFail("leaf is in the tree, so the removal must succeed")
        }

        XCTAssertEqual(removal.replacedAncestors.map(\.new.name), ["a", "b", "c"])
        XCTAssertEqual(removal.replacedAncestors.map(\.new.size), [50, 20, 0])
        XCTAssertEqual(removal.root.size, 50)
    }

    // MARK: - Navigation state

    func testTrashingTheFolderYouAreInsideWalksBackToItsParent() {
        let tree = Fixture()

        guard let removal = DiskTreeMutator.removing(tree.docs, from: tree.root) else {
            return XCTFail("docs is in the tree, so the removal must succeed")
        }

        let patched = DiskTreeNavigationPatch.patchedPath(
            [tree.root, tree.docs],
            removing: removal.removed,
            using: DiskTreeNavigationPatch.replacementMap(for: removal.replacedAncestors),
            fallbackRoot: removal.root
        )

        XCTAssertEqual(patched.map(\.name), ["root"])
        XCTAssertTrue(patched.first === removal.root, "the breadcrumb points at the resized root, not the stale one")
    }

    func testTrashingElsewhereKeepsTheBreadcrumbButSwapsInTheResizedAncestors() {
        let tree = Fixture()

        guard let removal = DiskTreeMutator.removing(tree.notes, from: tree.root) else {
            return XCTFail("notes.txt is in the tree, so the removal must succeed")
        }

        let patched = DiskTreeNavigationPatch.patchedPath(
            [tree.root, tree.docs],
            removing: removal.removed,
            using: DiskTreeNavigationPatch.replacementMap(for: removal.replacedAncestors),
            fallbackRoot: removal.root
        )

        XCTAssertEqual(patched.map(\.name), ["root", "docs"])
        XCTAssertEqual(patched.map(\.size), [80, 50], "the breadcrumb shows the new totals, not the ones from the scan")
        XCTAssertFalse(patched.last === tree.docs)
    }

    func testAnEmptiedBreadcrumbFallsBackToTheRoot() {
        // Nothing may leave the stack empty: the treemap draws from its last entry.
        let tree = Fixture()

        guard let removal = DiskTreeMutator.removing(tree.docs, from: tree.root) else {
            return XCTFail("docs is in the tree, so the removal must succeed")
        }

        let patched = DiskTreeNavigationPatch.patchedPath(
            [tree.docs],
            removing: removal.removed,
            using: [:],
            fallbackRoot: removal.root
        )

        XCTAssertEqual(patched.count, 1)
        XCTAssertTrue(patched.first === removal.root)
    }

    func testExpandedFoldersStayExpandedAcrossTheRebuild() {
        let tree = Fixture()

        guard let removal = DiskTreeMutator.removing(tree.notes, from: tree.root) else {
            return XCTFail("notes.txt is in the tree, so the removal must succeed")
        }

        let patched = DiskTreeNavigationPatch.patchedExpansion(
            [tree.root.id, tree.docs.id, tree.logs.id],
            using: removal.replacedAncestors
        )

        XCTAssertFalse(patched.contains(tree.root.id), "the stale ancestor id is dropped")
        XCTAssertFalse(patched.contains(tree.docs.id))
        XCTAssertTrue(patched.contains(removal.root.id))
        XCTAssertTrue(patched.contains(removal.replacedAncestors[1].new.id))
        XCTAssertTrue(patched.contains(tree.logs.id), "an untouched folder is left alone")
    }

    func testHighlightFollowsAResizedAncestorAndClearsForTheTrashedRow() {
        let tree = Fixture()

        guard let removal = DiskTreeMutator.removing(tree.notes, from: tree.root) else {
            return XCTFail("notes.txt is in the tree, so the removal must succeed")
        }
        let replacements = DiskTreeNavigationPatch.replacementMap(for: removal.replacedAncestors)

        XCTAssertNil(
            DiskTreeNavigationPatch.patchedSelection(tree.notes, removing: removal.removed, using: replacements),
            "the row that was trashed cannot stay selected"
        )
        XCTAssertTrue(
            DiskTreeNavigationPatch.patchedSelection(tree.docs, removing: removal.removed, using: replacements) === removal.replacedAncestors[1].new
        )
        XCTAssertTrue(
            DiskTreeNavigationPatch.patchedSelection(tree.logs, removing: removal.removed, using: replacements) === tree.logs
        )
        XCTAssertNil(DiskTreeNavigationPatch.patchedSelection(nil, removing: removal.removed, using: replacements))
    }
}
