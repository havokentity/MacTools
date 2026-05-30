import AppKit
import DMonteCore
import SwiftUI

private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class DevToolsStatusView: NSControl {
    static let statusWidth: CGFloat = 22

    var onClick: (() -> Void)?

    private let image: NSImage
    private let highlightLayer = CALayer()
    private var trackingArea: NSTrackingArea?

    init() {
        image = NSImage(systemSymbolName: "curlybraces", accessibilityDescription: "Dev Tools") ?? NSImage()
        super.init(frame: NSRect(x: 0, y: 0, width: Self.statusWidth, height: NSStatusBar.system.thickness))
        wantsLayer = true
        image.isTemplate = true
        highlightLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.11).cgColor
        highlightLayer.cornerRadius = 6
        highlightLayer.cornerCurve = .continuous
        highlightLayer.masksToBounds = true
        highlightLayer.isHidden = true
        layer?.insertSublayer(highlightLayer, at: 0)
        toolTip = "Dev Tools"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor.labelColor.set()
        let imageSize = NSSize(width: 15, height: 15)
        let imageRect = NSRect(
            x: bounds.midX - imageSize.width / 2,
            y: bounds.midY - imageSize.height / 2,
            width: imageSize.width,
            height: imageSize.height
        )
        image.draw(in: imageRect)
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

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

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

    override func mouseEntered(with event: NSEvent) {
        highlightLayer.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        highlightLayer.isHidden = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    private var isMouseInside: Bool {
        guard let window else {
            return false
        }

        let mouseInWindow = window.mouseLocationOutsideOfEventStream
        let mouseInView = convert(mouseInWindow, from: nil)
        return bounds.contains(mouseInView)
    }
}

@MainActor
final class DevToolsAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static let showWindowNotification = Notification.Name("com.havokentity.mactools.devtools.showWindow")

    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private var hasPositionedWindow = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDefaults.registerDefaults()

        configureWindow()
        configureWindowShowNotifications()

        if CommandLine.arguments.contains("--open") || statusItem == nil {
            DispatchQueue.main.async { [weak self] in
                self?.showWindow()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)

        window?.orderOut(nil)
        window?.delegate = nil
        window = nil

        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    private func configureWindow() {
        let windowSize = DevToolsSizing.preferredSize()
        let window = KeyableWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .clear
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hostingController = NSHostingController(
            rootView: DevToolsWindowView(
                onQuit: { [weak self] in
                    self?.quitDevTools()
                }
            )
        )
        hostingController.view.frame = NSRect(origin: .zero, size: windowSize)
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.cornerRadius = 18
        hostingController.view.layer?.cornerCurve = .continuous
        hostingController.view.layer?.masksToBounds = true
        window.contentViewController = hostingController
        window.contentMinSize = windowSize
        window.contentMaxSize = windowSize
        window.setContentSize(windowSize)
        window.delegate = self
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.level = .normal
        window.title = "Dev Tools"
        self.window = window
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: DevToolsStatusView.statusWidth)
        statusItem = item

        let statusView = DevToolsStatusView()
        statusView.onClick = { [weak self, weak statusView] in
            self?.showWindow(relativeTo: statusView)
        }
        item.view = statusView
    }

    private func configureWindowShowNotifications() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(showWindowFromNotification(_:)),
            name: Self.showWindowNotification,
            object: nil
        )
    }

    @objc private func showWindowFromNotification(_ notification: Notification) {
        showWindow()
    }

    private func showWindow(relativeTo view: NSView? = nil) {
        guard let window else {
            return
        }

        let windowSize = DevToolsSizing.preferredSize()
        window.contentMinSize = windowSize
        window.contentMaxSize = windowSize

        if hasPositionedWindow {
            window.setContentSize(windowSize)
        } else {
            let frame = if let view {
                Self.windowFrame(for: windowSize, near: view)
            } else {
                Self.centeredWindowFrame(for: windowSize)
            }
            window.setFrame(frame, display: true)
            hasPositionedWindow = true
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func quitDevTools() {
        NSApp.terminate(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if statusItem == nil {
            NSApp.terminate(nil)
        }
    }

    private static func windowFrame(for size: NSSize, near view: NSView) -> NSRect {
        guard let window = view.window, let screen = window.screen ?? NSScreen.main else {
            return centeredWindowFrame(for: size)
        }

        let viewFrameInWindow = view.convert(view.bounds, to: nil)
        let anchorFrame = window.convertToScreen(viewFrameInWindow)
        let visibleFrame = screen.visibleFrame
        let x = min(
            max(anchorFrame.midX - (size.width / 2), visibleFrame.minX + 8),
            visibleFrame.maxX - size.width - 8
        )
        let y = max(visibleFrame.minY + 8, anchorFrame.minY - size.height - 8)

        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private static func centeredWindowFrame(for size: NSSize) -> NSRect {
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(
            x: visibleFrame.midX - (size.width / 2),
            y: visibleFrame.midY - (size.height / 2),
            width: size.width,
            height: size.height
        )
    }
}
