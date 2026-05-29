import AppKit
import DMonteCore
import SwiftUI

/// A panel that can take keyboard focus (so the user can type to search and navigate) while
/// still floating over other apps. We re-activate the previous app before pasting.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The menu-bar tray button for the clipboard manager.
private final class ClipboardStatusView: NSControl {
    static let statusWidth: CGFloat = 22

    var onClick: (() -> Void)?

    private let image: NSImage
    private let highlightLayer = CALayer()
    private var trackingArea: NSTrackingArea?

    init() {
        image = NSImage(systemSymbolName: "doc.on.clipboard.fill", accessibilityDescription: "Clipboard") ?? NSImage()
        super.init(frame: NSRect(x: 0, y: 0, width: Self.statusWidth, height: NSStatusBar.system.thickness))
        wantsLayer = true
        image.isTemplate = true
        highlightLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.11).cgColor
        highlightLayer.cornerRadius = 6
        highlightLayer.cornerCurve = .continuous
        highlightLayer.masksToBounds = true
        highlightLayer.isHidden = true
        layer?.insertSublayer(highlightLayer, at: 0)
        toolTip = "Clipboard"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Inverted look: a solid rounded chip with the clipboard glyph knocked out of it.
        let chipSide: CGFloat = 16
        let chipRect = NSRect(
            x: bounds.midX - chipSide / 2,
            y: bounds.midY - chipSide / 2,
            width: chipSide,
            height: chipSide
        )
        NSColor.labelColor.setFill()
        NSBezierPath(roundedRect: chipRect, xRadius: 4.5, yRadius: 4.5).fill()

        let glyphSize = NSSize(width: 10.5, height: 10.5)
        let glyphRect = NSRect(
            x: bounds.midX - glyphSize.width / 2,
            y: bounds.midY - glyphSize.height / 2,
            width: glyphSize.width,
            height: glyphSize.height
        )
        // The simple draw(in:) ignores the context's compositing op, so pass it explicitly
        // to knock the clipboard glyph out of the chip.
        image.draw(in: glyphRect, from: .zero, operation: .destinationOut, fraction: 1.0)
    }

    override func layout() {
        super.layout()
        highlightLayer.frame = bounds.insetBy(dx: 1, dy: 3)
    }

    override func mouseDown(with event: NSEvent) {
        highlightLayer.isHidden = false
        onClick?()
    }

    override func mouseUp(with event: NSEvent) {
        highlightLayer.isHidden = !isMouseInside
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { highlightLayer.isHidden = false }
    override func mouseExited(with event: NSEvent) { highlightLayer.isHidden = true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    private var isMouseInside: Bool {
        guard let window else { return false }
        let mouseInWindow = window.mouseLocationOutsideOfEventStream
        let mouseInView = convert(mouseInWindow, from: nil)
        return bounds.contains(mouseInView)
    }
}

@MainActor
final class ClipboardAppDelegate: NSObject, NSApplicationDelegate {
    private let controller = ClipboardController()

    private var statusItem: NSStatusItem?
    private weak var statusView: ClipboardStatusView?
    private var panel: NSPanel?
    private var hotKey: GlobalHotKey?
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private weak var lastActiveApp: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDefaults.registerDefaults()
        ClipboardLoginItem.refreshIfEnabled()

        controller.onRequestClose = { [weak self] in
            self?.closePanel()
        }
        controller.startCapturing()

        configurePanel()
        configureStatusItem()
        configureShowNotification()
        observeActiveApp()
        registerHotKey()
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        removeClickMonitor()
        removeKeyMonitor()
        hotKey = nil
        panel?.orderOut(nil)
        panel = nil

        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
            self.statusView = nil
        }
    }

    // MARK: - Setup

    private func configurePanel() {
        let size = ClipboardSizing.preferredSize()
        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
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
            rootView: ClipboardPopoverView(controller: controller, onQuit: { [weak self] in self?.quit() })
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
        let item = NSStatusBar.system.statusItem(withLength: ClipboardStatusView.statusWidth)
        statusItem = item

        let statusView = ClipboardStatusView()
        statusView.onClick = { [weak self] in
            self?.togglePanel()
        }
        item.view = statusView
        self.statusView = statusView
    }

    private func configureShowNotification() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(showPanelFromNotification(_:)),
            name: HelperNotifications.showClipboardWindow,
            object: nil
        )
    }

    private func observeActiveApp() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeAppChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    private func registerHotKey() {
        hotKey = GlobalHotKey.commandShiftV { [weak self] in
            Task { @MainActor in
                self?.togglePanel()
            }
        }
    }

    @objc private func showPanelFromNotification(_ notification: Notification) {
        showPanel()
    }

    @objc private func activeAppChanged(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier != ClipboardMonitor.bundleIdentifier else {
            return
        }
        lastActiveApp = app
    }

    // MARK: - Panel show/hide

    private func togglePanel() {
        if panel?.isVisible == true {
            closePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let panel else { return }

        // The app to paste into is whatever was frontmost just before we appeared.
        controller.pasteTarget = lastActiveApp ?? NSWorkspace.shared.frontmostApplication
        controller.prepareForShow()

        let size = ClipboardSizing.preferredSize()
        panel.setContentSize(size)
        panel.setFrame(panelFrame(for: size), display: true)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        installKeyMonitor()
        startClickMonitorAfterOpeningClick()
    }

    private func closePanel() {
        panel?.orderOut(nil)
        removeClickMonitor()
        removeKeyMonitor()
    }

    private func panelFrame(for size: NSSize) -> NSRect {
        guard let statusView, let window = statusView.window, let screen = window.screen ?? NSScreen.main else {
            let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            return NSRect(
                x: visibleFrame.midX - size.width / 2,
                y: visibleFrame.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
        }

        let viewFrameInWindow = statusView.convert(statusView.bounds, to: nil)
        let anchorFrame = window.convertToScreen(viewFrameInWindow)
        let visibleFrame = screen.visibleFrame
        let x = min(
            max(anchorFrame.midX - size.width / 2, visibleFrame.minX + 8),
            visibleFrame.maxX - size.width - 8
        )
        let y = max(visibleFrame.minY + 8, anchorFrame.minY - size.height - 8)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    // MARK: - Event monitors

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.controller.handleKey(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

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
