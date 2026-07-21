import CoreAudio
import XCTest
@testable import DMonteCore

/// Pure tests for the Audio Switcher's device profiles. Nothing here touches CoreAudio:
/// capture, resolution, and persistence all operate on a supplied device list and a
/// throwaway `UserDefaults` suite, so the whole feature is exercised headlessly and the
/// user's real audio configuration is never read or written.
final class AudioSwitcherProfilesTests: XCTestCase {

    // MARK: - Fixtures

    private func device(
        id: AudioDeviceID,
        name: String,
        uid: String,
        hasOutput: Bool = false,
        hasInput: Bool = false
    ) -> AudioDevice {
        AudioDevice(id: id, name: name, uid: uid, hasOutput: hasOutput, hasInput: hasInput)
    }

    /// A throwaway defaults suite, torn down after the test so nothing leaks into the
    /// shared suite the shipping app reads.
    private func makeDefaults() -> UserDefaults {
        let suiteName = "AudioSwitcherProfilesTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Could not create a test defaults suite")
        }
        addTeardownBlock { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    // MARK: - Capture

    func testCapturePinsUIDsRatherThanDeviceIDs() throws {
        let devices = [
            device(id: 41, name: "Studio Display", uid: "AppleDisplay:5F2A", hasOutput: true),
            device(id: 42, name: "Shure MV7", uid: "USB:MV7-8891", hasInput: true)
        ]

        let profile = try XCTUnwrap(
            AudioDeviceProfile.capture(
                name: "Desk",
                devices: devices,
                defaultOutputID: 41,
                defaultInputID: 42
            )
        )

        XCTAssertEqual(profile.name, "Desk")
        XCTAssertEqual(profile.output?.uid, "AppleDisplay:5F2A")
        XCTAssertEqual(profile.output?.name, "Studio Display")
        XCTAssertEqual(profile.input?.uid, "USB:MV7-8891")
        XCTAssertEqual(profile.input?.name, "Shure MV7")
    }

    func testCaptureTrimsTheNameAndRefusesABlankOne() {
        let devices = [device(id: 1, name: "Speakers", uid: "built-in", hasOutput: true)]

        XCTAssertEqual(
            AudioDeviceProfile.capture(name: "  Desk  ", devices: devices, defaultOutputID: 1, defaultInputID: nil)?.name,
            "Desk"
        )
        XCTAssertNil(
            AudioDeviceProfile.capture(name: "   ", devices: devices, defaultOutputID: 1, defaultInputID: nil)
        )
    }

    func testCaptureLeavesADirectionUnpinnedWhenThereIsNoDefaultForIt() throws {
        let devices = [device(id: 1, name: "Speakers", uid: "built-in", hasOutput: true)]

        let profile = try XCTUnwrap(
            AudioDeviceProfile.capture(name: "Speakers only", devices: devices, defaultOutputID: 1, defaultInputID: nil)
        )

        XCTAssertNotNil(profile.output)
        XCTAssertNil(profile.input, "A direction with no current default must stay unpinned")
    }

    func testCaptureRefusesWhenNoDefaultDeviceExposesAUID() {
        // Some virtual drivers publish no kAudioDevicePropertyDeviceUID at all. A leg
        // pinned to "" could later match any other UID-less device, so nothing is saved.
        let devices = [device(id: 7, name: "Nameless Virtual", uid: "", hasOutput: true, hasInput: true)]

        XCTAssertNil(
            AudioDeviceProfile.capture(name: "Broken", devices: devices, defaultOutputID: 7, defaultInputID: 7)
        )
    }

    func testCaptureRefusesWhenTheDefaultIsNotInTheDeviceList() {
        let devices = [device(id: 1, name: "Speakers", uid: "built-in", hasOutput: true)]

        XCTAssertNil(
            AudioDeviceProfile.capture(name: "Ghost", devices: devices, defaultOutputID: 99, defaultInputID: 99)
        )
    }

    // MARK: - Resolution

    func testResolutionFollowsTheUIDWhenDeviceIDsAreReassigned() throws {
        let atCaptureTime = [
            device(id: 41, name: "Studio Display", uid: "AppleDisplay:5F2A", hasOutput: true),
            device(id: 42, name: "Shure MV7", uid: "USB:MV7-8891", hasInput: true)
        ]
        let profile = try XCTUnwrap(
            AudioDeviceProfile.capture(name: "Desk", devices: atCaptureTime, defaultOutputID: 41, defaultInputID: 42)
        )

        // After a reboot the HAL hands out different ids, and 41 now belongs to an
        // entirely unrelated device. Matching by id would route audio to the AirPods.
        let afterReboot = [
            device(id: 41, name: "AirPods Pro", uid: "BT:AIRPODS-0001", hasOutput: true, hasInput: true),
            device(id: 88, name: "Studio Display", uid: "AppleDisplay:5F2A", hasOutput: true),
            device(id: 90, name: "Shure MV7", uid: "USB:MV7-8891", hasInput: true)
        ]

        let resolution = profile.resolve(against: afterReboot)

        XCTAssertTrue(resolution.isApplicable)
        XCTAssertEqual(resolution.outputDeviceID, 88)
        XCTAssertEqual(resolution.inputDeviceID, 90)
        XCTAssertNil(resolution.unavailableReason)
    }

    func testResolutionDistinguishesTwoDevicesSharingAName() throws {
        // Two identical USB headsets: same product name, different UIDs. Any
        // name-based fallback in resolution would pick whichever came first.
        let devices = [
            device(id: 10, name: "USB Audio Device", uid: "USB:SERIAL-AAA", hasOutput: true, hasInput: true),
            device(id: 11, name: "USB Audio Device", uid: "USB:SERIAL-BBB", hasOutput: true, hasInput: true)
        ]
        let profile = try XCTUnwrap(
            AudioDeviceProfile.capture(name: "Second headset", devices: devices, defaultOutputID: 11, defaultInputID: 11)
        )
        XCTAssertEqual(profile.output?.uid, "USB:SERIAL-BBB")

        let resolution = profile.resolve(against: devices)

        XCTAssertEqual(resolution.outputDeviceID, 11)
        XCTAssertEqual(resolution.inputDeviceID, 11)

        // And with the two swapped in the list, it still follows the UID.
        let reordered = [devices[1], devices[0]]
        XCTAssertEqual(profile.resolve(against: reordered).outputDeviceID, 11)
    }

    func testResolutionReportsAMissingDeviceByNameAndBlocksApplication() {
        let profile = AudioDeviceProfile(
            name: "Meeting",
            output: .init(uid: "BT:QC35-77", name: "Bose QC 35"),
            input: .init(uid: "USB:MV7-8891", name: "Shure MV7")
        )
        let devices = [device(id: 3, name: "Shure MV7", uid: "USB:MV7-8891", hasInput: true)]

        let resolution = profile.resolve(against: devices)

        XCTAssertFalse(resolution.isApplicable)
        XCTAssertNil(resolution.outputDeviceID, "An unresolved leg must not offer a device to switch to")
        XCTAssertEqual(resolution.inputDeviceID, 3)
        let reason = resolution.unavailableReason
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("Bose QC 35") == true, "Reason should name the missing device: \(reason ?? "nil")")
        XCTAssertTrue(reason?.contains("Output") == true, "Reason should say which direction is broken: \(reason ?? "nil")")
    }

    func testResolutionRejectsADeviceThatNoLongerServesTheDirection() {
        // The aggregate is still attached under the same UID but lost its output
        // sub-device; making it the default output would silently kill playback.
        let profile = AudioDeviceProfile(
            name: "Rig",
            output: .init(uid: "AGG:9001", name: "Studio Aggregate")
        )
        let devices = [device(id: 5, name: "Studio Aggregate", uid: "AGG:9001", hasOutput: false, hasInput: true)]

        let resolution = profile.resolve(against: devices)

        XCTAssertFalse(resolution.isApplicable)
        XCTAssertNil(resolution.outputDeviceID)
        XCTAssertEqual(resolution.unavailableReason, "Output “Studio Aggregate” has no output channels")
    }

    func testResolutionTreatsAnEmptyStoredUIDAsMissing() {
        // Only a corrupt or hand-edited blob can produce this, but "" must never match
        // a UID-less device that happens to be attached.
        let profile = AudioDeviceProfile(name: "Corrupt", output: .init(uid: "", name: "Ghost"))
        let devices = [device(id: 2, name: "Nameless Virtual", uid: "", hasOutput: true)]

        let resolution = profile.resolve(against: devices)

        XCTAssertFalse(resolution.isApplicable)
        XCTAssertNil(resolution.outputDeviceID)
    }

    func testResolutionReportsBothBrokenLegsAtOnce() {
        let profile = AudioDeviceProfile(
            name: "Headset",
            output: .init(uid: "BT:QC35-77", name: "Bose QC 35"),
            input: .init(uid: "BT:QC35-77-in", name: "Bose QC 35 Mic")
        )

        let reason = profile.resolve(against: []).unavailableReason

        XCTAssertTrue(reason?.contains("Bose QC 35”") == true, "Missing output should be named: \(reason ?? "nil")")
        XCTAssertTrue(reason?.contains("Bose QC 35 Mic") == true, "Missing input should be named: \(reason ?? "nil")")
    }

    func testAnUnpinnedDirectionDoesNotBlockApplication() {
        let profile = AudioDeviceProfile(name: "Speakers only", output: .init(uid: "built-in", name: "Speakers"))
        let devices = [device(id: 1, name: "Speakers", uid: "built-in", hasOutput: true)]

        let resolution = profile.resolve(against: devices)

        XCTAssertTrue(resolution.isApplicable)
        XCTAssertEqual(resolution.outputDeviceID, 1)
        XCTAssertNil(resolution.inputDeviceID, "An unpinned direction must be left alone, not switched")
        XCTAssertEqual(resolution.input, .unpinned)
    }

    func testDeviceSummaryPrefersTheLiveNameOverTheCapturedOne() {
        let profile = AudioDeviceProfile(
            name: "Desk",
            output: .init(uid: "AppleDisplay:5F2A", name: "Studio Display"),
            input: .init(uid: "USB:MV7-8891", name: "Shure MV7")
        )
        let devices = [
            device(id: 1, name: "Studio Display (Office)", uid: "AppleDisplay:5F2A", hasOutput: true),
            device(id: 2, name: "Shure MV7", uid: "USB:MV7-8891", hasInput: true)
        ]

        XCTAssertEqual(profile.resolve(against: devices).deviceSummary, "Studio Display (Office) · Shure MV7")
    }

    func testEmptyDeviceListLeavesEveryPinnedLegMissing() {
        let profile = AudioDeviceProfile(
            name: "Desk",
            output: .init(uid: "a", name: "A"),
            input: .init(uid: "b", name: "B")
        )

        let resolution = profile.resolve(against: [])

        XCTAssertEqual(resolution.output, .missing(name: "A"))
        XCTAssertEqual(resolution.input, .missing(name: "B"))
        XCTAssertFalse(resolution.isApplicable)
    }

    // MARK: - Active-profile matching

    func testMatchesDefaultsComparesUIDsOnly() {
        let profile = AudioDeviceProfile(
            name: "Second headset",
            output: .init(uid: "USB:SERIAL-BBB", name: "USB Audio Device"),
            input: .init(uid: "USB:SERIAL-BBB", name: "USB Audio Device")
        )

        XCTAssertTrue(profile.matchesDefaults(outputUID: "USB:SERIAL-BBB", inputUID: "USB:SERIAL-BBB"))
        // The identically-named twin must not count as a match.
        XCTAssertFalse(profile.matchesDefaults(outputUID: "USB:SERIAL-AAA", inputUID: "USB:SERIAL-AAA"))
        XCTAssertFalse(profile.matchesDefaults(outputUID: nil, inputUID: nil))
    }

    func testMatchesDefaultsIgnoresUnpinnedDirections() {
        let profile = AudioDeviceProfile(name: "Speakers only", output: .init(uid: "built-in", name: "Speakers"))

        XCTAssertTrue(profile.matchesDefaults(outputUID: "built-in", inputUID: "anything-at-all"))
        XCTAssertFalse(profile.matchesDefaults(outputUID: "somewhere-else", inputUID: nil))
    }

    // MARK: - Persistence

    func testEmptyProfileListLoadsAsEmptyAndMutatorsAreSafe() {
        let defaults = makeDefaults()

        XCTAssertEqual(AudioProfileStore.load(defaults: defaults), [])
        XCTAssertEqual(AudioProfileStore.remove(id: UUID(), defaults: defaults), [])
        XCTAssertEqual(AudioProfileStore.rename(id: UUID(), to: "Nope", defaults: defaults), [])
        XCTAssertEqual(AudioProfileStore.load(defaults: defaults), [])
    }

    func testProfilesRoundTripThroughDefaults() {
        let defaults = makeDefaults()
        let profiles = [
            AudioDeviceProfile(
                name: "Desk",
                output: .init(uid: "AppleDisplay:5F2A", name: "Studio Display"),
                input: .init(uid: "USB:MV7-8891", name: "Shure MV7")
            ),
            AudioDeviceProfile(name: "Speakers only", output: .init(uid: "built-in", name: "Speakers")),
            AudioDeviceProfile(name: "Mic only", input: .init(uid: "USB:MV7-8891", name: "Shure MV7"))
        ]

        AudioProfileStore.save(profiles, defaults: defaults)

        let loaded = AudioProfileStore.load(defaults: defaults)
        XCTAssertEqual(loaded, profiles, "Ids, names, and both device refs must survive the round trip")
        XCTAssertNil(loaded[2].output, "An unpinned direction must decode back as unpinned, not as an empty UID")
    }

    func testProfileRoundTripsThroughJSONDirectly() throws {
        let profile = AudioDeviceProfile(
            name: "Meeting",
            output: .init(uid: "BT:QC35-77", name: "Bose QC 35"),
            input: .init(uid: "BT:QC35-77-in", name: "Bose QC 35 Mic")
        )

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(AudioDeviceProfile.self, from: data)

        XCTAssertEqual(decoded, profile)
        XCTAssertEqual(decoded.id, profile.id, "The id is the identity used for rename/delete and must persist")
    }

    func testUpsertAppendsThenReplacesInPlace() {
        let defaults = makeDefaults()
        let first = AudioDeviceProfile(name: "Desk", output: .init(uid: "a", name: "A"))
        let second = AudioDeviceProfile(name: "Meeting", output: .init(uid: "b", name: "B"))

        AudioProfileStore.upsert(first, defaults: defaults)
        AudioProfileStore.upsert(second, defaults: defaults)

        var edited = first
        edited.output = .init(uid: "c", name: "C")
        let result = AudioProfileStore.upsert(edited, defaults: defaults)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.map(\.id), [first.id, second.id], "An edit must not reorder the list")
        XCTAssertEqual(result[0].output?.uid, "c")
        XCTAssertEqual(AudioProfileStore.load(defaults: defaults), result)
    }

    func testRenameTrimsWhitespaceAndRefusesABlankName() {
        let defaults = makeDefaults()
        let profile = AudioDeviceProfile(name: "Desk", output: .init(uid: "a", name: "A"))
        AudioProfileStore.upsert(profile, defaults: defaults)

        XCTAssertEqual(AudioProfileStore.rename(id: profile.id, to: "  Studio  ", defaults: defaults).first?.name, "Studio")
        XCTAssertEqual(AudioProfileStore.rename(id: profile.id, to: "   ", defaults: defaults).first?.name, "Studio")
        XCTAssertEqual(AudioProfileStore.load(defaults: defaults).first?.name, "Studio")
    }

    func testRenamingAnUnknownIDChangesNothing() {
        let defaults = makeDefaults()
        let profile = AudioDeviceProfile(name: "Desk", output: .init(uid: "a", name: "A"))
        AudioProfileStore.upsert(profile, defaults: defaults)

        XCTAssertEqual(AudioProfileStore.rename(id: UUID(), to: "Other", defaults: defaults), [profile])
    }

    func testRemoveDeletesOnlyTheNamedProfile() {
        let defaults = makeDefaults()
        let keep = AudioDeviceProfile(name: "Desk", output: .init(uid: "a", name: "A"))
        let drop = AudioDeviceProfile(name: "Meeting", output: .init(uid: "b", name: "B"))
        AudioProfileStore.save([keep, drop], defaults: defaults)

        let remaining = AudioProfileStore.remove(id: drop.id, defaults: defaults)

        XCTAssertEqual(remaining, [keep])
        XCTAssertEqual(AudioProfileStore.load(defaults: defaults), [keep])
    }

    func testCorruptStoredBlobLoadsAsNoProfiles() {
        let defaults = makeDefaults()
        defaults.set(Data("not json".utf8), forKey: DefaultsKey.audioSwitcherProfiles)

        XCTAssertEqual(
            AudioProfileStore.load(defaults: defaults), [],
            "A corrupt blob must read as 'no profiles' rather than crash a menu-bar helper at launch"
        )
    }
}
