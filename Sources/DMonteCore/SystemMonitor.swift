import Combine
import Foundation

@MainActor
public final class SystemMonitor: ObservableObject {
    @Published public private(set) var snapshot = MetricSnapshot.placeholder
    /// The last minute of samples, for the popover's sparklines.
    @Published public private(set) var history = MetricHistory()
    /// The busiest processes, refreshed on a slower cadence than the metrics themselves.
    @Published public private(set) var topProcesses = TopProcessSnapshot.empty

    private let provider = SystemMetricsProvider()
    private var timer: Timer?
    private var isRunning = false

    /// Polls remaining before the next `ps` run. Counts down and resets, so unlike a tick total it
    /// has no value it can grow into over a months-long uptime.
    private var pollsUntilProcessRefresh = 0
    /// Guards against a second `ps` being launched while the first is still running, which a
    /// momentarily slow listing would otherwise cause once per poll.
    private var isSamplingProcesses = false

    public init(snapshot: MetricSnapshot = .placeholder) {
        self.snapshot = snapshot
    }

    public func start() {
        guard !isRunning else {
            return
        }

        isRunning = true
        // A stopped-then-restarted monitor has a gap in the middle of its history; splicing the
        // two halves together would draw a jump that never happened.
        history.removeAll()
        pollsUntilProcessRefresh = 0
        refresh()

        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard self?.isRunning == true else {
                    return
                }

                self?.refresh()
            }
        }
        timer.tolerance = 0.2
        // Common mode keeps the sampling alive while a menu tracks the run loop, so the metrics
        // don't freeze for as long as the tray item's context menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
    }

    public func refresh() {
        let snapshot = provider.sample()
        self.snapshot = snapshot
        history.append(snapshot: snapshot)
        refreshTopProcessesIfDue()
    }

    /// Runs `ps` every `TopProcessKit.pollDivider`-th poll. The metrics timer is the only timer in
    /// the app; the process list rides on it at a fraction of its rate rather than getting one of
    /// its own.
    private func refreshTopProcessesIfDue() {
        let decision = TopProcessKit.processRefreshDecision(pollsRemaining: pollsUntilProcessRefresh)

        guard decision.shouldRefresh else {
            pollsUntilProcessRefresh = decision.pollsRemaining
            return
        }

        // A listing still running when the next one comes due is left to finish rather than
        // stacked on top of, and the countdown is left at zero so the retry is the very next poll.
        guard !isSamplingProcesses else {
            return
        }

        pollsUntilProcessRefresh = decision.pollsRemaining
        isSamplingProcesses = true

        Task { [weak self] in
            // `sample` detaches internally, so the subprocess and its exit wait stay off the main
            // actor; only the assignment below comes back here.
            let processes = await TopProcessKit.sample()

            guard let self else {
                return
            }

            self.isSamplingProcesses = false

            // A run that finished after the user closed the panel is still worth keeping — but a
            // failed listing should not blank a list that is merely a few seconds stale.
            guard !processes.isEmpty || self.topProcesses.isEmpty else {
                return
            }

            self.topProcesses = processes
        }
    }
}
