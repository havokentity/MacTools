import AppKit
import DMonteCore

let singleInstanceGuard = SingleInstanceGuard(identifier: "com.havokentity.mactools.snippets")

guard singleInstanceGuard.isPrimary else {
    if CommandLine.arguments.contains("--open") {
        DistributedNotificationCenter.default().postNotificationName(
            SnippetsNotifications.showWindow,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    exit(EXIT_SUCCESS)
}

let app = NSApplication.shared
let delegate = SnippetsAppDelegate()

app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
