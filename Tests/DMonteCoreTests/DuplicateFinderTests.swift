import Foundation
import XCTest
@testable import DMonteCore

final class DuplicateFinderTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DuplicateFinderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    @discardableResult
    private func write(_ contents: String, to name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func standardizedPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    // MARK: - Tests

    func testFindsExactlyTwoGroupsAndSkipsEdgeCases() throws {
        // Pair A: two identical files.
        let a1 = try write("alpha-payload", to: "a1.txt")
        let a2 = try write("alpha-payload", to: "nested/a2.txt")

        // Pair B: two identical files, different content + size from pair A.
        let b1 = try write("beta-content-here", to: "b1.txt")
        let b2 = try write("beta-content-here", to: "nested/deeper/b2.txt")

        // Unique file — never grouped.
        try write("unique-and-alone", to: "unique.txt")

        // Zero-byte file — must be skipped.
        let zero = tempDir.appendingPathComponent("empty.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: zero.path, contents: Data()))

        // Two files with the SAME size (9 bytes) but DIFFERENT content. They land
        // in the same size bucket but must NOT be grouped (SHA-256 differs).
        try write("size-aaaa", to: "same1.bin")
        try write("size-bbbb", to: "same2.bin")

        let groups = DuplicateFinderKit.findDuplicates(in: tempDir, progress: nil)

        // Exactly two duplicate groups.
        XCTAssertEqual(groups.count, 2, "Expected exactly two duplicate groups")

        // Each group has exactly two members.
        for group in groups {
            XCTAssertEqual(group.urls.count, 2)
        }

        let groupedPaths = Set(groups.flatMap { $0.urls }.map { self.standardizedPath($0) })

        XCTAssertTrue(groupedPaths.contains(standardizedPath(a1)))
        XCTAssertTrue(groupedPaths.contains(standardizedPath(a2)))
        XCTAssertTrue(groupedPaths.contains(standardizedPath(b1)))
        XCTAssertTrue(groupedPaths.contains(standardizedPath(b2)))

        // Same-size-different-content files must NOT be grouped.
        let same1 = tempDir.appendingPathComponent("same1.bin")
        let same2 = tempDir.appendingPathComponent("same2.bin")
        XCTAssertFalse(groupedPaths.contains(standardizedPath(same1)))
        XCTAssertFalse(groupedPaths.contains(standardizedPath(same2)))

        // Zero-byte and unique files must not appear anywhere.
        XCTAssertFalse(groupedPaths.contains(standardizedPath(zero)))
        let unique = tempDir.appendingPathComponent("unique.txt")
        XCTAssertFalse(groupedPaths.contains(standardizedPath(unique)))

        // Each returned group is internally consistent: every URL exists, and
        // all members share the reported byte size.
        for group in groups {
            for url in group.urls {
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
                XCTAssertEqual(UInt64(size), group.size)
            }
        }
    }

    func testWastedBytesIsSumOfExtraCopies() throws {
        // Group A: 2 copies of a 13-byte payload -> waste 13.
        try write("alpha-payload", to: "a1.txt")
        try write("alpha-payload", to: "a2.txt")

        // Group B: 3 copies of a 17-byte payload -> waste 34.
        try write("beta-content-here", to: "b1.txt")
        try write("beta-content-here", to: "b2.txt")
        try write("beta-content-here", to: "b3.txt")

        let groups = DuplicateFinderKit.findDuplicates(in: tempDir, progress: nil)
        XCTAssertEqual(groups.count, 2)

        let sizeA = UInt64("alpha-payload".utf8.count)
        let sizeB = UInt64("beta-content-here".utf8.count)
        let expected = sizeA + (sizeB + sizeB)

        XCTAssertEqual(DuplicateFinderKit.wastedBytes(groups), expected)
    }

    func testEmptyDirectoryReturnsNoGroups() throws {
        let groups = DuplicateFinderKit.findDuplicates(in: tempDir, progress: nil)
        XCTAssertTrue(groups.isEmpty)
        XCTAssertEqual(DuplicateFinderKit.wastedBytes(groups), 0)
    }

    func testProgressCallbackCountsExaminedFiles() throws {
        try write("one", to: "one.txt")
        try write("two", to: "two.txt")
        try write("three", to: "three.txt")

        let box = CounterBox()
        _ = DuplicateFinderKit.findDuplicates(in: tempDir) { count in
            box.update(count)
        }
        XCTAssertEqual(box.maxValue, 3)
    }
}

// MARK: - Test helpers

private final class CounterBox: @unchecked Sendable {
    private var value = 0
    private let lock = NSLock()

    func update(_ candidate: Int) {
        lock.lock()
        defer { lock.unlock() }
        value = max(value, candidate)
    }

    var maxValue: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
