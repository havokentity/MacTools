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

    /// Both sizes derive from the same scale, so the sheet must shrink with the panel rather than
    /// staying pinned at its full-size literal.
    func testSettingsScalesWithPanel() {
        let scale = NetworkInfoSizing.currentScale
        let settings = NetworkInfoSizing.settingsSize()
        XCTAssertEqual(settings.width, min((340 * scale).rounded(), NetworkInfoSizing.preferredSize().width))
        XCTAssertEqual(settings.height, (300 * scale).rounded())
    }
}
