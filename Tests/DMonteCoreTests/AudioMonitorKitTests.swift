import XCTest
import CoreAudio
@testable import DMonteCore

/// Tests for the input-monitor support types. The real-time engine itself needs
/// audio hardware, so these cover the pure pieces: gain clamping, error
/// messages, and the shared sample-rate helper the monitor relies on.
final class AudioMonitorKitTests: XCTestCase {

    func testClampGainBounds() {
        XCTAssertEqual(AudioMonitorEngine.clampGain(-1), 0)
        XCTAssertEqual(AudioMonitorEngine.clampGain(0.5), 0.5)
        XCTAssertEqual(AudioMonitorEngine.clampGain(2), 1)
    }

    func testMonitorErrorMessagesAreNonEmpty() {
        XCTAssertFalse(AudioMonitorError.deviceUnavailable.message.isEmpty)
        XCTAssertFalse(AudioMonitorError.incompatibleSampleRate.message.isEmpty)
        XCTAssertFalse(AudioMonitorError.coreAudio(-10875).message.isEmpty)
    }

    func testFreshEngineIsNotRunning() {
        XCTAssertFalse(AudioMonitorEngine().isRunning)
    }

    // MARK: - Shared sample-rate helper (used by the monitor + the mixer)

    func testSharedChooserPrefersCommonRate() {
        // Mic at 44.1, output (e.g. HDMI) only 48 → must converge on 48.
        XCTAssertEqual(
            CoreAudioSampleRate.chooseCommonSampleRate(
                preferred: 44100,
                deviceSupportedRates: [[44100, 48000], [48000]]
            ),
            48000
        )
    }

    func testSharedChooserReturnsNilWhenDisjoint() {
        XCTAssertNil(
            CoreAudioSampleRate.chooseCommonSampleRate(
                preferred: nil,
                deviceSupportedRates: [[44100], [48000]]
            )
        )
    }

    func testSharedRatesFromRangesExpandsContinuousSpan() {
        let rates = CoreAudioSampleRate.ratesFromRanges(
            [AudioValueRange(mMinimum: 44100, mMaximum: 48000)]
        )
        XCTAssertEqual(rates, [44100, 48000])
    }

    func testSharedUniquedPreservesOrder() {
        XCTAssertEqual(CoreAudioSampleRate.uniqued([5, 1, 5, 9, 1]), [5, 1, 9])
    }
}
