import AppKit
import DMonteCore
import SwiftUI

@MainActor
final class ColorPickerAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPanel?
    private var outsideClickMonitor: Any?
    private var hostingController: NSHostingController<ColorPickerPopoverView>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDefaults.registerDefaults()
        setUpStatusItem()
        registerShowWindowObserver()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        if let button = item.button {
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            let image = NSImage(
                systemSymbolName: "eyedropper.halffull",
                accessibilityDescription: "Color Picker"
            )?.withSymbolConfiguration(config)
            button.image = image
            button.toolTip = "Color Picker"
            button.target = self
            button.action = #selector(togglePopover)
        }
    }

    // MARK: - Notifications

    private func registerShowWindowObserver() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleShowWindow),
            name: Notification.Name("com.havokentity.mactools.colorpicker.showWindow"),
            object: nil
        )
    }

    @objc private func handleShowWindow() {
        showPopover()
    }

    // MARK: - Popover

    @objc private func togglePopover() {
        if let popover, popover.isVisible {
            hidePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        let panel = popover ?? makePanel()
        popover = panel

        guard let button = statusItem?.button, let buttonWindow = button.window else { return }

        let buttonBoundsInWindow = button.convert(button.bounds, to: nil)
        let buttonRectOnScreen = buttonWindow.convertToScreen(buttonBoundsInWindow)

        let panelSize = panel.frame.size
        var origin = NSPoint(
            x: buttonRectOnScreen.midX - panelSize.width / 2,
            y: buttonRectOnScreen.minY - panelSize.height - 6
        )

        if let screen = buttonWindow.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            let minX = visible.minX + 8
            let maxX = visible.maxX - panelSize.width - 8
            if origin.x < minX { origin.x = minX }
            if origin.x > maxX { origin.x = maxX }
            let minY = visible.minY + 8
            if origin.y < minY { origin.y = minY }
        }

        panel.setFrameOrigin(origin)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        installOutsideClickMonitor()
    }

    private func hidePopover() {
        popover?.orderOut(nil)
        removeOutsideClickMonitor()
    }

    private func makePanel() -> NSPanel {
        let rootView = ColorPickerPopoverView(onQuit: { [weak self] in
            self?.quit()
        })
        let hosting = NSHostingController(rootView: rootView)
        hostingController = hosting

        let panelSize = ColorPickerSizing.preferredSize()
        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        return panel
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.hidePopover()
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - KeyablePanel

/// An `NSPanel` subclass that can become key even with the `.nonactivatingPanel` style,
/// so the embedded SwiftUI text fields and buttons receive keyboard/mouse input.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
