import AppKit
import XCTest
@testable import DMonteCore

/// Covers the two display actions: moving the focused window to the next display, and restoring
/// the frame it had before the last Window Manager action.
///
/// Everything here is the pure half — the cross-display mapping, the cycle order, and the bounded
/// restore store — because that is where the failure modes live: a window that lands off-screen on
/// a differently-shaped display, a "next display" that mangles the window on a single-display Mac,
/// or a cache that grows for the lifetime of the helper. All rects are AX top-left visible frames,
/// exactly what the controller feeds in.
final class WindowManagerDisplayActionTests: XCTestCase {

    // The reporter's real three-display Mac Studio arrangement (AX-converted visible frames):
    // AW3225QF primary in the middle with menu bar + dock insets, BenQ PD3226G to the LEFT at
    // negative x, BenQ EX3210U to the RIGHT.
    private let primary = CGRect(x: 0, y: 30, width: 2560, height: 1332)
    private let leftScreen = CGRect(x: -2560, y: 30, width: 2560, height: 1410)
    private let rightScreen = CGRect(x: 2560, y: 30, width: 2560, height: 1410)

    /// Where a frame sits inside an area, as fractions of that area — the quantity the mapping is
    /// supposed to preserve.
    private func fractions(of frame: CGRect, in area: CGRect) -> [CGFloat] {
        [
            (frame.minX - area.minX) / area.width,
            (frame.minY - area.minY) / area.height,
            frame.width / area.width,
            frame.height / area.height
        ]
    }

    private func assertInside(_ frame: CGRect, _ area: CGRect, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(frame.minX, area.minX - 0.001, "\(message) escaped left", file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minY, area.minY - 0.001, "\(message) escaped top", file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, area.maxX + 0.001, "\(message) escaped right", file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxY, area.maxY + 0.001, "\(message) escaped bottom", file: file, line: line)
    }

    // MARK: - Cross-display mapping

    func testMappingPreservesRelativePositionAndProportionalSize() {
        // A window occupying a known fraction of the primary must occupy the same fraction of the
        // destination, whatever that display's shape.
        let window = CGRect(
            x: primary.minX + primary.width * 0.25,
            y: primary.minY + primary.height * 0.2,
            width: primary.width * 0.5,
            height: primary.height * 0.4
        )
        let moved = WindowManagerKit.frame(movingWindow: window, from: primary, to: rightScreen)
        for (expected, actual) in zip(fractions(of: window, in: primary), fractions(of: moved, in: rightScreen)) {
            XCTAssertEqual(actual, expected, accuracy: 0.0001)
        }
        assertInside(moved, rightScreen, "proportional move")
    }

    func testMappingAcrossDifferentAspectRatios() {
        // 16:9 → 16:10 → 4:3 → ultrawide 21:9. The fractions must survive every hop, and the
        // result must stay on the destination each time.
        let shapes: [CGRect] = [
            CGRect(x: 0, y: 30, width: 2560, height: 1410),   // 16:9 with a menu bar inset
            CGRect(x: 0, y: 25, width: 1440, height: 875),    // 16:10 laptop
            CGRect(x: -1024, y: 0, width: 1024, height: 768), // 4:3, negative origin
            CGRect(x: 3440, y: 40, width: 3440, height: 1400) // ultrawide
        ]
        let source = shapes[0]
        let window = CGRect(x: source.minX + 640, y: source.minY + 282, width: 1280, height: 705)
        let expected = fractions(of: window, in: source)

        for destination in shapes.dropFirst() {
            let moved = WindowManagerKit.frame(movingWindow: window, from: source, to: destination)
            for (want, got) in zip(expected, fractions(of: moved, in: destination)) {
                XCTAssertEqual(got, want, accuracy: 0.0001, "aspect \(destination.width)x\(destination.height)")
            }
            assertInside(moved, destination, "aspect \(destination.width)x\(destination.height)")
        }
    }

    func testMaximizedWindowStaysMaximizedOnTheDestination() {
        // The whole point of mapping through *visible* frames: a window filling a screen with a
        // 30pt menu bar and a 78pt dock must fill the destination's own usable area, not inherit
        // the source's insets.
        let moved = WindowManagerKit.frame(movingWindow: primary, from: primary, to: leftScreen)
        XCTAssertEqual(moved, leftScreen)
    }

    func testWindowLargerThanDestinationIsClampedToFitIt() {
        // A 3000×2000 window on a big screen cannot keep its size on a 1440×900 laptop display.
        let laptop = CGRect(x: 2560, y: 25, width: 1440, height: 875)
        let oversized = CGRect(x: primary.minX + 100, y: primary.minY + 100, width: 3000, height: 2000)
        let moved = WindowManagerKit.frame(movingWindow: oversized, from: primary, to: laptop)

        XCTAssertLessThanOrEqual(moved.width, laptop.width + 0.001)
        XCTAssertLessThanOrEqual(moved.height, laptop.height + 0.001)
        assertInside(moved, laptop, "oversized window")
        XCTAssertGreaterThan(moved.width, 0)
        XCTAssertGreaterThan(moved.height, 0)
    }

    func testPartiallyOffscreenWindowIsPulledFullyOntoTheDestination() {
        // Hanging off the left and top of the primary. Copying coordinates (or the fractions
        // alone) would keep it hanging off the destination, where the user may not be able to
        // reach its title bar at all.
        let hangingOff = CGRect(x: primary.minX - 400, y: primary.minY - 200, width: 900, height: 700)
        let moved = WindowManagerKit.frame(movingWindow: hangingOff, from: primary, to: rightScreen)
        assertInside(moved, rightScreen, "window hanging off source top-left")
        XCTAssertEqual(moved.minX, rightScreen.minX, accuracy: 0.001)
        XCTAssertEqual(moved.minY, rightScreen.minY, accuracy: 0.001)
    }

    func testWindowHangingOffTheBottomRightIsPulledIn() {
        let hangingOff = CGRect(x: primary.maxX - 200, y: primary.maxY - 150, width: 900, height: 700)
        let moved = WindowManagerKit.frame(movingWindow: hangingOff, from: primary, to: leftScreen)
        assertInside(moved, leftScreen, "window hanging off source bottom-right")
        XCTAssertEqual(moved.maxX, leftScreen.maxX, accuracy: 0.001)
        XCTAssertEqual(moved.maxY, leftScreen.maxY, accuracy: 0.001)
    }

    func testSingleDisplayMoveIsAnExactNoOp() {
        // On a one-display Mac the source and destination are the same area. The window must come
        // back byte-identical — including a deliberately offscreen one, which a round-trip through
        // the clamp would have hauled back on-screen.
        let window = CGRect(x: 137, y: 411, width: 913, height: 622)
        XCTAssertEqual(WindowManagerKit.frame(movingWindow: window, from: primary, to: primary), window)

        let offscreen = CGRect(x: -500, y: -400, width: 900, height: 700)
        XCTAssertEqual(WindowManagerKit.frame(movingWindow: offscreen, from: primary, to: primary), offscreen)
    }

    func testDegenerateAreasLeaveTheWindowUntouched() {
        // Zero-sized areas show up while a display is being reconfigured; dividing by them would
        // produce NaN coordinates that AX accepts and the user then cannot find.
        let window = CGRect(x: 100, y: 100, width: 800, height: 600)
        XCTAssertEqual(WindowManagerKit.frame(movingWindow: window, from: .zero, to: rightScreen), window)
        XCTAssertEqual(WindowManagerKit.frame(movingWindow: window, from: primary, to: CGRect(x: 5000, y: 0, width: 0, height: 0)), window)
    }

    func testMappingNeverProducesNonFiniteGeometry() {
        let window = CGRect(x: primary.minX + 10, y: primary.minY + 10, width: 640, height: 480)
        for destination in [leftScreen, rightScreen, CGRect(x: 0, y: -1080, width: 1920, height: 1080)] {
            let moved = WindowManagerKit.frame(movingWindow: window, from: primary, to: destination)
            XCTAssertTrue(moved.origin.x.isFinite && moved.origin.y.isFinite)
            XCTAssertTrue(moved.width.isFinite && moved.height.isFinite)
            XCTAssertGreaterThan(moved.width, 0)
            XCTAssertGreaterThan(moved.height, 0)
        }
    }

    // MARK: - Clamping

    func testClampLeavesAnAlreadyContainedFrameAlone() {
        let inside = CGRect(x: primary.minX + 50, y: primary.minY + 50, width: 400, height: 300)
        XCTAssertEqual(WindowManagerKit.clamped(inside, into: primary), inside)
    }

    func testClampShrinksAndRepositionsAsNeeded() {
        let huge = CGRect(x: -9000, y: -9000, width: 99_999, height: 99_999)
        XCTAssertEqual(WindowManagerKit.clamped(huge, into: primary), primary)
    }

    func testClampOnADegenerateAreaReturnsTheFrameUnchanged() {
        let frame = CGRect(x: 10, y: 20, width: 30, height: 40)
        XCTAssertEqual(WindowManagerKit.clamped(frame, into: .zero), frame)
    }

    // MARK: - Display cycling

    func testNextDisplayIsNilWhenThereIsNowhereToGo() {
        XCTAssertNil(WindowManagerKit.nextAreaIndex(after: 0, in: []), "no displays")
        XCTAssertNil(WindowManagerKit.nextAreaIndex(after: 0, in: [primary]), "single display")
        XCTAssertNil(WindowManagerKit.nextAreaIndex(after: 7, in: [primary, rightScreen]), "index out of range")
        XCTAssertNil(WindowManagerKit.nextAreaIndex(after: -1, in: [primary, rightScreen]), "negative index")
    }

    func testCycleFollowsPhysicalLeftToRightOrderNotScreensOrder() {
        // NSScreen.screens puts the primary first regardless of where it physically sits, so the
        // list order here is primary, left, right — cycling must still go left → primary → right.
        let areas = [primary, leftScreen, rightScreen]
        XCTAssertEqual(WindowManagerKit.displayCycleOrder(of: areas), [1, 0, 2])
        XCTAssertEqual(WindowManagerKit.nextAreaIndex(after: 1, in: areas), 0)
        XCTAssertEqual(WindowManagerKit.nextAreaIndex(after: 0, in: areas), 2)
        XCTAssertEqual(WindowManagerKit.nextAreaIndex(after: 2, in: areas), 1, "wraps back to the leftmost")
    }

    func testCycleVisitsEveryDisplayExactlyOnceBeforeReturning() {
        let areas = [primary, leftScreen, rightScreen, CGRect(x: 0, y: -1080, width: 1920, height: 1080)]
        for start in areas.indices {
            var visited = [start]
            var current = start
            for _ in 1..<areas.count {
                guard let next = WindowManagerKit.nextAreaIndex(after: current, in: areas) else {
                    return XCTFail("cycle stopped early from \(start)")
                }
                visited.append(next)
                current = next
            }
            XCTAssertEqual(Set(visited).count, areas.count, "cycle from \(start) repeated a display: \(visited)")
            XCTAssertEqual(WindowManagerKit.nextAreaIndex(after: current, in: areas), start, "cycle from \(start) did not wrap home")
        }
    }

    func testVerticallyStackedDisplaysCycleTopToBottom() {
        // Same x for both, so the y tie-break decides: the upper (negative AX y) display first.
        let areas = [
            CGRect(x: 0, y: 30, width: 2560, height: 1410),
            CGRect(x: 0, y: -1080, width: 2560, height: 1080)
        ]
        XCTAssertEqual(WindowManagerKit.displayCycleOrder(of: areas), [1, 0])
        XCTAssertEqual(WindowManagerKit.nextAreaIndex(after: 1, in: areas), 0)
        XCTAssertEqual(WindowManagerKit.nextAreaIndex(after: 0, in: areas), 1)
    }

    func testIdenticallyPositionedAreasKeepAStableOrder() {
        // Mirrored displays report the same origin; the tie-break on index keeps the cycle
        // deterministic instead of depending on the sort's stability.
        let areas = [primary, primary]
        XCTAssertEqual(WindowManagerKit.displayCycleOrder(of: areas), [0, 1])
        XCTAssertEqual(WindowManagerKit.nextAreaIndex(after: 0, in: areas), 1)
        XCTAssertEqual(WindowManagerKit.nextAreaIndex(after: 1, in: areas), 0)
    }

    /// End-to-end on the real three-display arrangement: cycling a window all the way round leaves
    /// it inside every screen it visits and back where it started, which is the property that broke
    /// when coordinates were copied instead of mapped.
    func testCyclingAllTheWayRoundKeepsTheWindowOnScreenAndReturnsHome() {
        let areas = [primary, leftScreen, rightScreen]
        var index = 0
        var frame = CGRect(x: primary.minX + 300, y: primary.minY + 200, width: 1200, height: 800)
        let originalFractions = fractions(of: frame, in: primary)

        for _ in areas.indices {
            guard let next = WindowManagerKit.nextAreaIndex(after: index, in: areas) else {
                return XCTFail("three displays should always have a next")
            }
            frame = WindowManagerKit.frame(movingWindow: frame, from: areas[index], to: areas[next])
            assertInside(frame, areas[next], "cycled onto screen \(next)")
            index = next
        }

        XCTAssertEqual(index, 0, "a full cycle returns to the starting display")
        for (want, got) in zip(originalFractions, fractions(of: frame, in: primary)) {
            XCTAssertEqual(got, want, accuracy: 0.0001, "a full cycle restored the original proportions")
        }
    }

    // MARK: - Restore memory

    private func identity(_ pid: pid_t, _ number: Int?) -> WindowIdentity {
        WindowIdentity(pid: pid, windowNumber: number)
    }

    func testRememberPeekAndForget() {
        var memory = WindowFrameMemory()
        let key = identity(501, 42)
        let frame = CGRect(x: 10, y: 20, width: 800, height: 600)

        XCTAssertNil(memory.frame(for: key), "nothing remembered yet")
        memory.remember(frame, for: key)
        XCTAssertEqual(memory.frame(for: key), frame)
        XCTAssertEqual(memory.frame(for: key), frame, "peeking does not consume — the write may still fail")

        memory.forget(key)
        XCTAssertNil(memory.frame(for: key), "a landed restore consumes its entry")
        XCTAssertEqual(memory.count, 0)
    }

    func testRememberingAgainReplacesTheEarlierFrame() {
        // Restore undoes the *last* action, so a second snap must overwrite rather than stack.
        var memory = WindowFrameMemory()
        let key = identity(501, 42)
        memory.remember(CGRect(x: 0, y: 0, width: 100, height: 100), for: key)
        memory.remember(CGRect(x: 5, y: 5, width: 200, height: 200), for: key)
        XCTAssertEqual(memory.frame(for: key), CGRect(x: 5, y: 5, width: 200, height: 200))
        XCTAssertEqual(memory.count, 1)
    }

    func testDistinctWindowsAndAppsGetDistinctSlots() {
        var memory = WindowFrameMemory()
        let sameAppWindowA = identity(501, 1)
        let sameAppWindowB = identity(501, 2)
        let otherApp = identity(777, 1)
        // An app that withholds AXWindowNumber shares one slot per pid — coarser, but distinct
        // from the numbered windows of the same app.
        let numberless = identity(501, nil)

        memory.remember(CGRect(x: 1, y: 0, width: 10, height: 10), for: sameAppWindowA)
        memory.remember(CGRect(x: 2, y: 0, width: 10, height: 10), for: sameAppWindowB)
        memory.remember(CGRect(x: 3, y: 0, width: 10, height: 10), for: otherApp)
        memory.remember(CGRect(x: 4, y: 0, width: 10, height: 10), for: numberless)

        XCTAssertEqual(memory.count, 4)
        XCTAssertEqual(memory.frame(for: sameAppWindowA)?.minX, 1)
        XCTAssertEqual(memory.frame(for: sameAppWindowB)?.minX, 2)
        XCTAssertEqual(memory.frame(for: otherApp)?.minX, 3)
        XCTAssertEqual(memory.frame(for: numberless)?.minX, 4)
    }

    func testMemoryIsBoundedAndEvictsTheLeastRecentlyRemembered() {
        // Windows close without telling us, so the store must never grow with the number of
        // windows the user has ever snapped.
        var memory = WindowFrameMemory(capacity: 3)
        for index in 0..<10 {
            memory.remember(CGRect(x: CGFloat(index), y: 0, width: 10, height: 10), for: identity(501, index))
        }
        XCTAssertEqual(memory.count, 3)
        XCTAssertNil(memory.frame(for: identity(501, 6)), "old entries are gone")
        XCTAssertEqual(memory.frame(for: identity(501, 7))?.minX, 7)
        XCTAssertEqual(memory.frame(for: identity(501, 9))?.minX, 9)
    }

    func testReRememberingRefreshesRecencySoAnActiveWindowIsNotEvicted() {
        var memory = WindowFrameMemory(capacity: 3)
        let pinned = identity(501, 1)
        memory.remember(CGRect(x: 1, y: 0, width: 10, height: 10), for: pinned)
        memory.remember(CGRect(x: 2, y: 0, width: 10, height: 10), for: identity(501, 2))
        memory.remember(CGRect(x: 3, y: 0, width: 10, height: 10), for: identity(501, 3))
        // Touch the oldest entry, then push two more in: the touched one must survive.
        memory.remember(CGRect(x: 11, y: 0, width: 10, height: 10), for: pinned)
        memory.remember(CGRect(x: 4, y: 0, width: 10, height: 10), for: identity(501, 4))
        memory.remember(CGRect(x: 5, y: 0, width: 10, height: 10), for: identity(501, 5))

        XCTAssertEqual(memory.count, 3)
        XCTAssertEqual(memory.frame(for: pinned)?.minX, 11)
        XCTAssertNil(memory.frame(for: identity(501, 2)), "the genuinely oldest entry was evicted")
        XCTAssertNil(memory.frame(for: identity(501, 3)))
    }

    func testForgettingAnUnknownIdentityIsHarmless() {
        var memory = WindowFrameMemory(capacity: 2)
        memory.forget(identity(501, 1))
        XCTAssertEqual(memory.count, 0)
        memory.remember(CGRect(x: 1, y: 0, width: 10, height: 10), for: identity(501, 1))
        memory.forget(identity(501, 2))
        XCTAssertEqual(memory.count, 1)
    }

    func testCapacityIsNeverZeroSoAtLeastOneUndoAlwaysExists() {
        var memory = WindowFrameMemory(capacity: 0)
        memory.remember(CGRect(x: 1, y: 0, width: 10, height: 10), for: identity(501, 1))
        XCTAssertEqual(memory.count, 1)
    }

    /// A remembered frame from a display that has since been unplugged must be clamped onto a
    /// screen that still exists — the controller does exactly this before writing a restore.
    func testRestoringAFrameFromAnUnpluggedDisplayLandsOnScreen() {
        let stale = CGRect(x: 5000, y: 5000, width: 900, height: 700)
        XCTAssertNil(WindowManagerKit.areaIndex(forWindow: stale, in: [primary]), "the old display is gone")
        let rescued = WindowManagerKit.clamped(stale, into: primary)
        assertInside(rescued, primary, "restored frame from an unplugged display")
        XCTAssertEqual(rescued.size, stale.size, "the remembered size still fits, so it is kept")
    }

    // MARK: - Action wiring

    func testDisplayActionsAreNotAreaRelative() {
        XCTAssertFalse(WindowAction.nextDisplay.isAreaRelative)
        XCTAssertFalse(WindowAction.restorePrevious.isAreaRelative)
        XCTAssertTrue(WindowAction.leftHalf.isAreaRelative)
        XCTAssertTrue(WindowAction.maximize.isAreaRelative)
    }

    func testDisplayActionsCarryUiMetadataAndDefaultShortcuts() {
        for action in [WindowAction.nextDisplay, .restorePrevious] {
            XCTAssertFalse(action.title.isEmpty)
            XCTAssertFalse(action.symbol.isEmpty)
            let shortcut = action.defaultShortcut
            XCTAssertNotNil(shortcut, "\(action.rawValue) should ship with a binding like the other actions")
            XCTAssertTrue(shortcut?.isUsableGlobally == true, "\(action.rawValue) default must be safe to claim globally")
            XCTAssertFalse(shortcut?.displayString.contains("Key ") == true, "\(action.rawValue) shortcut lacks a glyph")
        }
        XCTAssertEqual(WindowAction.nextDisplay.defaultShortcut?.displayString, "⌃⌥⌘→")
        XCTAssertEqual(WindowAction.restorePrevious.defaultShortcut?.displayString, "⌃⌥⌫")
    }

    func testDisplayActionShortcutsDoNotCollideWithTheSnapDefaults() {
        // ⌃⌥→ is already Right Half; the display move escalates to ⌃⌥⌘→ rather than stealing it.
        XCTAssertNotEqual(WindowAction.nextDisplay.defaultShortcut, WindowAction.rightHalf.defaultShortcut)
        var seen = Set<WindowShortcut>()
        for action in WindowAction.allCases {
            guard let shortcut = action.defaultShortcut else { continue }
            XCTAssertTrue(seen.insert(shortcut).inserted, "\(action.rawValue) duplicates another default")
        }
    }

    func testDisplayActionsRoundTripThroughTheShortcutStore() {
        // They must be bindable exactly like the snaps: same persistence, same rawValue keying.
        let suite = "test.windowmanager.displayactions.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("could not create a scratch defaults suite")
        }
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        let store = WindowShortcutStore(defaults: defaults)
        XCTAssertEqual(store.effectiveShortcuts()[.nextDisplay], WindowAction.nextDisplay.defaultShortcut)
        XCTAssertEqual(store.effectiveShortcuts()[.restorePrevious], WindowAction.restorePrevious.defaultShortcut)

        let custom = WindowShortcut(keyCode: 105, modifiers: 0) // bare F13
        store.save(custom, for: .nextDisplay)
        XCTAssertEqual(store.effectiveShortcuts()[.nextDisplay], custom)
        XCTAssertEqual(store.storedShortcuts()[.nextDisplay], custom)
        store.reset()
        XCTAssertEqual(store.effectiveShortcuts()[.nextDisplay], WindowAction.nextDisplay.defaultShortcut)
    }

    @MainActor
    func testControllerBindsTheDisplayActionsLikeAnyOther() {
        let suite = "test.windowmanager.displaycontroller.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("could not create a scratch defaults suite")
        }
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        let controller = WindowManagerController(defaults: defaults)
        defer { controller.unregisterHotKeys() }

        XCTAssertEqual(controller.shortcut(for: .nextDisplay), WindowAction.nextDisplay.defaultShortcut)
        XCTAssertEqual(controller.shortcut(for: .restorePrevious), WindowAction.restorePrevious.defaultShortcut)

        // Duplicate prevention covers them too.
        guard let leftHalf = WindowAction.leftHalf.defaultShortcut else {
            return XCTFail("left half should have a default")
        }
        XCTAssertEqual(controller.assignShortcut(leftHalf, to: .nextDisplay), .conflict(.leftHalf))

        let custom = WindowShortcut(keyCode: 0x2D, modifiers: HotKeyModifier.controlOptionCommand) // ⌃⌥⌘N
        XCTAssertEqual(controller.assignShortcut(custom, to: .nextDisplay), .assigned)
        XCTAssertEqual(controller.shortcut(for: .nextDisplay), custom)
    }

    /// Without Accessibility the display actions must refuse in the same way the snaps do, rather
    /// than reporting a bogus success. The grant is a system state we cannot fake, so this asserts
    /// whichever branch the test machine is actually in.
    @MainActor
    func testDisplayActionsHonourTheAccessibilityGate() {
        let suite = "test.windowmanager.displaypermission.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("could not create a scratch defaults suite")
        }
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        let controller = WindowManagerController(defaults: defaults)
        defer { controller.unregisterHotKeys() }

        let result = controller.apply(.restorePrevious)
        if AXIsProcessTrusted() {
            XCTAssertNotEqual(result, .needsPermission, "trusted process should get past the gate")
        } else {
            XCTAssertEqual(result, .needsPermission)
            XCTAssertFalse(controller.hasAccessibility)
        }
    }
}
