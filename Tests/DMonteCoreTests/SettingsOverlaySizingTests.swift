import AppKit
import XCTest
@testable import DMonteCore

/// Every tool's settings sheet is drawn by `PreferencesOverlay`, which centres it *over* the
/// panel. A sheet wider than its panel is therefore clipped on both sides — the title loses its
/// first and last characters and the value column runs off the edge.
///
/// This shipped because the panel's size is scaled by `currentScale` while each sheet's was a
/// literal, so the two agree only on a Mac where the scale happens to be 1. It was reported from
/// a machine with a 22pt menu bar, where the scale is 0.846 and the sheets overflowed by 49pt and
/// 69pt respectively.
///
/// The scale is read from live screen and menu-bar metrics, so asserting today's numbers would
/// only pin today's machine. These assert the relationship instead.
final class SettingsOverlaySizingTests: XCTestCase {

    func testKeepAwakeSettingsSheetFitsItsPanel() {
        assertSheetFits(panel: KeepAwakeSizing.preferredSize(), sheet: KeepAwakeSizing.settingsSize(), tool: "Keep Awake")
    }

    func testFocusTimerSettingsSheetFitsItsPanel() {
        assertSheetFits(panel: FocusTimerSizing.preferredSize(), sheet: FocusTimerSizing.settingsSize(), tool: "Focus Timer")
    }

    /// System Monitor's sheet was a literal 338x350 against a 370pt panel, so at scale 1 it
    /// overhung by 4pt once the overlay's padding was added. It is capped at the panel now.
    func testSystemMonitorSettingsSheetFitsItsPanel() {
        assertSheetFits(
            panel: SystemMonitorPanelSizing.preferredSize(),
            sheet: SystemMonitorPanelSizing.settingsSize(),
            tool: "System Monitor"
        )
    }

    /// Both tools derive from the same clamped scale, so the guarantee has to hold across its
    /// whole range rather than at whatever this machine reports.
    func testScaleStaysWithinItsDocumentedBounds() {
        for scale in [KeepAwakeSizing.currentScale, FocusTimerSizing.currentScale] {
            XCTAssertGreaterThanOrEqual(scale, 0.82)
            XCTAssertLessThanOrEqual(scale, 1.0)
        }
    }

    private func assertSheetFits(panel: NSSize, sheet: NSSize, tool: String) {
        XCTAssertLessThanOrEqual(
            sheet.width, panel.width,
            "\(tool): a settings sheet wider than the panel is clipped on both sides"
        )
        XCTAssertLessThanOrEqual(
            sheet.height, panel.height,
            "\(tool): a settings sheet taller than the panel cannot show its bottom row"
        )
        XCTAssertGreaterThan(sheet.width, 0)
        XCTAssertGreaterThan(sheet.height, 0)
    }
}
