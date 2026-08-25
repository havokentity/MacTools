import Combine
import Foundation

@MainActor
public final class SystemMonitor: ObservableObject {
    @Published public private(set) var snapshot = MetricSnapshot.placeholder
    /// The last minute of samples, for the popover's sparklines.
    @Published public private(set) var history = MetricHistory()
    /// The busiest processes, refreshed on a slower cadence than the metrics themselves.
    @Published public private(set) var topProcesses = TopProcessSnapshot.empty

    /// How the busiest processes are read. Injectable so the panel-visibility gate below can be
    /// proved in a test without launching a single subprocess.
    public typealias TopProcessSampler = @Sendable () async -> TopProcessSnapshot

    private let provider = SystemMetricsProvider()
    private let processSampler: TopProcessSampler
    private var timer: Timer?
    private var isRunning = false

    /// Polls remaining before the next `ps` run. Counts down and resets, so unlike a tick total it
    /// has no value it can grow into over a months-long uptime.
    private var pollsUntilProcessRefresh = 0
    /// Guards against a second `ps` being launched while the first is still running, which a
    /// momentarily slow listing would otherwise cause once per poll.
    private var isSamplingProcesses = false
    /// Whether anything is displaying the process list. Starts false because the panel starts
    /// closed, and a tool installed as a login item may never be opened at all.
    private var isProcessListVisible = false

    public init(
        snapshot: MetricSnapshot = .placeholder,
        processSampler: @escaping TopProcessSampler = { await TopProcessKit.sample() }
    ) {
        self.snapshot = snapshot
        self.processSampler = processSampler
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

    /// Tells the monitor whether the process list is on screen.
    ///
    /// The metrics themselves are Mach counters that cost next to nothing, but the process list
    /// shells out to `ps -A`, and a login item left running for a week that is never opened would
    /// otherwise spawn it seventeen thousand times a day to compute a snapshot nothing reads. The
    /// panel's own show/close hooks drive this, so a dismissal by outside click or by a display
    /// change stops the sampling just as a deliberate close does.
    public func setProcessListVisible(_ isVisible: Bool) {
        guard isVisible != isProcessListVisible else {
            return
        }

        isProcessListVisible = isVisible

        // Opening the panel should not have to sit in front of a stale list — or, on the first
        // opening of a session, an empty one — while the countdown drains, so a show primes the
        // listing immediately and the countdown then resumes from full. Zeroing the countdown
        // rather than trusting it to already be zero covers the case where the panel is closed and
        // reopened between two polls, which leaves whatever count the last visible poll wrote.
        if isVisible {
            pollsUntilProcessRefresh = 0
            refreshTopProcessesIfDue()
        }
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
        let decision = TopProcessKit.processRefreshDecision(
            pollsRemaining: pollsUntilProcessRefresh,
            isListVisible: isProcessListVisible
        )

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

        Task { [weak self, processSampler] in
            // The default sampler detaches internally, so the subprocess and its exit wait stay off
            // the main actor; only the assignment below comes back here.
            let processes = await processSampler()

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
