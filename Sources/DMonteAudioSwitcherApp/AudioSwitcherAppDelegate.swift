import AppKit
import SwiftUI
import DMonteCore

/// A borderless panel that can still become key so the SwiftUI popover can take
/// keyboard focus while floating over other apps. (Each helper target defines its
/// own private copy; there is no shared symbol.)
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AudioSwitcherAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panel: KeyablePanel?
    private var outsideClickMonitor: Any?
    private var showWindowObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDefaults.registerDefaults()

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "hifispeaker.fill",
                accessibilityDescription: "Audio Switcher"
            )
            button.image?.isTemplate = true
            button.toolTip = "Audio Switcher"
            button.target = self
            button.action = #selector(togglePopover)
        }
        self.statusItem = statusItem

        showWindowObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.havokentity.mactools.audioswitcher.showWindow"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.showPopover()
            }
        }
    }

    @objc private func togglePopover() {
        if let panel, panel.isVisible {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        let panelToShow: KeyablePanel
        if let existing = panel {
            panelToShow = existing
        } else {
            let newPanel = makePanel()
            panel = newPanel
            panelToShow = newPanel
        }

        positionPanel(panelToShow)
        panelToShow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        addOutsideClickMonitor()
    }

    private func closePopover() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
        panel?.orderOut(nil)
    }

    private func makePanel() -> KeyablePanel {
        let content = AudioSwitcherPopoverView(onQuit: { [weak self] in
            self?.quit()
        })
        let hosting = NSHostingView(rootView: content)
        let panel = KeyablePanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: AudioSwitcherSizing.panelWidth,
                height: AudioSwitcherSizing.panelHeight
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }

    private func positionPanel(_ panel: KeyablePanel) {
        guard let button = statusItem?.button, let screen = button.window?.screen else { return }
        let buttonFrame = button.window?.convertToScreen(button.bounds) ?? .zero
        var x = buttonFrame.midX - AudioSwitcherSizing.panelWidth / 2
        var y = buttonFrame.minY - 8 - AudioSwitcherSizing.panelHeight
        let visible = screen.visibleFrame
        x = max(visible.minX + 8, min(x, visible.maxX - AudioSwitcherSizing.panelWidth - 8))
        if y < visible.minY + 8 { y = visible.minY + 8 }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    @objc private func addOutsideClickMonitor() {
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.closePopover()
            }
        }
    }

    private func quit() {
        cleanup()
        NSApp.terminate(nil)
    }

    private func cleanup() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
        if let observer = showWindowObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            showWindowObserver = nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        cleanup()
    }
}
