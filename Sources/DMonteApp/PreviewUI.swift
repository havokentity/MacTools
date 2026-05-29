import AppKit
import DMonteCore
import SwiftUI

@MainActor
final class PreviewAppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = SystemMonitor(snapshot: .preview)
    private var windows: [NSWindow] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)

        showWindow(
            title: "Tray Preview",
            size: NSSize(width: 390, height: 72),
            originOffset: NSPoint(x: -220, y: 220),
            rootView: TrayPreviewView(snapshot: monitor.snapshot)
        )

        let systemMonitorSize = AppDelegate.preferredSystemMonitorPanelSize()
        showWindow(
            title: "System Monitor Popup Preview",
            size: systemMonitorSize,
            originOffset: NSPoint(x: -220, y: -90),
            rootView: FixedPreviewFrame(size: systemMonitorSize) {
                SystemMonitorPopoverView(
                    monitor: monitor,
                    onQuit: {}
                )
            }
        )

        let toolboxSize = AppDelegate.preferredPopoverSize()
        showWindow(
            title: "DMonte Toolbox Popup Preview",
            size: toolboxSize,
            originOffset: NSPoint(x: 230, y: -90),
            rootView: FixedPreviewFrame(size: toolboxSize) {
                ToolPopoverView(
                    popoverSize: toolboxSize,
                    onOpenSystemMonitor: {},
                    onOpenUninstaller: {},
                    onOpenCleanDrive: {},
                    onOpenVideoDownloader: {},
                    onOpenDiskAnalyzer: {},
                    onOpenClipboard: {},
                    onCheckForUpdates: {},
                    onQuit: {}
                )
            }
        )
    }

    private func showWindow<Content: View>(
        title: String,
        size: NSSize,
        originOffset: NSPoint,
        rootView: Content
    ) {
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(
            x: visibleFrame.midX - size.width / 2 + originOffset.x,
            y: visibleFrame.midY - size.height / 2 + originOffset.y,
            width: size.width,
            height: size.height
        )
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: rootView)
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
    }
}

private struct FixedPreviewFrame<Content: View>: View {
    var size: NSSize
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(width: size.width, height: size.height)
    }
}

private struct TrayPreviewView: View {
    var snapshot: MetricSnapshot

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.55, green: 0.48, blue: 0.78),
                    Color(red: 0.43, green: 0.38, blue: 0.64)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )

            HStack(spacing: 0) {
                Spacer()

                SystemMonitorStatusRepresentable(snapshot: snapshot)
                    .frame(
                        width: SystemMonitorStatusView.statusWidth,
                        height: NSStatusBar.system.thickness
                    )

                ToolboxStatusRepresentable()
                    .frame(
                        width: ToolboxStatusView.statusWidth,
                        height: NSStatusBar.system.thickness
                    )
            }
            .padding(.trailing, 18)
        }
    }
}

private struct SystemMonitorStatusRepresentable: NSViewRepresentable {
    var snapshot: MetricSnapshot

    func makeNSView(context: Context) -> SystemMonitorStatusView {
        let view = SystemMonitorStatusView()
        view.update(snapshot: snapshot)
        return view
    }

    func updateNSView(_ nsView: SystemMonitorStatusView, context: Context) {
        nsView.update(snapshot: snapshot)
    }
}

private struct ToolboxStatusRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> ToolboxStatusView {
        ToolboxStatusView(image: AppDelegate.toolboxStatusImage())
    }

    func updateNSView(_ nsView: ToolboxStatusView, context: Context) {}
}
