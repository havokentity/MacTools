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

    /// Clean Drive's developer-junk sheet is sized to fill the panel rather than to a comfortable
    /// literal, so it is the one sheet that would spill the instant the 18pt-per-side padding
    /// `PreferencesOverlay` adds were forgotten. Asserted against the padded size for that reason.
    func testCleanDriveDevJunkSheetFitsItsPanelOncePadded() {
        let panel = CleanDriveSizing.preferredSize()
        let sheet = CleanDriveSizing.devJunkSize()
        let overlayChrome = PreferencesOverlayMetrics.chrome

        assertSheetFits(panel: panel, sheet: sheet, tool: "Clean Drive developer junk")
        XCTAssertLessThanOrEqual(
            sheet.width + overlayChrome, panel.width,
            "Clean Drive: PreferencesOverlay pads the sheet by \(PreferencesOverlayMetrics.padding)pt a side, so it must be \(overlayChrome)pt narrower than the panel"
        )
        XCTAssertLessThanOrEqual(
            sheet.height + overlayChrome, panel.height,
            "Clean Drive: PreferencesOverlay pads the sheet by \(PreferencesOverlayMetrics.padding)pt a side, so it must be \(overlayChrome)pt shorter than the panel"
        )
    }

    /// The chrome a sizing file subtracts is two of `PreferencesOverlay`'s paddings, not a number of
    /// its own. `PreferencesOverlayMetrics` is now the single definition and the overlay pads with
    /// it, so asserting the *budget* here rather than a literal means moving that padding fails this
    /// test — including for the tools that still spell the total out locally — instead of quietly
    /// pushing their sheets over their panels.
    func testSettingsSheetsLeaveRoomForTheOverlayChrome() {
        let chrome = PreferencesOverlayMetrics.chrome
        XCTAssertEqual(chrome, PreferencesOverlayMetrics.padding * 2)

        for (tool, panel, sheet) in [
            ("Keep Awake", KeepAwakeSizing.preferredSize(), KeepAwakeSizing.settingsSize()),
            ("Focus Timer", FocusTimerSizing.preferredSize(), FocusTimerSizing.settingsSize())
        ] {
            XCTAssertLessThanOrEqual(
                sheet.width + chrome, panel.width,
                "\(tool): the sheet has to leave the overlay's padding on both sides"
            )
            XCTAssertLessThanOrEqual(
                sheet.height + chrome, panel.height,
                "\(tool): the sheet has to leave the overlay's padding above and below"
            )
        }
    }

    /// Both tools derive from the same clamped scale, so the guarantee has to hold across its
    /// whole range rather than at whatever this machine reports.
    func testScaleStaysWithinItsDocumentedBounds() {
        for scale in [KeepAwakeSizing.currentScale, FocusTimerSizing.currentScale, CleanDriveSizing.currentScale] {
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
