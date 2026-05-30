import Foundation

public extension DefaultsKey {
    /// Length of a focus session, in whole minutes. Integrator should register a default of `25`.
    static let focusTimerFocusMinutes = "tool.focusTimer.focusMinutes"

    /// Length of a short break, in whole minutes. Default `5`.
    static let focusTimerShortBreakMinutes = "tool.focusTimer.shortBreakMinutes"

    /// Length of a long break, in whole minutes. Default `15`.
    static let focusTimerLongBreakMinutes = "tool.focusTimer.longBreakMinutes"

    /// Number of focus sessions completed before a long break is taken. Default `4`.
    static let focusTimerLongBreakInterval = "tool.focusTimer.longBreakInterval"
}

/// The three phases of the classic Pomodoro cycle.
public enum FocusPhase: Equatable, Sendable {
    case focus
    case shortBreak
    case longBreak

    /// A short, user-facing label for the phase.
    public var title: String {
        switch self {
        case .focus: return "Focus"
        case .shortBreak: return "Short Break"
        case .longBreak: return "Long Break"
        }
    }
}

/// Drives the Pomodoro state machine and the live countdown. The state machine is fully
/// deterministic and is exercised through `tick(by:)`, which the real `Timer` calls once per second.
/// Tests advance time by calling `tick(by:)` directly, so no real sleeps are needed.
///
/// All mutation happens on the main actor, so the timer and published state are never touched
/// concurrently. The repeating `Timer` block follows the Swift-6.1-safe pattern: it hops back onto
/// the main actor with `MainActor.assumeIsolated`, and the timer is always invalidated before being
/// re-scheduled and on stop/reset so it can never leak or double-fire.
@MainActor
public final class FocusTimerController: ObservableObject {
    /// The phase currently being timed.
    @Published public private(set) var phase: FocusPhase = .focus

    /// Seconds remaining in the current phase.
    @Published public private(set) var remaining: TimeInterval

    /// `true` while the countdown is actively running.
    @Published public private(set) var isRunning = false

    /// Total number of focus sessions completed since the last `reset()`.
    @Published public private(set) var completedFocusCount = 0

    private var countdownTimer: Timer?

    /// Number of focus sessions completed *within the current long-break cycle*. Resets to `0`
    /// after a long break so long breaks recur every Nth focus session.
    private var focusInCycle = 0

    /// Persisted-settings store the durations and interval are read from. Defaults to the app-wide
    /// shared suite in production; tests inject an isolated suite so they never touch real defaults.
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = AppDefaults.shared) {
        self.defaults = defaults
        // Seed `remaining` with the configured focus duration so the UI shows the full time at rest.
        remaining = 0
        remaining = duration(for: .focus)
    }

    deinit {
        // `deinit` is nonisolated and, under Swift 6 strict concurrency, must not touch the
        // @MainActor-isolated, non-Sendable `countdownTimer` (this mirrors KeepAwakeController, whose
        // deinit likewise never touches its Timer). The repeating timer captures only `[weak self]`,
        // so it cannot keep this controller alive; once the controller is gone the block is a no-op.
        // The timer is invalidated deterministically on the main actor in `pause()` / `reset()` /
        // `invalidateTimer()`, so it never leaks.
    }

    // MARK: - Configured durations

    /// Focus-session length in seconds, derived from the persisted minutes (clamped to >= 1 minute).
    public var focusDuration: TimeInterval { duration(for: .focus) }

    /// Short-break length in seconds.
    public var shortBreakDuration: TimeInterval { duration(for: .shortBreak) }

    /// Long-break length in seconds.
    public var longBreakDuration: TimeInterval { duration(for: .longBreak) }

    /// Number of focus sessions between long breaks (clamped to >= 1).
    public var longBreakInterval: Int {
        max(1, defaults.integer(forKey: DefaultsKey.focusTimerLongBreakInterval))
    }

    private func duration(for phase: FocusPhase) -> TimeInterval {
        let key: String
        switch phase {
        case .focus: key = DefaultsKey.focusTimerFocusMinutes
        case .shortBreak: key = DefaultsKey.focusTimerShortBreakMinutes
        case .longBreak: key = DefaultsKey.focusTimerLongBreakMinutes
        }
        let minutes = max(1, defaults.integer(forKey: key))
        return TimeInterval(minutes * 60)
    }

    /// Fraction of the current phase that has *elapsed*, in `0...1`. Useful for a depleting ring.
    public var progress: Double {
        let total = duration(for: phase)
        guard total > 0 else { return 0 }
        let elapsed = total - remaining
        return min(1, max(0, elapsed / total))
    }

    // MARK: - Controls

    /// Starts (or resumes) the countdown for the current phase. If the current phase has already
    /// fully elapsed (remaining <= 0), it is refilled to its configured duration first.
    public func start() {
        guard !isRunning else { return }
        if remaining <= 0 {
            remaining = duration(for: phase)
        }
        isRunning = true
        scheduleTimer()
    }

    /// Pauses the countdown, leaving `remaining` and `phase` untouched so it can be resumed.
    public func pause() {
        guard isRunning else { return }
        isRunning = false
        invalidateTimer()
    }

    /// Stops the timer and returns to the initial state: a fresh focus phase at full duration, with
    /// all counters cleared.
    public func reset() {
        invalidateTimer()
        isRunning = false
        phase = .focus
        focusInCycle = 0
        completedFocusCount = 0
        remaining = duration(for: .focus)
    }

    /// Immediately ends the current phase and advances to the next. Unlike a naturally elapsed
    /// focus phase, a skipped one is *not* tallied as a completed session (and does not advance the
    /// long-break cycle). Preserves the running/paused state.
    public func skip() {
        advancePhase(countingCompletion: false)
    }

    // MARK: - State machine (deterministic, test entry point)

    /// Advances the state machine by `seconds`. Decrements `remaining`; when it reaches zero the
    /// current phase completes and the machine transitions to the next phase with a freshly reset
    /// `remaining`. The real `Timer` calls `tick(by: 1)`; tests call it with larger spans.
    ///
    /// Advances at most one phase per call (a single tick is one phase-completion event at most,
    /// matching the once-per-second real cadence); overshoot is discarded so each phase starts clean.
    func tick(by seconds: TimeInterval) {
        guard isRunning, seconds > 0 else { return }

        remaining -= seconds
        if remaining <= 0 {
            advancePhase()
        }
    }

    /// Transitions from the current phase to the next, updating counters and refilling `remaining`.
    /// When `countingCompletion` is `false` (a skip), a focus phase is abandoned without tallying it
    /// as completed or advancing the long-break cycle.
    private func advancePhase(countingCompletion: Bool = true) {
        switch phase {
        case .focus:
            if countingCompletion {
                completedFocusCount += 1
                focusInCycle += 1
            }
            if focusInCycle >= longBreakInterval {
                focusInCycle = 0
                phase = .longBreak
            } else {
                phase = .shortBreak
            }
        case .shortBreak, .longBreak:
            phase = .focus
        }
        remaining = duration(for: phase)
    }

    // MARK: - Timer lifecycle

    private func scheduleTimer() {
        invalidateTimer()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick(by: 1)
            }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    private func invalidateTimer() {
        countdownTimer?.invalidate()
        countdownTimer = nil
    }
}
