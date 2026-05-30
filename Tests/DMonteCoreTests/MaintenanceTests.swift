import XCTest
@testable import DMonteCore

final class MaintenanceTests: XCTestCase {

    /// A throwaway defaults domain so tests never touch real system settings.
    private let testDomain = "com.havokentity.mactools.maintenancetest"
    private let testKey = "MaintenanceUnitTestFlag"

    override func tearDown() {
        // Ensure no test residue is left behind.
        _ = MaintenanceKit.deleteDefaults(domain: testDomain, key: testKey)
        super.tearDown()
    }

    // MARK: - runShell

    func testRunShellEchoSucceeds() {
        let result = MaintenanceKit.runShell("/bin/echo", ["hello"])
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("hello"),
                      "Expected output to contain 'hello', got: \(result.output)")
    }

    func testRunShellNonexistentLaunchPathFails() {
        let result = MaintenanceKit.runShell("/definitely/not/a/real/binary", [])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertFalse(result.output.isEmpty)
    }

    // MARK: - defaults round-trip

    func testWriteAndReadDefaultsBoolTrue() {
        XCTAssertTrue(MaintenanceKit.writeDefaultsBool(domain: testDomain, key: testKey, value: true))
        XCTAssertTrue(MaintenanceKit.readDefaultsBool(domain: testDomain, key: testKey))
    }

    func testWriteAndReadDefaultsBoolFalse() {
        XCTAssertTrue(MaintenanceKit.writeDefaultsBool(domain: testDomain, key: testKey, value: false))
        XCTAssertFalse(MaintenanceKit.readDefaultsBool(domain: testDomain, key: testKey))
    }

    func testDefaultsBoolFullCycle() {
        XCTAssertTrue(MaintenanceKit.writeDefaultsBool(domain: testDomain, key: testKey, value: true))
        XCTAssertTrue(MaintenanceKit.readDefaultsBool(domain: testDomain, key: testKey))

        XCTAssertTrue(MaintenanceKit.writeDefaultsBool(domain: testDomain, key: testKey, value: false))
        XCTAssertFalse(MaintenanceKit.readDefaultsBool(domain: testDomain, key: testKey))

        XCTAssertTrue(MaintenanceKit.deleteDefaults(domain: testDomain, key: testKey))
        // Missing key reads as false.
        XCTAssertFalse(MaintenanceKit.readDefaultsBool(domain: testDomain, key: testKey))
    }

    func testReadMissingDefaultsKeyReturnsFalse() {
        // Make sure the key does not exist first.
        _ = MaintenanceKit.deleteDefaults(domain: testDomain, key: testKey)
        XCTAssertFalse(MaintenanceKit.readDefaultsBool(domain: testDomain, key: testKey))
    }

    // MARK: - lsregister discovery (non-destructive)

    func testLsregisterPathIsExecutableOrNil() {
        // We only verify the contract: if a path is returned, it is executable.
        if let path = MaintenanceKit.lsregisterPath() {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path),
                          "lsregisterPath returned a non-executable path: \(path)")
        }
    }

    // MARK: - catalog integrity

    func testSectionsAreNonEmptyAndIDsUnique() {
        let sections = MaintenanceKit.sections
        XCTAssertFalse(sections.isEmpty)

        var ids = Set<String>()
        for section in sections {
            for toggle in section.toggles {
                XCTAssertTrue(ids.insert(toggle.id).inserted, "Duplicate id: \(toggle.id)")
                XCTAssertFalse(toggle.title.isEmpty)
                XCTAssertFalse(toggle.key.isEmpty)
            }
            for action in section.actions {
                XCTAssertTrue(ids.insert(action.id).inserted, "Duplicate id: \(action.id)")
                XCTAssertFalse(action.title.isEmpty)
                XCTAssertFalse(action.buttonLabel.isEmpty)
            }
        }
    }
}
