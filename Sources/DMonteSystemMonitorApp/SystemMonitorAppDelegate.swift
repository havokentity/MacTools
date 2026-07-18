import AppKit
import Combine
import DMonteCore
import SwiftUI

@MainActor
final class SystemMonitorAppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = SystemMonitor()
    private var statusItem: NSStatusItem?
    private var statusView: SystemMonitorStatusView?
    private var panelHost: HelperPanelHost?
    private var snapshotSink: AnyCancellable?
    private var defaultsSink: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDefaults.registerDefaults()

        configurePopover()
        configureStatusItem()
        configureObservers()
        configureEnvironmentObservers()
        SystemMonitorLoginItem.refreshIfEnabled()
        monitor.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        snapshotSink = nil
        defaultsSink = nil
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)

        panelHost?.removeOutsideClickMonitor()
        panelHost?.dismissForTermination()

        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
            self.statusView = nil
        }
    }

    private func configurePopover() {
        // The popover panel never takes key focus (read-only metrics), sits at pop-up-menu
        // level and is revealed with orderFrontRegardless without stealing activation.
        let host = HelperPanelHost(
            configuration: HelperPanelHost.Configuration(
                styleMask: [.borderless, .nonactivatingPanel],
                level: .popUpMenu,
                canBecomeKey: false,
                canBecomeMain: false,
                sizing: .preferredPinned({ SystemMonitorPanelSizing.preferredSize() }),
                activation: .orderFrontRegardless
            ),
            content: .viewController({ [monitor, weak self] in
                NSHostingController(
                    rootView: SystemMonitorPopoverView(
                        monitor: monitor,
                        onQuit: {
                            self?.quitSystemMonitor()
                        }
                    )
                )
            }),
            anchorView: { [weak self] in self?.statusView }
        )
        panelHost = host
        host.configure()
    }

    private func configureStatusItem() {
        let showsIcon = AppDefaults.shared.bool(forKey: DefaultsKey.systemMonitorShowsTrayIcon)
        // A concrete (non-variable) length keeps AppKit from treating the button as empty and
        // culling it when the menu bar gets crowded — the disappearing-icon bug that drove the
        // migration off the old custom-subview install path for the other 17 tools.
        let item = NSStatusBar.system.statusItem(withLength: SystemMonitorStatusView.statusWidth(showsIcon: showsIcon))
        statusItem = item

        // System Monitor is the hard case: the tray content is a live multi-metric strip, not a
        // single icon/title. Keep the rich custom view, but host it inside the status item's own
        // button (the AppKit-managed content the menu bar won't drop) and let the button's
        // target/action handle the click instead of the view's onClick closure.
        let statusView = SystemMonitorStatusView()
        statusView.applyShowsIcon(showsIcon)
        self.statusView = statusView

        if let button = item.button {
            button.toolTip = "System Monitor"
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])

            statusView.frame = button.bounds
            statusView.autoresizingMask = [.width, .height]
            button.addSubview(statusView)
        }

        updateStatusTitle(monitor.snapshot)
    }

    @objc private func statusItemClicked() {
        if StatusBarButtonContent.popUpQuitMenuIfNeeded(for: statusItem, action: { [weak self] in
            self?.quitSystemMonitor()
        }) {
            return
        }

        togglePopover()
    }

    private func configureObservers() {
        // DispatchQueue.main rather than RunLoop.main: the RunLoop scheduler delivers only in
        // default mode, which would freeze the tray strip for as long as a menu tracks the run
        // loop. The main queue is drained in the common modes, so updates continue.
        snapshotSink = monitor.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.updateStatusTitle(snapshot)
            }

        defaultsSink = NotificationCenter.default.publisher(
            for: UserDefaults.didChangeNotification,
            object: AppDefaults.shared
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            let showsIcon = AppDefaults.shared.bool(forKey: DefaultsKey.systemMonitorShowsTrayIcon)
            self?.statusView?.applyShowsIcon(showsIcon)
            self?.statusItem?.length = SystemMonitorStatusView.statusWidth(showsIcon: showsIcon)
        }
    }

    private func configureEnvironmentObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(closePopoverForEnvironmentChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(closePopoverForEnvironmentChange(_:)),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(closePopoverForEnvironmentChange(_:)),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
    }

    @objc private func closePopoverForEnvironmentChange(_ notification: Notification) {
        panelHost?.close()
    }

    private func updateStatusTitle(_ snapshot: MetricSnapshot) {
        statusView?.update(snapshot: snapshot)
    }

    private func togglePopover() {
        guard let panelHost else {
            return
        }

        if panelHost.isPanelVisible {
            // A display-layout change can strand the visible panel off screen; re-show it
            // near the status item instead of merely hiding it.
            guard panelHost.isPanelOnVisibleScreen() else {
                panelHost.close()
                showPopover()
                return
            }

            panelHost.close()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard statusView != nil else {
            return
        }

        panelHost?.show()
    }

    private func quitSystemMonitor() {
        NSApp.terminate(nil)
    }
}
