import AppKit
import DMonteCore
import OSLog
import SwiftUI

/// Distributed notification used to reveal this helper's popover when the Toolbox (or a second
/// launch with `--open`) asks for it.
enum SnippetsNotifications {
    static let showWindow = Notification.Name("com.havokentity.mactools.snippets.showWindow")
}

@MainActor
final class SnippetsAppDelegate: NSObject, NSApplicationDelegate {
    private let controller = SnippetsController()

    private var statusItem: HelperStatusItem?
    private var panelHost: HelperPanelHost?
    private var keyMonitor: Any?

    /// History of app activations so a pasted snippet lands in the app the user was typing in
    /// before the status-item click — with separate Spaces that click spuriously re-activates the
    /// topmost app on the panel's display, sometimes *before* `onWillShow` runs. The tracker owns
    /// the skip logic and freezes the history while the panel is open; see `ActivationTracker`.
    /// Only our own activations are excluded — pasting into another helper is legitimate.
    private let activationTracker: ActivationTracker

    private static let log = Logger(subsystem: SnippetsController.bundleIdentifier, category: "paste-target")

    override init() {
        activationTracker = ActivationTracker(
            logger: SnippetsAppDelegate.log,
            excluding: { $0.bundleIdentifier == SnippetsController.bundleIdentifier }
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDefaults.registerDefaults()

        controller.onRequestClose = { [weak self] in
            self?.panelHost?.close()
        }

        configurePanelHost()
        configureStatusItem()
        panelHost?.observeShowNotification(named: SnippetsNotifications.showWindow)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Library saves are debounced; the task that would perform them dies with us.
        controller.store.flushPendingSave()
        panelHost?.stopObservingShowNotifications()
        activationTracker.stopObserving()
        panelHost?.removeOutsideClickMonitor()
        removeKeyMonitor()
        panelHost?.dismissForTermination()
        statusItem?.remove()
    }

    // MARK: - Setup

    private func configurePanelHost() {
        // The panel takes keyboard focus so the user can type to search; the previous app is
        // re-activated right before the synthetic ⌘V.
        let host = HelperPanelHost(
            configuration: HelperPanelHost.Configuration(
                sizing: .preferred({ SnippetsSizing.preferredSize() })
            ),
            content: .viewController({ [controller, weak self] in
                NSHostingController(
                    rootView: SnippetsPopoverView(controller: controller, onQuit: { self?.quit() })
                )
            }),
            anchorView: { [weak self] in self?.statusItem?.button }
        )
        host.onWillShow = { [weak self] in
            guard let self else { return }
            // The app to paste into is whatever the user was working in just before we
            // appeared — resolved from the activation history, then frozen for this session.
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
        statusItem = HelperStatusItem(
            image: Self.statusIcon(),
            toolTip: "Snippets",
            primaryAction: { [weak self] in self?.panelHost?.toggle() },
            quitAction: { [weak self] in self?.quit() }
        )
    }

    private static func statusIcon() -> NSImage {
        let image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Snippets") ?? NSImage()
        image.isTemplate = true
        return image
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
