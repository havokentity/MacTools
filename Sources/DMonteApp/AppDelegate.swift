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
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let systemMonitorHelperBundleIdentifier = "com.havokentity.mactools.systemmonitor"
    private static let uninstallerHelperBundleIdentifier = "com.havokentity.mactools.uninstaller"
    private static let cleanDriveHelperBundleIdentifier = "com.havokentity.mactools.cleandrive"
    private static let videoDownloaderHelperBundleIdentifier = "com.havokentity.mactools.videodownloader"
    private static let diskAnalyzerHelperBundleIdentifier = "com.havokentity.mactools.diskanalyzer"
    private static let clipboardHelperBundleIdentifier = "com.havokentity.mactools.clipboard"

    private static let openHelpersDefaultsKey = "com.havokentity.mactools.toolbox.openHelpers"

    private struct HelperDescriptor {
        let bundleId: String
        let appName: String
        let executableName: String
        let arguments: [String]
    }

    private static let helperDescriptors: [HelperDescriptor] = [
        HelperDescriptor(bundleId: systemMonitorHelperBundleIdentifier, appName: "DMonte System Monitor.app", executableName: "DMonteSystemMonitor", arguments: []),
        HelperDescriptor(bundleId: uninstallerHelperBundleIdentifier, appName: "DMonte Uninstaller.app", executableName: "DMonteUninstaller", arguments: ["--open"]),
        HelperDescriptor(bundleId: cleanDriveHelperBundleIdentifier, appName: "DMonte Clean Drive.app", executableName: "DMonteCleanDrive", arguments: ["--open"]),
        HelperDescriptor(bundleId: videoDownloaderHelperBundleIdentifier, appName: "DMonte Video Downloader.app", executableName: "DMonteVideoDownloader", arguments: ["--open"]),
        HelperDescriptor(bundleId: diskAnalyzerHelperBundleIdentifier, appName: "DMonte Disk Analyzer.app", executableName: "DMonteDiskAnalyzer", arguments: ["--open"]),
        HelperDescriptor(bundleId: clipboardHelperBundleIdentifier, appName: "DMonte Clipboard.app", executableName: "DMonteClipboard", arguments: ["--open"])
    ]

    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    private var toolboxStatusItem: NSStatusItem?
    private weak var toolboxStatusView: ToolboxStatusView?
    private var toolboxPanel: NSPanel?
    private var defaultsSink: AnyCancellable?
    private var eventMonitor: Any?
    private var helpersPendingRelaunch: Set<String> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDefaults.registerDefaults()
        configureToolboxPopover()
        configureToolboxStatusItem()
        configureToolboxShowNotifications()
        observeHelperTerminations()
        restoreHelpersAfterRestart()
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        // A deliberate quit must NOT trigger a restore on the next launch — only an
        // unexpected kill (e.g. TCC restarting us to apply a permission grant) should.
        // The kill path skips this method, so the saved set survives only then.
        saveOpenHelpers([])
        defaultsSink = nil

        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }

        toolboxPanel?.orderOut(nil)
        toolboxPanel = nil

        if let toolboxStatusItem {
            NSStatusBar.system.removeStatusItem(toolboxStatusItem)
            self.toolboxStatusItem = nil
            self.toolboxStatusView = nil
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

        let item = NSStatusBar.system.statusItem(withLength: ToolboxStatusView.statusWidth)
        toolboxStatusItem = item

        let statusView = ToolboxStatusView(image: Self.toolboxStatusImage())
        statusView.onClick = { [weak self, weak statusView] in
            guard let statusView else {
                return
            }

            self?.toggleToolboxPopover(from: statusView)
        }
        item.view = statusView
        toolboxStatusView = statusView
    }

    private func toolboxRootView(popoverSize: NSSize) -> some View {
        ToolPopoverView(
            popoverSize: popoverSize,
            onOpenSystemMonitor: { [weak self] in
                self?.openSystemMonitorFromToolbox()
            },
            onOpenUninstaller: { [weak self] in
                self?.openUninstallerFromToolbox()
            },
            onOpenCleanDrive: { [weak self] in
                self?.openCleanDriveFromToolbox()
            },
            onOpenVideoDownloader: { [weak self] in
                self?.openVideoDownloaderFromToolbox()
            },
            onOpenDiskAnalyzer: { [weak self] in
                self?.openDiskAnalyzerFromToolbox()
            },
            onOpenClipboard: { [weak self] in
                self?.openClipboardFromToolbox()
            },
            onCheckForUpdates: { [weak self] in
                self?.updaterController.checkForUpdates(nil)
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
        guard let statusView = toolboxStatusView else {
            return
        }

        showToolboxPopover(from: statusView)
    }

    private func launchHelper(
        bundleIdentifier: String,
        appName: String,
        executableName: String,
        arguments: [String] = []
    ) {
        // Remember that this tool is open so we can restore it if macOS kills and
        // relaunches the Toolbox (e.g. when applying a Full Disk Access grant).
        persistHelperOpen(bundleIdentifier)

        let runningApplications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)

        guard runningApplications.isEmpty else {
            if arguments.contains("--open") {
                if bundleIdentifier == Self.systemMonitorHelperBundleIdentifier {
                    DistributedNotificationCenter.default().postNotificationName(
                        HelperNotifications.showSystemMonitorWindow,
                        object: nil,
                        userInfo: nil,
                        deliverImmediately: true
                    )
                } else if bundleIdentifier == Self.uninstallerHelperBundleIdentifier {
                    DistributedNotificationCenter.default().postNotificationName(
                        HelperNotifications.showUninstallerWindow,
                        object: nil,
                        userInfo: nil,
                        deliverImmediately: true
                    )
                } else if bundleIdentifier == Self.cleanDriveHelperBundleIdentifier {
                    DistributedNotificationCenter.default().postNotificationName(
                        HelperNotifications.showCleanDriveWindow,
                        object: nil,
                        userInfo: nil,
                        deliverImmediately: true
                    )
                } else if bundleIdentifier == Self.videoDownloaderHelperBundleIdentifier {
                    DistributedNotificationCenter.default().postNotificationName(
                        HelperNotifications.showVideoDownloaderWindow,
                        object: nil,
                        userInfo: nil,
                        deliverImmediately: true
                    )
                } else if bundleIdentifier == Self.diskAnalyzerHelperBundleIdentifier {
                    DistributedNotificationCenter.default().postNotificationName(
                        HelperNotifications.showDiskAnalyzerWindow,
                        object: nil,
                        userInfo: nil,
                        deliverImmediately: true
                    )
                } else if bundleIdentifier == Self.clipboardHelperBundleIdentifier {
                    DistributedNotificationCenter.default().postNotificationName(
                        HelperNotifications.showClipboardWindow,
                        object: nil,
                        userInfo: nil,
                        deliverImmediately: true
                    )
                }
            }

            return
        }

        if let helperAppURL = bundledHelperURL(appName: appName), FileManager.default.fileExists(atPath: helperAppURL.path) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.arguments = arguments
            NSWorkspace.shared.openApplication(at: helperAppURL, configuration: configuration)
            return
        }

        if let helperExecutableURL = debugHelperExecutableURL(executableName: executableName),
           FileManager.default.fileExists(atPath: helperExecutableURL.path) {
            _ = try? Process.run(helperExecutableURL, arguments: arguments)
        }
    }

    private func terminateHelper(bundleIdentifier: String) {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).forEach { $0.terminate() }
    }

    // MARK: - Helper session restore

    private func observeHelperTerminations() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(helperAppDidTerminate(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
    }

    @objc private func helperAppDidTerminate(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleId = app.bundleIdentifier,
              Self.helperDescriptors.contains(where: { $0.bundleId == bundleId }) else {
            return
        }

        if helpersPendingRelaunch.remove(bundleId) != nil {
            // We terminated this orphaned instance as part of a restart-restore;
            // bring it back fresh so it runs under the relaunched Toolbox (and thus
            // inherits any newly granted permission).
            relaunchHelper(bundleId: bundleId)
            return
        }

        // Otherwise the user closed the tool themselves — stop tracking it.
        persistHelperClosed(bundleId)
    }

    private func restoreHelpersAfterRestart() {
        let saved = loadOpenHelpers()
        guard !saved.isEmpty else {
            return
        }

        for bundleId in saved {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            if running.isEmpty {
                // Nothing left to clean up (kill took it too) — just reopen.
                relaunchHelper(bundleId: bundleId)
            } else {
                // Close the orphan first; the termination observer reopens it fresh.
                helpersPendingRelaunch.insert(bundleId)
                running.forEach { $0.terminate() }
            }
        }

        if !helpersPendingRelaunch.isEmpty {
            scheduleOrphanForceTerminate()
        }
    }

    private func scheduleOrphanForceTerminate() {
        // If a helper ignores the polite terminate (e.g. a modal sheet), force it
        // after a grace period; the termination observer still handles the reopen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self else { return }
            for bundleId in self.helpersPendingRelaunch {
                NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).forEach { $0.forceTerminate() }
            }
        }
    }

    private func relaunchHelper(bundleId: String) {
        guard let descriptor = Self.helperDescriptors.first(where: { $0.bundleId == bundleId }) else {
            return
        }

        launchHelper(
            bundleIdentifier: descriptor.bundleId,
            appName: descriptor.appName,
            executableName: descriptor.executableName,
            arguments: descriptor.arguments
        )
    }

    private func loadOpenHelpers() -> Set<String> {
        let stored = UserDefaults.standard.array(forKey: Self.openHelpersDefaultsKey) as? [String] ?? []
        return Set(stored)
    }

    private func saveOpenHelpers(_ helpers: Set<String>) {
        UserDefaults.standard.set(Array(helpers), forKey: Self.openHelpersDefaultsKey)
    }

    private func persistHelperOpen(_ bundleId: String) {
        var set = loadOpenHelpers()
        guard !set.contains(bundleId) else { return }
        set.insert(bundleId)
        saveOpenHelpers(set)
    }

    private func persistHelperClosed(_ bundleId: String) {
        var set = loadOpenHelpers()
        guard set.contains(bundleId) else { return }
        set.remove(bundleId)
        saveOpenHelpers(set)
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
        panel.setContentSize(size)
        panel.setFrame(Self.panelFrame(for: size, anchoredTo: view), display: true)
        panel.makeKeyAndOrderFront(nil)
        startOutsideClickMonitorAfterOpeningClick()
    }

    private func closeToolboxPopover() {
        toolboxPanel?.orderOut(nil)
        stopOutsideClickMonitorIfIdle()
    }

    private func openSystemMonitorFromToolbox() {
        launchHelper(
            bundleIdentifier: Self.systemMonitorHelperBundleIdentifier,
            appName: "DMonte System Monitor.app",
            executableName: "DMonteSystemMonitor"
        )
        closeToolboxPopover()
    }

    private func openUninstallerFromToolbox() {
        launchHelper(
            bundleIdentifier: Self.uninstallerHelperBundleIdentifier,
            appName: "DMonte Uninstaller.app",
            executableName: "DMonteUninstaller",
            arguments: ["--open"]
        )
        closeToolboxPopover()
    }

    private func openCleanDriveFromToolbox() {
        launchHelper(
            bundleIdentifier: Self.cleanDriveHelperBundleIdentifier,
            appName: "DMonte Clean Drive.app",
            executableName: "DMonteCleanDrive",
            arguments: ["--open"]
        )
        closeToolboxPopover()
    }

    private func openVideoDownloaderFromToolbox() {
        launchHelper(
            bundleIdentifier: Self.videoDownloaderHelperBundleIdentifier,
            appName: "DMonte Video Downloader.app",
            executableName: "DMonteVideoDownloader",
            arguments: ["--open"]
        )
        closeToolboxPopover()
    }

    private func openDiskAnalyzerFromToolbox() {
        launchHelper(
            bundleIdentifier: Self.diskAnalyzerHelperBundleIdentifier,
            appName: "DMonte Disk Analyzer.app",
            executableName: "DMonteDiskAnalyzer",
            arguments: ["--open"]
        )
        closeToolboxPopover()
    }

    private func openClipboardFromToolbox() {
        launchHelper(
            bundleIdentifier: Self.clipboardHelperBundleIdentifier,
            appName: "DMonte Clipboard.app",
            executableName: "DMonteClipboard",
            arguments: ["--open"]
        )
        closeToolboxPopover()
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
            self.toolboxStatusView = nil
        }

        NSApp.terminate(nil)

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
        image.accessibilityDescription = "D'Monte's Toolbox"

        return image
    }
}
