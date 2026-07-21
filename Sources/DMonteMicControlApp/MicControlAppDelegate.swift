import AppKit
import Combine
import DMonteCore
import SwiftUI

/// Distributed notification used to reveal this helper's popover when the Toolbox (or a second
/// launch with `--open`) asks for it.
enum MicControlNotifications {
    static let showWindow = Notification.Name("com.havokentity.mactools.miccontrol.showWindow")
}

@MainActor
final class MicControlAppDelegate: NSObject, NSApplicationDelegate {
    private let controller = MicControlController()

    private var statusItem: HelperStatusItem?
    private var panelHost: HelperPanelHost?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDefaults.registerDefaults()

        let host = HelperPanelHost(
            configuration: HelperPanelHost.Configuration(
                sizing: .preferred({ MicControlSizing.preferredSize() })
            ),
            content: .viewController({ [controller, weak self] in
                NSHostingController(
                    rootView: MicControlPopoverView(controller: controller, onQuit: { self?.quit() })
                )
            }),
            anchorView: { [weak self] in self?.statusItem?.button }
        )
        panelHost = host
        host.configure()

        statusItem = HelperStatusItem(
            image: Self.statusIcon(for: controller.state),
            toolTip: MicControlKit.trayTooltip(for: controller.state, deviceName: controller.deviceName),
            primaryAction: { [weak self] in self?.panelHost?.toggle() },
            quitAction: { [weak self] in self?.quit() }
        )

        // The whole point of this tool is the glance: the tray must already be
        // correct at launch, before any state change arrives.
        updateStatusIcon()

        host.observeShowNotification(named: MicControlNotifications.showWindow)
        observeControllerState()
    }

    func applicationWillTerminate(_ notification: Notification) {
        panelHost?.stopObservingShowNotifications()
        panelHost?.removeOutsideClickMonitor()
        cancellables.removeAll()
        panelHost?.dismissForTermination()
        statusItem?.remove()
    }

    /// The tray glyph for a mute state. Forced to template so AppKit tints it adaptive white and
    /// gives it the native rollover highlight.
    private static func statusIcon(for state: MicControlKit.MicState) -> NSImage {
        let name = MicControlKit.trayGlyphName(for: state)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Mic Control") ?? NSImage()
        image.isTemplate = true
        return image
    }

    /// Swaps the status button's image and tooltip to match the controller's mute state. Driven by
    /// the `$state` Combine sink, so an external mute (a meeting app, Control Center, or a device
    /// swap) moves the glyph too — a stale glyph here would actively mislead.
    private func updateStatusIcon() {
        statusItem?.button?.image = Self.statusIcon(for: controller.state)
        statusItem?.button?.toolTip = MicControlKit.trayTooltip(
            for: controller.state,
            deviceName: controller.deviceName
        )
    }

    /// Keep the tray glyph in sync with the controller's mute state, and the tooltip in sync with
    /// the device name too — swapping between two unmuted mics leaves `state` untouched while the
    /// tooltip would otherwise keep naming the device you just unplugged.
    private func observeControllerState() {
        controller.$state
            .map { _ in () }
            .merge(with: controller.$deviceName.map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.updateStatusIcon()
            }
            .store(in: &cancellables)
    }

    private func quit() {
        panelHost?.close()
        NSApp.terminate(nil)
    }
}
