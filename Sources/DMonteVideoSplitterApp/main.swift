import AppKit
import DMonteCore

/// The distributed-notification this helper posts (when re-launched with `--open` while
/// already running) and observes (in its delegate) to reveal its window. Matches the
/// toolbox convention of `<bundleID>.showWindow`.
let videoSplitterShowWindowNotification = Notification.Name("com.havokentity.mactools.videosplitter.showWindow")

let singleInstanceGuard = SingleInstanceGuard(identifier: "com.havokentity.mactools.videosplitter")

guard singleInstanceGuard.isPrimary else {
    if CommandLine.arguments.contains("--open") {
        DistributedNotificationCenter.default().postNotificationName(
            videoSplitterShowWindowNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    exit(EXIT_SUCCESS)
}

let app = NSApplication.shared
let delegate = VideoSplitterAppDelegate()

app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
