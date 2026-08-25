import XCTest
@testable import DMonteCore

final class DiskTreeCacheTests: XCTestCase {
    func testIndexesAncestorPathForEveryNode() {
        let file = DiskNode(path: "/root/apps/tool.bin", name: "tool.bin", isDirectory: false, size: 12, children: [])
        let apps = DiskNode(path: "/root/apps", name: "apps", isDirectory: true, size: 12, children: [file])
        let logs = DiskNode(path: "/root/logs", name: "logs", isDirectory: true, size: 4, children: [])
        let root = DiskNode(path: "/root", name: "root", isDirectory: true, size: 16, children: [apps, logs])

        let cache = DiskTreeCache(root: root)

        XCTAssertEqual(cache.nodeCount, 4)
        XCTAssertEqual(cache.path(to: file)?.map(\.name), ["root", "apps", "tool.bin"])
        XCTAssertEqual(cache.path(to: logs)?.map(\.name), ["root", "logs"])
        XCTAssertEqual(cache.path(to: root)?.map(\.name), ["root"])
    }

    func testIndexingStopsWhenBuildTaskIsCancelled() async {
        // The cache is built on a detached task (scheduleTreeCacheBuild) so that a
        // boot-volume index — millions of nodes — never blocks the main actor. A
        // superseded build is cancelled and its result discarded; the walk must
        // observe that cancellation and bail instead of burning CPU to completion.
        let file = DiskNode(path: "/root/apps/tool.bin", name: "tool.bin", isDirectory: false, size: 12, children: [])
        let apps = DiskNode(path: "/root/apps", name: "apps", isDirectory: true, size: 12, children: [file])
        let root = DiskNode(path: "/root", name: "root", isDirectory: true, size: 12, children: [apps])

        let build = Task.detached { () -> DiskTreeCache in
            // Cancel ourselves before constructing so the walk sees the cancelled
            // flag from the very first node — deterministic, no timing dependence.
            withUnsafeCurrentTask { $0?.cancel() }
            return DiskTreeCache(root: root)
        }
        let cache = await build.value

        XCTAssertEqual(cache.nodeCount, 0, "a cancelled build must abandon the walk")
        XCTAssertNil(cache.path(to: root))
        XCTAssertNil(cache.path(to: file))
    }

    func testPatchingForATrashedNodeKeepsTheIndexUsableWithoutARebuild() {
        // Rebuilding the index walks every node on the volume — seconds on a boot
        // disk, during which the tree pane would still be showing the trashed row.
        // Patching has to leave an index indistinguishable from a fresh one.
        let archive = DiskNode(path: "/root/docs/archive.zip", name: "archive.zip", isDirectory: false, size: 50, children: [])
        let notes = DiskNode(path: "/root/docs/notes.txt", name: "notes.txt", isDirectory: false, size: 20, children: [])
        let docs = DiskNode(path: "/root/docs", name: "docs", isDirectory: true, size: 70, children: [archive, notes])
        let logs = DiskNode(path: "/root/logs", name: "logs", isDirectory: true, size: 30, children: [])
        let root = DiskNode(path: "/root", name: "root", isDirectory: true, size: 100, children: [docs, logs])

        guard let removal = DiskTreeMutator.removing(archive, from: root) else {
            return XCTFail("archive.zip is in the tree, so the removal must succeed")
        }
        let patched = DiskTreeCache(root: root).applying(removal)

        XCTAssertEqual(patched.nodeCount, 4, "one node left the tree")
        XCTAssertTrue(patched.root === removal.root)
        XCTAssertNil(patched.path(to: archive), "the trashed row is no longer navigable")
        XCTAssertEqual(patched.path(to: removal.root)?.map(\.name), ["root"])
        XCTAssertEqual(patched.path(to: notes)?.map(\.name), ["root", "docs"] + ["notes.txt"])
        XCTAssertEqual(patched.path(to: notes)?.map(\.size), [50, 20, 20], "the walk goes through the resized ancestors")
        XCTAssertEqual(patched.path(to: logs)?.map(\.name), ["root", "logs"], "an untouched branch still resolves")
    }

    func testPatchingForATrashedDirectoryForgetsItsWholeSubtree() {
        let archive = DiskNode(path: "/root/docs/archive.zip", name: "archive.zip", isDirectory: false, size: 50, children: [])
        let docs = DiskNode(path: "/root/docs", name: "docs", isDirectory: true, size: 50, children: [archive])
        let logs = DiskNode(path: "/root/logs", name: "logs", isDirectory: true, size: 30, children: [])
        let root = DiskNode(path: "/root", name: "root", isDirectory: true, size: 80, children: [docs, logs])

        guard let removal = DiskTreeMutator.removing(docs, from: root) else {
            return XCTFail("docs is in the tree, so the removal must succeed")
        }
        let patched = DiskTreeCache(root: root).applying(removal)

        XCTAssertEqual(patched.nodeCount, 2, "the folder and its child both left")
        XCTAssertNil(patched.path(to: docs))
        XCTAssertNil(patched.path(to: archive), "a descendant of a trashed folder must not stay reachable")
        XCTAssertEqual(patched.path(to: logs)?.map(\.size), [30, 30])
    }

    func testAPatchedIndexMatchesOneBuiltFromScratch() {
        let deep = DiskNode(path: "/root/a/b/leaf", name: "leaf", isDirectory: false, size: 10, children: [])
        let sibling = DiskNode(path: "/root/a/b/other", name: "other", isDirectory: false, size: 5, children: [])
        let b = DiskNode(path: "/root/a/b", name: "b", isDirectory: true, size: 15, children: [deep, sibling])
        let a = DiskNode(path: "/root/a", name: "a", isDirectory: true, size: 15, children: [b])
        let root = DiskNode(path: "/root", name: "root", isDirectory: true, size: 15, children: [a])

        guard let removal = DiskTreeMutator.removing(deep, from: root) else {
            return XCTFail("leaf is in the tree, so the removal must succeed")
        }
        let patched = DiskTreeCache(root: root).applying(removal)
        let rebuilt = DiskTreeCache(root: removal.root)

        XCTAssertEqual(patched.nodeCount, rebuilt.nodeCount)
        XCTAssertEqual(patched.path(to: sibling)?.map(\.name), rebuilt.path(to: sibling)?.map(\.name))
        XCTAssertEqual(patched.path(to: sibling)?.map(\.size), rebuilt.path(to: sibling)?.map(\.size))
        XCTAssertEqual(patched.path(to: removal.root)?.count, rebuilt.path(to: removal.root)?.count)
    }
}
