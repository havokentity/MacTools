import AppKit
import Combine
import DMonteCore
import SwiftUI
import UserNotifications

/// Distributed notification used to reveal this helper's popover when the Toolbox (or a second launch
/// with `--open`) asks for it.
enum FocusTimerNotifications {
    static let showWindow = Notification.Name("com.havokentity.mactools.focustimer.showWindow")
}

/// A panel that can take keyboard focus while still floating over other apps. Mirrors the other
/// tools' floating-panel behaviour and dismissal handling.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The menu-bar tray button for Focus Timer. While a session is running (or paused mid-session) it
/// draws the remaining time as text (e.g. "24:13"); when idle it draws the timer glyph. The width is
/// fixed so MM:SS fits comfortably.
private final class FocusTimerStatusView: NSControl {
    /// Wide enough to hold "MM:SS" plus padding; the status item uses this fixed width.
    static let statusWidth: CGFloat = 52

    var onClick: (() -> Void)?

    /// The text to draw, or `nil` to draw the idle glyph instead.
    var timeText: String? {
        didSet {
            guard timeText != oldValue else { return }
            needsDisplay = true
        }
    }

    private let glyph: NSImage
    private let highlightLayer = CALayer()
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        let image = NSImage(systemSymbolName: "timer", accessibilityDescription: "Focus Timer") ?? NSImage()
        image.isTemplate = true
        glyph = image
        super.init(frame: frameRect)
        wantsLayer = true
        highlightLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.11).cgColor
        highlightLayer.cornerRadius = 6
        highlightLayer.cornerCurve = .continuous
        highlightLayer.masksToBounds = true
        highlightLayer.isHidden = true
        layer?.insertSublayer(highlightLayer, at: 0)
        toolTip = "Focus Timer"
    }

    convenience init() {
        self.init(frame: NSRect(x: 0, y: 0, width: Self.statusWidth, height: NSStatusBar.system.thickness))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if let timeText {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]
            let attributed = NSAttributedString(string: timeText, attributes: attributes)
            let textSize = attributed.size()
            let textRect = NSRect(
                x: bounds.minX,
                y: bounds.midY - textSize.height / 2,
                width: bounds.width,
                height: textSize.height
            )
            attributed.draw(in: textRect)
        } else {
            let glyphSize = NSSize(width: 16, height: 16)
            let glyphRect = NSRect(
                x: bounds.midX - glyphSize.width / 2,
                y: bounds.midY - glyphSize.height / 2,
                width: glyphSize.width,
                height: glyphSize.height
            )
            NSColor.labelColor.set()
            glyph.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: 0.9)
        }
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
final class FocusTimerAppDelegate: NSObject, NSApplicationDelegate {
    private let controller = FocusTimerController()

    private var statusItem: NSStatusItem?
    private weak var statusView: FocusTimerStatusView?
    private var panel: NSPanel?
    private var clickMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []

    /// `true` once we have asked the user for notification permission (only attempted once, lazily,
    /// on the first phase completion so the prompt never appears merely on launch).
    private var didRequestNotificationAuth = false

    /// Tracks the previous phase so we only chime when the controller actually advances.
    private var lastPhase: FocusPhase = .focus

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDefaults.registerDefaults()

        lastPhase = controller.phase
        configurePanel()
        configureStatusItem()
        configureShowNotification()
        observeControllerState()
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        removeClickMonitor()
        cancellables.removeAll()
        controller.reset()
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
        let size = FocusTimerSizing.preferredSize()
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
            rootView: FocusTimerPopoverView(controller: controller, onQuit: { [weak self] in self?.quit() })
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
        let item = NSStatusBar.system.statusItem(withLength: FocusTimerStatusView.statusWidth)
        statusItem = item

        let statusView = FocusTimerStatusView()
        statusView.onClick = { [weak self] in
            self?.togglePanel()
        }
        item.view = statusView
        self.statusView = statusView
        refreshStatusTitle()
    }

    private func configureShowNotification() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(showPanelFromNotification(_:)),
            name: FocusTimerNotifications.showWindow,
            object: nil
        )
    }

    /// Keep the tray button and chime logic in sync with the controller. A single sink fires on any
    /// published change (tick, phase change, run/pause), which is exactly when the title may differ.
    private func observeControllerState() {
        controller.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                // `objectWillChange` fires *before* the new value is applied; defer to the next run
                // loop pass so we read the updated state.
                DispatchQueue.main.async {
                    self?.handleControllerChange()
                }
            }
            .store(in: &cancellables)
    }

    private func handleControllerChange() {
        if controller.phase != lastPhase {
            lastPhase = controller.phase
            announcePhaseTransition()
        }
        refreshStatusTitle()
    }

    /// Draws the remaining time when a session is active (running or paused mid-phase), otherwise the
    /// idle glyph.
    private func refreshStatusTitle() {
        guard let statusView else { return }
        if controller.isRunning || controller.progress > 0 {
            statusView.timeText = FocusTimerPopoverView.formatTime(controller.remaining)
        } else {
            statusView.timeText = nil
        }
    }

    @objc private func showPanelFromNotification(_ notification: Notification) {
        showPanel()
    }

    // MARK: - Phase transitions: chime + notification

    private func announcePhaseTransition() {
        // Always beep as a guaranteed fallback chime, even if notifications are denied/unavailable.
        NSSound.beep()
        postPhaseNotification()
    }

    /// Posts a local notification describing the new phase, requesting authorization lazily on first
    /// use. Wrapped so a missing/unavailable notification centre can never crash the helper.
    private func postPhaseNotification() {
        guard let center = makeNotificationCenter() else { return }

        let deliver: () -> Void = { [weak self] in
            guard let self else { return }
            let content = UNMutableNotificationContent()
            content.title = "Focus Timer"
            content.body = self.notificationBody(for: self.controller.phase)
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            center.add(request, withCompletionHandler: nil)
        }

        if didRequestNotificationAuth {
            // Authorization already decided once; just attempt delivery (no-op if denied).
            deliver()
            return
        }

        didRequestNotificationAuth = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async {
                deliver()
            }
        }
    }

    /// `UNUserNotificationCenter.current()` aborts the process when there is no real `.app` bundle
    /// hosting the code. Gate access on an actual packaged app so we degrade gracefully (chime only)
    /// rather than crash if launched from an unbundled context.
    private func makeNotificationCenter() -> UNUserNotificationCenter? {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return UNUserNotificationCenter.current()
    }

    private func notificationBody(for phase: FocusPhase) -> String {
        switch phase {
        case .focus:
            return "Break over — time to focus."
        case .shortBreak:
            return "Focus session complete. Take a short break."
        case .longBreak:
            return "Great work! Time for a long break."
        }
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

        let size = FocusTimerSizing.preferredSize()
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
