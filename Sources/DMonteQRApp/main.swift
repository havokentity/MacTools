import AppKit
import DMonteCore

/// The distributed-notification this helper posts (when re-launched with `--open` while
/// already running) and observes (in its delegate) to reveal its window. Matches the
/// toolbox convention of `<bundleID>.showWindow`.
let qrShowWindowNotification = Notification.Name("com.havokentity.mactools.qr.showWindow")

let singleInstanceGuard = SingleInstanceGuard(identifier: "com.havokentity.mactools.qr")

guard singleInstanceGuard.isPrimary else {
    if CommandLine.arguments.contains("--open") {
        DistributedNotificationCenter.default().postNotificationName(
            qrShowWindowNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    exit(EXIT_SUCCESS)
}

let app = NSApplication.shared
let delegate = QRAppDelegate()

app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
