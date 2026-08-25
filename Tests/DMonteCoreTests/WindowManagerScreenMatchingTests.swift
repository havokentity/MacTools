import AppKit
import XCTest
@testable import DMonteCore

/// Pins the pure screen matcher (`WindowManagerKit.areaIndex(forWindow:in:)`) against the real
/// three-display arrangement this bug was reported on, plus canonical synthetic arrangements
/// (secondary left with negative x, above with negative AX y, below, mixed resolutions). All
/// rects are in AX top-left space, exactly as the controller feeds them.
final class WindowManagerScreenMatchingTests: XCTestCase {

    /// The reporter's actual Mac Studio arrangement (measured live, 2026-06):
    /// AW3225QF primary in the middle, BenQ PD3226G to the LEFT (negative x),
    /// BenQ EX3210U to the RIGHT — all 2560×1440pt, menu bar 30pt, dock 78pt on the primary.
    /// These are the AX-converted visibleFrames as a GUI app sees them.
    private let realArrangement: [CGRect] = [
        CGRect(x: 0, y: 30, width: 2560, height: 1332),      // primary (menu bar + dock insets)
        CGRect(x: -2560, y: 30, width: 2560, height: 1410),  // left BenQ (menu bar inset)
        CGRect(x: 2560, y: 30, width: 2560, height: 1410)    // right BenQ (menu bar inset)
    ]

    /// The same arrangement as a non-GUI process reports it (secondaries claim the full frame).
    /// The matcher must behave identically either way.
    private let realArrangementUninsetted: [CGRect] = [
        CGRect(x: 0, y: 30, width: 2560, height: 1332),
        CGRect(x: -2560, y: 0, width: 2560, height: 1440),
        CGRect(x: 2560, y: 0, width: 2560, height: 1440)
    ]

    private func window(centeredIn area: CGRect, width: CGFloat = 800, height: CGFloat = 600) -> CGRect {
        CGRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
    }

    // MARK: - Real arrangement

    func testRealArrangementMatchesWindowCenteredOnEachScreen() {
        for (index, area) in realArrangement.enumerated() {
            let matched = WindowManagerKit.areaIndex(forWindow: window(centeredIn: area), in: realArrangement)
            XCTAssertEqual(matched, index, "window centered on screen \(index) matched \(String(describing: matched))")
        }
    }

    func testRealArrangementUninsettedVariantMatchesToo() {
        for (index, area) in realArrangementUninsetted.enumerated() {
            let matched = WindowManagerKit.areaIndex(forWindow: window(centeredIn: area), in: realArrangementUninsetted)
            XCTAssertEqual(matched, index)
        }
    }

    func testRealArrangementTargetRectsStayWithinTheMatchedScreen() {
        for (index, area) in realArrangement.enumerated() {
            let matched = WindowManagerKit.areaIndex(forWindow: window(centeredIn: area), in: realArrangement)
            XCTAssertEqual(matched, index)
            for action in WindowAction.areaRelativeCases {
                guard let target = WindowManagerKit.frame(for: action, in: area) else {
                    XCTFail("\(action.rawValue) is area-relative but produced no frame")
                    continue
                }
                XCTAssertGreaterThanOrEqual(target.minX, area.minX - 0.001, "\(action.rawValue) escaped screen \(index) left")
                XCTAssertGreaterThanOrEqual(target.minY, area.minY - 0.001, "\(action.rawValue) escaped screen \(index) top")
                XCTAssertLessThanOrEqual(target.maxX, area.maxX + 0.001, "\(action.rawValue) escaped screen \(index) right")
                XCTAssertLessThanOrEqual(target.maxY, area.maxY + 0.001, "\(action.rawValue) escaped screen \(index) bottom")
            }
        }
    }

    func testRealArrangementMaximizedWindowOnRightScreenMatchesRightScreen() {
        // The live Figma window that participated in the diagnosis: maximized on the right BenQ.
        let maximized = CGRect(x: 2560, y: 30, width: 2560, height: 1410)
        XCTAssertEqual(WindowManagerKit.areaIndex(forWindow: maximized, in: realArrangement), 2)
    }

    func testRealArrangementWindowStraddlingPrimaryAndRightPicksTheMajoritySide() {
        // Center sits 100pt into the right screen → right screen wins by center containment.
        let straddling = CGRect(x: 2660 - 800, y: 400, width: 1600, height: 900)
        XCTAssertEqual(WindowManagerKit.areaIndex(forWindow: straddling, in: realArrangement), 2)
    }

    // MARK: - Synthetic arrangements

    func testSecondaryAbovePrimaryWithNegativeAXOriginMatches() {
        // 1920×1080 display above a 2560×1440 primary: AX y is negative for the upper screen.
        let areas = [
            CGRect(x: 0, y: 30, width: 2560, height: 1410),
            CGRect(x: 320, y: -1080, width: 1920, height: 1080)
        ]
        XCTAssertEqual(WindowManagerKit.areaIndex(forWindow: window(centeredIn: areas[0]), in: areas), 0)
        XCTAssertEqual(WindowManagerKit.areaIndex(forWindow: window(centeredIn: areas[1]), in: areas), 1)
    }

    func testSecondaryBelowPrimaryMatches() {
        let areas = [
            CGRect(x: 0, y: 30, width: 2560, height: 1410),
            CGRect(x: 320, y: 1440, width: 1920, height: 1080)
        ]
        XCTAssertEqual(WindowManagerKit.areaIndex(forWindow: window(centeredIn: areas[1]), in: areas), 1)
    }

    func testMixedResolutionsLeftAndRightMatch() {
        // Small 1440×900 laptop left of the primary, 4K-points 3008×1692 right of it.
        let areas = [
            CGRect(x: 0, y: 30, width: 2560, height: 1410),
            CGRect(x: -1440, y: 540, width: 1440, height: 875),
            CGRect(x: 2560, y: -252, width: 3008, height: 1667)
        ]
        for (index, area) in areas.enumerated() {
            XCTAssertEqual(WindowManagerKit.areaIndex(forWindow: window(centeredIn: area, width: 400, height: 300), in: areas), index)
        }
    }

    func testCenterOutsideAllAreasFallsBackToLargestOverlap() {
        // A window hanging off the top of the left screen: its center is above every area, so
        // center containment fails and the largest-overlap fallback must pick the left screen.
        let areas = realArrangement
        let hangingOff = CGRect(x: -2000, y: -500, width: 800, height: 900)
        XCTAssertEqual(WindowManagerKit.areaIndex(forWindow: hangingOff, in: areas), 1)
    }

    func testWindowOverlappingNothingReturnsNilSoCallerPicksPrimary() {
        // Fully off every screen (e.g. stale coordinates after a display was unplugged): the
        // matcher must say "no screen" instead of inventing one — the controller then falls back
        // to the primary screen, never the popover's screen.
        let areas = realArrangement
        let lost = CGRect(x: 9000, y: 9000, width: 500, height: 500)
        XCTAssertNil(WindowManagerKit.areaIndex(forWindow: lost, in: areas))
    }

    func testEmptyAreaListReturnsNil() {
        XCTAssertNil(WindowManagerKit.areaIndex(forWindow: CGRect(x: 0, y: 0, width: 100, height: 100), in: []))
    }

    func testZeroOverlapNeverBeatsPositiveOverlap() {
        // Regression guard: the old controller fallback used max(by:) over *all* screens, which
        // happily returned a zero-overlap screen. Any positive overlap must win.
        let areas = [
            CGRect(x: 0, y: 0, width: 1000, height: 1000),
            CGRect(x: 5000, y: 5000, width: 100, height: 100)
        ]
        // Center outside both (window pokes above area 0), overlap only with area 0.
        let poking = CGRect(x: 100, y: -800, width: 200, height: 1000)
        XCTAssertEqual(WindowManagerKit.areaIndex(forWindow: poking, in: areas), 0)
    }
}

/// Diagnostic against the REAL display arrangement of the machine running the tests: prints each
/// screen's Cocoa frame/visibleFrame and AX conversion, then for a synthetic window centered on
/// each screen asserts the matcher picks that screen and every action's target rect lies within
/// that screen's AX visibleFrame. Skips gracefully on headless runners with no displays.
final class WindowManagerRealScreensDiagnosticTests: XCTestCase {

    @MainActor
    func testMatcherPicksEveryRealScreenAndTargetsStayInside() throws {
        let screens = NSScreen.screens
        try XCTSkipIf(screens.isEmpty, "No displays attached (headless test runner)")

        let areas = screens.map { WindowManagerController.axRect(fromCocoa: $0.visibleFrame) }
        for (index, screen) in screens.enumerated() {
            print("screen[\(index)] \(screen.localizedName)")
            print("  cocoa frame        = \(screen.frame)")
            print("  cocoa visibleFrame = \(screen.visibleFrame)")
            print("  ax visibleFrame    = \(areas[index])")
        }

        for (index, area) in areas.enumerated() {
            let width = min(800, area.width / 2)
            let height = min(600, area.height / 2)
            let window = CGRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)

            let matched = WindowManagerKit.areaIndex(forWindow: window, in: areas)
            XCTAssertEqual(matched, index, "synthetic window centered on screen \(index) matched \(String(describing: matched))")

            for action in WindowAction.areaRelativeCases {
                guard let target = WindowManagerKit.frame(for: action, in: area) else {
                    XCTFail("\(action.rawValue) is area-relative but produced no frame")
                    continue
                }
                XCTAssertGreaterThanOrEqual(target.minX, area.minX - 0.001, "\(action.rawValue) escaped screen \(index)")
                XCTAssertGreaterThanOrEqual(target.minY, area.minY - 0.001, "\(action.rawValue) escaped screen \(index)")
                XCTAssertLessThanOrEqual(target.maxX, area.maxX + 0.001, "\(action.rawValue) escaped screen \(index)")
                XCTAssertLessThanOrEqual(target.maxY, area.maxY + 0.001, "\(action.rawValue) escaped screen \(index)")
            }
        }
    }
}
