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

    // MARK: - Error surface

    func testIncompatibleRateErrorHasMessage() {
        XCTAssertFalse(AppVolumeMixerError.incompatibleOutputSampleRate.message.isEmpty)
    }
}
