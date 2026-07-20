import AppKit
import XCTest
@testable import DMonteCore

/// The settings sheet is centred over the panel, so a sheet wider than the panel is clipped on
/// both sides — the title loses its first and last characters and the value column runs off the
/// edge. Scratchpad's literal 320pt sheet cleared its 380pt panel by only about a point once the
/// panel was scaled down, so either number moving would have started clipping it.
final class ScratchpadSizingTests: XCTestCase {

    func testSettingsSheetNeverExceedsThePanel() {
        let panel = ScratchpadSizing.preferredSize()
        let settings = ScratchpadSizing.settingsSize()

        XCTAssertLessThanOrEqual(
            settings.width, panel.width,
            "A settings sheet wider than the panel is clipped on both sides"
        )
        XCTAssertLessThanOrEqual(
            settings.height, panel.height,
            "A settings sheet taller than the panel cannot show its bottom row — on this sheet, Quit"
        )
    }

    /// The sheet should be as large as it was designed to be, shrinking only as far as the panel
    /// forces. Asserting the contract rather than restating the arithmetic: when this rule changed
    /// from "scale with the panel" to "cap at the panel", the tests that restated the formula
    /// failed while the ones asserting the relationship kept passing.
    func testSettingsUsesItsDesignSizeUnlessThePanelIsSmaller() {
        let panel = ScratchpadSizing.preferredSize()
        let settings = ScratchpadSizing.settingsSize()

        XCTAssertEqual(settings.width, min(320, panel.width - 36), accuracy: 1)
        XCTAssertEqual(settings.height, min(290, panel.height - 36), accuracy: 1)
    }

    /// The scale is derived from live screen and menu-bar metrics, so the guarantee has to hold
    /// across the whole range rather than at whatever this machine reports today.
    func testScaleStaysWithinItsDocumentedBounds() {
        let scale = ScratchpadSizing.currentScale
        XCTAssertGreaterThanOrEqual(scale, 0.82)
        XCTAssertLessThanOrEqual(scale, 1.0)
    }
}
