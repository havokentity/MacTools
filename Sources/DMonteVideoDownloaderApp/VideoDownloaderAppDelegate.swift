import AppKit
import DMonteCore
import SwiftUI

@MainActor
final class VideoDownloaderAppDelegate: NSObject, NSApplicationDelegate {
    private var windowHost: HelperWindowHost?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDefaults.registerDefaults()
        VideoDownloaderNotifications.requestAuthorization()

        let host = HelperWindowHost(
            configuration: HelperWindowHost.Configuration(
                title: "Download Video",
                sizing: .fixed(preferredSize: { VideoDownloaderSizing.preferredSize() })
            ),
            makeContent: { [weak self] in
                NSHostingController(
                    rootView: VideoDownloaderWindowView(
                        onQuit: {
                            self?.quitVideoDownloader()
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
        host.observeShowNotification(named: HelperNotifications.showVideoDownloaderWindow)

        DispatchQueue.main.async { [weak self] in
            self?.windowHost?.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        VideoDownloaderProcesses.terminateAll()
        windowHost?.tearDownForTermination()
    }

    private func quitVideoDownloader() {
        NSApp.terminate(nil)
    }
}
