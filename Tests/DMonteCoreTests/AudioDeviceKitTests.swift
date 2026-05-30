import XCTest
import CoreAudio
@testable import DMonteCore

/// Environment-tolerant tests for the CoreAudio wrapper. CI / headless machines
/// may expose zero audio devices, so these assert structural correctness rather
/// than the presence of any specific device.
final class AudioDeviceKitTests: XCTestCase {

    func testAllDevicesReturnsArrayWithoutCrashing() {
        let devices = AudioDeviceKit.allDevices()
        // Count is environment-dependent; it must simply be non-negative.
        XCTAssertGreaterThanOrEqual(devices.count, 0)
    }

    func testEveryDeviceHasOutputOrInput() {
        for device in AudioDeviceKit.allDevices() {
            XCTAssertTrue(
                device.hasOutput || device.hasInput,
                "Device \(device.name) should expose at least one stream direction"
            )
        }
    }

    func testOutputAndInputSubsetsMatchFlags() {
        let all = AudioDeviceKit.allDevices()
        XCTAssertEqual(AudioDeviceKit.outputDevices(), all.filter { $0.hasOutput })
        XCTAssertEqual(AudioDeviceKit.inputDevices(), all.filter { $0.hasInput })
    }

    func testDefaultOutputIsListedWhenPresent() {
        guard let defaultID = AudioDeviceKit.defaultOutputDeviceID() else {
            // No default output on this machine (valid in headless/CI).
            return
        }
        let all = AudioDeviceKit.allDevices()
        XCTAssertTrue(
            all.contains { $0.id == defaultID },
            "Default output device should appear in the enumerated list"
        )
    }

    func testDefaultInputIsListedWhenPresent() {
        guard let defaultID = AudioDeviceKit.defaultInputDeviceID() else {
            return
        }
        let all = AudioDeviceKit.allDevices()
        XCTAssertTrue(
            all.contains { $0.id == defaultID },
            "Default input device should appear in the enumerated list"
        )
    }

    func testVolumeForDefaultOutputIsNilOrNormalized() {
        guard let defaultID = AudioDeviceKit.defaultOutputDeviceID() else {
            return
        }
        if let volume = AudioDeviceKit.volume(for: defaultID) {
            XCTAssertGreaterThanOrEqual(volume, 0)
            XCTAssertLessThanOrEqual(volume, 1)
        }
        // nil is acceptable: some devices expose no readable volume control.
    }

    func testIsMutedForDefaultOutputIsBoolOrNil() {
        guard let defaultID = AudioDeviceKit.defaultOutputDeviceID() else {
            return
        }
        // Just ensure the call does not crash; nil or a Bool are both valid.
        _ = AudioDeviceKit.isMuted(defaultID)
    }

    func testAudioDeviceEquatable() {
        let a = AudioDeviceKit.AudioDevice(id: 42, name: "Speakers", hasOutput: true, hasInput: false)
        let b = AudioDeviceKit.AudioDevice(id: 42, name: "Speakers", hasOutput: true, hasInput: false)
        let c = AudioDeviceKit.AudioDevice(id: 99, name: "Mic", hasOutput: false, hasInput: true)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testAudioDeviceIdentifiableUsesDeviceID() {
        let device = AudioDeviceKit.AudioDevice(id: 7, name: "Headphones", hasOutput: true, hasInput: false)
        XCTAssertEqual(device.id, AudioDeviceID(7))
    }
}
