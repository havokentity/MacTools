import AppKit
import DMonteCore

let singleInstanceGuard = SingleInstanceGuard(identifier: "com.havokentity.mactools.clipboard")

guard singleInstanceGuard.isPrimary else {
    if CommandLine.arguments.contains("--open") {
        DistributedNotificationCenter.default().postNotificationName(
            HelperNotifications.showClipboardWindow,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    exit(EXIT_SUCCESS)
}

let app = NSApplication.shared
let delegate = ClipboardAppDelegate()

app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
