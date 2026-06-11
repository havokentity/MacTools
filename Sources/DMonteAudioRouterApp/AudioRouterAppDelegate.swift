import AppKit
import DMonteCore
import SwiftUI

@MainActor
final class AudioRouterAppDelegate: NSObject, NSApplicationDelegate {
    private static let showWindowNotification =
        Notification.Name("com.havokentity.mactools.audiorouter.showWindow")

    private var statusItem: NSStatusItem?
    private var panelHost: HelperPanelHost?
    private var controller: AudioRouterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDefaults.registerDefaults()
        controller = AudioRouterController()

        let host = HelperPanelHost(
            configuration: HelperPanelHost.Configuration(
                styleMask: [.borderless, .nonactivatingPanel],
                isFloatingPanel: nil,
                hidesOnDeactivate: nil,
                isReleasedWhenClosed: nil,
                creation: .onFirstShow,
                sizing: .fixedAtCreation(
                    NSSize(width: AudioRouterSizing.panelWidth, height: AudioRouterSizing.panelHeight)
                ),
                activation: .orderFrontThenActivate,
                clickMonitorInstall: .immediate,
                positioning: .anchoredOriginRawBounds(gap: 8)
            ),
            content: .view({ [weak self] in
                let controller = self?.controller ?? AudioRouterController()
                self?.controller = controller
                let content = AudioRouterPopoverView(controller: controller, onQuit: {
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
                systemSymbolName: "point.3.connected.trianglepath.dotted",
                accessibilityDescription: "Audio Router"
            )
            button.image?.isTemplate = true
            button.toolTip = "Audio Router"
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        self.statusItem = statusItem

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
        // Stop monitors before terminating: each engine restores the device
        // sample rates it forced and destroys its private aggregate — state
        // that would otherwise outlive the process.
        controller?.stopAllMonitors()
        panelHost?.removeOutsideClickMonitor()
        panelHost?.stopObservingShowNotifications()
    }

    func applicationWillTerminate(_ notification: Notification) {
        cleanup()
    }
}
