import AppKit
import DMonteCore
import SwiftUI

/// Distributed notification used to reveal this helper's popover when the Toolbox (or a second launch
/// with `--open`) asks for it.
enum CalendarNotifications {
    static let showWindow = Notification.Name("com.havokentity.mactools.calendar.showWindow")
}

@MainActor
final class CalendarAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: HelperStatusItem?
    private var panelHost: HelperPanelHost?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDefaults.registerDefaults()

        let host = HelperPanelHost(
            configuration: HelperPanelHost.Configuration(
                sizing: .preferred({ CalendarSizing.preferredSize() })
            ),
            content: .viewController({ [weak self] in
                NSHostingController(
                    rootView: CalendarPopoverView(onQuit: { self?.quit() })
                )
            }),
            anchorView: { [weak self] in self?.statusItem?.button }
        )
        panelHost = host
        host.configure()

        // The cached panel's `onAppear` fires only once, so re-check access and reload the
        // events every time it opens.
        host.onWillShow = {
            NotificationCenter.default.post(
                name: CalendarPopoverView.willShowNotification, object: nil
            )
        }

        let icon = NSImage(systemSymbolName: "calendar", accessibilityDescription: "Calendar") ?? NSImage()
        statusItem = HelperStatusItem(
            image: icon,
            toolTip: "Calendar",
            primaryAction: { [weak self] in self?.panelHost?.toggle() },
            quitAction: { [weak self] in self?.quit() }
        )

        host.observeShowNotification(named: CalendarNotifications.showWindow)
    }

    func applicationWillTerminate(_ notification: Notification) {
        panelHost?.stopObservingShowNotifications()
        panelHost?.removeOutsideClickMonitor()
        panelHost?.dismissForTermination()
        statusItem?.remove()
    }

    private func quit() {
        panelHost?.close()
        NSApp.terminate(nil)
    }
}
