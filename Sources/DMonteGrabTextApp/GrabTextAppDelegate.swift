import AppKit
import DMonteCore
import SwiftUI

@MainActor
final class GrabTextAppDelegate: NSObject, NSApplicationDelegate {
    private let controller = GrabTextController()

    private var statusItem: HelperStatusItem?
    private var windowHost: HelperWindowHost?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDefaults.registerDefaults()

        let host = HelperWindowHost(
            configuration: HelperWindowHost.Configuration(
                title: "DMonte Grab Text",
                sizing: .fixed(preferredSize: { GrabTextSizing.preferredSize() })
            ),
            makeContent: { [controller, weak self] in
                NSHostingController(
                    rootView: GrabTextWindowView(
                        controller: controller,
                        onQuit: {
                            self?.quitGrabText()
                        }
                    )
                )
            },
            onUserClosedWindow: { [weak self] in
                if self?.statusItem == nil {
                    NSApp.terminate(nil)
                }
            }
        )
        windowHost = host
        host.configureWindow()

        let icon = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: "Grab Text") ?? NSImage()
        statusItem = HelperStatusItem(
            image: icon,
            toolTip: "Grab Text",
            primaryAction: { [weak self] in
                self?.windowHost?.show(relativeTo: self?.statusItem?.button)
            },
            quitAction: { [weak self] in self?.quitGrabText() }
        )

        host.observeShowNotification(named: grabTextShowWindowNotification)

        // A hotkey grab deliberately leaves the window closed — that is the point of the shortcut.
        // It only comes forward when the result needs the user: a failure, a missing permission, or
        // recognized text that "copy automatically" was off for and would otherwise be lost.
        controller.onHotKeyResultNeedsAttention = { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.windowHost?.show(relativeTo: self?.statusItem?.button)
        }
        controller.registerHotKey()

        if CommandLine.arguments.contains("--open") || statusItem == nil {
            DispatchQueue.main.async { [weak self] in
                self?.windowHost?.show()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.unregisterHotKey()
        windowHost?.tearDownForTermination()
        statusItem?.remove()
    }

    private func quitGrabText() {
        NSApp.terminate(nil)
    }
}
