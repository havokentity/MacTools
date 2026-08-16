import AppKit
import DMonteCore
import SwiftUI

@MainActor
final class VideoSplitterAppDelegate: NSObject, NSApplicationDelegate {
    private var windowHost: HelperWindowHost?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDefaults.registerDefaults()

        // Without a main menu, AppKit never matches ⌘C/⌘V/⌘A/⌘Z, so they are dead in
        // this tool's text fields. The menu is never drawn; it exists for the shortcuts.
        HelperMainMenu.installEditMenuIfNeeded()

        let host = HelperWindowHost(
            configuration: HelperWindowHost.Configuration(
                title: "Video Splitter",
                sizing: .fixed(preferredSize: { VideoSplitterSizing.preferredSize() })
            ),
            makeContent: { [weak self] in
                NSHostingController(
                    rootView: VideoSplitterWindowView(
                        onQuit: {
                            self?.quitVideoSplitter()
                        }
                    )
                )
            },
            onUserClosedWindow: {
                NSApp.terminate(nil)
            }
        )
        windowHost = host
        host.configureWindow()
        host.observeShowNotification(named: videoSplitterShowWindowNotification)

        DispatchQueue.main.async { [weak self] in
            self?.windowHost?.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowHost?.tearDownForTermination()
    }

    private func quitVideoSplitter() {
        NSApp.terminate(nil)
    }
}
