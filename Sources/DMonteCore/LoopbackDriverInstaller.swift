import Foundation

/// Installs / removes the bundled BlackHole loopback driver for the Audio Router
/// tool. The driver ships inside the app's Resources (re-signed with our
/// Developer ID); installing copies it to the system HAL plug-in directory and
/// reloads `coreaudiod`, which requires admin rights — so the privileged steps
/// run through an `osascript` "with administrator privileges" prompt.
///
/// The shell/AppleScript construction is split into pure, unit-tested helpers;
/// only the actual `Process` execution touches the system.
public enum LoopbackDriverInstaller {

    /// The system directory CoreAudio loads HAL plug-ins from.
    public static let halPluginDirectory = "/Library/Audio/Plug-Ins/HAL"

    public enum InstallError: Error, Equatable {
        /// This build shipped without a bundled driver (e.g. `swift run`).
        case driverNotBundled
        /// The user dismissed the admin authorization prompt.
        case authorizationCancelled
        /// The privileged command exited non-zero.
        case commandFailed(Int32, String)

        public var message: String {
            switch self {
            case .driverNotBundled:
                return "No loopback driver is bundled in this build"
            case .authorizationCancelled:
                return "Installation cancelled"
            case .commandFailed(let status, let output):
                let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
                return detail.isEmpty ? "Install failed (status \(status))" : detail
            }
        }
    }

    // MARK: - Cable model

    /// One installable virtual cable from the bundled pool. Each is an
    /// independent BlackHole instance with its own device UID, so multiple can
    /// be installed and used simultaneously (e.g. one for Discord, one for Zoom).
    public struct LoopbackCable: Identifiable, Sendable, Equatable {
        /// Stable id = the driver bundle's base name, e.g. `DMonteCable1`.
        public let id: String
        /// Friendly label shown in our UI, e.g. `DMonte Cable 1`.
        public let displayName: String
        /// How the device appears to other apps (Discord/Zoom/…), e.g.
        /// `DMonte Cable 1` — the driver's `kDevice_Name` is built with the
        /// friendly spaced form.
        public let deviceName: String
        /// Location of the `.driver` bundle inside the app's Resources.
        public let driverURL: URL

        public var driverFileName: String { driverURL.lastPathComponent }

        public init(id: String, displayName: String, deviceName: String, driverURL: URL) {
            self.id = id
            self.displayName = displayName
            self.deviceName = deviceName
            self.driverURL = driverURL
        }
    }

    // MARK: - Discovery

    /// The directory in the app's Resources holding the bundled cable pool.
    static func cablesDirectory(in bundle: Bundle = .main) -> URL? {
        bundle.resourceURL?.appendingPathComponent("Cables", isDirectory: true)
    }

    /// Every virtual cable bundled with this build, sorted by index. Empty when
    /// the build shipped without a pool (e.g. `swift run`, or an offline build).
    public static func bundledCables(in bundle: Bundle = .main) -> [LoopbackCable] {
        guard let dir = cablesDirectory(in: bundle) else { return [] }
        return cables(inDirectory: dir)
    }

    /// Pure directory scan: every `*.driver` in `directory` mapped to a cable,
    /// natural-sorted by index. Non-driver entries are ignored.
    static func cables(inDirectory directory: URL) -> [LoopbackCable] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return urls
            .filter { $0.pathExtension == "driver" }
            .map { url in
                let driverID = url.deletingPathExtension().lastPathComponent
                let friendly = friendlyName(forDriverID: driverID)
                return LoopbackCable(
                    id: driverID,
                    displayName: friendly,
                    // The driver's kDevice_Name is the friendly form, so this is
                    // exactly how the cable appears in other apps' device menus.
                    deviceName: friendly,
                    driverURL: url
                )
            }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    /// Whether this build bundles any cables to install.
    public static func canManageCables(in bundle: Bundle = .main) -> Bool {
        !bundledCables(in: bundle).isEmpty
    }

    /// Where a cable's driver lands once installed.
    public static func installedURL(for cable: LoopbackCable) -> URL {
        URL(fileURLWithPath: halPluginDirectory).appendingPathComponent(cable.driverFileName)
    }

    /// Whether a specific cable is currently installed in the HAL directory.
    public static func isInstalled(_ cable: LoopbackCable) -> Bool {
        FileManager.default.fileExists(atPath: installedURL(for: cable).path)
    }

    /// Where a bundled driver would land once installed (used by the pure tests).
    public static func installedDriverURL(forBundled bundled: URL) -> URL {
        URL(fileURLWithPath: halPluginDirectory)
            .appendingPathComponent(bundled.lastPathComponent)
    }

    /// Turns a space-free driver id into a friendly label:
    /// `DMonteCable1` → `DMonte Cable 1`. Inserts a space at lower→upper and
    /// letter→digit boundaries.
    static func friendlyName(forDriverID driverID: String) -> String {
        var result = ""
        for character in driverID {
            if let last = result.last,
               (last.isLowercase && character.isUppercase) ||
               (last.isLetter && character.isNumber) {
                result.append(" ")
            }
            result.append(character)
        }
        return result
    }

    // MARK: - Command construction (pure)

    /// POSIX-single-quotes a path so it survives `/bin/sh` intact.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Shell that installs `source` (a `.driver`) into `destinationDirectory` and
    /// reloads CoreAudio.
    static func installShellCommand(
        source: String,
        destinationDirectory: String = halPluginDirectory
    ) -> String {
        let destination = destinationDirectory + "/" + (source as NSString).lastPathComponent
        return [
            "mkdir -p \(shellQuote(destinationDirectory))",
            "rm -rf \(shellQuote(destination))",
            "cp -R \(shellQuote(source)) \(shellQuote(destination))",
            "killall coreaudiod"
        ].joined(separator: " && ")
    }

    /// Shell that removes an installed driver and reloads CoreAudio.
    static func uninstallShellCommand(driverPath: String) -> String {
        "rm -rf \(shellQuote(driverPath)) && killall coreaudiod"
    }

    /// Wraps a shell command in an AppleScript that runs it with admin rights,
    /// escaping it for the AppleScript string literal.
    static func adminAppleScript(forShellCommand command: String) -> String {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    // MARK: - Execution

    @discardableResult
    static func runPrivileged(_ shellCommand: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", adminAppleScript(forShellCommand: shellCommand)]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()

        let errText = String(
            data: errPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        guard process.terminationStatus == 0 else {
            // osascript reports a user-dismissed auth dialog as error -128.
            if errText.contains("-128") || errText.localizedCaseInsensitiveContains("cancel") {
                throw InstallError.authorizationCancelled
            }
            throw InstallError.commandFailed(process.terminationStatus, errText)
        }
        return String(
            data: outPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
    }

    // MARK: - Public actions

    /// Copies a cable's driver into the HAL directory and reloads CoreAudio.
    /// Blocks on the admin prompt — call off the main thread.
    public static func install(_ cable: LoopbackCable) throws {
        guard FileManager.default.fileExists(atPath: cable.driverURL.path) else {
            throw InstallError.driverNotBundled
        }
        try runPrivileged(installShellCommand(source: cable.driverURL.path))
    }

    /// Removes an installed cable's driver and reloads CoreAudio.
    public static func uninstall(_ cable: LoopbackCable) throws {
        try runPrivileged(uninstallShellCommand(driverPath: installedURL(for: cable).path))
    }
}
