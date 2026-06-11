import XCTest
import CoreAudio
@testable import DMonteCore

/// Environment-tolerant tests for the Audio Router. The CoreAudio-touching paths
/// (enumeration, create, destroy) may see zero hardware on headless / CI
/// machines, so those assert structural correctness without requiring a device
/// and never leave a router device behind. The description-building and preset
/// logic is pure and is asserted exactly.
final class AudioRouterKitTests: XCTestCase {

    // MARK: - Enumeration (best-effort, no side effects)

    func testRouterDevicesReturnsWithoutCrashing() {
        XCTAssertGreaterThanOrEqual(AudioRouterKit.routerDevices().count, 0)
    }

    func testLoopbackDetectionReturnsWithoutCrashing() {
        // Result is environment-dependent; it must simply not crash and stay
        // consistent with the device list.
        XCTAssertEqual(
            AudioRouterKit.isLoopbackDriverInstalled(),
            !AudioRouterKit.loopbackDevices().isEmpty
        )
    }

    func testRouterDevicesAllCarryOwnUIDPrefix() {
        for device in AudioRouterKit.routerDevices() {
            XCTAssertTrue(
                device.uid.hasPrefix(AudioRouterKit.uidPrefix),
                "routerDevices() must only surface devices this tool created"
            )
        }
    }

    func testAvailableSubDevicesExcludeOwnDevices() {
        let subUIDs = AudioRouterKit.availableSubDevices(matching: .multiOutput).map(\.uid)
        for uid in subUIDs {
            XCTAssertFalse(
                uid.hasPrefix(AudioRouterKit.uidPrefix),
                "A router must not be offered itself as a sub-device"
            )
        }
    }

    func testAvailableSubDevicesForMultiOutputAreOutputCapable() {
        for device in AudioRouterKit.availableSubDevices(matching: .multiOutput) {
            XCTAssertTrue(device.hasOutput, "Multi-output sub-devices must expose output")
        }
    }

    // MARK: - UID generation

    func testMakeUIDIsPrefixedAndUnique() {
        let a = AudioRouterKit.makeUID()
        let b = AudioRouterKit.makeUID()
        XCTAssertTrue(a.hasPrefix(AudioRouterKit.uidPrefix))
        XCTAssertTrue(b.hasPrefix(AudioRouterKit.uidPrefix))
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Description building (pure)

    func testMultiOutputDescriptionIsStacked() {
        let spec = AudioRouterKit.RouterDeviceSpec(
            name: "Mirror",
            uid: "uid-mirror",
            mode: .multiOutput,
            subDeviceUIDs: ["A", "B"]
        )
        let description = AudioRouterKit.aggregateDescription(for: spec)
        XCTAssertEqual(description[kAudioAggregateDeviceNameKey] as? String, "Mirror")
        XCTAssertEqual(description[kAudioAggregateDeviceUIDKey] as? String, "uid-mirror")
        XCTAssertEqual(description[kAudioAggregateDeviceIsStackedKey] as? Bool, true)
        XCTAssertEqual(description[kAudioAggregateDeviceIsPrivateKey] as? Bool, false)
    }

    func testAggregateDescriptionIsNotStacked() {
        let spec = AudioRouterKit.RouterDeviceSpec(
            name: "Combine",
            uid: "uid-combine",
            mode: .aggregate,
            subDeviceUIDs: ["A", "B"]
        )
        let description = AudioRouterKit.aggregateDescription(for: spec)
        XCTAssertEqual(description[kAudioAggregateDeviceIsStackedKey] as? Bool, false)
    }

    func testDescriptionDefaultsClockMasterToFirstSubDevice() {
        let spec = AudioRouterKit.RouterDeviceSpec(
            name: "R",
            uid: "uid-r",
            mode: .multiOutput,
            subDeviceUIDs: ["first", "second"]
        )
        let description = AudioRouterKit.aggregateDescription(for: spec)
        XCTAssertEqual(description[kAudioAggregateDeviceMainSubDeviceKey] as? String, "first")
        XCTAssertEqual(description[kAudioAggregateDeviceClockDeviceKey] as? String, "first")
    }

    func testDescriptionHonoursExplicitClockMaster() {
        let spec = AudioRouterKit.RouterDeviceSpec(
            name: "R",
            uid: "uid-r",
            mode: .multiOutput,
            subDeviceUIDs: ["first", "second"],
            clockMasterUID: "second"
        )
        let description = AudioRouterKit.aggregateDescription(for: spec)
        XCTAssertEqual(description[kAudioAggregateDeviceMainSubDeviceKey] as? String, "second")
    }

    func testDescriptionDriftCompensatesEverySubDeviceExceptMaster() throws {
        let spec = AudioRouterKit.RouterDeviceSpec(
            name: "R",
            uid: "uid-r",
            mode: .multiOutput,
            subDeviceUIDs: ["master", "slave1", "slave2"],
            clockMasterUID: "master"
        )
        let description = AudioRouterKit.aggregateDescription(for: spec)
        let subList = try XCTUnwrap(
            description[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]]
        )
        XCTAssertEqual(subList.count, 3)
        for entry in subList {
            let uid = try XCTUnwrap(entry[kAudioSubDeviceUIDKey] as? String)
            let drift = try XCTUnwrap(entry[kAudioSubDeviceDriftCompensationKey] as? Bool)
            XCTAssertEqual(drift, uid != "master", "Only the clock master should skip drift compensation")
        }
    }

    // MARK: - Create validation (no hardware required)

    func testCreateRejectsEmptyName() {
        let spec = AudioRouterKit.RouterDeviceSpec(
            name: "   ",
            uid: "uid",
            mode: .aggregate,
            subDeviceUIDs: ["A"]
        )
        XCTAssertEqual(AudioRouterKit.createDevice(spec), .failure(.emptyName))
    }

    func testCreateRejectsNoSubDevices() {
        let spec = AudioRouterKit.RouterDeviceSpec(
            name: "Router",
            uid: "uid",
            mode: .aggregate,
            subDeviceUIDs: []
        )
        XCTAssertEqual(AudioRouterKit.createDevice(spec), .failure(.noSubDevices))
    }

    func testDestroyUnknownUIDReturnsFalse() {
        XCTAssertFalse(AudioRouterKit.destroyDevice(uid: "com.havokentity.mactools.audiorouter.does-not-exist"))
    }

    // MARK: - Presets

    private func makeSuite() -> (UserDefaults, String) {
        let name = "AudioRouterTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    func testPresetStoreRoundTrips() {
        let (suite, name) = makeSuite()
        defer { suite.removePersistentDomain(forName: name) }

        let preset = RouterPreset(
            name: "Streaming",
            mode: .multiOutput,
            subDeviceUIDs: ["speakers", "blackhole"],
            clockMasterUID: "speakers"
        )
        RouterPresetStore.upsert(preset, defaults: suite)

        let loaded = RouterPresetStore.load(defaults: suite)
        XCTAssertEqual(loaded, [preset])
    }

    func testPresetUpsertReplacesSameID() {
        let (suite, name) = makeSuite()
        defer { suite.removePersistentDomain(forName: name) }

        var preset = RouterPreset(name: "A", mode: .aggregate, subDeviceUIDs: ["x"])
        RouterPresetStore.upsert(preset, defaults: suite)
        preset.name = "A renamed"
        RouterPresetStore.upsert(preset, defaults: suite)

        let loaded = RouterPresetStore.load(defaults: suite)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "A renamed")
    }

    func testPresetRemove() {
        let (suite, name) = makeSuite()
        defer { suite.removePersistentDomain(forName: name) }

        let keep = RouterPreset(name: "Keep", mode: .aggregate, subDeviceUIDs: ["x"])
        let drop = RouterPreset(name: "Drop", mode: .aggregate, subDeviceUIDs: ["y"])
        RouterPresetStore.upsert(keep, defaults: suite)
        RouterPresetStore.upsert(drop, defaults: suite)

        RouterPresetStore.remove(id: drop.id, defaults: suite)

        let loaded = RouterPresetStore.load(defaults: suite)
        XCTAssertEqual(loaded, [keep])
    }

    func testPresetMakeSpecMintsFreshPrefixedUID() {
        let preset = RouterPreset(name: "P", mode: .multiOutput, subDeviceUIDs: ["a", "b"])
        let spec1 = preset.makeSpec()
        let spec2 = preset.makeSpec()
        XCTAssertTrue(spec1.uid.hasPrefix(AudioRouterKit.uidPrefix))
        XCTAssertNotEqual(spec1.uid, spec2.uid, "Each application should mint a unique device UID")
        XCTAssertEqual(spec1.name, "P")
        XCTAssertEqual(spec1.subDeviceUIDs, ["a", "b"])
    }

    func testLoadCorruptDataYieldsEmpty() {
        let (suite, name) = makeSuite()
        defer { suite.removePersistentDomain(forName: name) }
        suite.set(Data([0x00, 0x01, 0x02]), forKey: DefaultsKey.audioRouterPresets)
        XCTAssertEqual(RouterPresetStore.load(defaults: suite), [])
    }
}
