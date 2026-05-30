import AppKit
import DMonteCore

// Single-instance enforcement. If another copy is already running, re-post the
// show-window notification (so the existing instance reveals its popover) and
// exit. Mirrors the CleanDrive launcher.
let guardInstance = SingleInstanceGuard(identifier: "com.havokentity.mactools.maintenance")

if !guardInstance.isPrimary {
    if CommandLine.arguments.contains("--open") {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.havokentity.mactools.maintenance.showWindow"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = MaintenanceAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
