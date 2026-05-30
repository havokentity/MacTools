import Foundation
import XCTest
@testable import DMonteCore

final class DuplicateFinderKitTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DuplicateFinderKitTests-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - End-to-end

    func testFindsTwoGroupsWithCorrectMembershipAndReclaim() throws {
        // Group 1: three identical "dupe" files (one nested).
        let dupe1 = try write("dupe", to: "dupe1.txt")
        let dupe2 = try write("dupe", to: "nested/dupe2.txt")
        let dupe3 = try write("dupe", to: "nested/deeper/dupe3.txt")

        // Group 2: two identical "other" files.
        let other1 = try write("other", to: "other1.txt")
        let other2 = try write("other", to: "nested/other2.txt")

        // A unique file — never grouped.
        let unique = try write("unique-and-alone", to: "unique.txt")

        // Two files with the SAME length but DIFFERENT content. They share a size
        // bucket but must NOT be grouped (SHA-256 differs).
        let same1 = try write("AAAA", to: "same1.bin")
        let same2 = try write("BBBB", to: "same2.bin")

        let groups = DuplicatesKit.findDuplicates(in: tempDir, progress: nil)

        // Exactly two duplicate groups.
        XCTAssertEqual(groups.count, 2, "Expected exactly two duplicate groups")

        // Locate the "dupe" group (the 4-byte, 3-member one).
        guard let dupeGroup = groups.first(where: { $0.files.count == 3 }) else {
            return XCTFail("Missing the three-member dupe group")
        }
        XCTAssertEqual(dupeGroup.files.count, 3)
        XCTAssertEqual(dupeGroup.size, UInt64("dupe".utf8.count))
        // Reclaimable for the dupe group is size × (count − 1) == 2 × size.
        XCTAssertEqual(dupeGroup.reclaimable, dupeGroup.size * 2)

        let dupePaths = Set(dupeGroup.files.map { standardizedPath($0.url) })
        XCTAssertEqual(
            dupePaths,
            Set([dupe1, dupe2, dupe3].map { standardizedPath($0) })
        )

        // Locate the "other" group (the 5-byte, 2-member one).
        guard let otherGroup = groups.first(where: { $0.files.count == 2 }) else {
            return XCTFail("Missing the two-member other group")
        }
        XCTAssertEqual(otherGroup.size, UInt64("other".utf8.count))
        XCTAssertEqual(otherGroup.reclaimable, otherGroup.size)

        let otherPaths = Set(otherGroup.files.map { standardizedPath($0.url) })
        XCTAssertEqual(
            otherPaths,
            Set([other1, other2].map { standardizedPath($0) })
        )

        // Nothing else should ever appear in a group.
        let allGroupedPaths = Set(groups.flatMap { $0.files }.map { standardizedPath($0.url) })
        XCTAssertFalse(allGroupedPaths.contains(standardizedPath(unique)))
        XCTAssertFalse(allGroupedPaths.contains(standardizedPath(same1)))
        XCTAssertFalse(allGroupedPaths.contains(standardizedPath(same2)))

        // Results are sorted by reclaimable space descending.
        XCTAssertGreaterThanOrEqual(groups[0].reclaimable, groups[1].reclaimable)

        // Every returned member exists and reports the group's byte size.
        for group in groups {
            for file in group.files {
                XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
                XCTAssertEqual(file.size, group.size)
            }
        }
    }

    func testWastedBytesIsSumOfExtraCopies() throws {
        // 3 copies of a 4-byte payload -> waste 8.
        try write("dupe", to: "a1.txt")
        try write("dupe", to: "a2.txt")
        try write("dupe", to: "a3.txt")
        // 2 copies of a 5-byte payload -> waste 5.
        try write("other", to: "b1.txt")
        try write("other", to: "b2.txt")

        let groups = DuplicatesKit.findDuplicates(in: tempDir, progress: nil)
        XCTAssertEqual(groups.count, 2)

        let expected = UInt64("dupe".utf8.count) * 2 + UInt64("other".utf8.count)
        XCTAssertEqual(DuplicatesKit.wastedBytes(groups), expected)
    }

    func testEmptyDirectoryReturnsNoGroups() throws {
        let groups = DuplicatesKit.findDuplicates(in: tempDir, progress: nil)
        XCTAssertTrue(groups.isEmpty)
        XCTAssertEqual(DuplicatesKit.wastedBytes(groups), 0)
    }

    func testZeroByteFilesAreIgnored() throws {
        let zeroA = tempDir.appendingPathComponent("emptyA.txt")
        let zeroB = tempDir.appendingPathComponent("emptyB.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: zeroA.path, contents: Data()))
        XCTAssertTrue(FileManager.default.createFile(atPath: zeroB.path, contents: Data()))

        let groups = DuplicatesKit.findDuplicates(in: tempDir, progress: nil)
        XCTAssertTrue(groups.isEmpty, "Empty files must not be reported as duplicates")
    }

    func testProgressCallbackReportsExaminedFiles() throws {
        try write("one", to: "one.txt")
        try write("two", to: "two.txt")
        try write("three", to: "three.txt")

        let box = CounterBox()
        _ = DuplicatesKit.findDuplicates(in: tempDir) { count in
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
