import AppKit
import SwiftUI
import DMonteCore

@MainActor
final class MaintenanceAppDelegate: NSObject, NSApplicationDelegate {

    /// The distributed notification used to reveal the popover when the tool is
    /// re-launched with `--open` while already running.
    private static let showWindowNotification =
        Notification.Name("com.havokentity.mactools.maintenance.showWindow")

    private var statusItem: HelperStatusItem?
    private var panelHost: HelperPanelHost?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDefaults.registerDefaults()

        // A borderless, non-activating panel that can become key (but never main) so the
        // SwiftUI controls respond on first click. Sized from the content's fitting size,
        // pinned at status-bar level, not movable.
        let host = HelperPanelHost(
            configuration: HelperPanelHost.Configuration(
                styleMask: [.borderless, .nonactivatingPanel],
                level: .statusBar,
                canBecomeMain: false,
                isReleasedWhenClosed: nil,
                isMovable: false,
                creation: .onFirstShow,
                sizing: .fittingContent,
                clickMonitorInstall: .immediate,
                positioning: .anchoredOriginOrTopRight(gap: 6)
            ),
            content: .viewController({ [weak self] in
                NSHostingController(
                    rootView: MaintenancePopoverView(onQuit: {
                        self?.quit()
                    })
                )
            }),
            anchorView: { [weak self] in self?.statusItem?.button }
        )
        panelHost = host

        // The cached panel's `onAppear` fires only once, so re-read the system
        // toggles every time it opens.
        host.onWillShow = {
            NotificationCenter.default.post(
                name: MaintenancePopoverView.willShowNotification, object: nil
            )
        }

        let icon = NSImage(systemSymbolName: "wrench.and.screwdriver.fill",
                           accessibilityDescription: "Maintenance") ?? NSImage()
        statusItem = HelperStatusItem(
            image: icon,
            toolTip: "Maintenance",
            primaryAction: { [weak self] in self?.panelHost?.toggle() },
            quitAction: { [weak self] in self?.quit() }
        )

        host.observeShowNotification(named: Self.showWindowNotification)

        // If launched with --open, reveal the popover immediately.
        if CommandLine.arguments.contains("--open") {
            DispatchQueue.main.async { [weak self] in
                self?.panelHost?.show()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        panelHost?.stopObservingShowNotifications()
        panelHost?.removeOutsideClickMonitor()
    }

    private func quit() {
        panelHost?.close()
        NSApp.terminate(nil)
    }
}
