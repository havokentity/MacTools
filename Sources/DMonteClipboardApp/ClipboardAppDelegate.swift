import AppKit
import DMonteCore
import OSLog
import SwiftUI

@MainActor
final class ClipboardAppDelegate: NSObject, NSApplicationDelegate {
    private let controller = ClipboardController()

    private var statusItem: HelperStatusItem?
    private var panelHost: HelperPanelHost?
    private var hotKey: GlobalHotKey?
    private var keyMonitor: Any?

    /// History of app activations so the paste target can be "the app the user was typing in
    /// before the status-item click" — with separate Spaces that click spuriously re-activates
    /// the topmost app on the panel's display, sometimes *before* `onWillShow` runs. The tracker
    /// owns the skip logic and freezes the history while the panel is open; see
    /// `ActivationTracker` for the full story. Only our own activations are excluded (no suite
    /// filtering: pasting into the Toolbox or another helper is legitimate).
    private let activationTracker: ActivationTracker

    private static let log = Logger(subsystem: ClipboardMonitor.bundleIdentifier, category: "paste-target")
    private static let hotKeyLog = Logger(subsystem: ClipboardMonitor.bundleIdentifier, category: "hotkey")

    override init() {
        activationTracker = ActivationTracker(
            logger: ClipboardAppDelegate.log,
            excluding: { $0.bundleIdentifier == ClipboardMonitor.bundleIdentifier }
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDefaults.registerDefaults()

        // Without a main menu, AppKit never matches ⌘C/⌘V/⌘A/⌘Z, so they are dead in
        // this tool's text fields. The menu is never drawn; it exists for the shortcuts.
        HelperMainMenu.installEditMenuIfNeeded()
        ClipboardLoginItem.refreshIfEnabled()

        controller.onRequestClose = { [weak self] in
            self?.panelHost?.close()
        }
        controller.startCapturing()

        configurePanelHost()
        configureStatusItem()
        panelHost?.observeShowNotification(named: HelperNotifications.showClipboardWindow)
        registerHotKey()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // History saves are debounced; the task that would perform them dies with us.
        controller.store.flushPendingSave()
        panelHost?.stopObservingShowNotifications()
        activationTracker.stopObserving()
        panelHost?.removeOutsideClickMonitor()
        removeKeyMonitor()
        hotKey = nil
        panelHost?.dismissForTermination()
        statusItem?.remove()
    }

    // MARK: - Setup

    private func configurePanelHost() {
        // The panel can take keyboard focus (so the user can type to search and navigate) while
        // still floating over other apps. We re-activate the previous app before pasting.
        let host = HelperPanelHost(
            configuration: HelperPanelHost.Configuration(
                sizing: .preferred({ ClipboardSizing.preferredSize() })
            ),
            content: .viewController({ [controller, weak self] in
                NSHostingController(
                    rootView: ClipboardPopoverView(controller: controller, onQuit: { self?.quit() })
                )
            }),
            anchorView: { [weak self] in self?.statusItem?.button }
        )
        host.onWillShow = { [weak self] in
            guard let self else { return }
            // The app to paste into is whatever the user was working in just before we
            // appeared — resolved from the activation history, frozen for this session.
            let target = self.activationTracker.resolveTarget() ?? NSWorkspace.shared.frontmostApplication
            self.activationTracker.beginSession()
            self.controller.pasteTarget = target
            Self.log.info("paste target: \(target?.localizedName ?? "none", privacy: .public)")
            self.controller.prepareForShow()
        }
        host.onDidShow = { [weak self] in
            self?.installKeyMonitor()
        }
        host.onDidClose = { [weak self] in
            self?.activationTracker.endSession()
            self?.removeKeyMonitor()
        }
        panelHost = host
        host.configure()
    }

    private func configureStatusItem() {
        let icon = NSImage(systemSymbolName: "doc.on.clipboard.fill", accessibilityDescription: "Clipboard") ?? NSImage()
        statusItem = HelperStatusItem(
            image: icon,
            toolTip: "Clipboard",
            primaryAction: { [weak self] in self?.panelHost?.toggle() },
            quitAction: { [weak self] in self?.quit() }
        )
    }

    private func registerHotKey() {
        // Release the old key before creating its replacement: GlobalHotKey refuses
        // duplicate ids, and plain reassignment constructs the new key while the old
        // one is still registered.
        hotKey = nil
        hotKey = GlobalHotKey.commandShiftV { [weak self] in
            Task { @MainActor in
                self?.panelHost?.toggle()
            }
        }

        if hotKey == nil {
            // Carbon refuses the combo when another clipboard manager holds it exclusively. The
            // panel is still reachable from the status item, so this costs the accelerator rather
            // than the feature — but it must not vanish without a trace.
            Self.hotKeyLog.error(
                "⇧⌘V registration failed; secure input active: \(SecureInputState.isBlockingHotKeys, privacy: .public)"
            )
        }
    }

    // MARK: - Key monitor

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

    private func quit() {
        panelHost?.close()
        NSApp.terminate(nil)
    }
}
