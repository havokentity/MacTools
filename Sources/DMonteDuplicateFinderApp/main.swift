import AppKit
import DMonteCore

let singleInstanceGuard = SingleInstanceGuard(identifier: "com.havokentity.mactools.duplicatefinder")

guard singleInstanceGuard.isPrimary else {
    if CommandLine.arguments.contains("--open") {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.havokentity.mactools.duplicatefinder.showWindow"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    exit(EXIT_SUCCESS)
}

let app = NSApplication.shared
let delegate = DuplicateFinderAppDelegate()

app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
