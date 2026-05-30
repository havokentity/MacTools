import XCTest
import CoreAudio
@testable import DMonteCore

/// Environment-tolerant tests for the spec-facing `AudioSwitcherKit`. CoreAudio
/// depends on real hardware, so CI / headless machines may expose zero devices.
/// These assert structural correctness rather than the presence of any specific
/// device, and never call a `setDefault*` (which would change the user's audio).
/// Mirrors the DevToolsTests style: robust, non-flaky, no side effects.
final class AudioSwitcherKitTests: XCTestCase {

    func testDevicesReturnsArrayWithoutCrashing() {
        // Must simply return without crashing; count is environment-dependent.
        let devices = AudioSwitcherKit.devices()
        XCTAssertGreaterThanOrEqual(devices.count, 0)
    }

    func testEveryDeviceHasANonEmptyName() {
        for device in AudioSwitcherKit.devices() {
            XCTAssertFalse(
                device.name.isEmpty,
                "Enumerated devices should always have a non-empty name"
            )
        }
    }

    func testEveryDeviceExposesAtLeastOneDirection() {
        for device in AudioSwitcherKit.devices() {
            XCTAssertTrue(
                device.hasOutput || device.hasInput,
                "Device \(device.name) should expose at least one stream direction"
            )
        }
    }

    func testDefaultOutputIDIsListedWhenPresent() {
        guard let defaultID = AudioSwitcherKit.defaultOutputID() else {
            // No default output on this machine (valid in headless/CI).
            return
        }
        let ids = AudioSwitcherKit.devices().map(\.id)
        XCTAssertTrue(
            ids.contains(defaultID),
            "Default output id should appear among the enumerated device ids"
        )
    }

    func testDefaultInputIDIsListedWhenPresent() {
        guard let defaultID = AudioSwitcherKit.defaultInputID() else {
            return
        }
        let ids = AudioSwitcherKit.devices().map(\.id)
        XCTAssertTrue(
            ids.contains(defaultID),
            "Default input id should appear among the enumerated device ids"
        )
    }

    func testDefaultOutputIsAnOutputDeviceWhenPresent() {
        guard let defaultID = AudioSwitcherKit.defaultOutputID(),
              let device = AudioSwitcherKit.devices().first(where: { $0.id == defaultID }) else {
            return
        }
        XCTAssertTrue(device.hasOutput, "The default output device should expose output streams")
    }

    func testAudioDeviceEquatableAndIdentifiable() {
        let a = AudioDevice(id: 42, name: "Speakers", uid: "uid-42", hasOutput: true, hasInput: false)
        let b = AudioDevice(id: 42, name: "Speakers", uid: "uid-42", hasOutput: true, hasInput: false)
        let c = AudioDevice(id: 99, name: "Mic", uid: "uid-99", hasOutput: false, hasInput: true)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(a.id, AudioDeviceID(42))
    }
}
