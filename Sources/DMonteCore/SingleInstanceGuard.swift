import Darwin
import Foundation

public enum HelperNotifications {
    public static let showToolboxWindow = Notification.Name("com.havokentity.mactools.toolbox.showWindow")
    public static let showSystemMonitorWindow = Notification.Name("com.havokentity.mactools.systemmonitor.showWindow")
    public static let showUninstallerWindow = Notification.Name("com.havokentity.mactools.uninstaller.showWindow")
    public static let showCleanDriveWindow = Notification.Name("com.havokentity.mactools.cleandrive.showWindow")
    public static let showVideoDownloaderWindow = Notification.Name("com.havokentity.mactools.videodownloader.showWindow")
    public static let showDiskAnalyzerWindow = Notification.Name("com.havokentity.mactools.diskanalyzer.showWindow")
    public static let showClipboardWindow = Notification.Name("com.havokentity.mactools.clipboard.showWindow")
}

public final class SingleInstanceGuard {
    public let isPrimary: Bool

    private let fileDescriptor: Int32

    public init(identifier: String) {
        let safeIdentifier = identifier
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let lockURL = Self.lockDirectory().appendingPathComponent("\(safeIdentifier).lock")

        let descriptor = lockURL.path.withCString { path in
            Darwin.open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        }

        guard descriptor >= 0 else {
            fileDescriptor = -1
            isPrimary = true
            return
        }

        fileDescriptor = descriptor

        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            isPrimary = true
        } else {
            // EWOULDBLOCK is the only answer that means "another instance holds it". Anything
            // else means the lock itself could not be taken — flock is unsupported on some
            // network-mounted homes, which Application Support (unlike the always-local
            // temporary directory) can live on. Fail open there, matching the open() failure
            // path above: a theoretical second instance beats refusing to launch at all.
            isPrimary = errno != EWOULDBLOCK
        }
    }

    /// Locks live in Application Support rather than the temporary directory: macOS reaps
    /// per-user temp files that go untouched for a few days, and helpers routinely run for
    /// weeks. Reaping unlinks the path without releasing the primary's flock (held on the
    /// inode), so the next instance would create a fresh inode, lock it unopposed and also
    /// consider itself primary.
    static func lockDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let directory = base
            .appendingPathComponent("DMonteTools", isDirectory: true)
            .appendingPathComponent("Locks", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        return directory
    }

    deinit {
        guard fileDescriptor >= 0 else {
            return
        }

        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
    }
}
