import XCTest
@testable import DMonteCore

/// Covers the byte, rate and duration formatting behind the System Monitor strip and popover.
/// The `ByteCountFormatter`-backed helpers are asserted against the formatter's own output rather
/// than hard-coded strings, so the tests stay valid across locales and OS releases.
final class FormattersTests: XCTestCase {

    // MARK: - Compact byte strings

    /// `compactBytesString` may only close up the space between the number and its unit.
    /// `ByteCountFormatter` emits up to two fraction digits at GB/TB scale, so any rewrite of the
    /// number itself mangles values whose tenths digit is zero ("1.05 GB" losing its ".0").
    func testCompactBytesStringOnlyRemovesTheUnitSpace() {
        let samples: [UInt64] = [
            0,
            512,
            1_536,
            1_048_576,
            1_127_428_915,      // ~1.05 GiB
            10_800_000_000,     // ~10.06 GiB
            1_132_774_195_527   // ~1.03 TiB
        ]

        for bytes in samples {
            XCTAssertEqual(
                bytes.compactBytesString,
                bytes.bytesString.replacingOccurrences(of: " ", with: ""),
                "compaction must not alter the formatted number for \(bytes)"
            )
        }
    }

    func testCompactBytesStringKeepsEveryDigitOfTwoDigitFractions() {
        let bytes: UInt64 = 1_127_428_915
        XCTAssertEqual(
            bytes.compactBytesString.filter(\.isNumber),
            bytes.bytesString.filter(\.isNumber),
            "no digit may be dropped while compacting"
        )
    }

    func testCompactRateStringAppendsPerSecondToCompactBytes() {
        let bytes: UInt64 = 1_127_428_915
        XCTAssertEqual(
            bytes.compactRateString,
            bytes.bytesString.replacingOccurrences(of: " ", with: "") + "/s",
            "the rate string is the unaltered byte string, closed up, plus a per-second suffix"
        )
    }

    // MARK: - Status strip strings

    func testStatusBytesStringUsesBinaryUnits() {
        XCTAssertEqual(UInt64(0).statusBytesString, "0B")
        XCTAssertEqual(UInt64(1_023).statusBytesString, "1023B")
        XCTAssertEqual(UInt64(1_024).statusBytesString, "1KB")
        XCTAssertEqual(UInt64(1_048_576).statusBytesString, "1MB")
        XCTAssertEqual(UInt64(1_073_741_824).statusBytesString, "1GB")
        XCTAssertEqual(UInt64(1_099_511_627_776).statusBytesString, "1TB")
    }

    func testDiskStatusBytesStringUsesDecimalUnits() {
        XCTAssertEqual(UInt64(999).diskStatusBytesString, "999B")
        XCTAssertEqual(UInt64(1_000).diskStatusBytesString, "1KB")
        XCTAssertEqual(UInt64(1_000_000).diskStatusBytesString, "1MB")
        XCTAssertEqual(UInt64(2_000_000_000).diskStatusBytesString, "2GB")
        XCTAssertEqual(UInt64(4_000_000_000_000).diskStatusBytesString, "4TB")
    }

    func testStatusRateStringAppendsPerSecond() {
        XCTAssertEqual(UInt64(1_048_576).statusRateString, "1MB/s")
    }

    // MARK: - Percentages, temperature and duration

    func testPercentStringRoundsToWholePercent() {
        XCTAssertEqual(0.0.percentString, "0%")
        XCTAssertEqual(0.5.percentString, "50%")
        XCTAssertEqual(0.876.percentString, "88%")
        XCTAssertEqual(1.0.percentString, "100%")
    }

    func testTemperatureStringConvertsToFahrenheit() {
        XCTAssertEqual(20.0.temperatureString(unit: .celsius), "20.0°C")
        XCTAssertEqual(100.0.temperatureString(unit: .fahrenheit), "212.0°F")
    }

    func testCompactDurationStringPicksTheCoarsestUnits() {
        XCTAssertEqual(TimeInterval(0).compactDurationString, "0m")
        XCTAssertEqual(TimeInterval(90).compactDurationString, "1m")
        XCTAssertEqual(TimeInterval(3_600).compactDurationString, "1h 0m")
        XCTAssertEqual(TimeInterval(3_660).compactDurationString, "1h 1m")
        XCTAssertEqual(TimeInterval(90_000).compactDurationString, "1d 1h")
    }
}
