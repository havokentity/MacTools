import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

public extension DefaultsKey {
    static let focusTimerFocusMinutes = "tool.focusTimer.focusMinutes"
    static let focusTimerShortBreakMinutes = "tool.focusTimer.shortBreakMinutes"
    static let focusTimerLongBreakMinutes = "tool.focusTimer.longBreakMinutes"
    static let focusTimerSessionsBeforeLongBreak = "tool.focusTimer.sessionsBeforeLongBreak"
}

public enum FocusPhase: Sendable {
    case focus
    case shortBreak
    case longBreak

    public var displayName: String {
        switch self {
        case .focus: return "Focus"
        case .shortBreak: return "Short Break"
        case .longBreak: return "Long Break"
        }
    }
}

@MainActor
public final class FocusTimerController: ObservableObject {
    @Published public private(set) var phase: FocusPhase = .focus
    @Published public private(set) var remaining: TimeInterval = 0
    @Published public private(set) var isRunning: Bool = false
    @Published public private(set) var completedFocusCount: Int = 0

    // Configurable durations (minutes), persisted in AppDefaults.
    @Published public var focusMinutes: Int {
        didSet { persist(focusMinutes, forKey: DefaultsKey.focusTimerFocusMinutes); refreshRemainingIfIdle() }
    }
    @Published public var shortBreakMinutes: Int {
        didSet { persist(shortBreakMinutes, forKey: DefaultsKey.focusTimerShortBreakMinutes); refreshRemainingIfIdle() }
    }
    @Published public var longBreakMinutes: Int {
        didSet { persist(longBreakMinutes, forKey: DefaultsKey.focusTimerLongBreakMinutes); refreshRemainingIfIdle() }
    }
    @Published public var sessionsBeforeLongBreak: Int {
        didSet { persist(sessionsBeforeLongBreak, forKey: DefaultsKey.focusTimerSessionsBeforeLongBreak) }
    }

    private var timer: Timer?
    private var notificationsAuthorized = false
    private var didRequestNotificationAuthorization = false

    public init(defaults: UserDefaults = .standard) {
        self.userDefaults = defaults
        self.focusMinutes = FocusTimerController.readInt(
            defaults, key: DefaultsKey.focusTimerFocusMinutes, fallback: 25)
        self.shortBreakMinutes = FocusTimerController.readInt(
            defaults, key: DefaultsKey.focusTimerShortBreakMinutes, fallback: 5)
        self.longBreakMinutes = FocusTimerController.readInt(
            defaults, key: DefaultsKey.focusTimerLongBreakMinutes, fallback: 15)
        self.sessionsBeforeLongBreak = FocusTimerController.readInt(
            defaults, key: DefaultsKey.focusTimerSessionsBeforeLongBreak, fallback: 4)
        self.remaining = TimeInterval(self.focusMinutes * 60)
    }

    private let userDefaults: UserDefaults

    // MARK: - Derived values

    public func duration(for phase: FocusPhase) -> TimeInterval {
        switch phase {
        case .focus: return TimeInterval(max(1, focusMinutes) * 60)
        case .shortBreak: return TimeInterval(max(1, shortBreakMinutes) * 60)
        case .longBreak: return TimeInterval(max(1, longBreakMinutes) * 60)
        }
    }

    /// Fraction of the current phase already elapsed (0...1) for a depleting ring/bar.
    public var progress: Double {
        let total = duration(for: phase)
        guard total > 0 else { return 0 }
        let elapsed = total - remaining
        return min(1, max(0, elapsed / total))
    }

    // MARK: - Controls

    public func start() {
        guard !isRunning else { return }
        if remaining <= 0 {
            remaining = duration(for: phase)
        }
        isRunning = true
        requestNotificationAuthorizationIfNeeded()
        startTimer()
    }

    public func pause() {
        guard isRunning else { return }
        isRunning = false
        stopTimer()
    }

    public func reset() {
        stopTimer()
        isRunning = false
        phase = .focus
        completedFocusCount = 0
        remaining = duration(for: .focus)
    }

    /// Immediately advance to the next phase without counting it as completed.
    public func skip() {
        stopTimer()
        advanceToNextPhase(countingCompletion: false)
        if isRunning {
            startTimer()
        }
    }

    // MARK: - Deterministic time engine

    /// All countdown / phase-transition logic. The real repeating Timer calls
    /// `tick(by: 1)`; tests drive this directly with no wall-clock dependency.
    public func tick(by seconds: TimeInterval) {
        guard isRunning, seconds > 0 else { return }
        var budget = seconds
        // Loop so a single large tick can cross multiple phase boundaries.
        while budget > 0, isRunning {
            if remaining > budget {
                remaining -= budget
                budget = 0
            } else {
                budget -= remaining
                remaining = 0
                completeCurrentPhase()
            }
        }
    }

    private func completeCurrentPhase() {
        announceCompletion(of: phase)
        advanceToNextPhase(countingCompletion: true)
    }

    private func advanceToNextPhase(countingCompletion: Bool) {
        switch phase {
        case .focus:
            if countingCompletion {
                completedFocusCount += 1
            }
            let sessions = max(1, sessionsBeforeLongBreak)
            if completedFocusCount > 0, completedFocusCount % sessions == 0 {
                phase = .longBreak
            } else {
                phase = .shortBreak
            }
        case .shortBreak, .longBreak:
            phase = .focus
        }
        remaining = duration(for: phase)
    }

    // MARK: - Timer lifecycle (mirrors KeepAwakeController)

    private func startTimer() {
        timer?.invalidate()
        let newTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tick(by: 1)
            }
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        // `deinit` is nonisolated, so it cannot touch the @MainActor-isolated,
        // non-Sendable `timer` directly. The repeating Timer holds only a weak
        // reference back to `self`, so it cannot keep this controller alive; once
        // the controller is gone the timer's block is a no-op. We still invalidate
        // it deterministically in `pause()`/`reset()`/`stopTimer()` while on the
        // main actor (mirroring KeepAwakeController, whose deinit likewise only
        // releases its Sendable assertion handle, never the Timer).
    }

    // MARK: - Notifications & chime

    /// `UNUserNotificationCenter.current()` throws (`bundleProxyForCurrentProcess
    /// is nil`) when there is no real application bundle — e.g. inside the XCTest
    /// runner. Detect that case so the deterministic state machine never touches
    /// UserNotifications outside a packaged app. The guaranteed `NSSound.beep()`
    /// chime still fires in every environment.
    /// `UNUserNotificationCenter.current()` aborts the process (`bundleProxyForCurrentProcess
    /// is nil`) whenever there is no real `.app` bundle hosting the code — most notably inside
    /// the XCTest runner, where `Bundle.main` points at the `xctest` tool. Gate every
    /// UserNotifications access on an actual packaged app so the deterministic state machine is
    /// safe to drive from tests. The guaranteed `NSSound.beep()` chime still fires everywhere.
    private var canUseNotifications: Bool {
        #if canImport(UserNotifications)
        // Never touch UserNotifications under the XCTest harness.
        if NSClassFromString("XCTestCase") != nil { return false }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return false }
        // Require a genuine application bundle (path ends in ".app").
        return Bundle.main.bundleURL.pathExtension == "app"
        #else
        return false
        #endif
    }

    private func requestNotificationAuthorizationIfNeeded() {
        guard !didRequestNotificationAuthorization else { return }
        didRequestNotificationAuthorization = true
        #if canImport(UserNotifications)
        guard canUseNotifications else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in
                self?.notificationsAuthorized = granted
            }
        }
        #endif
    }

    private func announceCompletion(of finishedPhase: FocusPhase) {
        // Guaranteed audible chime regardless of notification permission.
        #if canImport(AppKit)
        NSSound.beep()
        #endif

        #if canImport(UserNotifications)
        guard notificationsAuthorized, canUseNotifications else { return }
        let content = UNMutableNotificationContent()
        switch finishedPhase {
        case .focus:
            content.title = "Focus session complete"
            content.body = "Time for a break."
        case .shortBreak, .longBreak:
            content.title = "Break over"
            content.body = "Back to focus."
        }
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        #endif
    }

    // MARK: - Persistence helpers

    private func refreshRemainingIfIdle() {
        guard !isRunning else { return }
        remaining = duration(for: phase)
    }

    private func persist(_ value: Int, forKey key: String) {
        userDefaults.set(value, forKey: key)
    }

    private static func readInt(_ defaults: UserDefaults, key: String, fallback: Int) -> Int {
        // Honour fallback even when defaults are unregistered.
        if defaults.object(forKey: key) == nil { return fallback }
        let value = defaults.integer(forKey: key)
        return value > 0 ? value : fallback
    }
}

#if canImport(AppKit)
public extension FocusTimerController {
    nonisolated static var statusGlyph: String { "timer" }
}
#endif
