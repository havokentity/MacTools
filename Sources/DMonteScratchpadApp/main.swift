import AppKit
import DMonteCore

let singleInstanceGuard = SingleInstanceGuard(identifier: "com.havokentity.mactools.scratchpad")

guard singleInstanceGuard.isPrimary else {
    if CommandLine.arguments.contains("--open") {
        DistributedNotificationCenter.default().postNotificationName(
            ScratchpadNotifications.showWindow,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    exit(EXIT_SUCCESS)
}

let app = NSApplication.shared
let delegate = ScratchpadAppDelegate()

app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
