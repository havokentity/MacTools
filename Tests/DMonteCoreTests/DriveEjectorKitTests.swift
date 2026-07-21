import XCTest
@testable import DMonteCore

/// The eject-safety rule is the entire reason this tool exists: unmounting someone's system disk
/// is not a bug you apologise for. These tests drive `DriveEjectorKit` with synthetic volume
/// descriptors covering every combination of the resource keys macOS vends — including the ones
/// it declines to vend — and assert exactly which volumes are offered.
///
/// Everything here is headless-safe: no hardware, no mounts, no network. The two tests that touch
/// the real filesystem only ever ask about "/" and a nonexistent path, both of which the rule
/// rejects *before* any unmount is attempted.
final class DriveEjectorKitTests: XCTestCase {

    // MARK: - Fixtures

    /// Builds a descriptor with the flags spelled out. Defaults are the fully-unknown case so a
    /// test that omits a flag is exercising the "macOS wouldn't say" branch on purpose.
    private func descriptor(
        path: String,
        name: String,
        isRootFileSystem: Bool? = nil,
        isInternal: Bool? = nil,
        isRemovable: Bool? = nil,
        isEjectable: Bool? = nil,
        isLocal: Bool? = true,
        totalBytes: UInt64 = 500_000_000_000,
        freeBytes: UInt64 = 250_000_000_000
    ) -> VolumeDescriptor {
        VolumeDescriptor(
            url: URL(fileURLWithPath: path),
            name: name,
            isRootFileSystem: isRootFileSystem,
            isInternal: isInternal,
            isRemovable: isRemovable,
            isEjectable: isEjectable,
            isLocal: isLocal,
            totalBytes: totalBytes,
            freeBytes: freeBytes
        )
    }

    /// The startup disk of a normally-configured Mac.
    private var bootVolume: VolumeDescriptor {
        descriptor(path: "/", name: "Macintosh HD", isRootFileSystem: true, isInternal: true, isRemovable: false, isEjectable: false)
    }

    /// The writable Data volume of an APFS system group. Internal, and catastrophic to unmount.
    private var dataVolume: VolumeDescriptor {
        descriptor(path: "/System/Volumes/Data", name: "Macintosh HD — Data", isRootFileSystem: false, isInternal: true, isRemovable: false, isEjectable: false)
    }

    /// A second internal SSD in a Mac Pro / Studio.
    private var internalSecondDisk: VolumeDescriptor {
        descriptor(path: "/Volumes/Scratch", name: "Scratch", isRootFileSystem: false, isInternal: true, isRemovable: false, isEjectable: true)
    }

    /// A bus-powered external SSD: not internal, ejectable but not removable media.
    private var externalSSD: VolumeDescriptor {
        descriptor(path: "/Volumes/Backup SSD", name: "Backup SSD", isRootFileSystem: false, isInternal: false, isRemovable: false, isEjectable: true)
    }

    /// A USB SSD exactly as macOS actually describes one — measured on a Mac Studio, where both
    /// the removable and the ejectable flag come back `false`. The tool listed nothing at all
    /// until the rule stopped requiring them; this fixture is the regression guard.
    private var usbSSDAsMacOSReportsIt: VolumeDescriptor {
        descriptor(path: "/Volumes/T9 MAC OUT", name: "T9 MAC OUT", isRootFileSystem: false, isInternal: false, isRemovable: false, isEjectable: false, isLocal: true)
    }

    /// A Thunderbolt/PCIe enclosure, likewise measured: false/false, and external only by
    /// `isInternal`.
    private var pcieEnclosureAsMacOSReportsIt: VolumeDescriptor {
        descriptor(path: "/Volumes/XTRM 5 Media", name: "XTRM 5 Media", isRootFileSystem: false, isInternal: false, isRemovable: false, isEjectable: false, isLocal: true)
    }

    /// An iOS Simulator runtime image. Reports removable *and* ejectable — the exact combination
    /// the old rule keyed on — while vending no `isInternal`, so it must still be refused.
    private var simulatorRuntimeImage: VolumeDescriptor {
        descriptor(path: "/Library/Developer/CoreSimulator/Volumes/iOS_23E254a", name: "iOS 26.4.1 Simulator", isRootFileSystem: false, isInternal: nil, isRemovable: true, isEjectable: true, isLocal: true)
    }

    /// A USB stick: removable media as well as ejectable.
    private var usbStick: VolumeDescriptor {
        descriptor(path: "/Volumes/USB Stick", name: "USB Stick", isRootFileSystem: false, isInternal: false, isRemovable: true, isEjectable: true)
    }

    /// A mounted disk image.
    private var diskImage: VolumeDescriptor {
        descriptor(path: "/Volumes/Installer", name: "Installer", isRootFileSystem: false, isInternal: false, isRemovable: false, isEjectable: true)
    }

    /// An SMB share. Identified by `isLocal == false` and nothing else: its removable and
    /// ejectable flags are indistinguishable from a real USB SSD's, which is precisely why the
    /// rule cannot be built on them.
    private var networkShare: VolumeDescriptor {
        descriptor(path: "/Volumes/Studio Share", name: "Studio Share", isRootFileSystem: false, isInternal: false, isRemovable: false, isEjectable: false, isLocal: false)
    }

    /// A filesystem that vends no classification flags at all (some FUSE mounts behave this way).
    private var unclassifiable: VolumeDescriptor {
        descriptor(path: "/Volumes/Mystery", name: "Mystery")
    }

    // MARK: - The safety rule

    /// THE test. Given the full spread of volume kinds a real Mac can present at once, exactly
    /// the detachable external ones are offered — by name, in display order.
    func testOnlyExternalRemovableVolumesAreOffered() {
        let all = [
            bootVolume,
            dataVolume,
            internalSecondDisk,
            externalSSD,
            usbStick,
            diskImage,
            networkShare,
            unclassifiable
        ]

        XCTAssertEqual(
            DriveEjectorKit.eligibleVolumes(from: all).map(\.name),
            ["Backup SSD", "Installer", "USB Stick"],
            "Only detachable external volumes may be offered; anything internal, boot, fixed or unclassifiable must be filtered out"
        )
    }

    func testBootVolumeIsBlocked() {
        XCTAssertEqual(DriveEjectorKit.verdict(for: bootVolume), .bootVolume)
    }

    /// The scenario that breaks a naive "not internal && ejectable" rule: a Mac booted from an
    /// external USB disk reports its startup volume as external, removable AND ejectable. The
    /// root-filesystem flag must win over all three.
    func testExternalStartupDiskIsStillBlocked() {
        let bootedFromUSB = descriptor(
            path: "/",
            name: "Field Boot Drive",
            isRootFileSystem: true,
            isInternal: false,
            isRemovable: true,
            isEjectable: true
        )

        XCTAssertEqual(DriveEjectorKit.verdict(for: bootedFromUSB), .bootVolume)
        XCTAssertTrue(DriveEjectorKit.eligibleVolumes(from: [bootedFromUSB]).isEmpty)
    }

    /// The mount point and the root-filesystem flag are independent signals; either one alone is
    /// enough to block, so a missing flag cannot expose the startup disk.
    func testRootMountPointIsBlockedEvenWhenTheRootFlagIsMissing() {
        let flagless = descriptor(
            path: "/",
            name: "Macintosh HD",
            isRootFileSystem: nil,
            isInternal: false,
            isRemovable: true,
            isEjectable: true
        )

        XCTAssertEqual(DriveEjectorKit.verdict(for: flagless), .bootVolume)
    }

    func testRootFlagIsBlockedEvenWhenMountedElsewhere() {
        let elsewhere = descriptor(
            path: "/Volumes/Somewhere",
            name: "Somewhere",
            isRootFileSystem: true,
            isInternal: false,
            isRemovable: true,
            isEjectable: true
        )

        XCTAssertEqual(DriveEjectorKit.verdict(for: elsewhere), .bootVolume)
    }

    /// A non-standardised mount-point URL must not slip past the "/" comparison.
    func testUnstandardisedRootPathIsBlocked() {
        let messyRoot = VolumeDescriptor(
            url: URL(fileURLWithPath: "/Volumes/.."),
            name: "Macintosh HD",
            isRootFileSystem: nil,
            isInternal: false,
            isRemovable: true,
            isEjectable: true,
            totalBytes: 1,
            freeBytes: 1
        )

        XCTAssertEqual(DriveEjectorKit.verdict(for: messyRoot), .bootVolume)
        XCTAssertEqual(messyRoot.id, "/", "The startup disk must not acquire a second identity")
    }

    /// The external-boot case one level deeper than the startup volume itself. When a Mac boots
    /// from a USB SSD, the firmlinked members of the running system's volume group sit on that same
    /// external medium: `isInternal` is false, removable and ejectable are true, and only the Data
    /// volume carries the root flag. `VM` and `Preboot` therefore clear every other check, and the
    /// enumeration's `.skipHiddenVolumes` does not protect `eject(volumeAt:)`, which re-derives its
    /// verdict from a bare mount point.
    func testSystemVolumeGroupIsBlockedOnAnExternallyBootedMac() {
        for path in ["/System/Volumes/Data", "/System/Volumes/VM", "/System/Volumes/Preboot", "/System/Volumes/Update"] {
            let onExternalBootMedia = descriptor(
                path: path,
                name: (path as NSString).lastPathComponent,
                isRootFileSystem: false,
                isInternal: false,
                isRemovable: true,
                isEjectable: true
            )

            XCTAssertEqual(
                DriveEjectorKit.verdict(for: onExternalBootMedia),
                .bootVolume,
                "\(path) belongs to the running system and must never be offered"
            )
        }
    }

    /// The system-volume guard is a path-prefix rule, so it must match on path *components* and not
    /// swallow an ordinary user disk whose mount point merely starts with the same characters.
    func testUserVolumesNamedLikeSystemPathsAreStillOffered() {
        for path in ["/Volumes/System", "/Volumes/System Volumes Backup"] {
            let userDisk = descriptor(
                path: path,
                name: "Backup",
                isRootFileSystem: false,
                isInternal: false,
                isRemovable: true,
                isEjectable: true
            )
            XCTAssertEqual(DriveEjectorKit.verdict(for: userDisk), .eligible, "\(path) is an ordinary external disk")
        }
    }

    func testInternalDisksAreBlockedEvenWhenEjectable() {
        // Internal drive bays report ejectable; "internal" must veto it.
        XCTAssertEqual(DriveEjectorKit.verdict(for: internalSecondDisk), .internalDisk)

        // The Data volume is caught earlier, by the system-volume-group rule, so it stays blocked
        // even on a Mac where "internal" would be false. Either way it is never offered.
        XCTAssertEqual(DriveEjectorKit.verdict(for: dataVolume), .bootVolume)
        XCTAssertFalse(DriveEjectorKit.isEligibleForEjection(dataVolume))
    }

    func testNetworkVolumesAreBlocked() {
        XCTAssertEqual(DriveEjectorKit.verdict(for: networkShare), .networkVolume)
        XCTAssertFalse(DriveEjectorKit.isEligibleForEjection(networkShare))
    }

    /// The regression this tool actually shipped with: every real external drive was refused.
    ///
    /// `isRemovable` means removable *media* — an SD card, an optical disc — so USB and
    /// Thunderbolt SSDs report it `false`, and report `isEjectable` `false` too. A rule that
    /// required either flag listed nothing at all on a normal Mac. These are the values macOS
    /// really returned for two attached drives.
    func testRealExternalDrivesAreOfferedEvenThoughBothFlagsAreFalse() {
        XCTAssertEqual(DriveEjectorKit.verdict(for: usbSSDAsMacOSReportsIt), .eligible)
        XCTAssertEqual(DriveEjectorKit.verdict(for: pcieEnclosureAsMacOSReportsIt), .eligible)
        XCTAssertTrue(DriveEjectorKit.isEligibleForEjection(usbSSDAsMacOSReportsIt))
        XCTAssertTrue(DriveEjectorKit.isEligibleForEjection(pcieEnclosureAsMacOSReportsIt))
    }

    /// The mirror image: the volumes that *do* claim removable+ejectable on a real Mac are
    /// simulator runtime images, which must never be offered. They vend no `isInternal`.
    func testSimulatorImagesAreRefusedDespiteClaimingRemovableAndEjectable() {
        XCTAssertEqual(DriveEjectorKit.verdict(for: simulatorRuntimeImage), .undetermined)
        XCTAssertFalse(DriveEjectorKit.isEligibleForEjection(simulatorRuntimeImage))
    }

    /// "Cannot be determined" must never resolve to "safe" — but only for the flag the rule
    /// actually depends on.
    ///
    /// `isInternal` is that flag: without it nothing distinguishes an external drive from the
    /// sealed system volume, so a missing value excludes. `isRemovable` and `isEjectable` are
    /// deliberately *not* required — real external drives report them as `false`, and requiring
    /// them (present or true) is what made the tool list nothing at all.
    func testUndeterminedVolumesAreExcluded() {
        XCTAssertEqual(DriveEjectorKit.verdict(for: unclassifiable), .undetermined)

        XCTAssertEqual(
            DriveEjectorKit.verdict(for: descriptor(path: "/Volumes/A", name: "A", isRootFileSystem: false, isInternal: nil, isRemovable: true, isEjectable: true)),
            .undetermined,
            "An unknown internal flag must exclude the volume"
        )
        XCTAssertEqual(
            DriveEjectorKit.verdict(for: descriptor(path: "/Volumes/B", name: "B", isRootFileSystem: false, isInternal: false, isRemovable: nil, isEjectable: true)),
            .eligible,
            "A missing removable flag is not disqualifying: the rule does not consult it"
        )
        XCTAssertEqual(
            DriveEjectorKit.verdict(for: descriptor(path: "/Volumes/C", name: "C", isRootFileSystem: false, isInternal: false, isRemovable: true, isEjectable: nil)),
            .eligible,
            "A missing ejectable flag is not disqualifying: the rule does not consult it"
        )
    }

    /// Removable and ejectable are alternatives, not a conjunction: card media reports one, a
    /// disk image reports the other, and both are legitimately ejectable.
    func testEitherRemovableOrEjectableIsEnough() {
        XCTAssertEqual(DriveEjectorKit.verdict(for: externalSSD), .eligible)
        XCTAssertEqual(DriveEjectorKit.verdict(for: usbStick), .eligible)
        XCTAssertEqual(DriveEjectorKit.verdict(for: diskImage), .eligible)

        let cardMedia = descriptor(path: "/Volumes/SD Card", name: "SD Card", isRootFileSystem: false, isInternal: false, isRemovable: true, isEjectable: false)
        XCTAssertEqual(DriveEjectorKit.verdict(for: cardMedia), .eligible)
    }

    func testIsEligibleAgreesWithVerdict() {
        for volume in [bootVolume, dataVolume, internalSecondDisk, externalSSD, usbStick, diskImage, networkShare, unclassifiable] {
            XCTAssertEqual(
                DriveEjectorKit.isEligibleForEjection(volume),
                DriveEjectorKit.verdict(for: volume) == .eligible,
                "The convenience predicate must never disagree with the verdict for \(volume.name)"
            )
        }
    }

    func testEligibleVolumesAreSortedCaseInsensitively() {
        let volumes = [
            descriptor(path: "/Volumes/zeta", name: "zeta", isRootFileSystem: false, isInternal: false, isRemovable: true, isEjectable: true),
            descriptor(path: "/Volumes/Alpha", name: "Alpha", isRootFileSystem: false, isInternal: false, isRemovable: true, isEjectable: true),
            descriptor(path: "/Volumes/beta", name: "beta", isRootFileSystem: false, isInternal: false, isRemovable: true, isEjectable: true)
        ]

        XCTAssertEqual(DriveEjectorKit.eligibleVolumes(from: volumes).map(\.name), ["Alpha", "beta", "zeta"])
    }

    func testEmptyInputYieldsNoVolumes() {
        XCTAssertTrue(DriveEjectorKit.eligibleVolumes(from: []).isEmpty)
    }

    // MARK: - Pre-eject re-check

    /// Safe to run: the rule rejects "/" and returns before `unmountAndEjectDevice` is reached,
    /// which is precisely the guarantee under test.
    func testEjectingTheStartupDiskIsRefused() {
        XCTAssertEqual(
            DriveEjectorKit.eject(volumeAt: URL(fileURLWithPath: "/")),
            .blocked(.bootVolume),
            "Ejecting the startup disk must be refused by the re-check, not merely absent from the list"
        )
    }

    /// A path that cannot be inspected yields no descriptor, and "no descriptor" must mean
    /// "refuse" rather than "proceed with defaults".
    func testEjectingAnUninspectablePathIsRefused() {
        let missing = URL(fileURLWithPath: "/Volumes/\(UUID().uuidString)")
        XCTAssertEqual(DriveEjectorKit.eject(volumeAt: missing), .blocked(.undetermined))
    }

    // MARK: - Foreign unmount announcements

    /// The bug this guards: `willUnmountNotification` fires, the unmount is then *denied* by an app
    /// holding the volume, and no further notification ever arrives. Keeping the marker on the
    /// grounds that the volume is still mounted would disable its Eject button — and drop it from
    /// Eject All — until the tool was relaunched.
    func testStillMountedAnnouncementIsReleasedAfterTheGracePeriod() {
        let announced = Date()
        let announcements = ["/Volumes/USB Stick": announced]
        let mounted: Set<String> = ["/Volumes/USB Stick"]

        XCTAssertEqual(
            DriveEjectorKit.liveUnmountAnnouncements(announcements, mountedIDs: mounted, now: announced.addingTimeInterval(5), grace: 15).keys.sorted(),
            ["/Volumes/USB Stick"],
            "An unmount still in progress must keep the row busy"
        )

        XCTAssertTrue(
            DriveEjectorKit.liveUnmountAnnouncements(announcements, mountedIDs: mounted, now: announced.addingTimeInterval(15), grace: 15).isEmpty,
            "A volume still mounted after the grace period had its unmount denied; the row must become pressable again"
        )
    }

    /// The unmount succeeded, so there is no row left to protect and the marker must not linger to
    /// suppress a disk later remounted at the same point.
    func testAnnouncementForAVanishedVolumeIsDroppedImmediately() {
        let announced = Date()
        XCTAssertTrue(
            DriveEjectorKit.liveUnmountAnnouncements(
                ["/Volumes/USB Stick": announced],
                mountedIDs: [],
                now: announced.addingTimeInterval(1),
                grace: 15
            ).isEmpty
        )
    }

    func testAnnouncementsAreFilteredIndependently() {
        let now = Date()
        let live = DriveEjectorKit.liveUnmountAnnouncements(
            [
                "/Volumes/Slow": now.addingTimeInterval(-2),
                "/Volumes/Vetoed": now.addingTimeInterval(-99),
                "/Volumes/Gone": now.addingTimeInterval(-1)
            ],
            mountedIDs: ["/Volumes/Slow", "/Volumes/Vetoed"],
            now: now,
            grace: 15
        )

        XCTAssertEqual(live.keys.sorted(), ["/Volumes/Slow"])
    }

    // MARK: - Descriptors and formatting

    func testUsedBytesNeverUnderflows() {
        // A stale free-space reading larger than the capacity must clamp, not wrap around.
        let odd = descriptor(path: "/Volumes/Odd", name: "Odd", totalBytes: 100, freeBytes: 400)
        XCTAssertEqual(odd.usedBytes, 0)

        let normal = descriptor(path: "/Volumes/Normal", name: "Normal", totalBytes: 400, freeBytes: 100)
        XCTAssertEqual(normal.usedBytes, 300)
    }

    func testDescriptorIdentityIsTheMountPoint() {
        XCTAssertEqual(usbStick.id, "/Volumes/USB Stick")
    }

    /// Identity is canonical, so the same mount point spelled three different ways is one volume.
    /// This is what lets a busy marker keyed on a `willUnmount` notification's URL match the row
    /// built from `mountedVolumeURLs`; without it a row would stay pressable mid-unmount.
    func testDescriptorIdentityIsCanonical() {
        for spelling in ["/Volumes/USB Stick", "/Volumes/USB Stick/", "/Volumes/./USB Stick", "/Volumes/Other/../USB Stick"] {
            XCTAssertEqual(
                descriptor(path: spelling, name: "USB Stick").id,
                usbStick.id,
                "\(spelling) names the same mount point and must produce the same identity"
            )
        }
    }

    /// The descriptor's own mount point is canonicalised too — it is the URL handed to
    /// `unmountAndEjectDevice`, so it must name the same volume the safety rule cleared.
    func testDescriptorURLIsCanonicalised() {
        XCTAssertEqual(descriptor(path: "/Volumes/Other/../USB Stick", name: "USB Stick").url.path, "/Volumes/USB Stick")
    }

    /// A busy marker and a row ID derived from different spellings of one mount point must collide,
    /// which is the whole point of routing both through `volumeIdentity(for:)`.
    func testBusyMarkerMatchesARowBuiltFromADifferentSpelling() {
        let announcement = DriveEjectorKit.volumeIdentity(for: URL(fileURLWithPath: "/Volumes/Other/../USB Stick/"))
        XCTAssertTrue(
            DriveEjectorKit.liveUnmountAnnouncements(
                [announcement: Date()],
                mountedIDs: [usbStick.id],
                now: Date(),
                grace: 15
            ).keys.contains(usbStick.id),
            "An unmount announced for a non-canonical path must keep the matching row busy"
        )
    }

    /// Canonicalising identity must not weaken the rule: a system-volume-group member reached
    /// through a non-canonical path is still refused.
    func testNonCanonicalSystemVolumePathsAreStillBlocked() {
        for path in ["/System/Volumes/Data/", "/System/Volumes/./VM", "/Volumes/../System/Volumes/Preboot", "/System/Volumes/Update/.."] {
            let onExternalBootMedia = descriptor(
                path: path,
                name: "Data",
                isRootFileSystem: false,
                isInternal: false,
                isRemovable: true,
                isEjectable: true
            )
            XCTAssertEqual(
                DriveEjectorKit.verdict(for: onExternalBootMedia),
                .bootVolume,
                "\(path) resolves inside the running system's volume group and must never be offered"
            )
        }
    }

    func testBlockedReasonsReadAsSentencesAndEligibleHasNone() {
        XCTAssertNil(VolumeEjectionVerdict.eligible.blockedReason)
        for verdict: VolumeEjectionVerdict in [.bootVolume, .internalDisk, .networkVolume, .undetermined] {
            let reason = verdict.blockedReason ?? ""
            XCTAssertFalse(reason.isEmpty, "Every blocking verdict needs an explanation to show the user")
            XCTAssertFalse(reason.contains("..."), "Typography: use a real ellipsis, never three dots")
        }
    }

    func testFailureMessageCombinesDescriptionAndRecoverySuggestion() {
        // macOS routinely puts the name of the app holding the volume in the recovery suggestion,
        // so dropping it would throw away the only actionable part of the failure.
        let withSuggestion = NSError(domain: NSCocoaErrorDomain, code: 1, userInfo: [
            NSLocalizedDescriptionKey: "The disk is in use.",
            NSLocalizedRecoverySuggestionErrorKey: "Quit Preview and try again."
        ])
        XCTAssertEqual(
            DriveEjectorKit.failureMessage(for: withSuggestion),
            "The disk is in use. Quit Preview and try again."
        )
    }

    func testFailureMessageDoesNotRepeatItself() {
        let duplicated = NSError(domain: NSCocoaErrorDomain, code: 1, userInfo: [
            NSLocalizedDescriptionKey: "The disk is in use.",
            NSLocalizedRecoverySuggestionErrorKey: "The disk is in use."
        ])
        XCTAssertEqual(DriveEjectorKit.failureMessage(for: duplicated), "The disk is in use.")
    }

    func testFailureMessageAlwaysSaysSomething() {
        let blank = NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: ""])
        XCTAssertFalse(
            DriveEjectorKit.failureMessage(for: blank).isEmpty,
            "A silent failure would leave the status line blank after a failed eject"
        )
    }

    // MARK: - Live enumeration (environment-tolerant)

    /// Whatever this machine happens to have mounted, nothing the tool offers may be internal or
    /// the startup disk. Asserts an invariant rather than a count, so it is stable on CI.
    func testNothingOfferedOnThisMachineIsInternalOrBoot() {
        for volume in DriveEjectorKit.ejectableVolumes() {
            XCTAssertNotEqual(volume.url.standardizedFileURL.path, "/", "The startup disk was offered")
            XCTAssertNotEqual(volume.isRootFileSystem, true, "The root filesystem was offered")
            XCTAssertNotEqual(volume.isInternal, true, "An internal disk was offered: \(volume.name)")
            XCTAssertNotEqual(volume.isLocal, false, "A network volume was offered: \(volume.name)")
            // Deliberately NOT asserting isRemovable/isEjectable here. Real external drives
            // report both as false, so requiring either is what made this tool list nothing.
        }
    }

    func testMountedDescriptorsIncludeTheStartupDiskAndTheRuleRejectsIt() {
        let descriptors = DriveEjectorKit.mountedVolumeDescriptors()
        XCTAssertFalse(descriptors.isEmpty, "A running Mac always has at least the startup volume mounted")

        guard let root = descriptors.first(where: { $0.url.standardizedFileURL.path == "/" }) else {
            // Some sandboxes hide "/" from the volume enumeration; the "/" eject test above still
            // covers the refusal path directly.
            return
        }
        XCTAssertEqual(DriveEjectorKit.verdict(for: root), .bootVolume)
    }
}
