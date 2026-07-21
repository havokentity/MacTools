import XCTest
@testable import DMonteCore

/// Geometry tests for the window-snap engine. All work in a top-left-origin area so the math is
/// independent of any real display; the controller handles Cocoa↔AX conversion separately.
final class WindowManagerKitTests: XCTestCase {

    /// A non-zero-origin area (like a real visible frame inset below the menu bar) so off-by-origin
    /// bugs surface.
    private let area = CGRect(x: 100, y: 50, width: 1200, height: 800)

    /// Every action asserted on below is area-relative, so a nil here is a kit bug. `.infinite`
    /// makes that bug fail the containment assertions loudly instead of being swallowed.
    private func frame(_ action: WindowAction) -> CGRect {
        WindowManagerKit.frame(for: action, in: area) ?? .infinite
    }

    // MARK: - Corner chords

    func testCornerCombiningPerpendicularPairsAreOrderIndependent() {
        XCTAssertEqual(WindowManagerKit.cornerCombining(.rightHalf, .topHalf), .topRight)
        XCTAssertEqual(WindowManagerKit.cornerCombining(.topHalf, .rightHalf), .topRight)
        XCTAssertEqual(WindowManagerKit.cornerCombining(.leftHalf, .topHalf), .topLeft)
        XCTAssertEqual(WindowManagerKit.cornerCombining(.bottomHalf, .leftHalf), .bottomLeft)
        XCTAssertEqual(WindowManagerKit.cornerCombining(.rightHalf, .bottomHalf), .bottomRight)
    }

    func testCornerCombiningRejectsSameAxisAndNonHalves() {
        XCTAssertNil(WindowManagerKit.cornerCombining(.leftHalf, .rightHalf))
        XCTAssertNil(WindowManagerKit.cornerCombining(.topHalf, .bottomHalf))
        XCTAssertNil(WindowManagerKit.cornerCombining(.leftHalf, .leftHalf))
        XCTAssertNil(WindowManagerKit.cornerCombining(.maximize, .topHalf))
        XCTAssertNil(WindowManagerKit.cornerCombining(.leftThird, .topHalf))
    }

    func testResolveChordPromotesPerpendicularWithinWindow() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        let previous = WindowManagerKit.ChordState(action: .rightHalf, at: t0)
        XCTAssertEqual(
            WindowManagerKit.resolveChord(previous: previous, current: .topHalf, now: t0.addingTimeInterval(0.2)),
            .corner(.topRight)
        )
    }

    func testResolveChordJustInsideWindowPromotes() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        let previous = WindowManagerKit.ChordState(action: .rightHalf, at: t0)
        XCTAssertEqual(
            WindowManagerKit.resolveChord(previous: previous, current: .bottomHalf, now: t0.addingTimeInterval(WindowManagerKit.cornerChordWindow - 0.02)),
            .corner(.bottomRight)
        )
    }

    func testResolveChordIgnoresStalePrevious() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        let previous = WindowManagerKit.ChordState(action: .rightHalf, at: t0)
        XCTAssertEqual(
            WindowManagerKit.resolveChord(previous: previous, current: .topHalf, now: t0.addingTimeInterval(0.5)),
            .half(.topHalf)
        )
    }

    func testResolveChordSameAxisStaysHalf() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        let previous = WindowManagerKit.ChordState(action: .leftHalf, at: t0)
        XCTAssertEqual(
            WindowManagerKit.resolveChord(previous: previous, current: .rightHalf, now: t0.addingTimeInterval(0.1)),
            .half(.rightHalf)
        )
    }

    func testResolveChordWithoutPreviousIsHalf() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        XCTAssertEqual(WindowManagerKit.resolveChord(previous: nil, current: .leftHalf, now: t0), .half(.leftHalf))
    }

    func testLeftHalf() {
        XCTAssertEqual(frame(.leftHalf), CGRect(x: 100, y: 50, width: 600, height: 800))
    }

    func testRightHalf() {
        XCTAssertEqual(frame(.rightHalf), CGRect(x: 700, y: 50, width: 600, height: 800))
    }

    func testTopHalf() {
        XCTAssertEqual(frame(.topHalf), CGRect(x: 100, y: 50, width: 1200, height: 400))
    }

    func testBottomHalf() {
        XCTAssertEqual(frame(.bottomHalf), CGRect(x: 100, y: 450, width: 1200, height: 400))
    }

    func testHalvesTileWithoutGapOrOverlap() {
        // Left + right halves must exactly cover the area with no gap and no overlap.
        let left = frame(.leftHalf)
        let right = frame(.rightHalf)
        XCTAssertEqual(left.maxX, right.minX, accuracy: 0.001)
        XCTAssertEqual(left.width + right.width, area.width, accuracy: 0.001)
    }

    func testCorners() {
        XCTAssertEqual(frame(.topLeft), CGRect(x: 100, y: 50, width: 600, height: 400))
        XCTAssertEqual(frame(.topRight), CGRect(x: 700, y: 50, width: 600, height: 400))
        XCTAssertEqual(frame(.bottomLeft), CGRect(x: 100, y: 450, width: 600, height: 400))
        XCTAssertEqual(frame(.bottomRight), CGRect(x: 700, y: 450, width: 600, height: 400))
    }

    func testThirdsTileTheFullWidth() {
        let l = frame(.leftThird)
        let c = frame(.centerThird)
        let r = frame(.rightThird)
        XCTAssertEqual(l.minX, area.minX, accuracy: 0.001)
        XCTAssertEqual(l.maxX, c.minX, accuracy: 0.001)
        XCTAssertEqual(c.maxX, r.minX, accuracy: 0.001)
        XCTAssertEqual(r.maxX, area.maxX, accuracy: 0.001)
        // Right third absorbs any rounding remainder so the edge lands exactly on the area edge.
        XCTAssertEqual(l.width + c.width + r.width, area.width, accuracy: 0.001)
    }

    func testTwoThirds() {
        XCTAssertEqual(frame(.firstTwoThirds).width, area.width * 2 / 3, accuracy: 0.001)
        XCTAssertEqual(frame(.lastTwoThirds).maxX, area.maxX, accuracy: 0.001)
        XCTAssertEqual(frame(.lastTwoThirds).minX, area.minX + area.width / 3, accuracy: 0.001)
    }

    func testMaximizeEqualsArea() {
        XCTAssertEqual(frame(.maximize), area)
    }

    func testCenterIsCenteredAndSmallerThanArea() {
        let f = frame(.center)
        XCTAssertEqual(f.midX, area.midX, accuracy: 0.001)
        XCTAssertEqual(f.midY, area.midY, accuracy: 0.001)
        XCTAssertLessThan(f.width, area.width)
        XCTAssertLessThan(f.height, area.height)
    }

    func testAlmostMaximizeStaysInsideArea() {
        let f = frame(.almostMaximize)
        XCTAssertGreaterThanOrEqual(f.minX, area.minX)
        XCTAssertGreaterThanOrEqual(f.minY, area.minY)
        XCTAssertLessThanOrEqual(f.maxX, area.maxX + 0.001)
        XCTAssertLessThanOrEqual(f.maxY, area.maxY + 0.001)
        XCTAssertEqual(f.midX, area.midX, accuracy: 0.001)
    }

    func testAllActionsProduceFinitePositiveSizes() {
        for action in WindowAction.areaRelativeCases {
            let f = frame(action)
            XCTAssertTrue(f.width > 0 && f.height > 0, "\(action.rawValue) produced non-positive size \(f)")
            XCTAssertTrue(f.width.isFinite && f.height.isFinite, "\(action.rawValue) produced non-finite size")
        }
    }

    func testAllActionsStayWithinArea() {
        for action in WindowAction.areaRelativeCases {
            let f = frame(action)
            XCTAssertGreaterThanOrEqual(f.minX, area.minX - 0.001, "\(action.rawValue) escaped left")
            XCTAssertGreaterThanOrEqual(f.minY, area.minY - 0.001, "\(action.rawValue) escaped top")
            XCTAssertLessThanOrEqual(f.maxX, area.maxX + 0.001, "\(action.rawValue) escaped right")
            XCTAssertLessThanOrEqual(f.maxY, area.maxY + 0.001, "\(action.rawValue) escaped bottom")
        }
    }

    /// The area-relative set must stay exactly "everything except the two display actions", so
    /// switching the loops above off `allCases` cannot become a way for coverage to quietly shrink.
    func testAreaRelativeCasesCoverEverythingButTheDisplayActions() {
        XCTAssertEqual(
            Set(WindowAction.areaRelativeCases),
            Set(WindowAction.allCases).subtracting([.nextDisplay, .restorePrevious])
        )
        for action in WindowAction.areaRelativeCases {
            XCTAssertNotNil(WindowManagerKit.frame(for: action, in: area), "\(action.rawValue) has no area frame")
        }
        XCTAssertNil(WindowManagerKit.frame(for: .nextDisplay, in: area))
        XCTAssertNil(WindowManagerKit.frame(for: .restorePrevious, in: area))
    }

    func testActionMetadataIsComplete() {
        for action in WindowAction.allCases {
            XCTAssertFalse(action.title.isEmpty, "\(action.rawValue) missing title")
            XCTAssertFalse(action.symbol.isEmpty, "\(action.rawValue) missing symbol")
            XCTAssertEqual(action.id, action.rawValue)
        }
    }

    func testDefaultShortcutsAreUnique() {
        // No two actions may share the same (keyCode, modifiers) or the hotkeys would clash.
        var seen = Set<String>()
        for action in WindowAction.allCases {
            guard let sc = action.defaultShortcut else { continue }
            let key = "\(sc.keyCode)-\(sc.modifiers)"
            XCTAssertTrue(seen.insert(key).inserted, "Duplicate default shortcut for \(action.rawValue)")
        }
    }

    // MARK: - Frame verification (pins the "snap moved but didn't resize" fix)

    func testFrameMatchesExactFrame() {
        let target = CGRect(x: 3840, y: 30, width: 1280, height: 1410)
        XCTAssertTrue(WindowManagerKit.frameMatches(target, target: target))
    }

    func testFrameMatchesRejectsTheLiveDiagnosedKeptSizeCase() {
        // The real failure measured against Claude Desktop with AXEnhancedUserInterface set:
        // right-half snap returned three AX successes, but the window only moved (and y was
        // mangled) while keeping its 900×700 size. Verification must call this a mismatch.
        let target = CGRect(x: 3840, y: 30, width: 1280, height: 1410)
        let achieved = CGRect(x: 3840, y: 570, width: 900, height: 700)
        XCTAssertFalse(WindowManagerKit.frameMatches(achieved, target: target))
    }

    func testFrameMatchesEachComponentIndependently() {
        let target = CGRect(x: 100, y: 50, width: 1200, height: 800)
        let t = WindowManagerKit.frameMatchTolerance
        // Just inside the tolerance on each component passes…
        XCTAssertTrue(WindowManagerKit.frameMatches(target.offsetBy(dx: t - 1, dy: 0), target: target))
        XCTAssertTrue(WindowManagerKit.frameMatches(target.offsetBy(dx: 0, dy: -(t - 1)), target: target))
        XCTAssertTrue(WindowManagerKit.frameMatches(CGRect(x: 100, y: 50, width: 1200 - (t - 1), height: 800), target: target))
        XCTAssertTrue(WindowManagerKit.frameMatches(CGRect(x: 100, y: 50, width: 1200, height: 800 + (t - 1)), target: target))
        // …and just beyond it on any single component fails.
        XCTAssertFalse(WindowManagerKit.frameMatches(target.offsetBy(dx: t + 1, dy: 0), target: target))
        XCTAssertFalse(WindowManagerKit.frameMatches(target.offsetBy(dx: 0, dy: t + 1), target: target))
        XCTAssertFalse(WindowManagerKit.frameMatches(CGRect(x: 100, y: 50, width: 1200 + (t + 1), height: 800), target: target))
        XCTAssertFalse(WindowManagerKit.frameMatches(CGRect(x: 100, y: 50, width: 1200, height: 800 - (t + 1)), target: target))
    }

    func testFrameMatchesWorksWithNegativeCoordinates() {
        // The left BenQ lives at negative AX x on the reporter's arrangement; tolerance math must
        // not assume positive coordinates.
        let target = CGRect(x: -1280, y: 30, width: 1280, height: 1410)
        XCTAssertTrue(WindowManagerKit.frameMatches(CGRect(x: -1282, y: 32, width: 1278, height: 1408), target: target))
        XCTAssertFalse(WindowManagerKit.frameMatches(CGRect(x: -2560, y: 30, width: 1280, height: 1410), target: target))
    }

    func testFrameMatchesToleratesTerminalGridRounding() {
        // Terminals round their size to character-cell multiples (~8–20 pt under the default
        // font). A snap that lands one cell short is visually correct and must count as success.
        let target = CGRect(x: 0, y: 30, width: 1280, height: 1410)
        let rounded = CGRect(x: 0, y: 30, width: 1274, height: 1396)
        XCTAssertTrue(WindowManagerKit.frameMatches(rounded, target: target))
    }

    func testFrameMatchesHonorsExplicitTolerance() {
        let target = CGRect(x: 0, y: 0, width: 100, height: 100)
        let off = CGRect(x: 3, y: 0, width: 100, height: 100)
        XCTAssertFalse(WindowManagerKit.frameMatches(off, target: target, tolerance: 2))
        XCTAssertTrue(WindowManagerKit.frameMatches(off, target: target, tolerance: 3))
    }

    func testFrameSetAttemptsStartPositionFirstAndAlternate() {
        // The initial attempt keeps the historical position→size→position order; the retries
        // must include the size-first alternate (the ordering that survives apps which drop a
        // size set issued after a move), and the whole plan is initial + up to two retries.
        XCTAssertEqual(WindowManagerKit.frameSetAttempts.count, 3)
        XCTAssertEqual(WindowManagerKit.frameSetAttempts.first, .positionFirst)
        XCTAssertTrue(WindowManagerKit.frameSetAttempts.contains(.sizeFirst))
        // Consecutive attempts never repeat an ordering — a retry with the identical sequence
        // would just reproduce the identical failure.
        for (a, b) in zip(WindowManagerKit.frameSetAttempts, WindowManagerKit.frameSetAttempts.dropFirst()) {
            XCTAssertNotEqual(a, b)
        }
    }

    func testAXRectConversionRoundTripsThroughPrimaryHeight() {
        // With a known primary height, Cocoa(bottom-left) → AX(top-left) flips y about the height.
        // We verify the inverse is symmetric: converting twice returns the original rect.
        let cocoa = CGRect(x: 10, y: 20, width: 300, height: 200)
        let once = WindowManagerController.axRect(fromCocoa: cocoa)
        let twice = WindowManagerController.axRect(fromCocoa: once)
        XCTAssertEqual(twice, cocoa)
    }

    func testPureAXRectConversionIsAnInvolution() {
        let cocoa = CGRect(x: -2560, y: 0, width: 2560, height: 1440)
        let once = WindowManagerKit.axRect(fromCocoa: cocoa, primaryScreenHeight: 1440)
        let twice = WindowManagerKit.axRect(fromCocoa: once, primaryScreenHeight: 1440)
        XCTAssertEqual(twice, cocoa)
        XCTAssertEqual(once, CGRect(x: -2560, y: 0, width: 2560, height: 1440))
    }

    func testPureAXRectConversionFlipsAboveAndBelowScreens() {
        // A screen ABOVE the primary (cocoa y = primary height) lands at negative AX y.
        let above = WindowManagerKit.axRect(
            fromCocoa: CGRect(x: 0, y: 1440, width: 1920, height: 1080),
            primaryScreenHeight: 1440
        )
        XCTAssertEqual(above, CGRect(x: 0, y: -1080, width: 1920, height: 1080))

        // A screen BELOW the primary (negative cocoa y) lands below in AX space (y = primary height).
        let below = WindowManagerKit.axRect(
            fromCocoa: CGRect(x: 0, y: -1080, width: 1920, height: 1080),
            primaryScreenHeight: 1440
        )
        XCTAssertEqual(below, CGRect(x: 0, y: 1440, width: 1920, height: 1080))
    }
}
