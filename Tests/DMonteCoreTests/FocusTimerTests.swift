import XCTest
@testable import DMonteCore

@MainActor
final class FocusTimerTests: XCTestCase {
    /// Isolated defaults so the controller's persistence didSets and duration
    /// reads never touch (or depend on) the real standard defaults.
    private func makeController(
        focus: Int = 25,
        shortBreak: Int = 5,
        longBreak: Int = 15,
        sessions: Int = 4
    ) -> FocusTimerController {
        let suite = UserDefaults(suiteName: "FocusTimerTests-\(UUID().uuidString)")!
        suite.set(focus, forKey: DefaultsKey.focusTimerFocusMinutes)
        suite.set(shortBreak, forKey: DefaultsKey.focusTimerShortBreakMinutes)
        suite.set(longBreak, forKey: DefaultsKey.focusTimerLongBreakMinutes)
        suite.set(sessions, forKey: DefaultsKey.focusTimerSessionsBeforeLongBreak)
        return FocusTimerController(defaults: suite)
    }

    func testDefaultsWhenUnregistered() {
        let suite = UserDefaults(suiteName: "FocusTimerTests-empty-\(UUID().uuidString)")!
        let controller = FocusTimerController(defaults: suite)
        XCTAssertEqual(controller.focusMinutes, 25)
        XCTAssertEqual(controller.shortBreakMinutes, 5)
        XCTAssertEqual(controller.longBreakMinutes, 15)
        XCTAssertEqual(controller.sessionsBeforeLongBreak, 4)
    }

    func testInitialState() {
        let controller = makeController()
        XCTAssertEqual(controller.phase, .focus)
        XCTAssertFalse(controller.isRunning)
        XCTAssertEqual(controller.completedFocusCount, 0)
        XCTAssertEqual(controller.remaining, 25 * 60)
    }

    func testFocusCompletionAdvancesToBreak() {
        let controller = makeController(focus: 25, shortBreak: 5)
        controller.start()
        XCTAssertTrue(controller.isRunning)

        controller.tick(by: 25 * 60)

        XCTAssertEqual(controller.phase, .shortBreak)
        XCTAssertEqual(controller.remaining, 5 * 60)
        XCTAssertEqual(controller.completedFocusCount, 1)
        XCTAssertTrue(controller.isRunning)
    }

    func testCountdownDecrements() {
        let controller = makeController(focus: 25)
        controller.start()
        controller.tick(by: 60)
        XCTAssertEqual(controller.remaining, 24 * 60)
        XCTAssertEqual(controller.phase, .focus)
    }

    func testLongBreakAfterConfiguredSessions() {
        let sessions = 4
        let controller = makeController(focus: 25, shortBreak: 5, longBreak: 15, sessions: sessions)
        controller.start()

        for session in 1...sessions {
            // Complete a focus phase.
            controller.tick(by: TimeInterval(controller.focusMinutes * 60))
            XCTAssertEqual(controller.completedFocusCount, session)
            if session == sessions {
                XCTAssertEqual(controller.phase, .longBreak, "Session \(session) should yield a long break")
                XCTAssertEqual(controller.remaining, TimeInterval(controller.longBreakMinutes * 60))
            } else {
                XCTAssertEqual(controller.phase, .shortBreak, "Session \(session) should yield a short break")
            }
            // Complete the break to get back to a focus phase.
            controller.tick(by: controller.remaining)
            XCTAssertEqual(controller.phase, .focus)
        }
    }

    func testPauseStopsCountdown() {
        let controller = makeController(focus: 25)
        controller.start()
        controller.tick(by: 60)
        let snapshot = controller.remaining
        controller.pause()
        XCTAssertFalse(controller.isRunning)
        controller.tick(by: 120)
        XCTAssertEqual(controller.remaining, snapshot, "tick() must not decrement while paused")
    }

    func testResetReturnsToFocus() {
        let controller = makeController(focus: 25)
        controller.start()
        controller.tick(by: 10 * 60) // partway into focus
        controller.tick(by: 25 * 60) // force into a break + increment count
        XCTAssertNotEqual(controller.phase, .focus)

        controller.reset()
        XCTAssertEqual(controller.phase, .focus)
        XCTAssertEqual(controller.remaining, 25 * 60)
        XCTAssertEqual(controller.completedFocusCount, 0)
        XCTAssertFalse(controller.isRunning)
    }

    func testSkipAdvancesWithoutCompletionCount() {
        let controller = makeController(focus: 25, shortBreak: 5)
        controller.start()
        controller.skip()
        XCTAssertEqual(controller.phase, .shortBreak)
        XCTAssertEqual(controller.remaining, 5 * 60)
        XCTAssertEqual(controller.completedFocusCount, 0, "Skip should not count as a completed focus session")
    }

    func testTickBeforeStartDoesNothing() {
        let controller = makeController(focus: 25)
        controller.tick(by: 60)
        XCTAssertEqual(controller.remaining, 25 * 60)
        XCTAssertFalse(controller.isRunning)
    }
}
