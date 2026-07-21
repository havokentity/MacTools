import XCTest
@testable import DMonteCore

final class NetworkInfoSizingTests: XCTestCase {
    func testCurrentScaleWithinExpectedRange() {
        let scale = NetworkInfoSizing.currentScale
        XCTAssertGreaterThanOrEqual(scale, 0.82)
        XCTAssertLessThanOrEqual(scale, 1.0)
    }

    func testPreferredSizeHasPositiveDimensions() {
        let size = NetworkInfoSizing.preferredSize()
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
    }

    func testSettingsSizeHasPositiveDimensions() {
        let size = NetworkInfoSizing.settingsSize()
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
    }

    /// The overlay is centred over the panel, so anything wider is clipped symmetrically at both
    /// edges. This is the invariant the whole change exists to guarantee.
    func testSettingsFitsWithinPanel() {
        let panel = NetworkInfoSizing.preferredSize()
        let settings = NetworkInfoSizing.settingsSize()
        XCTAssertLessThanOrEqual(settings.width, panel.width)
        XCTAssertLessThanOrEqual(settings.height, panel.height)
    }

    /// The sheet should be as large as it was designed to be, shrinking only as far as the panel
    /// forces. Asserting the contract rather than restating the arithmetic: when this rule changed
    /// from "scale with the panel" to "cap at the panel", the tests that restated the formula
    /// failed while the ones asserting the relationship kept passing.
    func testSettingsUsesItsDesignSizeUnlessThePanelIsSmaller() {
        let panel = NetworkInfoSizing.preferredSize()
        let settings = NetworkInfoSizing.settingsSize()

        XCTAssertEqual(settings.width, min(340, panel.width - 36), accuracy: 1)
        XCTAssertEqual(settings.height, min(300, panel.height - 36), accuracy: 1)
    }
}
