import AppKit
import Combine
import DMonteCore
import SwiftUI

/// Distributed notification used to reveal this helper's popover when the Toolbox (or a second
/// launch with `--open`) asks for it.
enum FileShelfNotifications {
    static let showWindow = Notification.Name("com.havokentity.mactools.fileshelf.showWindow")
}

@MainActor
final class FileShelfAppDelegate: NSObject, NSApplicationDelegate {
    /// Built lazily, on the first access in `applicationDidFinishLaunching` — i.e. *after*
    /// `AppDefaults.registerDefaults()`. The store reads the Clear Shelf confirmation preference
    /// in `init`, and a registration domain only exists once registered in this process, so an
    /// eagerly-created store would read `false` and ship the one destructive action here with its
    /// confirmation turned off.
    private lazy var store = FileShelfStore()

    private var statusItem: HelperStatusItem?
    private var panelHost: HelperPanelHost?
    private var dropView: StatusItemFileDropView?
    private var cancellables: Set<AnyCancellable> = []

    /// `true` while a drag is hovering the menu-bar icon, so the glyph can show it is a live
    /// target — the icon is the only feedback available before the popover is even open.
    private var isDragTargetingStatusItem = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDefaults.registerDefaults()

        let host = HelperPanelHost(
            configuration: HelperPanelHost.Configuration(
                sizing: .preferred({ FileShelfSizing.preferredSize() })
            ),
            content: .viewController({ [store, weak self] in
                NSHostingController(
                    rootView: FileShelfPopoverView(store: store, onQuit: { self?.quit() })
                )
            }),
            anchorView: { [weak self] in self?.statusItem?.button }
        )
        panelHost = host

        // Files get deleted, renamed and unplugged while the popover is closed, so every entry is
        // re-checked on open rather than only when something changes in-process. Cheap, and it
        // makes a row that lies about a missing file impossible to see.
        host.onWillShow = { [store] in
            store.clearStatus()
            // An armed Clear Shelf must not survive the panel closing: reopening minutes later
            // onto a primed "Clear 12 Files" button is one stray click from an empty shelf.
            store.cancelClearAll()
            store.refresh()
        }
        host.configure()

        statusItem = HelperStatusItem(
            image: Self.statusIcon(hasFiles: false, isDragTargeted: false),
            toolTip: "File Shelf — drop files here to park them",
            primaryAction: { [weak self] in self?.panelHost?.toggle() },
            quitAction: { [weak self] in self?.quit() }
        )

        installStatusItemDropTarget()

        // Reflect whatever survived the last run, before any change arrives.
        refreshStatusBadge()

        host.observeShowNotification(named: FileShelfNotifications.showWindow)
        observeStoreState()
    }

    func applicationWillTerminate(_ notification: Notification) {
        panelHost?.stopObservingShowNotifications()
        panelHost?.removeOutsideClickMonitor()
        cancellables.removeAll()
        // The shelf itself is written synchronously on every edit, so there is nothing to flush —
        // only the security scopes this process is holding open need balancing.
        store.releaseAllAccess()
        panelHost?.dismissForTermination()
        statusItem?.remove()
    }

    // MARK: - Status item

    /// The two-state tray glyph: a filled tray while files are parked, an empty one otherwise, and
    /// a downward arrow while a drag is hovering so the user can see the icon will accept it.
    /// Forced to template so AppKit tints it adaptive white and gives it the native rollover
    /// highlight.
    private static func statusIcon(hasFiles: Bool, isDragTargeted: Bool) -> NSImage {
        let name: String
        if isDragTargeted {
            name = "tray.and.arrow.down.fill"
        } else {
            name = hasFiles ? "tray.full.fill" : "tray"
        }

        let image = NSImage(systemSymbolName: name, accessibilityDescription: "File Shelf") ?? NSImage()
        image.isTemplate = true
        return image
    }

    /// Lets the menu-bar icon itself accept a drag, which is the point of the tool: park a file
    /// without opening anything, from whatever app you were already in.
    private func installStatusItemDropTarget() {
        guard let button = statusItem?.button else { return }

        let dropView = StatusItemFileDropView.install(over: button)
        dropView.onDrop = { [weak self] urls in
            self?.store.shelve(urls: urls)
        }
        dropView.onDragTargetingChanged = { [weak self] isTargeted in
            guard let self, self.isDragTargetingStatusItem != isTargeted else { return }
            self.isDragTargetingStatusItem = isTargeted
            self.refreshStatusBadge()
        }
        self.dropView = dropView
    }

    /// Keeps the menu-bar glyph and its count in step with the shelf, so "how many things am I
    /// carrying?" is answered without opening the popover.
    private func refreshStatusBadge() {
        guard let item = statusItem?.item else { return }

        StatusBarButtonContent.updateBadge(
            FileShelfKit.badgeTitle(for: store.items.count),
            image: Self.statusIcon(hasFiles: !store.items.isEmpty, isDragTargeted: isDragTargetingStatusItem),
            in: item
        )
    }

    private func observeStoreState() {
        store.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshStatusBadge()
            }
            .store(in: &cancellables)
    }

    private func quit() {
        panelHost?.close()
        NSApp.terminate(nil)
    }
}
