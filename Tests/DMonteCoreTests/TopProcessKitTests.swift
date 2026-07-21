import XCTest
@testable import DMonteCore

/// Exercises the parsing and ranking half of `TopProcessKit` against fixture text. Nothing here
/// launches `ps` — the reading half is deliberately kept out of the suite because its output is
/// whatever happens to be running on the test machine.
///
/// The fixtures are real `ps -Ao "pid=,pcpu=,pmem=,comm=" -r` rows, right-aligned columns and all,
/// because the column widths shift from row to row and a naive split on a single space gets them
/// wrong in exactly the cases a hand-written fixture would not have.
final class TopProcessKitTests: XCTestCase {

    private let listing = """
        28816 128.3  1.1 /opt/anaconda3/envs/mlagents/bin/python3.10
        90581  49.6  0.9 /Applications/Claude.app/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer)
          638  45.6  9.2 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer
            1  16.5  0.0 /sbin/launchd
          643  11.3  3.4 /usr/libexec/trustd
          701   0.0 24.8 /usr/sbin/bigmemd
        """

    // MARK: - Parsing

    func testParsesEveryColumnOfARow() {
        let processes = TopProcessKit.parse(processListing: listing)

        XCTAssertEqual(processes.count, 6)
        XCTAssertEqual(processes[0].pid, 28_816)
        XCTAssertEqual(processes[0].name, "python3.10")
        XCTAssertEqual(processes[0].cpuPercent, 128.3, accuracy: 1e-9)
        XCTAssertEqual(processes[0].memoryPercent, 1.1, accuracy: 1e-9)
    }

    /// Helper executables live at paths full of spaces, so the command has to be taken as the
    /// whole remainder of the row rather than as a fourth space-delimited field.
    func testCommandKeepsItsInternalSpaces() {
        let processes = TopProcessKit.parse(processListing: listing)

        XCTAssertEqual(processes[1].name, "Claude Helper (Renderer)")
    }

    /// `ps` right-aligns the pid column, so leading whitespace varies with the width of the widest
    /// pid on the machine.
    func testRowsWithLeadingWhitespaceParse() {
        let processes = TopProcessKit.parse(processListing: listing)

        XCTAssertEqual(processes[3].pid, 1)
        XCTAssertEqual(processes[3].name, "launchd")
    }

    func testEmptyListingParsesToNothing() {
        XCTAssertEqual(TopProcessKit.parse(processListing: ""), [])
        XCTAssertEqual(TopProcessKit.parse(processListing: "\n\n   \n"), [])
    }

    /// A header row survives if the caller forgets the `=` suffixes; it has to be skipped rather
    /// than parsed into a process with a pid of zero.
    func testHeaderRowIsSkipped() {
        let withHeader = "  PID %CPU %MEM COMM\n  123  4.0  1.0 /usr/bin/foo"
        let processes = TopProcessKit.parse(processListing: withHeader)

        XCTAssertEqual(processes.count, 1)
        XCTAssertEqual(processes[0].name, "foo")
    }

    /// One unreadable row must not empty the panel, so bad rows are dropped individually.
    func testMalformedRowsAreDroppedWithoutLosingTheGoodOnes() {
        let mixed = """
            123 4.0 1.0 /usr/bin/good
            not-a-pid 4.0 1.0 /usr/bin/bad
            124 not-a-number 1.0 /usr/bin/bad
            125 4.0 not-a-number /usr/bin/bad
            126 4.0 1.0
            127
            128 4.0 1.0 /usr/bin/alsogood
            """
        let processes = TopProcessKit.parse(processListing: mixed)

        XCTAssertEqual(processes.map(\.name), ["good", "alsogood"])
    }

    func testDisplayNameTakesTheLeafOfThePath() {
        XCTAssertEqual(TopProcessKit.displayName(forCommand: "/usr/libexec/trustd"), "trustd")
        XCTAssertEqual(TopProcessKit.displayName(forCommand: "kernel_task"), "kernel_task")
        XCTAssertEqual(TopProcessKit.displayName(forCommand: "  /sbin/launchd  "), "launchd")
        XCTAssertEqual(TopProcessKit.displayName(forCommand: ""), "")
        XCTAssertEqual(TopProcessKit.displayName(forCommand: "   "), "")
    }

    /// `lastPathComponent` has no leaf to return for a path that is only separators; showing the
    /// row blank would be worse than showing it verbatim.
    func testDisplayNameFallsBackForASeparatorOnlyCommand() {
        XCTAssertEqual(TopProcessKit.displayName(forCommand: "/"), "/")
    }

    // MARK: - Ranking

    func testTopByCPUIsRankedHighestFirst() {
        let processes = TopProcessKit.parse(processListing: listing)
        let top = TopProcessKit.top(processes, by: .cpu, limit: 3)

        XCTAssertEqual(top.map(\.name), ["python3.10", "Claude Helper (Renderer)", "WindowServer"])
    }

    /// The memory ranking must genuinely re-sort rather than reuse the CPU order `ps -r` handed
    /// back: the heaviest process by memory here is the lightest by CPU.
    func testTopByMemoryIsRankedIndependentlyOfCPU() {
        let processes = TopProcessKit.parse(processListing: listing)
        let top = TopProcessKit.top(processes, by: .memory, limit: 3)

        XCTAssertEqual(top.map(\.name), ["bigmemd", "WindowServer", "trustd"])
    }

    func testLimitBeyondTheListReturnsEverything() {
        let processes = TopProcessKit.parse(processListing: listing)

        XCTAssertEqual(TopProcessKit.top(processes, by: .cpu, limit: 99).count, 6)
    }

    func testNonPositiveLimitReturnsNothing() {
        let processes = TopProcessKit.parse(processListing: listing)

        XCTAssertEqual(TopProcessKit.top(processes, by: .cpu, limit: 0), [])
        XCTAssertEqual(TopProcessKit.top(processes, by: .cpu, limit: -5), [])
    }

    /// Swift's sort is not stable, and hundreds of idle processes sit at exactly 0.0%. Without a
    /// tie-break the bottom of the list would reshuffle every five seconds.
    func testTiesAreBrokenDeterministicallyByPID() {
        let tied = (1...20).map { ProcessUsage(pid: Int32(100 - $0), name: "p\($0)", cpuPercent: 0, memoryPercent: 0) }

        let first = TopProcessKit.top(tied, by: .cpu, limit: 5)
        let second = TopProcessKit.top(tied.shuffled(), by: .cpu, limit: 5)

        XCTAssertEqual(first.map(\.pid), second.map(\.pid))
        XCTAssertEqual(first.map(\.pid), [80, 81, 82, 83, 84])
    }

    // MARK: - Snapshot

    func testSnapshotCarriesBothRankings() {
        let snapshot = TopProcessKit.snapshot(fromProcessListing: listing, limit: 2)

        XCTAssertFalse(snapshot.isEmpty)
        XCTAssertEqual(snapshot.processes(for: .cpu).map(\.name), ["python3.10", "Claude Helper (Renderer)"])
        XCTAssertEqual(snapshot.processes(for: .memory).map(\.name), ["bigmemd", "WindowServer"])
    }

    /// A `ps` that failed to launch hands back an empty string; the controller keys off `isEmpty`
    /// to leave the previous list on screen rather than blanking it.
    func testSnapshotOfAFailedListingIsEmpty() {
        let snapshot = TopProcessKit.snapshot(fromProcessListing: "")

        XCTAssertTrue(snapshot.isEmpty)
        XCTAssertEqual(snapshot, .empty)
    }

    // MARK: - Cadence

    func testRefreshFiresOnTheFirstPollAndThenEveryDividerPolls() {
        var remaining = 0
        var firedAt: [Int] = []

        for poll in 0..<20 {
            let decision = TopProcessKit.processRefreshDecision(pollsRemaining: remaining, divider: 5)
            if decision.shouldRefresh {
                firedAt.append(poll)
            }
            remaining = decision.pollsRemaining
        }

        XCTAssertEqual(firedAt, [0, 5, 10, 15])
    }

    /// The countdown is the piece that runs for the life of the process, so it has to stay inside
    /// its bounds over a run far longer than any test would otherwise cover — a million polls is
    /// eleven days of the one-second poll.
    func testCountdownStaysBoundedAcrossAMillionPolls() {
        var remaining = 0
        var refreshes = 0

        for _ in 0..<1_000_000 {
            let decision = TopProcessKit.processRefreshDecision(pollsRemaining: remaining, divider: 5)
            if decision.shouldRefresh {
                refreshes += 1
            }
            remaining = decision.pollsRemaining

            XCTAssertGreaterThanOrEqual(remaining, 0)
            XCTAssertLessThan(remaining, 5)
        }

        XCTAssertEqual(refreshes, 200_000)
    }

    /// A divider of zero would otherwise ask for a negative reload interval.
    func testDividerBelowOneRefreshesEveryPollRatherThanGoingNegative() {
        for divider in [0, -3] {
            let decision = TopProcessKit.processRefreshDecision(pollsRemaining: 0, divider: divider)

            XCTAssertTrue(decision.shouldRefresh)
            XCTAssertEqual(decision.pollsRemaining, 0)
        }
    }

    /// The controller leaves the countdown at zero while a listing is still running, so a poll
    /// arriving in that state must simply try again rather than skipping ahead.
    func testAZeroCountdownKeepsAskingUntilItIsAccepted() {
        for _ in 0..<3 {
            XCTAssertTrue(TopProcessKit.processRefreshDecision(pollsRemaining: 0, divider: 5).shouldRefresh)
        }
    }

    func testShippedDividerIsSlowerThanTheMetricPoll() {
        XCTAssertGreaterThan(TopProcessKit.pollDivider, 1)
        XCTAssertGreaterThan(TopProcessKit.listLimit, 0)
    }

    // MARK: - Visibility gate

    /// The tool is a login item, so a panel that is never opened is the common case rather than an
    /// edge one. A week of that used to be a week of `ps -A` every five seconds for a snapshot
    /// nothing could read.
    func testAnInvisibleListNeverRefreshesHoweverManyPollsPass() {
        var remaining = 0

        for _ in 0..<10_000 {
            let decision = TopProcessKit.processRefreshDecision(
                pollsRemaining: remaining,
                isListVisible: false,
                divider: 5
            )

            XCTAssertFalse(decision.shouldRefresh)
            remaining = decision.pollsRemaining
        }
    }

    /// The countdown is parked at zero rather than left to drain while the panel is closed, so the
    /// first poll after it reopens refreshes on the spot instead of waiting out a leftover count.
    func testAnInvisibleListParksTheCountdownAtZero() {
        for pollsRemaining in 0...4 {
            let decision = TopProcessKit.processRefreshDecision(
                pollsRemaining: pollsRemaining,
                isListVisible: false,
                divider: 5
            )

            XCTAssertEqual(decision.pollsRemaining, 0)
        }

        XCTAssertTrue(
            TopProcessKit.processRefreshDecision(pollsRemaining: 0, isListVisible: true, divider: 5).shouldRefresh
        )
    }

    /// The gate is an added parameter with a default, so every existing caller has to keep behaving
    /// exactly as it did before it was introduced.
    func testTheGateDefaultsToVisible() {
        let explicit = TopProcessKit.processRefreshDecision(pollsRemaining: 0, isListVisible: true, divider: 5)
        let defaulted = TopProcessKit.processRefreshDecision(pollsRemaining: 0, divider: 5)

        XCTAssertEqual(defaulted.shouldRefresh, explicit.shouldRefresh)
        XCTAssertEqual(defaulted.pollsRemaining, explicit.pollsRemaining)
    }
}
