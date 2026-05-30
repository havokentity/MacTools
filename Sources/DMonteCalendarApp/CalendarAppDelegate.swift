import AppKit
import DMonteCore
import SwiftUI

/// Distributed notification used to reveal this helper's popover when the Toolbox (or a second launch
/// with `--open`) asks for it.
enum CalendarNotifications {
    static let showWindow = Notification.Name("com.havokentity.mactools.calendar.showWindow")
}

/// A panel that can take keyboard focus while still floating over other apps. Mirrors the other
/// tools' floating-panel behaviour and dismissal handling.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The menu-bar tray button for Calendar. Draws a calendar glyph with the current day-of-month
/// number knocked out of it (like the macOS Calendar icon), refreshed once per day so it stays
/// current. The width matches the other single-glyph tray items.
private final class CalendarStatusView: NSControl {
    static let statusWidth: CGFloat = 22

    var onClick: (() -> Void)?

    private let highlightLayer = CALayer()
    private var trackingArea: NSTrackingArea?

    /// The day-of-month string drawn inside the glyph (e.g. "30").
    private var dayString: String = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        highlightLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.11).cgColor
        highlightLayer.cornerRadius = 6
        highlightLayer.cornerCurve = .continuous
        highlightLayer.masksToBounds = true
        highlightLayer.isHidden = true
        layer?.insertSublayer(highlightLayer, at: 0)
        toolTip = "Calendar"
        refreshDay()
    }

    convenience init() {
        self.init(frame: NSRect(x: 0, y: 0, width: Self.statusWidth, height: NSStatusBar.system.thickness))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Updates the drawn day number to the current day-of-month.
    func refreshDay() {
        let day = Calendar.current.component(.day, from: Date())
        let newValue = String(day)
        guard newValue != dayString else { return }
        dayString = newValue
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // A solid rounded chip with the day number knocked out of it.
        let chipSide: CGFloat = 16
        let chipRect = NSRect(
            x: bounds.midX - chipSide / 2,
            y: bounds.midY - chipSide / 2,
            width: chipSide,
            height: chipSide
        )
        NSColor.labelColor.setFill()
        NSBezierPath(roundedRect: chipRect, xRadius: 4.0, yRadius: 4.0).fill()

        // A thin top band evokes the calendar header binding.
        let bandRect = NSRect(
            x: chipRect.minX,
            y: chipRect.maxY - 3.5,
            width: chipRect.width,
            height: 3.5
        )
        NSColor.labelColor.withAlphaComponent(0.0).setFill()
        bandRect.fill()

        // Draw the day number knocked out of the chip.
        let fontSize: CGFloat = dayString.count >= 2 ? 9 : 10
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        let attributed = NSAttributedString(string: dayString, attributes: attributes)
        let textSize = attributed.size()
        let textRect = NSRect(
            x: chipRect.minX,
            y: chipRect.midY - textSize.height / 2 - 0.5,
            width: chipRect.width,
            height: textSize.height
        )

        NSGraphicsContext.current?.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        attributed.draw(in: textRect)
        NSGraphicsContext.current?.restoreGraphicsState()
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
final class CalendarAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private weak var statusView: CalendarStatusView?
    private var panel: NSPanel?
    private var clickMonitor: Any?
    private var dayRefreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDefaults.registerDefaults()

        configurePanel()
        configureStatusItem()
        configureShowNotification()
        scheduleDayRefresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        removeClickMonitor()
        dayRefreshTimer?.invalidate()
        dayRefreshTimer = nil
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
        let size = CalendarSizing.preferredSize()
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
            rootView: CalendarPopoverView(onQuit: { [weak self] in self?.quit() })
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
        let item = NSStatusBar.system.statusItem(withLength: CalendarStatusView.statusWidth)
        statusItem = item

        let statusView = CalendarStatusView()
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
            name: CalendarNotifications.showWindow,
            object: nil
        )
    }

    /// Refreshes the tray glyph's day number periodically so it rolls over at midnight without a
    /// relaunch. Follows the Swift-6.1-safe timer pattern: the block hops back onto the main actor.
    private func scheduleDayRefresh() {
        dayRefreshTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.statusView?.refreshDay()
            }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        dayRefreshTimer = timer
    }

    @objc private func showPanelFromNotification(_ notification: Notification) {
        showPanel()
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

        statusView?.refreshDay()

        let size = CalendarSizing.preferredSize()
        panel.setContentSize(size)
        panel.setFrame(panelFrame(for: size), display: true)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        startClickMonitorAfterOpeningClick()
    }

    private func closePanel() {
        panel?.orderOut(nil)
        removeClickMonitor()
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
