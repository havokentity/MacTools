import AppKit
import XCTest
@testable import DMonteCore

/// The settings sheet is centred over the panel, so a sheet wider than the panel is clipped on
/// both sides — the title loses its first and last characters and the trailing switch runs off the
/// edge. That is invisible on a Mac where `currentScale` happens to be 1, which is why it shipped:
/// the sheet's size was a literal while the panel's was scaled.
final class DriveEjectorSizingTests: XCTestCase {

    func testSettingsSheetNeverExceedsThePanel() {
        let panel = DriveEjectorSizing.preferredSize()
        let settings = DriveEjectorSizing.settingsSize()

        XCTAssertLessThanOrEqual(
            settings.width, panel.width,
            "A settings sheet wider than the panel is clipped on both sides"
        )
        XCTAssertLessThanOrEqual(
            settings.height, panel.height,
            "A settings sheet taller than the panel cannot show its bottom row — on this sheet, Quit"
        )
    }

    /// Both sizes have to move together. Pinning only the panel would let a later edit reintroduce
    /// a literal sheet width that passes the check above at today's scale and fails at another.
    func testBothSizesScaleTogether() {
        let scale = DriveEjectorSizing.currentScale
        let panel = DriveEjectorSizing.preferredSize()
        let settings = DriveEjectorSizing.settingsSize()

        XCTAssertEqual(panel.width, (340 * scale).rounded(), accuracy: 1)
        XCTAssertEqual(settings.width, min((340 * scale).rounded(), panel.width), accuracy: 1)
        XCTAssertEqual(settings.height, (330 * scale).rounded(), accuracy: 1)
    }

    /// The scale is derived from live screen and menu-bar metrics, so the guarantee has to hold
    /// across the whole range rather than at whatever this machine reports today.
    func testScaleStaysWithinItsDocumentedBounds() {
        let scale = DriveEjectorSizing.currentScale
        XCTAssertGreaterThanOrEqual(scale, 0.82)
        XCTAssertLessThanOrEqual(scale, 1.0)
    }
}
