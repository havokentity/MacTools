import XCTest
@testable import DMonteCore

/// Tests for the pure command/escaping logic behind the loopback-driver install.
/// The privileged `osascript` execution itself isn't exercised here; these lock
/// down the shell and AppleScript strings so the admin step is safe and correct.
final class LoopbackDriverInstallerTests: XCTestCase {

    func testShellQuoteWrapsSimplePath() {
        XCTAssertEqual(
            LoopbackDriverInstaller.shellQuote("/Library/Audio/Plug-Ins/HAL"),
            "'/Library/Audio/Plug-Ins/HAL'"
        )
    }

    func testShellQuoteEscapesEmbeddedSingleQuotes() {
        // A path containing a single quote must be split-and-escaped so it can't
        // break out of the quoting (defends against odd .app names).
        XCTAssertEqual(
            LoopbackDriverInstaller.shellQuote("/Users/a'b/Driver.driver"),
            "'/Users/a'\\''b/Driver.driver'"
        )
    }

    func testInstallShellCommandTargetsHALAndReloadsCoreAudio() {
        let command = LoopbackDriverInstaller.installShellCommand(
            source: "/Apps/Tool.app/Contents/Resources/BlackHole.driver"
        )
        XCTAssertTrue(command.contains("mkdir -p '/Library/Audio/Plug-Ins/HAL'"))
        XCTAssertTrue(command.contains("cp -R '/Apps/Tool.app/Contents/Resources/BlackHole.driver' '/Library/Audio/Plug-Ins/HAL/BlackHole.driver'"))
        XCTAssertTrue(command.contains("rm -rf '/Library/Audio/Plug-Ins/HAL/BlackHole.driver'"))
        XCTAssertTrue(command.hasSuffix("killall coreaudiod"))
        // rm must precede cp so a stale copy is replaced cleanly.
        let rmRange = command.range(of: "rm -rf")!
        let cpRange = command.range(of: "cp -R")!
        XCTAssertTrue(rmRange.lowerBound < cpRange.lowerBound)
    }

    func testUninstallShellCommandRemovesAndReloads() {
        let command = LoopbackDriverInstaller.uninstallShellCommand(
            driverPath: "/Library/Audio/Plug-Ins/HAL/BlackHole.driver"
        )
        XCTAssertEqual(
            command,
            "rm -rf '/Library/Audio/Plug-Ins/HAL/BlackHole.driver' && killall coreaudiod"
        )
    }

    func testAdminAppleScriptEscapesQuotesAndRequestsPrivileges() {
        let script = LoopbackDriverInstaller.adminAppleScript(forShellCommand: "echo \"hi\"")
        XCTAssertTrue(script.hasPrefix("do shell script \""))
        XCTAssertTrue(script.hasSuffix("\" with administrator privileges"))
        // The inner double quotes must be backslash-escaped for the AppleScript literal.
        XCTAssertTrue(script.contains("echo \\\"hi\\\""))
    }

    func testInstalledDriverURLLandsInHAL() {
        let bundled = URL(fileURLWithPath: "/Apps/Tool.app/Contents/Resources/BlackHole.driver")
        let installed = LoopbackDriverInstaller.installedDriverURL(forBundled: bundled)
        XCTAssertEqual(installed.path, "/Library/Audio/Plug-Ins/HAL/BlackHole.driver")
    }

    // MARK: - Cable pool

    func testFriendlyNameInsertsSpacesAtBoundaries() {
        XCTAssertEqual(LoopbackDriverInstaller.friendlyName(forDriverID: "DMonteCable1"), "DMonte Cable 1")
        XCTAssertEqual(LoopbackDriverInstaller.friendlyName(forDriverID: "DMonteCable12"), "DMonte Cable 12")
    }

    func testInstalledURLForCableLandsInHAL() {
        let cable = LoopbackDriverInstaller.LoopbackCable(
            id: "DMonteCable3",
            displayName: "DMonte Cable 3",
            deviceName: "DMonteCable3 2ch",
            driverURL: URL(fileURLWithPath: "/Apps/Tool.app/Contents/Resources/Cables/DMonteCable3.driver")
        )
        XCTAssertEqual(
            LoopbackDriverInstaller.installedURL(for: cable).path,
            "/Library/Audio/Plug-Ins/HAL/DMonteCable3.driver"
        )
    }

    func testCablesInDirectoryEnumeratesSortsAndIgnoresNonDrivers() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("LoopbackTest-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        // Out-of-order indices + a non-driver entry that must be ignored.
        for name in ["DMonteCable2.driver", "DMonteCable10.driver", "DMonteCable1.driver", "notes.txt"] {
            try fm.createDirectory(at: dir.appendingPathComponent(name), withIntermediateDirectories: true)
        }

        let found = LoopbackDriverInstaller.cables(inDirectory: dir)
        // Natural sort: 1, 2, 10 (not lexical 1, 10, 2).
        XCTAssertEqual(found.map(\.id), ["DMonteCable1", "DMonteCable2", "DMonteCable10"])
        XCTAssertEqual(found.first?.deviceName, "DMonte Cable 1")
        XCTAssertEqual(found.first?.displayName, "DMonte Cable 1")
    }

    func testCablesInDirectoryReturnsEmptyForMissingDirectory() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)")
        XCTAssertEqual(LoopbackDriverInstaller.cables(inDirectory: missing), [])
    }

    func testInstallErrorMessagesAreNonEmpty() {
        XCTAssertFalse(LoopbackDriverInstaller.InstallError.driverNotBundled.message.isEmpty)
        XCTAssertFalse(LoopbackDriverInstaller.InstallError.authorizationCancelled.message.isEmpty)
        XCTAssertFalse(LoopbackDriverInstaller.InstallError.commandFailed(1, "boom").message.isEmpty)
    }

    func testCommandFailedSurfacesOutputDetail() {
        let error = LoopbackDriverInstaller.InstallError.commandFailed(1, "  disk full  ")
        XCTAssertEqual(error.message, "disk full")
    }
}
