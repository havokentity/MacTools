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

@MainActor
final class FocusTimerAppDelegate: NSObject, NSApplicationDelegate {
    /// Built lazily, on the first access in `applicationDidFinishLaunching` — i.e. *after*
    /// `AppDefaults.registerDefaults()`. The controller seeds its countdown from the persisted focus
    /// duration in `init`, and a registration domain only exists once registered in this process, so
    /// an eagerly-created controller would read 0 minutes and clamp the session to 1 minute.
    private lazy var controller = FocusTimerController()

    private var statusItem: HelperStatusItem?
    /// Idle glyph shown on the status button when no session is running; the button shows the
    /// MM:SS countdown as its title while active.
    private let idleIcon: NSImage = {
        let image = NSImage(systemSymbolName: "timer", accessibilityDescription: "Focus Timer") ?? NSImage()
        image.isTemplate = true
        return image
    }()
    private var panelHost: HelperPanelHost?
    private var cancellables: Set<AnyCancellable> = []

    /// `true` once we have asked the user for notification permission (only attempted once, lazily,
    /// on the first phase completion so the prompt never appears merely on launch).
    private var didRequestNotificationAuth = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDefaults.registerDefaults()

        controller.onPhaseAdvance = { [weak self] in
            self?.announcePhaseTransition()
        }

        let host = HelperPanelHost(
            configuration: HelperPanelHost.Configuration(
                sizing: .preferred({ FocusTimerSizing.preferredSize() })
            ),
            content: .viewController({ [controller, weak self] in
                NSHostingController(
                    rootView: FocusTimerPopoverView(controller: controller, onQuit: { self?.quit() })
                )
            }),
            anchorView: { [weak self] in self?.statusItem?.button }
        )
        panelHost = host
        host.configure()

        statusItem = HelperStatusItem(
            title: nil,
            idleImage: idleIcon,
            toolTip: "Focus Timer",
            primaryAction: { [weak self] in self?.panelHost?.toggle() },
            quitAction: { [weak self] in self?.quit() }
        )
        refreshStatusTitle()

        host.observeShowNotification(named: FocusTimerNotifications.showWindow)
        observeControllerState()
    }

    func applicationWillTerminate(_ notification: Notification) {
        panelHost?.stopObservingShowNotifications()
        panelHost?.removeOutsideClickMonitor()
        cancellables.removeAll()
        controller.reset()
        panelHost?.dismissForTermination()
        statusItem?.remove()
    }

    /// Keep the tray button in sync with the controller. A single sink fires on any published
    /// change (tick, phase change, run/pause), which is exactly when the title may differ.
    private func observeControllerState() {
        controller.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                // `objectWillChange` fires *before* the new value is applied; defer to the next run
                // loop pass so we read the updated state.
                DispatchQueue.main.async {
                    self?.refreshStatusTitle()
                }
            }
            .store(in: &cancellables)
    }

    /// Draws the remaining time when a session is active (running or paused mid-phase), otherwise the
    /// idle glyph.
    private func refreshStatusTitle() {
        guard let item = statusItem?.item else { return }
        let title: String? = (controller.isRunning || controller.progress > 0)
            ? FocusTimerPopoverView.formatTime(controller.remaining)
            : nil
        StatusBarButtonContent.updateTitle(title, idleImage: idleIcon, in: item)
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
        guard makeNotificationCenter() != nil else { return }

        if didRequestNotificationAuth {
            // Authorization already decided once; just attempt delivery (no-op if denied).
            deliverPhaseNotification()
            return
        }

        didRequestNotificationAuth = true
        // The authorization completion runs off the main actor. Hop back with a fresh
        // @MainActor task instead of capturing a non-Sendable closure (which Swift 6 flags
        // as a data race), then build and post the notification on the main actor.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            guard granted else { return }
            Task { @MainActor in
                self?.deliverPhaseNotification()
            }
        }
    }

    /// Builds and posts the notification for the current phase. Main-actor isolated so it can
    /// safely read `controller` and never sends mutable state across executors.
    private func deliverPhaseNotification() {
        guard let center = makeNotificationCenter() else { return }
        let content = UNMutableNotificationContent()
        content.title = "Focus Timer"
        content.body = notificationBody(for: controller.phase)
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request, withCompletionHandler: nil)
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

    private func quit() {
        panelHost?.close()
        NSApp.terminate(nil)
    }
}
