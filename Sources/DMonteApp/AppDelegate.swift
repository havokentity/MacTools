import AppKit
import Combine
import CoreText
import DMonteCore
import Darwin
import Sparkle
import SwiftUI

/// A borderless panel returns `canBecomeKey == false` by default, which leaves the SwiftUI
/// search field unfocusable/unclickable. Overriding it lets the popover take keyboard focus
/// while `.nonactivatingPanel` keeps it from stealing activation from the user's current app.
private final class KeyableToolboxPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: self
    )
    private var toolboxStatusItem: NSStatusItem?
    private var toolboxPanel: NSPanel?
    private var toolboxHostingController: NSHostingController<ToolPopoverView>?
    private var defaultsSink: AnyCancellable?
    private var eventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDefaults.registerDefaults()
        // Force the lazy updater into existence at launch: Sparkle's scheduled
        // automatic checks (SUEnableAutomaticChecks/SUScheduledCheckInterval) only
        // start once SPUStandardUpdaterController is instantiated.
        _ = updaterController
        migrateHelperLoginItemsIfNeeded()
        configureToolboxPopover()
        configureToolboxStatusItem()
        configureToolboxShowNotifications()
    }

    /// The "DMonte Toolbox.app" → "DMonte Tool Box.app" rename (the installer deletes the
    /// legacy bundle) left existing LaunchAgents pointing at a dead helper path, and the
    /// helpers only rewrite their own agent when they run — which launchd can no longer do.
    /// Repair them from the main app instead: compute the path each helper's own
    /// `Bundle.main.executableURL` would report inside the *current* bundle and rewrite any
    /// installed agent that is stale. Silent and nearly free when nothing needs migrating.
    private func migrateHelperLoginItemsIfNeeded() {
        if let clipboardPath = bundledHelperExecutablePath(toolID: "clipboard") {
            ClipboardLoginItem.migrateInstalledAgentIfNeeded(toExecutablePath: clipboardPath)
        }

        if let systemMonitorPath = bundledHelperExecutablePath(toolID: "systemMonitor") {
            SystemMonitorLoginItem.migrateInstalledAgentIfNeeded(toExecutablePath: systemMonitorPath)
        }
    }

    /// Mirrors the layout `Scripts/package_app.sh` produces and that a running helper's
    /// `Bundle.main.executableURL` resolves to: Contents/Helpers/<App>.app/Contents/MacOS/<exe>.
    private func bundledHelperExecutablePath(toolID: String) -> String? {
        guard let tool = ToolboxCatalog.all.first(where: { $0.id == toolID }) else {
            return nil
        }

        return bundledHelperURL(appName: tool.appName)?
            .appendingPathComponent("Contents")
            .appendingPathComponent("MacOS")
            .appendingPathComponent(tool.executableName)
            .path
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        defaultsSink = nil

        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }

        toolboxPanel?.orderOut(nil)
        toolboxPanel = nil
        toolboxHostingController = nil

        if let toolboxStatusItem {
            NSStatusBar.system.removeStatusItem(toolboxStatusItem)
            self.toolboxStatusItem = nil
        }
    }

    private func configureToolboxPopover() {
        let popoverSize = Self.preferredPopoverSize()
        let panel = KeyableToolboxPanel(
            contentRect: NSRect(origin: .zero, size: popoverSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hostingController = NSHostingController(rootView: toolboxRootView(popoverSize: popoverSize))
        hostingController.view.frame = NSRect(origin: .zero, size: popoverSize)
        panel.contentViewController = hostingController
        toolboxHostingController = hostingController
        panel.contentMinSize = popoverSize
        panel.contentMaxSize = popoverSize
        panel.setContentSize(popoverSize)
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.level = .popUpMenu
        toolboxPanel = panel
    }

    private func configureToolboxStatusItem() {
        guard toolboxStatusItem == nil else {
            return
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        toolboxStatusItem = item

        StatusBarButtonContent.install(
            image: Self.toolboxStatusImage(),
            in: item,
            toolTip: "D'Monte's Tool Box",
            target: self,
            action: #selector(toolboxStatusItemClicked)
        )
    }

    @objc private func toolboxStatusItemClicked() {
        if StatusBarButtonContent.popUpQuitMenuIfNeeded(
            for: toolboxStatusItem,
            additionalItems: [
                (title: "Check for Updates", action: { [weak self] in
                    self?.checkForUpdates()
                })
            ],
            action: { [weak self] in
                self?.quit()
            }
        ) {
            return
        }

        guard let button = toolboxStatusItem?.button else { return }
        toggleToolboxPopover(from: button)
    }

    private func toolboxRootView(popoverSize: NSSize) -> ToolPopoverView {
        ToolPopoverView(
            popoverSize: popoverSize,
            onOpenTool: { [weak self] tool in
                self?.openTool(tool)
            },
            onCheckForUpdates: { [weak self] in
                self?.checkForUpdates()
            },
            onQuit: { [weak self] in
                self?.quit()
            }
        )
    }

    private func configureToolboxShowNotifications() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(showToolboxFromNotification(_:)),
            name: HelperNotifications.showToolboxWindow,
            object: nil
        )
    }

    @objc private func showToolboxFromNotification(_ notification: Notification) {
        guard let button = toolboxStatusItem?.button else {
            return
        }

        showToolboxPopover(from: button)
    }

    private func openTool(_ tool: ToolboxTool) {
        ToolboxRecentTools.record(tool, in: AppDefaults.shared)
        launchHelper(tool)
        closeToolboxPopover()
    }

    private func launchHelper(_ tool: ToolboxTool) {
        let runningApplications = NSRunningApplication.runningApplications(withBundleIdentifier: tool.bundleID)

        guard runningApplications.isEmpty else {
            // Already running: ask it to reveal its window (the helper observes this name).
            if tool.arguments.contains("--open") {
                DistributedNotificationCenter.default().postNotificationName(
                    tool.showNotification,
                    object: nil,
                    userInfo: nil,
                    deliverImmediately: true
                )
            }
            return
        }

        if let helperAppURL = bundledHelperURL(appName: tool.appName), FileManager.default.fileExists(atPath: helperAppURL.path) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.arguments = tool.arguments
            NSWorkspace.shared.openApplication(at: helperAppURL, configuration: configuration)
            return
        }

        if let helperExecutableURL = debugHelperExecutableURL(executableName: tool.executableName),
           FileManager.default.fileExists(atPath: helperExecutableURL.path) {
            _ = try? Process.run(helperExecutableURL, arguments: tool.arguments)
        }
    }

    private func bundledHelperURL(appName: String) -> URL? {
        Bundle.main.bundleURL.appendingPathComponent("Contents").appendingPathComponent("Helpers").appendingPathComponent(appName)
    }

    private func debugHelperExecutableURL(executableName: String) -> URL? {
        Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent(executableName)
    }

    private func toggleToolboxPopover(from view: NSView) {
        if isToolboxPanelVisible {
            closeToolboxPopover()
        } else {
            showToolboxPopover(from: view)
        }
    }

    private func showToolboxPopover(from view: NSView) {
        guard let panel = toolboxPanel else {
            return
        }

        let size = Self.preferredPopoverSize()
        applyPopoverSize(size, to: panel)
        panel.level = .popUpMenu
        panel.setFrame(Self.panelFrame(for: size, anchoredTo: view), display: true)
        panel.makeKeyAndOrderFront(nil)
        startOutsideClickMonitorAfterOpeningClick()
    }

    /// `ToolPopoverView` pins itself to the size it was built with, so resizing the panel alone
    /// leaves the frosted content at the old size. Rebuild the SwiftUI root alongside it: the
    /// preferred size follows `NSScreen.main`, which tracks the focused screen and can differ
    /// from the display the popover was configured on at launch.
    private func applyPopoverSize(_ size: NSSize, to panel: NSPanel) {
        guard panel.contentMinSize != size else {
            return
        }

        toolboxHostingController?.rootView = toolboxRootView(popoverSize: size)
        panel.contentMinSize = size
        panel.contentMaxSize = size
        panel.setContentSize(size)
    }

    private func closeToolboxPopover() {
        toolboxPanel?.orderOut(nil)
        stopOutsideClickMonitorIfIdle()
    }

    private func checkForUpdates() {
        prepareForSparkleModal()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.updaterController.checkForUpdates(nil)
        }
    }

    func standardUserDriverWillShowModalAlert() {
        prepareForSparkleModal()
    }

    func standardUserDriverDidShowModalAlert() {
        bringSparkleModalToFront()
    }

    private func prepareForSparkleModal() {
        closeToolboxPopover()
        toolboxPanel?.level = .normal
        NSApp.activate(ignoringOtherApps: true)
    }

    private func bringSparkleModalToFront() {
        prepareForSparkleModal()

        // Only promote Sparkle's own windows (SU-prefixed classes such as SUUpdateAlert /
        // SUStatusController). NSApp.windows also contains the always-visible
        // NSStatusBarWindow hosting the tray icon — demoting that from status-bar level to
        // .modalPanel and reordering it front is exactly the "disappearing tray icon" bug
        // class commit 1e04345 fixed. As a safety belt, also skip any window already above
        // .normal (status-bar and other elevated windows don't need our help). Sparkle's
        // windows close themselves when the update interaction ends, so restoring their
        // level afterward is unnecessary.
        for window in NSApp.windows where window !== toolboxPanel && window.isVisible {
            guard String(describing: type(of: window)).hasPrefix("SU"),
                  window.level.rawValue <= NSWindow.Level.normal.rawValue else {
                continue
            }

            window.level = .modalPanel
            window.makeKeyAndOrderFront(nil)
        }
    }


    private func startOutsideClickMonitor() {
        guard isToolboxPanelVisible else {
            return
        }

        if eventMonitor != nil {
            return
        }

        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closeToolboxPopover()
        }
    }

    private func startOutsideClickMonitorAfterOpeningClick() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.startOutsideClickMonitor()
        }
    }

    private func stopOutsideClickMonitorIfIdle() {
        guard !isToolboxPanelVisible, let eventMonitor else {
            return
        }

        NSEvent.removeMonitor(eventMonitor)
        self.eventMonitor = nil
    }

    private var isToolboxPanelVisible: Bool {
        toolboxPanel?.isVisible == true
    }

    private func quit() {
        closeToolboxPopover()

        if let toolboxStatusItem {
            NSStatusBar.system.removeStatusItem(toolboxStatusItem)
            self.toolboxStatusItem = nil
        }

        NSApp.terminate(nil)

        // Watchdog so a stalled or cancelled termination can't leave a "quit" app
        // running — but never while Sparkle has an update session in flight:
        // terminate(nil) is exactly how an install-on-quit update hands off to the
        // installer, and a hard exit here would abort the queued install mid-handoff.
        guard !updaterController.updater.sessionInProgress else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            exit(EXIT_SUCCESS)
        }
    }

    static func preferredPopoverSize() -> NSSize {
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(460, max(420, visibleFrame.width * 0.24))
        let height = min(430, max(360, visibleFrame.height - 220))

        return NSSize(width: width, height: height)
    }

    static func preferredSystemMonitorPanelSize() -> NSSize {
        SystemMonitorPanelSizing.preferredSize()
    }

    private static func panelFrame(for size: NSSize, anchoredTo view: NSView) -> NSRect {
        guard let window = view.window, let screen = window.screen ?? NSScreen.main else {
            return centeredPanelFrame(for: size)
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

    private static func centeredPanelFrame(for size: NSSize) -> NSRect {
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(
            x: visibleFrame.midX - (size.width / 2),
            y: visibleFrame.midY - (size.height / 2),
            width: size.width,
            height: size.height
        )
    }

    static func toolboxStatusImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            // A toolbox silhouette — solid body + arched handle — with a bold rounded "D"
            // monogram knocked out of the body.
            NSColor.black.setFill()
            NSColor.black.setStroke()

            let cx = rect.midX
            let body = NSRect(x: rect.minX + 1.7, y: rect.minY + 2.4, width: 14.6, height: 9.1)
            NSBezierPath(roundedRect: body, xRadius: 2.2, yRadius: 2.2).fill()

            let handle = NSBezierPath()
            handle.lineWidth = 1.7
            handle.lineCapStyle = .round
            handle.lineJoinStyle = .round
            let halfWidth: CGFloat = 3.4
            let handleTop = rect.minY + 15.0
            let bodyTop = body.maxY - 0.3
            handle.move(to: NSPoint(x: cx - halfWidth, y: bodyTop))
            handle.line(to: NSPoint(x: cx - halfWidth, y: handleTop - 1.0))
            handle.curve(
                to: NSPoint(x: cx + halfWidth, y: handleTop - 1.0),
                controlPoint1: NSPoint(x: cx - halfWidth, y: handleTop + 0.8),
                controlPoint2: NSPoint(x: cx + halfWidth, y: handleTop + 0.8)
            )
            handle.line(to: NSPoint(x: cx + halfWidth, y: bodyTop))
            handle.stroke()

            guard let context = NSGraphicsContext.current else { return true }
            let cgContext = context.cgContext

            // Render the "D" glyph large for precision, scale its bounding box to a fraction
            // of the body height, center it, and knock it out of the body.
            let font = NSFont.systemFont(ofSize: 100, weight: .heavy).fontDescriptor.withDesign(.rounded)
                .flatMap { NSFont(descriptor: $0, size: 100) } ?? NSFont.systemFont(ofSize: 100, weight: .heavy)
            let ctFont = font as CTFont
            var characters = Array("D".utf16)
            var glyphs = [CGGlyph](repeating: 0, count: characters.count)
            guard CTFontGetGlyphsForCharacters(ctFont, &characters, &glyphs, characters.count),
                  let glyphPath = CTFontCreatePathForGlyph(ctFont, glyphs[0], nil) else {
                return true
            }

            let box = glyphPath.boundingBoxOfPath
            let scale = (body.height * 0.62) / box.height
            var transform = CGAffineTransform(translationX: cx, y: body.midY)
                .scaledBy(x: scale, y: scale)
                .translatedBy(x: -box.midX, y: -box.midY)
            guard let centered = glyphPath.copy(using: &transform) else { return true }

            cgContext.saveGState()
            cgContext.setBlendMode(.destinationOut)
            cgContext.addPath(centered)
            cgContext.fillPath()
            cgContext.restoreGState()

            return true
        }

        image.isTemplate = true
        image.accessibilityDescription = "D'Monte's Tool Box"

        return image
    }
}
