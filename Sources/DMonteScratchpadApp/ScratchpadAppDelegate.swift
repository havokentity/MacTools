import AppKit
import DMonteCore
import SwiftUI

/// Distributed notification used to reveal this helper's popover when the Toolbox (or a second
/// launch with `--open`) asks for it.
enum ScratchpadNotifications {
    static let showWindow = Notification.Name("com.havokentity.mactools.scratchpad.showWindow")
}

@MainActor
final class ScratchpadAppDelegate: NSObject, NSApplicationDelegate {
    private let controller = ScratchpadController()

    private var statusItem: HelperStatusItem?
    private var panelHost: HelperPanelHost?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDefaults.registerDefaults()

        let host = HelperPanelHost(
            configuration: HelperPanelHost.Configuration(
                sizing: .preferred({ ScratchpadSizing.preferredSize() })
            ),
            content: .viewController({ [controller, weak self] in
                NSHostingController(
                    rootView: ScratchpadPopoverView(controller: controller, onQuit: { self?.quit() })
                )
            }),
            anchorView: { [weak self] in self?.statusItem?.button }
        )
        panelHost = host

        // Closing the panel is the moment a user assumes their notes are "put away", and it is
        // also the last chance to write before an idle process is killed — so the debounced save
        // is forced through here as well as at termination.
        host.onDidClose = { [controller] in controller.flushPendingSaves() }
        host.configure()

        statusItem = HelperStatusItem(
            image: Self.statusIcon(),
            toolTip: "Scratchpad",
            primaryAction: { [weak self] in self?.panelHost?.toggle() },
            quitAction: { [weak self] in self?.quit() }
        )

        host.observeShowNotification(named: ScratchpadNotifications.showWindow)
    }

    func applicationWillTerminate(_ notification: Notification) {
        panelHost?.stopObservingShowNotifications()
        panelHost?.removeOutsideClickMonitor()
        // Before anything else tears down: the debounced writes are detached tasks that die with
        // the process, so the last few hundred milliseconds of typing only survives this flush.
        controller.flushPendingSaves()
        panelHost?.dismissForTermination()
        statusItem?.remove()
    }

    private static func statusIcon() -> NSImage {
        let image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "Scratchpad") ?? NSImage()
        image.isTemplate = true
        return image
    }

    private func quit() {
        panelHost?.close()
        NSApp.terminate(nil)
    }
}
