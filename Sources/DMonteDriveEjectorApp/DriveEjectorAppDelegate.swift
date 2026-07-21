import AppKit
import Combine
import DMonteCore
import SwiftUI

/// Distributed notification used to reveal this helper's popover when the Toolbox (or a second
/// launch with `--open`) asks for it.
enum DriveEjectorNotifications {
    static let showWindow = Notification.Name("com.havokentity.mactools.driveejector.showWindow")
}

@MainActor
final class DriveEjectorAppDelegate: NSObject, NSApplicationDelegate {
    /// Built lazily, on the first access in `applicationDidFinishLaunching` — i.e. *after*
    /// `AppDefaults.registerDefaults()`. The controller reads the Eject All confirmation
    /// preference in `init`, and a registration domain only exists once registered in this
    /// process, so an eagerly-created controller would read `false` and silently ship the one
    /// destructive action here with its confirmation turned off.
    private lazy var controller = DriveEjectorController()

    private var statusItem: HelperStatusItem?
    private var panelHost: HelperPanelHost?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDefaults.registerDefaults()

        let host = HelperPanelHost(
            configuration: HelperPanelHost.Configuration(
                sizing: .preferred({ DriveEjectorSizing.preferredSize() })
            ),
            content: .viewController({ [controller, weak self] in
                NSHostingController(
                    rootView: DriveEjectorPopoverView(controller: controller, onQuit: { self?.quit() })
                )
            }),
            anchorView: { [weak self] in self?.statusItem?.button }
        )
        panelHost = host
        host.configure()

        // The mount table changes while the popover is closed, so the list is refreshed on
        // every open rather than only on notifications — cheap, and it makes a stale row
        // impossible to see even if a notification was missed.
        host.onWillShow = { [controller] in
            controller.clearStatus()
            // An armed Eject All must not survive the panel closing: reopening minutes later onto a
            // primed "Eject 3 Volumes" button is one stray click from unmounting everything.
            controller.cancelEjectAll()
            controller.refresh()
        }

        statusItem = HelperStatusItem(
            image: Self.statusIcon(hasVolumes: false),
            toolTip: "Drive Ejector",
            primaryAction: { [weak self] in self?.panelHost?.toggle() },
            quitAction: { [weak self] in self?.quit() }
        )

        // Reflect what is already mounted at launch, before any notification arrives.
        updateStatusIcon()

        host.observeShowNotification(named: DriveEjectorNotifications.showWindow)
        controller.startObserving()
        observeControllerState()
    }

    func applicationWillTerminate(_ notification: Notification) {
        panelHost?.stopObservingShowNotifications()
        panelHost?.removeOutsideClickMonitor()
        cancellables.removeAll()
        controller.stopObserving()
        panelHost?.dismissForTermination()
        statusItem?.remove()
    }

    /// The two-state tray glyph: a filled eject symbol while external volumes are mounted, an
    /// outline when there is nothing to eject. Forced to template so AppKit tints it adaptive
    /// white and gives it the native rollover highlight.
    private static func statusIcon(hasVolumes: Bool) -> NSImage {
        let name = hasVolumes ? "eject.fill" : "eject"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Drive Ejector") ?? NSImage()
        image.isTemplate = true
        return image
    }

    private func updateStatusIcon() {
        statusItem?.button?.image = Self.statusIcon(hasVolumes: !controller.volumes.isEmpty)
    }

    /// Keep the tray glyph in sync with what is mounted, so the menu bar answers “is anything
    /// plugged in?” without opening the popover.
    private func observeControllerState() {
        controller.$volumes
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusIcon()
            }
            .store(in: &cancellables)
    }

    private func quit() {
        panelHost?.close()
        NSApp.terminate(nil)
    }
}
