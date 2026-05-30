import AppKit
import SwiftUI
import DMonteCore

// MARK: - Status item control

/// A small NSControl that draws the menu-bar icon and forwards clicks to the
/// delegate. Using a custom control (rather than the button's default target)
/// keeps behaviour identical to the Clipboard tool.
final class MaintenanceStatusView: NSControl {

    static let statusWidth: CGFloat = 24

    private let glyph: NSImage

    override init(frame frameRect: NSRect) {
        glyph = NSImage(systemSymbolName: "wrench.and.screwdriver.fill",
                        accessibilityDescription: "Maintenance") ?? NSImage()
        super.init(frame: frameRect)
        glyph.isTemplate = true
        toolTip = "Maintenance"
    }

    required init?(coder: NSCoder) {
        glyph = NSImage(systemSymbolName: "wrench.and.screwdriver.fill",
                        accessibilityDescription: "Maintenance") ?? NSImage()
        super.init(coder: coder)
        glyph.isTemplate = true
        toolTip = "Maintenance"
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let glyphSize = NSSize(width: 15, height: 15)
        let rect = NSRect(
            x: (bounds.width - glyphSize.width) / 2,
            y: (bounds.height - glyphSize.height) / 2,
            width: glyphSize.width,
            height: glyphSize.height
        )
        // Template images tint to the menu-bar foreground colour automatically.
        glyph.draw(in: rect)
    }

    override func mouseDown(with event: NSEvent) {
        // Fire on mouse-down for snappy menu-bar feel.
        if let action, let target {
            NSApp.sendAction(action, to: target, from: self)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Keyable panel

/// A borderless, non-activating panel that can still become key so SwiftUI
/// controls (buttons, toggles) respond on first click. Mirrors the Clipboard
/// `KeyablePanel`.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - App delegate

@MainActor
final class MaintenanceAppDelegate: NSObject, NSApplicationDelegate {

    /// The distributed notification used to reveal the popover when the tool is
    /// re-launched with `--open` while already running.
    private static let showWindowNotification =
        Notification.Name("com.havokentity.mactools.maintenance.showWindow")

    private var statusItem: NSStatusItem?
    private var statusView: MaintenanceStatusView?
    private var panel: KeyablePanel?
    private var outsideClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDefaults.registerDefaults()

        setupStatusItem()
        setupShowWindowObserver()

        // If launched with --open, reveal the popover immediately.
        if CommandLine.arguments.contains("--open") {
            DispatchQueue.main.async { [weak self] in
                self?.showPanel()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        removeOutsideClickMonitor()
    }

    // MARK: Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: MaintenanceStatusView.statusWidth)
        let view = MaintenanceStatusView(
            frame: NSRect(x: 0, y: 0,
                          width: MaintenanceStatusView.statusWidth,
                          height: NSStatusBar.system.thickness)
        )
        view.target = self
        view.action = #selector(togglePanel)

        // Use the custom control as the status item's view directly (matches the
        // Clipboard tool) so click handling lives entirely in the control.
        item.view = view

        statusItem = item
        statusView = view
    }

    // MARK: Show-window observer

    private func setupShowWindowObserver() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(showPanelFromNotification(_:)),
            name: Self.showWindowNotification,
            object: nil
        )
    }

    @objc private func showPanelFromNotification(_ notification: Notification) {
        showPanel()
    }

    // MARK: Toggle / show / close

    @objc private func togglePanel() {
        if let panel, panel.isVisible {
            closePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        let panel = ensurePanel()
        positionPanel(panel)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        installOutsideClickMonitor()
    }

    private func closePanel() {
        panel?.orderOut(nil)
        removeOutsideClickMonitor()
    }

    private func ensurePanel() -> KeyablePanel {
        if let panel { return panel }

        let content = MaintenancePopoverView(onQuit: { [weak self] in
            self?.quit()
        })
        let hosting = NSHostingController(rootView: content)
        hosting.view.layoutSubtreeIfNeeded()

        let size = hosting.view.fittingSize
        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentViewController = hosting
        panel.contentView?.wantsLayer = true

        self.panel = panel
        return panel
    }

    /// Positions the panel directly beneath the menu-bar status item.
    private func positionPanel(_ panel: KeyablePanel) {
        panel.layoutIfNeeded()
        let size = panel.frame.size

        guard let statusView,
              let anchorWindow = statusView.window,
              let screen = anchorWindow.screen ?? NSScreen.main else {
            // Fallback: top-right of the main screen.
            if let screen = NSScreen.main {
                let x = screen.visibleFrame.maxX - size.width - 8
                let y = screen.visibleFrame.maxY - size.height - 8
                panel.setFrameOrigin(NSPoint(x: x, y: y))
            }
            return
        }

        let viewRectInWindow = statusView.convert(statusView.bounds, to: nil)
        let anchorOnScreen = anchorWindow.convertToScreen(viewRectInWindow)

        let visibleFrame = screen.visibleFrame
        var x = anchorOnScreen.midX - size.width / 2
        x = min(max(x, visibleFrame.minX + 8), visibleFrame.maxX - size.width - 8)
        let y = max(visibleFrame.minY + 8, anchorOnScreen.minY - size.height - 6)

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: Outside-click dismissal

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.closePanel()
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    // MARK: Quit

    private func quit() {
        closePanel()
        NSApp.terminate(nil)
    }
}
