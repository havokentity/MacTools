import XCTest
@testable import DMonteCore

@MainActor
final class KeepAwakeTests: XCTestCase {
    private var controller: KeepAwakeController!

    override func setUp() async throws {
        try await super.setUp()
        controller = KeepAwakeController()
        // Ensure we start from a clean, inactive state.
        controller.deactivate()
    }

    override func tearDown() async throws {
        controller.deactivate()
        controller = nil
        try await super.tearDown()
    }

    func testInitialStateIsInactive() {
        XCTAssertFalse(controller.isActive)
        XCTAssertNil(controller.remaining)
    }

    func testActivateWithDurationSetsActiveAndRemaining() {
        controller.activate(duration: 3600)

        XCTAssertTrue(controller.isActive)
        let remaining = try? XCTUnwrap(controller.remaining)
        XCTAssertNotNil(remaining)
        if let remaining {
            // Allow a small tolerance for the time elapsed between activation and assertion.
            XCTAssertEqual(remaining, 3600, accuracy: 2.0)
        }
    }

    func testActivateIndefinitelyHasNoRemaining() {
        controller.activate(duration: nil)

        XCTAssertTrue(controller.isActive)
        XCTAssertNil(controller.remaining)
    }

    func testDeactivateClearsState() {
        controller.activate(duration: 3600)
        XCTAssertTrue(controller.isActive)

        controller.deactivate()

        XCTAssertFalse(controller.isActive)
        XCTAssertNil(controller.remaining)
    }

    func testToggleFlipsActiveState() {
        XCTAssertFalse(controller.isActive)

        controller.toggle()
        XCTAssertTrue(controller.isActive)
        XCTAssertNil(controller.remaining, "Toggle activates indefinitely")

        controller.toggle()
        XCTAssertFalse(controller.isActive)
    }

    func testSetKeepDisplayOnUpdatesPublishedValue() {
        let initial = controller.keepDisplayOn

        controller.setKeepDisplayOn(!initial)
        XCTAssertEqual(controller.keepDisplayOn, !initial)

        controller.setKeepDisplayOn(initial)
        XCTAssertEqual(controller.keepDisplayOn, initial)
    }

    func testSetKeepDisplayOnWhileActiveKeepsSessionActive() {
        controller.activate(duration: 3600)
        XCTAssertTrue(controller.isActive)

        controller.setKeepDisplayOn(!controller.keepDisplayOn)

        // Recreating the assertion must not drop the active session or its countdown.
        XCTAssertTrue(controller.isActive)
        XCTAssertNotNil(controller.remaining)
    }

    func testNonPositiveDurationIsTreatedAsIndefinite() {
        controller.activate(duration: 0)

        XCTAssertTrue(controller.isActive)
        XCTAssertNil(controller.remaining)
    }
}
