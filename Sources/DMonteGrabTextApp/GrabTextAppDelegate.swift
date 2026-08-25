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

        // The hint line under the button reports two things macOS changes without telling anyone:
        // Secure Input (which silently swallows every hotkey press) and the Screen Recording grant.
        // Sampled once at launch they go stale in both directions — no warning while the shortcut
        // is being eaten, or a warning that outlives the password field that caused it. The window
        // is built once and never rebuilt, so `onAppear` cannot do this; re-read while it is on
        // screen, and stop the moment it isn't, because this is an idle helper the rest of the time.
        host.onVisibilityChanged = { [controller] isVisible in
            if isVisible {
                controller.beginEnvironmentMonitoring()
            } else {
                controller.endEnvironmentMonitoring()
            }
        }

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
        controller.endEnvironmentMonitoring()
        controller.unregisterHotKey()
        windowHost?.tearDownForTermination()
        statusItem?.remove()
    }

    private func quitGrabText() {
        NSApp.terminate(nil)
    }
}
