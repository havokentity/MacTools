import AppKit
import DMonteCore

let singleInstanceGuard = SingleInstanceGuard(identifier: "com.havokentity.mactools.fileshelf")

guard singleInstanceGuard.isPrimary else {
    if CommandLine.arguments.contains("--open") {
        DistributedNotificationCenter.default().postNotificationName(
            FileShelfNotifications.showWindow,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    exit(EXIT_SUCCESS)
}

let app = NSApplication.shared
let delegate = FileShelfAppDelegate()

app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
