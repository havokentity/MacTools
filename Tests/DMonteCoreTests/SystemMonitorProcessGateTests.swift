import XCTest
@testable import DMonteCore

/// Counts sampler calls in place of running `ps`, so the cadence can be driven without spawning a
/// single subprocess. Isolated to the main actor because the monitor is, which also makes it
/// `Sendable` enough for the sampler closure to capture.
@MainActor
private final class ProcessSamplerRecorder {
    private(set) var callCount = 0
    /// Non-empty, because the monitor deliberately refuses to let a failed listing blank a list
    /// that is merely stale, and these tests are about the sampling cadence rather than that rule.
    let result = TopProcessSnapshot(
        byCPU: [ProcessUsage(pid: 1, name: "launchd", cpuPercent: 12, memoryPercent: 1)],
        byMemory: [ProcessUsage(pid: 1, name: "launchd", cpuPercent: 12, memoryPercent: 1)]
    )

    func sample() -> TopProcessSnapshot {
        callCount += 1
        return result
    }
}

/// Proves the gate that keeps `ps` from running while nothing is displaying the process list.
///
/// System Monitor is installed as a login item, so on most machines it spends nearly all of its
/// life with the panel closed. Before the gate existed the five-second `ps -A` ran anyway —
/// seventeen thousand subprocess spawns a day, and roughly a hundred milliseconds of mostly system
/// time apiece, to compute a snapshot nothing could read. These tests drive the real poll path with
/// an injected sampler so a regression shows up as a call count rather than as battery drain
/// somebody notices months later.
@MainActor
final class SystemMonitorProcessGateTests: XCTestCase {

    // MARK: - Closed panel

    func testAClosedPanelNeverSamplesProcesses() async {
        let (monitor, recorder) = makeMonitor()

        // Two full countdowns and one poll over, so an ungated monitor would have run `ps` three
        // times by the end rather than merely once. The count is kept low deliberately: every poll
        // takes a real metric sample, which is cheap in the app and not free in a test suite.
        for _ in 0..<(TopProcessKit.pollDivider * 2 + 1) {
            monitor.refresh()
        }
        await drainSamplingTasks()

        XCTAssertEqual(recorder.callCount, 0)
        XCTAssertTrue(monitor.topProcesses.isEmpty)
    }

    /// The panel starts closed, so a monitor that is started and never opened must stay quiet too —
    /// `start` refreshes once immediately, and that first refresh used to sample.
    func testStartingTheMonitorDoesNotSampleWhileThePanelIsClosed() async {
        let (monitor, recorder) = makeMonitor()

        monitor.start()
        monitor.stop()
        await drainSamplingTasks()

        XCTAssertEqual(recorder.callCount, 0)
    }

    // MARK: - Open panel

    /// Opening the panel must not sit in front of an empty list until the countdown drains, so a
    /// show samples on the spot.
    func testShowingThePanelSamplesImmediately() async {
        let (monitor, recorder) = makeMonitor()

        monitor.setProcessListVisible(true)
        await drainSamplingTasks()

        XCTAssertEqual(recorder.callCount, 1)
        XCTAssertFalse(monitor.topProcesses.isEmpty)
    }

    /// The show hook fires on every show, and AppKit can hand out more than one for a single
    /// opening; only a genuine closed-to-open transition should cost a listing.
    func testASecondShowWithoutAnInterveningCloseDoesNotSampleAgain() async {
        let (monitor, recorder) = makeMonitor()

        monitor.setProcessListVisible(true)
        monitor.setProcessListVisible(true)
        await drainSamplingTasks()

        XCTAssertEqual(recorder.callCount, 1)
    }

    /// With the panel up the list has to keep refreshing, at the divided cadence and no faster.
    func testAVisiblePanelSamplesOnceEveryDividerPolls() async {
        let (monitor, recorder) = makeMonitor()
        let divider = TopProcessKit.pollDivider

        monitor.setProcessListVisible(true)
        await drainSamplingTasks()

        for _ in 0..<(divider * 2) {
            monitor.refresh()
            // Between polls rather than at the end, because a listing still in flight when the next
            // one comes due is deliberately skipped, and that would mask a too-fast cadence.
            await drainSamplingTasks()
        }

        // One for the show, then one per full countdown.
        XCTAssertEqual(recorder.callCount, 1 + 2)
    }

    // MARK: - Closing again

    func testClosingThePanelStopsFurtherSampling() async {
        let (monitor, recorder) = makeMonitor()

        monitor.setProcessListVisible(true)
        await drainSamplingTasks()
        let afterShow = recorder.callCount

        monitor.setProcessListVisible(false)
        for _ in 0..<(TopProcessKit.pollDivider * 2 + 1) {
            monitor.refresh()
        }
        await drainSamplingTasks()

        XCTAssertEqual(recorder.callCount, afterShow)
    }

    /// A close and a reopen between two polls leave behind whatever countdown the last visible poll
    /// wrote. Reopening must refresh straight away rather than showing a list from before the close
    /// while that leftover count drains.
    func testReopeningRefreshesWithoutWaitingOutTheLeftoverCountdown() async {
        let (monitor, recorder) = makeMonitor()

        monitor.setProcessListVisible(true)
        await drainSamplingTasks()
        // One poll in, so the countdown is part-drained rather than sitting at zero by luck.
        monitor.refresh()
        await drainSamplingTasks()
        XCTAssertEqual(recorder.callCount, 1)

        monitor.setProcessListVisible(false)
        monitor.setProcessListVisible(true)
        await drainSamplingTasks()

        XCTAssertEqual(recorder.callCount, 2)
    }

    // MARK: - Helpers

    private func makeMonitor() -> (SystemMonitor, ProcessSamplerRecorder) {
        let recorder = ProcessSamplerRecorder()
        let monitor = SystemMonitor(processSampler: { await recorder.sample() })

        return (monitor, recorder)
    }

    /// The monitor hands the listing to a fire-and-forget `Task` rather than awaiting it inline, so
    /// a test has to give the main actor a chance to drain that task before reading the count back.
    private func drainSamplingTasks() async {
        for _ in 0..<20 {
            await Task.yield()
        }
    }
}
