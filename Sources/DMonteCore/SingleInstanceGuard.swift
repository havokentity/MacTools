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
        let lockURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(safeIdentifier).lock")

        let descriptor = lockURL.path.withCString { path in
            Darwin.open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        }

        guard descriptor >= 0 else {
            fileDescriptor = -1
            isPrimary = true
            return
        }

        fileDescriptor = descriptor
        isPrimary = flock(descriptor, LOCK_EX | LOCK_NB) == 0
    }

    deinit {
        guard fileDescriptor >= 0 else {
            return
        }

        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
    }
}
