import XCTest
@testable import DMonteCore

final class SingleInstanceGuardTests: XCTestCase {
    private var identifier: String!

    override func setUp() {
        super.setUp()
        identifier = "SingleInstanceGuardTests-\(UUID().uuidString)"
    }

    override func tearDown() {
        // The guard resolves its own lock directory, so these land in the real Application
        // Support directory rather than a scratch one. Every identifier a test claims has to be
        // swept unconditionally, or UUID-named locks pile up in the user's home.
        try? FileManager.default.removeItem(at: lockURL)
        identifier = nil
        super.tearDown()
    }

    private var lockURL: URL {
        SingleInstanceGuard.lockDirectory().appendingPathComponent("\(identifier!).lock")
    }

    /// The regression this guards: locks used to live in NSTemporaryDirectory(), which macOS
    /// reaps for files untouched for a few days. Reaping unlinks the path without releasing the
    /// primary's flock, so a later instance would create a fresh inode and also claim primary.
    func testLockFileLivesOutsideTheReapableTemporaryDirectory() {
        let instance = SingleInstanceGuard(identifier: identifier)

        withExtendedLifetime(instance) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL.path))
            XCTAssertFalse(lockURL.path.hasPrefix(NSTemporaryDirectory()))
        }
    }

    func testFirstInstanceIsPrimary() {
        let instance = SingleInstanceGuard(identifier: identifier)

        withExtendedLifetime(instance) {
            XCTAssertTrue(instance.isPrimary)
        }
    }

    func testSecondInstanceForTheSameIdentifierIsNotPrimary() {
        let first = SingleInstanceGuard(identifier: identifier)

        withExtendedLifetime(first) {
            XCTAssertTrue(first.isPrimary)
            XCTAssertFalse(SingleInstanceGuard(identifier: identifier).isPrimary)
        }
    }

    func testDistinctIdentifiersDoNotContend() {
        let first = SingleInstanceGuard(identifier: identifier)
        let otherIdentifier = "\(identifier!)-other"
        let otherLockURL = SingleInstanceGuard.lockDirectory()
            .appendingPathComponent("\(otherIdentifier).lock")
        addTeardownBlock { try? FileManager.default.removeItem(at: otherLockURL) }
        let second = SingleInstanceGuard(identifier: otherIdentifier)

        withExtendedLifetime(first) {
            XCTAssertTrue(first.isPrimary)
            XCTAssertTrue(second.isPrimary)
        }

        withExtendedLifetime(second) {}
    }

    /// Releasing the primary must hand the lock back even though the lock file itself persists.
    func testReleasingThePrimaryLetsTheNextInstanceClaimIt() {
        do {
            let first = SingleInstanceGuard(identifier: identifier)
            XCTAssertTrue(first.isPrimary)
        }

        let second = SingleInstanceGuard(identifier: identifier)

        withExtendedLifetime(second) {
            XCTAssertTrue(second.isPrimary)
        }
    }
}
