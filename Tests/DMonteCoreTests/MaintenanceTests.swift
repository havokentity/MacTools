import XCTest
@testable import DMonteCore

final class MaintenanceTests: XCTestCase {

    /// `defaults` accepts a plist PATH in place of a domain name, and that form
    /// bypasses cfprefsd entirely — it edits the file directly.
    ///
    /// A named domain cannot be used here, for two separate reasons, both
    /// measured:
    ///
    /// 1. cfprefsd applies a write asynchronously, so `defaults write` exits 0
    ///    before the value is readable; the very next `defaults read` then
    ///    reports "the domain/default pair does not exist" and the assertion
    ///    fails. Roughly one run in three locally.
    /// 2. A named domain is shared process-wide, so two concurrent `swift test`
    ///    runs — parallel worktrees, or a local run alongside CI on the same
    ///    machine — write and delete the same key underneath each other.
    ///    Reproduced at one to seven failures per run.
    ///
    /// A per-test temp file fixes both: it bypasses cfprefsd, and the UUID in
    /// the path gives every run its own domain. It also keeps the suite out of
    /// the real preferences directory, so a test run leaves nothing behind on
    /// the machine.
    private var testDomain = ""
    private let testKey = "MaintenanceUnitTestFlag"
    private var tempDirectory: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("MaintenanceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectory = directory
        testDomain = directory.appendingPathComponent("defaults.plist").path
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        try super.tearDownWithError()
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

    // MARK: - missing vs. explicitly false

    func testReadDefaultsBoolIfPresentDistinguishesMissingFromFalse() {
        _ = MaintenanceKit.deleteDefaults(domain: testDomain, key: testKey)
        XCTAssertNil(MaintenanceKit.readDefaultsBoolIfPresent(domain: testDomain, key: testKey))

        XCTAssertTrue(MaintenanceKit.writeDefaultsBool(domain: testDomain, key: testKey, value: false))
        XCTAssertEqual(MaintenanceKit.readDefaultsBoolIfPresent(domain: testDomain, key: testKey), false)

        XCTAssertTrue(MaintenanceKit.writeDefaultsBool(domain: testDomain, key: testKey, value: true))
        XCTAssertEqual(MaintenanceKit.readDefaultsBoolIfPresent(domain: testDomain, key: testKey), true)
    }

    func testCurrentValueUsesDefaultOnlyWhenKeyIsMissing() {
        let toggle = MaintenanceKit.MaintenanceToggle(
            id: "test",
            title: "Test",
            subtitle: "Test",
            domain: testDomain,
            key: testKey,
            restartProcess: nil,
            defaultWhenMissing: true)

        _ = MaintenanceKit.deleteDefaults(domain: testDomain, key: testKey)
        XCTAssertTrue(MaintenanceKit.currentValue(of: toggle))

        // An explicit false must win over the true-by-default fallback.
        XCTAssertTrue(MaintenanceKit.writeDefaultsBool(domain: testDomain, key: testKey, value: false))
        XCTAssertFalse(MaintenanceKit.currentValue(of: toggle))
    }

    func testDesktopIconsToggleIsOnByDefault() {
        let toggles = MaintenanceKit.sections.flatMap(\.toggles)
        guard let desktopIcons = toggles.first(where: { $0.id == "desktop-icons" }) else {
            return XCTFail("Expected a desktop-icons toggle in the catalog")
        }
        // Finder shows desktop icons until CreateDesktop is written, so an unset
        // key must read as On.
        XCTAssertTrue(desktopIcons.defaultWhenMissing)

        // Every other toggle is off until its key is written.
        for toggle in toggles where toggle.id != "desktop-icons" {
            XCTAssertFalse(toggle.defaultWhenMissing, "\(toggle.id) should default to off")
        }
    }

    // MARK: - admin AppleScript

    func testAdminAppleScriptEscapesQuotesAndRequestsPrivileges() {
        let script = MaintenanceKit.adminAppleScript(forShellCommand: "echo \"hi\"")
        XCTAssertTrue(script.hasPrefix("do shell script \""))
        XCTAssertTrue(script.hasSuffix("\" with administrator privileges"))
        // The inner double quotes must be backslash-escaped for the AppleScript literal.
        XCTAssertTrue(script.contains("echo \\\"hi\\\""))
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
