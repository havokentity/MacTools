import AppKit
import Combine
import DMonteCore
import SwiftUI

/// Distributed notification used to reveal this helper's popover when the Toolbox (or a second
/// launch with `--open`) asks for it.
enum WindowManagerNotifications {
    static let showWindow = Notification.Name("com.havokentity.mactools.windowmanager.showWindow")
}

/// A borderless panel returns `canBecomeKey == false` by default, which leaves the SwiftUI
/// controls unfocusable. Overriding it lets the popover take keyboard focus while
/// `.nonactivatingPanel` keeps it from stealing activation from the user's current app —
/// essential here, since the snap tiles resolve their target via the frontmost application.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class WindowManagerAppDelegate: NSObject, NSApplicationDelegate {
    private let controller = WindowManagerController()

    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var clickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDefaults.registerDefaults()

        // Reconcile hotkey registration with the current Accessibility grant. This registers up
        // front when permission already exists; otherwise the controller registers automatically
        // the moment the grant is detected (permission polling or popover open), re-attempts
        // failed registrations on every popover open, and releases the keys if the grant is
        // revoked. Shortcut remaps re-register live via the controller.
        controller.refreshPermission()

        configurePanel()
        configureStatusItem()
        configureShowNotification()

        if CommandLine.arguments.contains("--open") {
            // This tool positions its own panel, so it waits on the shared settle check
            // directly rather than through HelperPanelHost. See `StatusItemAnchor`.
            StatusItemAnchor.whenSettled({ [weak self] in self?.statusItem?.button }) { [weak self] in
                self?.showPanel()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        closePanel()
        panel = nil

        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    // MARK: - Setup

    private func configurePanel() {
        let size = WindowManagerSizing.preferredSize()
        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let hosting = NSHostingController(
            rootView: WindowManagerPopoverView(controller: controller, onQuit: { [weak self] in self?.quit() })
        )
        hosting.view.frame = NSRect(origin: .zero, size: size)
        hosting.view.wantsLayer = true
        hosting.view.layer?.cornerRadius = 18
        hosting.view.layer?.cornerCurve = .continuous
        hosting.view.layer?.masksToBounds = true
        panel.contentViewController = hosting
        panel.setContentSize(size)
        self.panel = panel
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        let icon = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: "Window Manager") ?? NSImage()
        StatusBarButtonContent.install(image: icon, in: item, toolTip: "Window Manager", target: self, action: #selector(statusItemClicked))
    }

    @objc private func statusItemClicked() {
        if StatusBarButtonContent.popUpQuitMenuIfNeeded(for: statusItem, action: { [weak self] in
            self?.quit()
        }) {
            return
        }

        togglePanel(preferredScreenPoint: NSEvent.mouseLocation)
    }

    private func configureShowNotification() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(showPanelFromNotification(_:)),
            name: WindowManagerNotifications.showWindow,
            object: nil
        )
    }

    @objc private func showPanelFromNotification(_ notification: Notification) {
        showPanel()
    }

    // MARK: - Panel show/hide

    private func togglePanel(preferredScreenPoint: NSPoint? = nil) {
        if panel?.isVisible == true {
            closePanel()
        } else {
            showPanel(preferredScreenPoint: preferredScreenPoint)
        }
    }

    private func showPanel(preferredScreenPoint: NSPoint? = nil) {
        guard let panel else { return }

        // Resolve and freeze the snap target FIRST. With separate Spaces, the status-item click
        // that opened us re-activates the topmost app on the popover's display (sometimes before
        // this code runs, sometimes a few hundred ms after — both observed live); waiting until
        // a tile is clicked would resolve that app instead — the cross-display wrong-target bug.
        // The controller resolves from its activation history, not the live frontmost.
        controller.popoverWillShow()

        // The grant may have changed since launch; refresh so the banner/tiles reflect reality.
        controller.refreshPermission()

        let size = WindowManagerSizing.preferredSize()
        panel.setContentSize(size)
        panel.setFrame(panelFrame(for: size, preferredScreenPoint: preferredScreenPoint), display: true)

        // No NSApp.activate here: the panel must not steal activation from the user's app
        // (.nonactivatingPanel), and the target snapshot above must stay the last meaningful one.
        panel.makeKeyAndOrderFront(nil)

        startClickMonitorAfterOpeningClick()
    }

    private func closePanel() {
        panel?.orderOut(nil)
        removeClickMonitor()
        controller.popoverDidClose()
    }

    private func panelFrame(for size: NSSize, preferredScreenPoint: NSPoint? = nil) -> NSRect {
        if let preferredScreenPoint, let screen = Self.screen(containing: preferredScreenPoint) {
            let buttonSize = statusItem?.button?.bounds.size ?? NSSize(width: 24, height: 24)
            let anchorFrame = NSRect(
                x: preferredScreenPoint.x - buttonSize.width / 2,
                y: preferredScreenPoint.y - buttonSize.height / 2,
                width: buttonSize.width,
                height: buttonSize.height
            )
            return HelperPanelPlacement.anchoredFrame(
                for: size,
                anchorFrame: anchorFrame,
                visibleFrame: screen.visibleFrame
            )
        }

        guard let statusButton = statusItem?.button, let window = statusButton.window, let screen = window.screen ?? NSScreen.main else {
            return HelperPanelPlacement.centeredFrame(
                for: size,
                visibleFrame: NSScreen.main?.visibleFrame ?? HelperPanelPlacement.fallbackVisibleFrame
            )
        }

        let viewFrameInWindow = statusButton.convert(statusButton.bounds, to: nil)
        let anchorFrame = window.convertToScreen(viewFrameInWindow)
        return HelperPanelPlacement.anchoredFrame(
            for: size,
            anchorFrame: anchorFrame,
            visibleFrame: screen.visibleFrame
        )
    }

    private static func screen(containing point: NSPoint) -> NSScreen? {
        let screens = NSScreen.screens
        guard let index = HelperPanelPlacement.screenIndex(containing: point, in: screens.map(\.frame)) else {
            return nil
        }
        return screens[index]
    }

    // MARK: - Event monitors

    private func startClickMonitorAfterOpeningClick() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.startClickMonitor()
        }
    }

    private func startClickMonitor() {
        guard panel?.isVisible == true, clickMonitor == nil else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePanel()
        }
    }

    private func removeClickMonitor() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
    }

    private func quit() {
        closePanel()
        NSApp.terminate(nil)
    }
}
