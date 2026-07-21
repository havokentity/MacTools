import AppKit
import DMonteCore
import SwiftUI

@MainActor
final class VolumeMixerAppDelegate: NSObject, NSApplicationDelegate {
    private static let showWindowNotification =
        Notification.Name("com.havokentity.mactools.volumemixer.showWindow")

    private var statusItem: NSStatusItem?
    private var panelHost: HelperPanelHost?
    private var controller: AppVolumeMixerController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDefaults.registerDefaults()
        controller = AppVolumeMixerController()

        let host = HelperPanelHost(
            configuration: HelperPanelHost.Configuration(
                styleMask: [.borderless, .nonactivatingPanel],
                isFloatingPanel: nil,
                hidesOnDeactivate: nil,
                isReleasedWhenClosed: nil,
                creation: .onFirstShow,
                sizing: .fixedAtCreation(
                    NSSize(width: VolumeMixerSizing.panelWidth, height: VolumeMixerSizing.panelHeight)
                ),
                activation: .orderFrontThenActivate,
                clickMonitorInstall: .immediate,
                positioning: .anchoredOriginRawBounds(gap: 8)
            ),
            content: .view({ [weak self] in
                let controller = self?.controller ?? AppVolumeMixerController()
                self?.controller = controller
                let content = VolumeMixerPopoverView(controller: controller, onQuit: {
                    self?.quit()
                })
                return NSHostingView(rootView: content)
            }),
            anchorView: { [weak self] in self?.statusItem?.button }
        )
        panelHost = host

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "slider.horizontal.3",
                accessibilityDescription: "Volume Mixer"
            )
            button.image?.isTemplate = true
            button.toolTip = "Volume Mixer"
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        self.statusItem = statusItem

        // The host's outside-click monitor install is idempotent, which matters here:
        // show can run not only from togglePopover() (which guards on panel visibility)
        // but also from the second-instance distributed-notification path
        // (`main.swift --open`) while the panel may already be visible.
        host.observeShowNotification(named: Self.showWindowNotification)
    }

    @objc private func togglePopover() {
        if StatusBarButtonContent.popUpQuitMenuIfNeeded(for: statusItem, action: { [weak self] in
            self?.quit()
        }) {
            return
        }

        panelHost?.toggle()
    }

    private func quit() {
        cleanup()
        NSApp.terminate(nil)
    }

    private func cleanup() {
        // Teardown, not the footer gesture: `stopProcessing()` persists a force-off for every live
        // engine, which on quit would resurrect as stops the user never pressed.
        controller?.shutdownProcessing()
        panelHost?.removeOutsideClickMonitor()
        panelHost?.stopObservingShowNotifications()
    }

    func applicationWillTerminate(_ notification: Notification) {
        cleanup()
    }
}
