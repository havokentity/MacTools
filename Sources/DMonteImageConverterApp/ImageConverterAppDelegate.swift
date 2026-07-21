import AppKit
import DMonteCore
import SwiftUI

@MainActor
final class ImageConverterAppDelegate: NSObject, NSApplicationDelegate {
    private var windowHost: HelperWindowHost?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDefaults.registerDefaults()

        // Without a main menu, AppKit never matches ⌘C/⌘V/⌘A/⌘Z, so they are dead in
        // this tool's text fields. The menu is never drawn; it exists for the shortcuts.
        HelperMainMenu.installEditMenuIfNeeded()

        let host = HelperWindowHost(
            configuration: HelperWindowHost.Configuration(
                title: "Image Converter",
                sizing: .fixed(preferredSize: { ImageConverterSizing.preferredSize() })
            ),
            makeContent: { [weak self] in
                NSHostingController(
                    rootView: ImageConverterWindowView(
                        onQuit: {
                            self?.quitImageConverter()
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
        host.observeShowNotification(named: imageConverterShowWindowNotification)

        DispatchQueue.main.async { [weak self] in
            self?.windowHost?.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowHost?.tearDownForTermination()
    }

    private func quitImageConverter() {
        NSApp.terminate(nil)
    }
}
