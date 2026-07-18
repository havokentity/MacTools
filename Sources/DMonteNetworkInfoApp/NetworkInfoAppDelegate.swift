import AppKit
import Combine
import DMonteCore
import SwiftUI

/// Distributed notification used to reveal this helper's popover when the Toolbox (or a second
/// launch with `--open`) asks for it.
enum NetworkInfoNotifications {
    static let showWindow = Notification.Name("com.havokentity.mactools.networkinfo.showWindow")
}

@MainActor
final class NetworkInfoAppDelegate: NSObject, NSApplicationDelegate {
    private let controller = NetworkInfoController()

    private var statusItem: HelperStatusItem?
    private var panelHost: HelperPanelHost?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDefaults.registerDefaults()

        let host = HelperPanelHost(
            configuration: HelperPanelHost.Configuration(
                sizing: .preferred({ NetworkInfoSizing.preferredSize() })
            ),
            content: .viewController({ [controller, weak self] in
                NSHostingController(
                    rootView: NetworkInfoPopoverView(controller: controller, onQuit: { self?.quit() })
                )
            }),
            anchorView: { [weak self] in self?.statusItem?.button }
        )
        panelHost = host
        host.configure()

        statusItem = HelperStatusItem(
            image: Self.statusIcon(kind: controller.snapshot.kind, isConnected: controller.snapshot.hasConnection),
            toolTip: "Network Info",
            primaryAction: { [weak self] in self?.panelHost?.toggle() },
            quitAction: { [weak self] in self?.quit() }
        )

        host.observeShowNotification(named: NetworkInfoNotifications.showWindow)
        observeControllerState()

        // Start monitoring here rather than only from the popover's `onAppear`, so the tray glyph
        // is right before the user ever opens the panel.
        controller.start()

        // The distributed notification above only covers a *second* launch. On the first one this
        // process is the primary instance, so nothing posts it and the Toolbox tile would appear
        // to do nothing — reveal the panel here instead.
        //
        // `showWhenAnchored` rather than a one-turn `async`: the status item's button has a window
        // before the status bar has sized it, so showing too early anchors the panel to a
        // zero-sized rect at the screen origin and it opens in the corner of another display.
        if CommandLine.arguments.contains("--open") {
            panelHost?.showWhenAnchored()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        panelHost?.stopObservingShowNotifications()
        panelHost?.removeOutsideClickMonitor()
        cancellables.removeAll()
        controller.stop()
        panelHost?.dismissForTermination()
        statusItem?.remove()
    }

    /// The tray glyph mirrors the active link: the Wi‑Fi/Ethernet symbol while connected, a
    /// slashed Wi‑Fi when there is no primary service, so the state is legible without opening the
    /// panel. Forced to template so AppKit tints it adaptive white and gives it the native
    /// rollover highlight.
    private static func statusIcon(kind: NetworkLinkKind, isConnected: Bool) -> NSImage {
        let name = isConnected ? kind.symbolName : "wifi.slash"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Network Info") ?? NSImage()
        image.isTemplate = true
        return image
    }

    private func updateStatusIcon() {
        statusItem?.button?.image = Self.statusIcon(
            kind: controller.snapshot.kind,
            isConnected: controller.snapshot.hasConnection
        )
    }

    /// Keep the tray glyph in sync with the current link.
    private func observeControllerState() {
        controller.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusIcon()
            }
            .store(in: &cancellables)
    }

    private func quit() {
        panelHost?.close()
        NSApp.terminate(nil)
    }
}
