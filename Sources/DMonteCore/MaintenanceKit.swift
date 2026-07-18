import Foundation

/// Pure (AppKit-free) maintenance logic: shell + defaults helpers and a
/// data-driven description of the actions/toggles the UI renders.
///
/// All helpers here are `nonisolated` so they can be invoked from
/// `Task.detached` background work without touching the main actor. The UI
/// layer is responsible for hopping back to `@MainActor` to publish results.
public enum MaintenanceKit {

    // MARK: - Shell

    /// Runs an executable synchronously and returns its exit status plus the
    /// combined trimmed stdout/stderr.
    ///
    /// This is intentionally synchronous and `nonisolated`; call it from a
    /// background `Task.detached` and marshal the result back to the main
    /// actor for UI updates.
    public nonisolated static func runShell(_ launchPath: String, _ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return (status: -1, output: "Failed to launch \(launchPath): \(error.localizedDescription)")
        }

        // Drain the single combined pipe while the process is still running so
        // a noisy stderr stream cannot fill its pipe and block the child.
        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return (status: process.terminationStatus, output: output)
    }

    // MARK: - Privileged shell (GUI password prompt)

    /// Runs a shell command with administrator privileges using AppleScript so
    /// macOS shows its native authentication dialog. Returns `true` on success.
    ///
    /// If the user cancels the prompt, or the command fails, this returns
    /// `false` along with a human-readable message. Execution goes through an
    /// `osascript` subprocess rather than in-process `NSAppleScript`: OSA is not
    /// thread safe, and this runs off the main actor.
    public nonisolated static func runAdminScript(_ command: String) -> (success: Bool, message: String) {
        let result = runShell("/usr/bin/osascript", ["-e", adminAppleScript(forShellCommand: command)])
        guard result.status == 0 else {
            // osascript reports a user-dismissed auth dialog as error -128.
            if result.output.contains("-128") || result.output.localizedCaseInsensitiveContains("cancel") {
                return (false, "Cancelled.")
            }
            return (false, result.output.isEmpty ? "The command failed." : result.output)
        }
        return (true, "Done.")
    }

    /// Wraps a shell command in an AppleScript that runs it with admin rights,
    /// escaping it for the AppleScript string literal.
    public nonisolated static func adminAppleScript(forShellCommand command: String) -> String {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    // MARK: - Defaults

    /// Reads a boolean from the macOS defaults system, distinguishing a key that
    /// has never been written (`nil`) from one explicitly set to `false`. Treats
    /// common truthy representations ("1", "true", "yes") as `true`.
    public nonisolated static func readDefaultsBoolIfPresent(domain: String, key: String) -> Bool? {
        let result = runShell("/usr/bin/defaults", ["read", domain, key])
        guard result.status == 0 else { return nil }
        let value = result.output.lowercased()
        return value == "1" || value == "true" || value == "yes"
    }

    /// Reads a boolean from the macOS defaults system. Treats common truthy
    /// representations ("1", "true", "yes") as `true`. Missing keys read as
    /// `false`.
    public nonisolated static func readDefaultsBool(domain: String, key: String) -> Bool {
        readDefaultsBoolIfPresent(domain: domain, key: key) ?? false
    }

    /// Current on/off state of a toggle: the written value if the key exists,
    /// otherwise the value macOS behaves as if set.
    public nonisolated static func currentValue(of toggle: MaintenanceToggle) -> Bool {
        readDefaultsBoolIfPresent(domain: toggle.domain, key: toggle.key) ?? toggle.defaultWhenMissing
    }

    /// Writes a boolean to the macOS defaults system. Returns `true` on success.
    @discardableResult
    public nonisolated static func writeDefaultsBool(domain: String, key: String, value: Bool) -> Bool {
        let result = runShell("/usr/bin/defaults", ["write", domain, key, "-bool", value ? "YES" : "NO"])
        return result.status == 0
    }

    /// Deletes a defaults key. Used primarily for cleanup in tests. Returns
    /// `true` on success.
    @discardableResult
    public nonisolated static func deleteDefaults(domain: String, key: String) -> Bool {
        let result = runShell("/usr/bin/defaults", ["delete", domain, key])
        return result.status == 0
    }

    /// Restarts a process by name (e.g. "Finder", "Dock"). Best-effort: a
    /// non-zero exit usually means the process was not running, which is fine.
    @discardableResult
    public nonisolated static func killall(_ processName: String) -> (status: Int32, output: String) {
        return runShell("/usr/bin/killall", [processName])
    }

    /// Locates the `lsregister` tool. The canonical path has been stable for
    /// many macOS releases, but we still verify and fall back to a search.
    public nonisolated static func lsregisterPath() -> String? {
        let canonical = "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
        if FileManager.default.isExecutableFile(atPath: canonical) {
            return canonical
        }
        // Fallback: try to locate it relative to the CoreServices framework.
        let alt = runShell("/usr/bin/find",
                           ["/System/Library/Frameworks/CoreServices.framework",
                            "-name", "lsregister", "-type", "f"])
        if alt.status == 0 {
            let firstLine = alt.output.split(separator: "\n").first.map(String.init)
            if let path = firstLine, FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    // MARK: - Domains / keys

    public enum Domain {
        public static let finder = "com.apple.finder"
        public static let globalDomain = "NSGlobalDomain"
    }

    // MARK: - Data-driven action model

    /// A toggle row: reads and writes a boolean default, optionally restarting
    /// a process to apply the change.
    public struct MaintenanceToggle: Identifiable, Sendable {
        public let id: String
        public let title: String
        public let subtitle: String
        public let domain: String
        public let key: String
        /// Process to restart after the toggle changes (nil = none).
        public let restartProcess: String?
        /// How macOS behaves when the key has never been written. Most defaults
        /// are off until set, but some (Finder's `CreateDesktop`) are on.
        public let defaultWhenMissing: Bool

        public init(id: String, title: String, subtitle: String, domain: String, key: String, restartProcess: String?, defaultWhenMissing: Bool = false) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.domain = domain
            self.key = key
            self.restartProcess = restartProcess
            self.defaultWhenMissing = defaultWhenMissing
        }
    }

    /// An action row: performs a one-shot operation when its button is pressed.
    public struct MaintenanceAction: Identifiable, Sendable {
        public enum Kind: Sendable {
            case killall(process: String)        // restart a process by name
            case admin(command: String)          // privileged shell via GUI prompt
            case lsregister                       // rebuild Launch Services
            case openPath(path: String)           // open a path in Finder
        }

        public let id: String
        public let title: String
        public let subtitle: String
        public let buttonLabel: String
        public let kind: Kind
        /// Whether running this action may take a while (UI shows a spinner).
        public let isSlow: Bool

        public init(id: String, title: String, subtitle: String, buttonLabel: String, kind: Kind, isSlow: Bool = false) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.buttonLabel = buttonLabel
            self.kind = kind
            self.isSlow = isSlow
        }
    }

    /// Logical grouping for the UI.
    public struct MaintenanceSection: Identifiable, Sendable {
        public let id: String
        public let title: String
        public let toggles: [MaintenanceToggle]
        public let actions: [MaintenanceAction]

        public init(id: String, title: String, toggles: [MaintenanceToggle], actions: [MaintenanceAction]) {
            self.id = id
            self.title = title
            self.toggles = toggles
            self.actions = actions
        }
    }

    // MARK: - Catalog

    /// The full, ordered set of sections the popover renders. Defined once here
    /// so the UI stays purely presentational.
    public static var sections: [MaintenanceSection] {
        [
            MaintenanceSection(
                id: "finder",
                title: "Finder",
                toggles: [
                    MaintenanceToggle(
                        id: "hidden-files",
                        title: "Show hidden files",
                        subtitle: "Reveal dotfiles in Finder",
                        domain: Domain.finder,
                        key: "AppleShowAllFiles",
                        restartProcess: "Finder"),
                    MaintenanceToggle(
                        id: "all-extensions",
                        title: "Show all file extensions",
                        subtitle: "Never hide a file's extension",
                        domain: Domain.globalDomain,
                        key: "AppleShowAllExtensions",
                        restartProcess: "Finder"),
                    MaintenanceToggle(
                        id: "desktop-icons",
                        title: "Show desktop icons",
                        subtitle: "Toggle icons on the Desktop",
                        domain: Domain.finder,
                        key: "CreateDesktop",
                        restartProcess: "Finder",
                        defaultWhenMissing: true),
                    MaintenanceToggle(
                        id: "posix-path",
                        title: "Show full path in title",
                        subtitle: "Display the POSIX path in Finder windows",
                        domain: Domain.finder,
                        key: "_FXShowPosixPathInTitle",
                        restartProcess: "Finder")
                ],
                actions: [
                    MaintenanceAction(
                        id: "restart-finder",
                        title: "Restart Finder",
                        subtitle: "Relaunch the Finder process",
                        buttonLabel: "Restart",
                        kind: .killall(process: "Finder")),
                    MaintenanceAction(
                        id: "open-library",
                        title: "Show ~/Library in Finder",
                        subtitle: "Open your user Library folder",
                        buttonLabel: "Open",
                        kind: .openPath(path: (NSHomeDirectory() as NSString).appendingPathComponent("Library")))
                ]
            ),
            MaintenanceSection(
                id: "system",
                title: "System",
                toggles: [],
                actions: [
                    MaintenanceAction(
                        id: "restart-dock",
                        title: "Restart Dock",
                        subtitle: "Relaunch the Dock and Mission Control",
                        buttonLabel: "Restart",
                        kind: .killall(process: "Dock")),
                    MaintenanceAction(
                        id: "restart-menubar",
                        title: "Restart Menu Bar",
                        subtitle: "Relaunch SystemUIServer",
                        buttonLabel: "Restart",
                        kind: .killall(process: "SystemUIServer")),
                    MaintenanceAction(
                        id: "flush-dns",
                        title: "Flush DNS cache",
                        subtitle: "Requires your administrator password",
                        buttonLabel: "Flush",
                        kind: .admin(command: "dscacheutil -flushcache; killall -HUP mDNSResponder")),
                    MaintenanceAction(
                        id: "rebuild-launch-services",
                        title: "Rebuild \u{201C}Open With\u{201D} menu",
                        subtitle: "Reset Launch Services database",
                        buttonLabel: "Rebuild",
                        kind: .lsregister,
                        isSlow: true)
                ]
            )
        ]
    }
}
