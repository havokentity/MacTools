import XCTest
@testable import DMonteCore

/// Deterministic tests for the Focus Timer state machine. All time advancement goes through
/// `tick(by:)`, so there are no real sleeps. Each controller is built against an isolated
/// `UserDefaults` suite, so the tests never touch real app defaults.
@MainActor
final class FocusTimerTests: XCTestCase {
    private let focusMinutes = 25
    private let shortBreakMinutes = 5
    private let longBreakMinutes = 15
    private let longBreakInterval = 4

    private func makeController() -> FocusTimerController {
        let suite = UserDefaults(suiteName: "FocusTimerTests-\(UUID().uuidString)")!
        suite.set(focusMinutes, forKey: DefaultsKey.focusTimerFocusMinutes)
        suite.set(shortBreakMinutes, forKey: DefaultsKey.focusTimerShortBreakMinutes)
        suite.set(longBreakMinutes, forKey: DefaultsKey.focusTimerLongBreakMinutes)
        suite.set(longBreakInterval, forKey: DefaultsKey.focusTimerLongBreakInterval)
        return FocusTimerController(defaults: suite)
    }

    private var focusSeconds: TimeInterval { TimeInterval(focusMinutes * 60) }
    private var shortBreakSeconds: TimeInterval { TimeInterval(shortBreakMinutes * 60) }
    private var longBreakSeconds: TimeInterval { TimeInterval(longBreakMinutes * 60) }

    func testInitialStateIsFullFocus() {
        let controller = makeController()
        XCTAssertEqual(controller.phase, .focus)
        XCTAssertEqual(controller.remaining, focusSeconds, accuracy: 0.001)
        XCTAssertFalse(controller.isRunning)
        XCTAssertEqual(controller.completedFocusCount, 0)
    }

    func testFocusElapsesIntoShortBreakWithRemainingReset() {
        let controller = makeController()
        controller.start()
        XCTAssertTrue(controller.isRunning)
        controller.tick(by: focusSeconds)
        XCTAssertEqual(controller.phase, .shortBreak)
        XCTAssertEqual(controller.remaining, shortBreakSeconds, accuracy: 0.001)
        XCTAssertEqual(controller.completedFocusCount, 1)
        XCTAssertTrue(controller.isRunning)
    }

    func testNthFocusReachesLongBreak() {
        let controller = makeController()
        controller.start()
        for index in 1...longBreakInterval {
            controller.tick(by: focusSeconds)
            if index < longBreakInterval {
                XCTAssertEqual(controller.phase, .shortBreak, "Cycle \(index) should be a short break")
                controller.tick(by: shortBreakSeconds)
                XCTAssertEqual(controller.phase, .focus)
            } else {
                XCTAssertEqual(controller.phase, .longBreak, "The Nth focus should lead to a long break")
                XCTAssertEqual(controller.remaining, longBreakSeconds, accuracy: 0.001)
            }
        }
        XCTAssertEqual(controller.completedFocusCount, longBreakInterval)
        controller.tick(by: longBreakSeconds)
        XCTAssertEqual(controller.phase, .focus)
        controller.tick(by: focusSeconds)
        XCTAssertEqual(controller.phase, .shortBreak)
    }

    func testPausePreventsTicking() {
        let controller = makeController()
        controller.start()
        controller.tick(by: 60)
        let afterOneMinute = controller.remaining
        XCTAssertEqual(afterOneMinute, focusSeconds - 60, accuracy: 0.001)
        controller.pause()
        XCTAssertFalse(controller.isRunning)
        controller.tick(by: 120)
        XCTAssertEqual(controller.remaining, afterOneMinute, accuracy: 0.001)
        XCTAssertEqual(controller.phase, .focus)
    }

    func testResetReturnsToInitialFocusState() {
        let controller = makeController()
        controller.start()
        controller.tick(by: focusSeconds)
        controller.tick(by: shortBreakSeconds)
        controller.tick(by: 30)
        XCTAssertGreaterThan(controller.completedFocusCount, 0)
        controller.reset()
        XCTAssertEqual(controller.phase, .focus)
        XCTAssertEqual(controller.remaining, focusSeconds, accuracy: 0.001)
        XCTAssertFalse(controller.isRunning)
        XCTAssertEqual(controller.completedFocusCount, 0)
    }

    func testResumeAfterPauseDoesNotRefill() {
        let controller = makeController()
        controller.start()
        controller.tick(by: focusSeconds)
        controller.pause()
        let before = controller.remaining
        controller.start()
        XCTAssertEqual(controller.remaining, before, accuracy: 0.001)
        XCTAssertTrue(controller.isRunning)
    }

    func testSkipAdvancesToNextPhase() {
        let controller = makeController()
        // Skipping the focus phase advances to a break with its remaining reset.
        controller.skip()
        XCTAssertEqual(controller.phase, .shortBreak)
        XCTAssertEqual(controller.remaining, shortBreakSeconds, accuracy: 0.001)
        // Skipping the break returns to focus at full duration.
        controller.skip()
        XCTAssertEqual(controller.phase, .focus)
        XCTAssertEqual(controller.remaining, focusSeconds, accuracy: 0.001)
    }
}
