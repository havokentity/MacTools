import XCTest
@testable import DMonteCore

/// System Monitor is a login item that stays up for months, so the history behind its sparklines
/// is the one structure in the tool that a naive implementation would grow without bound. These
/// pin the two properties that matter over that timescale: the storage never gets bigger, and the
/// indices never wander outside the ring.
final class MetricHistoryTests: XCTestCase {

    // MARK: - Empty and near-empty

    func testNewHistoryIsEmpty() {
        let history = MetricHistory()

        XCTAssertTrue(history.isEmpty)
        XCTAssertFalse(history.isFull)
        XCTAssertEqual(history.count, 0)
        XCTAssertEqual(history.samples, [])
        XCTAssertEqual(history.series(\.cpuUsage), [])
    }

    func testSamplesBelowCapacityComeBackOldestFirst() {
        var history = MetricHistory(capacity: 8)
        for value in [0.1, 0.2, 0.3] {
            history.append(MetricHistorySample(cpuUsage: value))
        }

        XCTAssertEqual(history.count, 3)
        XCTAssertFalse(history.isFull)
        XCTAssertEqual(history.series(\.cpuUsage), [0.1, 0.2, 0.3])
    }

    func testExactlyFullHistoryKeepsEverySample() {
        var history = MetricHistory(capacity: 4)
        for value in [1.0, 2.0, 3.0, 4.0] {
            history.append(MetricHistorySample(cpuUsage: value))
        }

        XCTAssertTrue(history.isFull)
        XCTAssertEqual(history.series(\.cpuUsage), [1.0, 2.0, 3.0, 4.0])
    }

    // MARK: - Wrapping

    func testWrappingDropsTheOldestAndKeepsTheOrder() {
        var history = MetricHistory(capacity: 4)
        for value in [1.0, 2.0, 3.0, 4.0, 5.0, 6.0] {
            history.append(MetricHistorySample(cpuUsage: value))
        }

        XCTAssertEqual(history.count, 4)
        XCTAssertEqual(history.series(\.cpuUsage), [3.0, 4.0, 5.0, 6.0])
    }

    /// The long-uptime guarantee, asserted directly: a quarter of a million appends is roughly
    /// three days of the one-second poll, and neither the element count nor the ordering may drift
    /// no matter how many times the write cursor has been round.
    func testCapacityHoldsAcrossFarMoreAppendsThanItCanStore() {
        let capacity = 60
        var history = MetricHistory(capacity: capacity)

        for tick in 0..<250_000 {
            history.append(MetricHistorySample(cpuUsage: Double(tick)))
        }

        XCTAssertEqual(history.count, capacity)
        XCTAssertEqual(history.samples.count, capacity)
        XCTAssertEqual(history.series(\.cpuUsage).first, Double(250_000 - capacity))
        XCTAssertEqual(history.series(\.cpuUsage).last, Double(250_000 - 1))
    }

    /// The wrap must be seamless at every offset, not just the one a single test happens to stop
    /// at, so this checks the ring after each of a full lap's worth of extra appends.
    func testEveryWriteOffsetProducesTheSameOrdering() {
        let capacity = 5

        for extra in 0...capacity {
            var history = MetricHistory(capacity: capacity)
            let total = capacity + extra

            for tick in 0..<total {
                history.append(MetricHistorySample(cpuUsage: Double(tick)))
            }

            let expected = Array((total - capacity)..<total).map(Double.init)
            XCTAssertEqual(history.series(\.cpuUsage), expected, "wrong order \(extra) appends past full")
        }
    }

    // MARK: - Degenerate capacity

    /// A capacity of zero would leave nowhere to write; raising it beats trapping at launch.
    func testCapacityBelowOneIsRaisedRatherThanTrapping() {
        for requested in [0, -1, Int.min] {
            var history = MetricHistory(capacity: requested)
            XCTAssertEqual(history.capacity, 1)

            history.append(MetricHistorySample(cpuUsage: 0.4))
            history.append(MetricHistorySample(cpuUsage: 0.9))

            XCTAssertEqual(history.count, 1)
            XCTAssertEqual(history.series(\.cpuUsage), [0.9])
        }
    }

    // MARK: - Reset

    func testRemoveAllClearsTheRingWithoutChangingCapacity() {
        var history = MetricHistory(capacity: 3)
        history.append(MetricHistorySample(cpuUsage: 0.5))
        history.append(MetricHistorySample(cpuUsage: 0.6))

        history.removeAll()

        XCTAssertTrue(history.isEmpty)
        XCTAssertEqual(history.capacity, 3)
        XCTAssertEqual(history.samples, [])

        // A cleared ring has to start writing from the beginning again, not from wherever the old
        // cursor was left — otherwise the first samples after a restart come back out of order.
        history.append(MetricHistorySample(cpuUsage: 0.7))
        history.append(MetricHistorySample(cpuUsage: 0.8))
        XCTAssertEqual(history.series(\.cpuUsage), [0.7, 0.8])
    }

    /// The clear happens in place now rather than by replacing the buffer, which is exactly the
    /// kind of edit that silently leaves a ring half-reset. Clearing after a wrap is the case that
    /// catches it: the write cursor is sitting mid-buffer and `filled` is at capacity, so a reset
    /// that missed either one would read the samples back rotated or start out already full.
    func testRemoveAllAfterAWrapRestartsTheRingFromTheBeginning() {
        var history = MetricHistory(capacity: 4)
        for value in [1.0, 2.0, 3.0, 4.0, 5.0, 6.0] {
            history.append(MetricHistorySample(cpuUsage: value))
        }

        XCTAssertEqual(history.series(\.cpuUsage), [3.0, 4.0, 5.0, 6.0])

        history.removeAll()

        XCTAssertTrue(history.isEmpty)
        XCTAssertFalse(history.isFull)
        XCTAssertEqual(history.count, 0)
        XCTAssertEqual(history.samples, [])

        for value in [7.0, 8.0, 9.0] {
            history.append(MetricHistorySample(cpuUsage: value))
        }

        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(history.series(\.cpuUsage), [7.0, 8.0, 9.0])

        // And the refilled ring has to wrap exactly as a brand-new one would.
        for value in [10.0, 11.0] {
            history.append(MetricHistorySample(cpuUsage: value))
        }

        XCTAssertTrue(history.isFull)
        XCTAssertEqual(history.series(\.cpuUsage), [8.0, 9.0, 10.0, 11.0])
    }

    /// A cleared ring must be indistinguishable from a new one. `MetricHistory` is `Equatable`
    /// over its whole storage, so an in-place clear that only reset the indices and left the old
    /// samples sitting in the buffer would compare unequal to a fresh history of the same capacity.
    func testRemoveAllLeavesAHistoryEqualToAFreshOne() {
        var history = MetricHistory(capacity: 4)
        for value in [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0] {
            history.append(MetricHistorySample(cpuUsage: value))
        }

        history.removeAll()

        XCTAssertEqual(history, MetricHistory(capacity: 4))
    }

    /// The reset is called on every restart of the poll, so it has to survive being run repeatedly
    /// and from an already-empty ring without walking the indices anywhere.
    func testRepeatedRemoveAllIsHarmless() {
        var history = MetricHistory(capacity: 3)

        for _ in 0..<5 {
            history.removeAll()
        }

        history.append(MetricHistorySample(cpuUsage: 0.1))
        history.removeAll()
        history.removeAll()
        history.append(MetricHistorySample(cpuUsage: 0.2))

        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.capacity, 3)
        XCTAssertEqual(history.series(\.cpuUsage), [0.2])
    }

    // MARK: - Snapshot mapping

    func testSampleTakesEveryPlottedMetricFromTheSnapshot() {
        let snapshot = MetricSnapshot(
            timestamp: Date(),
            cpuUsage: 0.25,
            memoryUsed: 4 * 1_073_741_824,
            memoryTotal: 16 * 1_073_741_824,
            diskUsed: 0,
            diskTotal: 0,
            networkDownRate: 2_048,
            networkUpRate: 512,
            batteryPercent: nil,
            isCharging: false,
            uptime: 0,
            cpuTemperatureCelsius: nil
        )

        let sample = MetricHistorySample(snapshot: snapshot)

        XCTAssertEqual(sample.cpuUsage, 0.25, accuracy: 1e-9)
        XCTAssertEqual(sample.memoryUsage, 0.25, accuracy: 1e-9)
        XCTAssertEqual(sample.networkDownRate, 2_048, accuracy: 1e-9)
        XCTAssertEqual(sample.networkUpRate, 512, accuracy: 1e-9)
    }

    /// A snapshot taken before the machine reported its RAM divides by a zero total; the history
    /// must record the zero the snapshot already guards to, not a NaN that would blank the chart.
    func testSampleFromAPlaceholderSnapshotIsFinite() {
        let sample = MetricHistorySample(snapshot: .placeholder)

        XCTAssertTrue(sample.cpuUsage.isFinite)
        XCTAssertTrue(sample.memoryUsage.isFinite)
        XCTAssertTrue(sample.networkDownRate.isFinite)
        XCTAssertTrue(sample.networkUpRate.isFinite)
    }
}
