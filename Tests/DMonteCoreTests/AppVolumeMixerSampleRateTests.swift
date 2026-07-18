import XCTest
import CoreAudio
@testable import DMonteCore

/// Pure tests for the sample-rate reconciliation that lets the Volume Mixer
/// route an app to a fixed-rate output (e.g. an HDMI/TV at 48 kHz) without
/// going silent. These assert the rate-selection and range-expansion logic
/// directly; they touch no audio hardware.
final class AppVolumeMixerSampleRateTests: XCTestCase {

    // MARK: - chooseCommonSampleRate

    func testPrefersSourceRateWhenAllDevicesSupportIt() {
        let chosen = AppVolumeMixerAudioEngine.chooseCommonSampleRate(
            preferred: 44100,
            deviceSupportedRates: [[44100, 48000], [44100, 48000, 96000]]
        )
        XCTAssertEqual(chosen, 44100)
    }

    func testFallsBackToCommonRateWhenPreferredUnsupported() {
        // Source default is 44.1 kHz but the TV only does 48 kHz — the classic
        // HDMI case. They must converge on 48 kHz, not fail.
        let chosen = AppVolumeMixerAudioEngine.chooseCommonSampleRate(
            preferred: 44100,
            deviceSupportedRates: [[44100, 48000], [48000]]
        )
        XCTAssertEqual(chosen, 48000)
    }

    func testReturnsNilWhenNoCommonRateExists() {
        let chosen = AppVolumeMixerAudioEngine.chooseCommonSampleRate(
            preferred: 44100,
            deviceSupportedRates: [[44100], [48000]]
        )
        XCTAssertNil(chosen)
    }

    func testEmptyRateSetsAreTreatedAsUnconstrained() {
        // A device that reports no rates imposes no constraint; the preferred
        // rate should win.
        let chosen = AppVolumeMixerAudioEngine.chooseCommonSampleRate(
            preferred: 48000,
            deviceSupportedRates: [[], []]
        )
        XCTAssertEqual(chosen, 48000)
    }

    func testIgnoresUnconstrainedDeviceWhenIntersecting() {
        let chosen = AppVolumeMixerAudioEngine.chooseCommonSampleRate(
            preferred: nil,
            deviceSupportedRates: [[48000, 96000], []]
        )
        XCTAssertEqual(chosen, 48000)
    }

    func testBiasesTowardBroadcastRatesOverHighest() {
        // Both 48k and 96k are common; 48k is preferred as the universal rate
        // rather than just taking the maximum.
        let chosen = AppVolumeMixerAudioEngine.chooseCommonSampleRate(
            preferred: nil,
            deviceSupportedRates: [[48000, 96000], [48000, 96000]]
        )
        XCTAssertEqual(chosen, 48000)
    }

    func testFallsBackToMaxWhenNoStandardRateCommon() {
        let chosen = AppVolumeMixerAudioEngine.chooseCommonSampleRate(
            preferred: nil,
            deviceSupportedRates: [[12345, 67890], [12345, 67890]]
        )
        XCTAssertEqual(chosen, 67890)
    }

    // MARK: - ratesFromRanges

    func testDiscreteRangesYieldTheirRates() {
        let ranges = [
            AudioValueRange(mMinimum: 44100, mMaximum: 44100),
            AudioValueRange(mMinimum: 48000, mMaximum: 48000)
        ]
        XCTAssertEqual(AppVolumeMixerAudioEngine.ratesFromRanges(ranges), [44100, 48000])
    }

    func testContinuousRangeExpandsToStandardRatesInside() {
        // A device advertising a continuous 44.1–96 kHz span should surface the
        // standard rates within it.
        let ranges = [AudioValueRange(mMinimum: 44100, mMaximum: 96000)]
        let rates = AppVolumeMixerAudioEngine.ratesFromRanges(ranges)
        XCTAssertTrue(rates.contains(44100))
        XCTAssertTrue(rates.contains(48000))
        XCTAssertTrue(rates.contains(88200))
        XCTAssertTrue(rates.contains(96000))
        XCTAssertFalse(rates.contains(192000))
    }

    func testRangesAreDeduplicatedAndSorted() {
        let ranges = [
            AudioValueRange(mMinimum: 48000, mMaximum: 48000),
            AudioValueRange(mMinimum: 48000, mMaximum: 48000),
            AudioValueRange(mMinimum: 44100, mMaximum: 44100)
        ]
        XCTAssertEqual(AppVolumeMixerAudioEngine.ratesFromRanges(ranges), [44100, 48000])
    }

    // MARK: - uniqued

    func testUniquedPreservesOrder() {
        XCTAssertEqual(
            AppVolumeMixerAudioEngine.uniqued([3, 1, 3, 2, 1]),
            [3, 1, 2]
        )
    }

    // MARK: - Forced-rate refcount

    private func makeLedger() -> AppVolumeMixerAudioEngine.ForcedSampleRateLedger {
        AppVolumeMixerAudioEngine.ForcedSampleRateLedger()
    }

    func testSingleHolderRestoresTheOriginalRate() {
        var ledger = makeLedger()
        XCTAssertFalse(ledger.isForced(7))
        ledger.acquire(7, originalRate: 44100)
        XCTAssertTrue(ledger.isForced(7))
        let restored = ledger.release(7)
        XCTAssertEqual(restored, 44100)
        XCTAssertFalse(ledger.isForced(7))
    }

    /// The core rule: two engines routinely align the same device (every engine
    /// taps the system default output). The first to stop must NOT put the
    /// original rate back — the second still depends on the forced one, and the
    /// render loop does not resample, so restoring early silences it for good.
    func testDeviceIsRestoredOnlyAfterTheLastHolderReleases() {
        var ledger = makeLedger()
        ledger.acquire(7, originalRate: 44100)
        // The second engine finds the device already forced to 48 kHz.
        ledger.acquire(7, originalRate: 48000)

        let firstRelease = ledger.release(7)
        XCTAssertNil(firstRelease, "the second engine still depends on the forced rate")
        XCTAssertTrue(ledger.isForced(7))

        // Only the last release restores, and it restores the pre-mixer rate,
        // not the forced rate the later holder found.
        let lastRelease = ledger.release(7)
        XCTAssertEqual(lastRelease, 44100)
        XCTAssertFalse(ledger.isForced(7))
    }

    func testReleasingAnUnheldDeviceRestoresNothing() {
        var ledger = makeLedger()
        let unheld = ledger.release(7)
        XCTAssertNil(unheld)

        ledger.acquire(7, originalRate: 44100)
        let restored = ledger.release(7)
        XCTAssertEqual(restored, 44100)

        // A second stop of the same engine must not restore a second time.
        let doubleRelease = ledger.release(7)
        XCTAssertNil(doubleRelease)
    }

    func testDevicesAreRefcountedIndependently() {
        var ledger = makeLedger()
        ledger.acquire(7, originalRate: 44100)
        ledger.acquire(8, originalRate: 96000)

        let releasedEight = ledger.release(8)
        XCTAssertEqual(releasedEight, 96000)
        XCTAssertTrue(ledger.isForced(7))

        let releasedSeven = ledger.release(7)
        XCTAssertEqual(releasedSeven, 44100)
    }

    func testRestartedEngineKeepsTheDeviceHeldAcrossItsOwnReacquire() {
        // start() begins with stop(): the engine releases, then re-acquires. A
        // second engine's hold must carry the device through that gap.
        var ledger = makeLedger()
        ledger.acquire(7, originalRate: 44100)
        ledger.acquire(7, originalRate: 48000)

        let restartRelease = ledger.release(7)
        XCTAssertNil(restartRelease)
        ledger.acquire(7, originalRate: 48000)

        let firstStop = ledger.release(7)
        XCTAssertNil(firstStop)
        let lastStop = ledger.release(7)
        XCTAssertEqual(lastStop, 44100)
    }

    // MARK: - Error surface

    func testIncompatibleRateErrorHasMessage() {
        XCTAssertFalse(AppVolumeMixerError.incompatibleOutputSampleRate.message.isEmpty)
    }
}
