import XCTest
@testable import DMonteCore

/// The leftover sweep is the one part of the Uninstaller that can destroy data belonging to an app
/// the user did not ask to remove, so the rules that decide *what* it touches are tested far more
/// aggressively than the feature is large.
///
/// Everything here runs against synthetic Library roots inside a per-test temporary directory —
/// the real `~/Library` and `/Library` are never read, and nothing is ever actually moved to the
/// Trash. The removal tests only exercise the refusal path, which is the half that matters.
final class UninstallerLeftoversTests: XCTestCase {

    // MARK: - Fixtures

    private var sandbox: URL!

    /// Stands in for `~/Library`.
    private var userLibrary: URL { sandbox.appendingPathComponent("Library") }

    /// Stands in for `/Library`.
    private var systemLibrary: URL { sandbox.appendingPathComponent("SystemLibrary") }

    private var roots: [URL] {
        UninstallerLeftovers.allowedRoots(userLibrary: userLibrary, systemLibrary: systemLibrary)
    }

    override func setUpWithError() throws {
        try super.setUpWithError()

        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("UninstallerLeftoversTests-\(UUID().uuidString)")

        for library in [userLibrary, systemLibrary] {
            for location in UninstallerLeftovers.locations {
                try FileManager.default.createDirectory(
                    at: library.appendingPathComponent(location.subpath),
                    withIntermediateDirectories: true
                )
            }
        }
    }

    override func tearDownWithError() throws {
        if let sandbox, FileManager.default.fileExists(atPath: sandbox.path) {
            try FileManager.default.removeItem(at: sandbox)
        }
        sandbox = nil
        try super.tearDownWithError()
    }

    private func candidates(
        bundleIdentifier: String?,
        appName: String = "zz",
        otherAppNames: [String] = []
    ) -> [LeftoverCandidate] {
        UninstallerLeftovers.candidates(
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            userLibrary: userLibrary,
            systemLibrary: systemLibrary,
            otherAppNames: otherAppNames
        )
    }

    private func scan(bundleIdentifier: String?, appName: String = "zz", otherAppNames: [String] = []) -> [LeftoverItem] {
        LeftoverScanner.scan(
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            otherAppNames: otherAppNames,
            userLibrary: userLibrary,
            systemLibrary: systemLibrary
        )
    }

    /// Creates a directory holding one file of `bytes` bytes, so sizing has something to measure.
    @discardableResult
    private func makeLeaf(_ library: URL, _ subpath: String, _ leaf: String, bytes: Int = 64) throws -> URL {
        let url = library.appendingPathComponent(subpath).appendingPathComponent(leaf)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url.appendingPathComponent("payload.bin"))
        return url
    }

    // MARK: - Derivation covers exactly the documented locations

    func testBundleIdentifierCoversEveryLocationInBothLibraries() {
        let derived = candidates(bundleIdentifier: "com.example.app")

        XCTAssertEqual(derived.count, UninstallerLeftovers.locations.count * 2)

        let paths = Set(derived.map(\.url.path))
        XCTAssertTrue(paths.contains(userLibrary.appendingPathComponent("Application Support/com.example.app").path))
        XCTAssertTrue(paths.contains(userLibrary.appendingPathComponent("Caches/com.example.app").path))
        XCTAssertTrue(paths.contains(userLibrary.appendingPathComponent("Preferences/com.example.app.plist").path))
        XCTAssertTrue(paths.contains(userLibrary.appendingPathComponent("Containers/com.example.app").path))
        XCTAssertTrue(paths.contains(userLibrary.appendingPathComponent("Saved Application State/com.example.app.savedState").path))
        XCTAssertTrue(paths.contains(userLibrary.appendingPathComponent("Logs/com.example.app").path))
        XCTAssertTrue(paths.contains(userLibrary.appendingPathComponent("HTTPStorages/com.example.app").path))
        XCTAssertTrue(paths.contains(userLibrary.appendingPathComponent("WebKit/com.example.app").path))
        XCTAssertTrue(paths.contains(systemLibrary.appendingPathComponent("Application Support/com.example.app").path))
        XCTAssertTrue(paths.contains(systemLibrary.appendingPathComponent("Preferences/com.example.app.plist").path))
    }

    func testEveryDerivedCandidateSatisfiesTheRemovalFence() {
        for candidate in candidates(bundleIdentifier: "com.example.app") {
            XCTAssertTrue(
                UninstallerLeftovers.isRemovable(candidate.url, allowedRoots: roots),
                "derivation produced a path the fence would refuse: \(candidate.url.path)"
            )
        }
    }

    func testBundleIdentifierCandidatesAreSelectedByDefault() {
        let items = candidates(bundleIdentifier: "com.example.app")
            .map { LeftoverItem(candidate: $0, bytes: 10) }

        XCTAssertEqual(UninstallerLeftovers.defaultSelection(for: items).count, items.count)
    }

    // MARK: - Identifier hygiene

    func testDottedIdentifierIsUsedVerbatim() {
        let derived = candidates(bundleIdentifier: "com.company.Product.v2")

        XCTAssertEqual(
            derived.first { $0.label == "Caches" && $0.scope == .user }?.url.lastPathComponent,
            "com.company.Product.v2"
        )
    }

    func testIdentifierWithSpacesIsAccepted() {
        let derived = candidates(bundleIdentifier: "com.example.My Great App")

        XCTAssertEqual(derived.count, UninstallerLeftovers.locations.count * 2)
        XCTAssertEqual(
            derived.first { $0.label == "Application Support" && $0.scope == .user }?.url.lastPathComponent,
            "com.example.My Great App"
        )
    }

    func testUnicodeIdentifierIsAcceptedAndNotMangled() {
        let identifier = "com.exämple.日本語アプリ.Ω"
        let derived = candidates(bundleIdentifier: identifier)

        XCTAssertEqual(derived.count, UninstallerLeftovers.locations.count * 2)
        XCTAssertEqual(
            derived.first { $0.label == "Preferences" && $0.scope == .user }?.url.lastPathComponent,
            identifier + ".plist"
        )
    }

    func testSurroundingWhitespaceIsTrimmedRatherThanBakedIntoThePath() {
        XCTAssertEqual(UninstallerLeftovers.sanitizedIdentifier("  com.example.app\n"), "com.example.app")
    }

    func testTraversalIdentifiersAreRefused() {
        for hostile in ["../..", "../../etc", "com.example.app/../../..", "..", ".", "...", "/etc/passwd", "~", "~/Documents"] {
            XCTAssertNil(
                UninstallerLeftovers.sanitizedIdentifier(hostile),
                "identifier \(hostile) should not be usable as a path component"
            )
        }
    }

    func testTraversalIdentifierProducesNoCandidatesAtAll() {
        // The display name is deliberately too short to trigger the fallback, so an empty result
        // proves the traversal attempt produced nothing rather than being quietly replaced.
        XCTAssertTrue(candidates(bundleIdentifier: "../../../etc", appName: "ab").isEmpty)
    }

    func testSeparatorAndControlCharacterIdentifiersAreRefused() {
        XCTAssertNil(UninstallerLeftovers.sanitizedIdentifier("com/example/app"))
        XCTAssertNil(UninstallerLeftovers.sanitizedIdentifier("com:example:app"))
        XCTAssertNil(UninstallerLeftovers.sanitizedIdentifier("com.example\u{0}app"))
        XCTAssertNil(UninstallerLeftovers.sanitizedIdentifier("com.example\napp"))
    }

    func testEmptyAndOverlongIdentifiersAreRefused() {
        XCTAssertNil(UninstallerLeftovers.sanitizedIdentifier(nil))
        XCTAssertNil(UninstallerLeftovers.sanitizedIdentifier(""))
        XCTAssertNil(UninstallerLeftovers.sanitizedIdentifier("   "))
        XCTAssertNil(UninstallerLeftovers.sanitizedIdentifier(String(repeating: "a", count: 256)))
        XCTAssertEqual(UninstallerLeftovers.sanitizedIdentifier(String(repeating: "a", count: 255))?.count, 255)
    }

    // MARK: - Prefix collisions between apps

    func testCandidatesNeverReachAnIdentifierThatMerelySharesThePrefix() {
        let paths = Set(candidates(bundleIdentifier: "com.example.app").map(\.url.path))

        XCTAssertFalse(paths.contains { $0.contains("com.example.app.helper") })
        XCTAssertFalse(paths.contains { $0.contains("com.example.application") })
    }

    func testScanIgnoresNeighboursWhoseIdentifierExtendsTheOneBeingRemoved() throws {
        try makeLeaf(userLibrary, "Application Support", "com.example.app")
        try makeLeaf(userLibrary, "Application Support", "com.example.app.helper")
        try makeLeaf(userLibrary, "Application Support", "com.example.application")
        try makeLeaf(userLibrary, "Caches", "com.example.app.helper")

        let found = scan(bundleIdentifier: "com.example.app").map(\.url.path)

        XCTAssertEqual(found, [userLibrary.appendingPathComponent("Application Support/com.example.app").path])
    }

    func testScanFindsEveryLocationThatActuallyExists() throws {
        try makeLeaf(userLibrary, "Application Support", "com.example.app", bytes: 100)
        try makeLeaf(userLibrary, "Caches", "com.example.app", bytes: 100)
        try makeLeaf(systemLibrary, "Logs", "com.example.app", bytes: 100)

        let found = scan(bundleIdentifier: "com.example.app")

        XCTAssertEqual(found.count, 3)
        XCTAssertEqual(Set(found.map(\.candidate.label)), ["Application Support", "Caches", "Logs"])
        XCTAssertEqual(found.filter { $0.candidate.scope == .system }.count, 1)
        XCTAssertTrue(found.allSatisfy { $0.bytes > 0 }, "an existing leftover should report a measured size")
    }

    // MARK: - The display-name fallback

    func testNameFallbackOnlyTouchesTheDirectoriesThatAreEverNamedAfterAnApp() {
        let derived = candidates(bundleIdentifier: nil, appName: "Fantastical")

        XCTAssertEqual(Set(derived.map(\.label)), ["Application Support", "Caches", "Logs"])
        XCTAssertEqual(derived.count, 6)
        XCTAssertTrue(derived.allSatisfy { $0.match == .appName })
    }

    func testNameMatchedCandidatesAreNeverTickedByDefault() {
        let items = candidates(bundleIdentifier: nil, appName: "Fantastical")
            .map { LeftoverItem(candidate: $0, bytes: 10) }

        XCTAssertFalse(items.isEmpty)
        XCTAssertTrue(UninstallerLeftovers.defaultSelection(for: items).isEmpty)
    }

    func testNameFallbackRefusesUmbrellaVendorDirectories() {
        for shared in ["Google", "Adobe", "Microsoft", "Mozilla", "Steam"] {
            XCTAssertFalse(
                UninstallerLeftovers.isNameSpecificEnough(shared),
                "\(shared) names a directory shared by several apps"
            )
            XCTAssertTrue(candidates(bundleIdentifier: nil, appName: shared).isEmpty)
        }
    }

    func testNameFallbackRefusesGenericDirectoryNames() {
        for generic in ["Logs", "caches", "Support", "Preferences", "Data", "Updater"] {
            XCTAssertFalse(UninstallerLeftovers.isNameSpecificEnough(generic))
        }
    }

    func testNameFallbackRefusesNamesTooShortToBeUnambiguous() {
        for short in ["Go", "Zip", "IDE", "A"] {
            XCTAssertFalse(UninstallerLeftovers.isNameSpecificEnough(short))
        }

        XCTAssertTrue(UninstallerLeftovers.isNameSpecificEnough("Bear"))
    }

    func testNameFallbackRefusesNamesAnotherInstalledAppAlsoAnswersTo() {
        XCTAssertFalse(UninstallerLeftovers.isNameSpecificEnough("Fantastical", otherAppNames: ["Fantastical"]))
        XCTAssertFalse(UninstallerLeftovers.isNameSpecificEnough("Fantastical", otherAppNames: ["fantastical"]))
        XCTAssertFalse(UninstallerLeftovers.isNameSpecificEnough("Café Noir", otherAppNames: ["Cafe Noir"]))
        XCTAssertTrue(UninstallerLeftovers.isNameSpecificEnough("Fantastical", otherAppNames: ["Fantastical Helper"]))
    }

    func testNameFallbackRefusesNamesThatWouldEscapeTheirDirectory() {
        XCTAssertFalse(UninstallerLeftovers.isNameSpecificEnough("../../Documents"))
        XCTAssertFalse(UninstallerLeftovers.isNameSpecificEnough("/Users/someone"))
        XCTAssertTrue(candidates(bundleIdentifier: nil, appName: "../../Documents").isEmpty)
    }

    func testNameCandidatesAreAddedAlongsideBundleIdentifierCandidatesWithoutDuplicates() {
        let derived = candidates(bundleIdentifier: "com.flexibits.fantastical2.mac", appName: "Fantastical")

        XCTAssertEqual(derived.filter { $0.match == .bundleIdentifier }.count, UninstallerLeftovers.locations.count * 2)
        XCTAssertEqual(derived.filter { $0.match == .appName }.count, 6)
        XCTAssertEqual(Set(derived.map(\.id)).count, derived.count)
    }

    // MARK: - The removal fence

    func testFenceAcceptsADirectChildOfAKnownRoot() {
        let url = userLibrary.appendingPathComponent("Caches/com.example.app")

        XCTAssertTrue(UninstallerLeftovers.isRemovable(url, allowedRoots: roots))
    }

    func testFenceRefusesTheRootItself() {
        for root in roots {
            XCTAssertFalse(UninstallerLeftovers.isRemovable(root, allowedRoots: roots))
        }

        XCTAssertFalse(UninstallerLeftovers.isRemovable(userLibrary, allowedRoots: roots))
        XCTAssertFalse(UninstallerLeftovers.isRemovable(sandbox, allowedRoots: roots))
    }

    func testFenceRefusesAnythingDeeperThanADirectChild() {
        let nested = userLibrary.appendingPathComponent("Caches/com.example.app/Data/file.db")

        XCTAssertFalse(UninstallerLeftovers.isRemovable(nested, allowedRoots: roots))
    }

    func testFenceRefusesASiblingDirectoryThatMerelySharesTheRootsNamePrefix() {
        let lookalike = userLibrary.appendingPathComponent("CachesElsewhere/com.example.app")

        XCTAssertFalse(UninstallerLeftovers.isRemovable(lookalike, allowedRoots: roots))
    }

    func testFenceRefusesTraversalOutOfARoot() {
        let escapes = [
            userLibrary.appendingPathComponent("Caches/../../../etc/passwd"),
            userLibrary.appendingPathComponent("Caches/../Keychains/login.keychain-db"),
            userLibrary.appendingPathComponent("Caches/.."),
            URL(fileURLWithPath: "/etc/passwd"),
            sandbox.appendingPathComponent("Documents/Taxes")
        ]

        for escape in escapes {
            XCTAssertFalse(
                UninstallerLeftovers.isRemovable(escape, allowedRoots: roots),
                "\(escape.path) is outside every allowed root"
            )
        }
    }

    func testFenceIgnoresRootsShallowEnoughToHoldWholeVolumesOrAccounts() {
        let reckless = [URL(fileURLWithPath: "/"), URL(fileURLWithPath: "/Users"), URL(fileURLWithPath: "/Volumes")]

        XCTAssertFalse(UninstallerLeftovers.isRemovable(URL(fileURLWithPath: "/Users"), allowedRoots: reckless))
        XCTAssertFalse(UninstallerLeftovers.isRemovable(URL(fileURLWithPath: "/Applications"), allowedRoots: reckless))
        XCTAssertFalse(UninstallerLeftovers.isRemovable(URL(fileURLWithPath: "/Volumes/Backup"), allowedRoots: reckless))
        XCTAssertFalse(UninstallerLeftovers.isRemovable(URL(fileURLWithPath: "/Library/Caches/com.example.app"), allowedRoots: []))
    }

    // MARK: - Symlinks

    func testFenceRefusesASymlinkThatResolvesOutsideEveryAllowedRoot() throws {
        let secrets = sandbox.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: secrets, withIntermediateDirectories: true)

        let planted = userLibrary.appendingPathComponent("Caches/com.example.app")
        try FileManager.default.createSymbolicLink(at: planted, withDestinationURL: secrets)

        XCTAssertFalse(UninstallerLeftovers.isRemovable(planted, allowedRoots: roots))
    }

    func testFenceRefusesASymlinkAimedAtTheHomeDirectory() throws {
        let planted = userLibrary.appendingPathComponent("Application Support/com.example.app")
        try FileManager.default.createSymbolicLink(
            at: planted,
            withDestinationURL: FileManager.default.homeDirectoryForCurrentUser
        )

        XCTAssertFalse(UninstallerLeftovers.isRemovable(planted, allowedRoots: roots))
    }

    func testFenceStillAcceptsASymlinkThatStaysInsideAnAllowedRoot() throws {
        let real = try makeLeaf(userLibrary, "Caches", "com.example.real")
        let planted = userLibrary.appendingPathComponent("Caches/com.example.app")
        try FileManager.default.createSymbolicLink(at: planted, withDestinationURL: real)

        XCTAssertTrue(UninstallerLeftovers.isRemovable(planted, allowedRoots: roots))
    }

    /// A link that stays inside an allowed root is legitimately removable, so the sheet offers it
    /// — and must then price it as the link it is. Trashing a link frees the link, not the 400 KB
    /// it points at, and a sweep that promises to free the target is lying about the one number
    /// the user is looking at.
    func testASymlinkedLeftoverIsPricedAsTheLinkAndNotAsItsTarget() throws {
        let real = try makeLeaf(userLibrary, "Caches", "com.example.real", bytes: 400_000)
        let planted = userLibrary.appendingPathComponent("Caches/com.example.app")
        try FileManager.default.createSymbolicLink(at: planted, withDestinationURL: real)

        let found = scan(bundleIdentifier: "com.example.app")

        XCTAssertEqual(found.map(\.url.path), [planted.path])
        XCTAssertGreaterThan(found[0].bytes, 0, "a link is measured as itself, not as nothing")
        XCTAssertLessThan(found[0].bytes, 1_024, "the link's 400 KB target must not be billed to the app")
    }

    /// The same promise one level down: a link met *inside* a leftover directory is a leaf, not a
    /// doorway into whatever volume it points at.
    func testASymlinkInsideALeftoverDoesNotBillItsTargetToTheApp() throws {
        let elsewhere = sandbox.appendingPathComponent("Elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data(repeating: 0x45, count: 400_000).write(to: elsewhere.appendingPathComponent("huge.bin"))

        let leaf = try makeLeaf(userLibrary, "Application Support", "com.example.app", bytes: 64)
        try FileManager.default.createSymbolicLink(
            at: leaf.appendingPathComponent("link-to-elsewhere"),
            withDestinationURL: elsewhere
        )

        let found = scan(bundleIdentifier: "com.example.app")

        XCTAssertEqual(found.count, 1)
        XCTAssertLessThan(found[0].bytes, 100_000, "the walk followed a symlink out of the leftover directory")
    }

    func testScanDropsAnEscapingSymlinkInsteadOfOfferingIt() throws {
        let secrets = sandbox.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: secrets, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 4_096).write(to: secrets.appendingPathComponent("taxes.pdf"))

        try FileManager.default.createSymbolicLink(
            at: userLibrary.appendingPathComponent("Caches/com.example.app"),
            withDestinationURL: secrets
        )
        try makeLeaf(userLibrary, "Logs", "com.example.app")

        let found = scan(bundleIdentifier: "com.example.app")

        XCTAssertEqual(found.map(\.candidate.label), ["Logs"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: secrets.appendingPathComponent("taxes.pdf").path))
    }

    // MARK: - Removal refuses what the fence refuses

    func testMoveToTrashRefusesAnItemOutsideTheAllowedRootsAndLeavesItOnDisk() throws {
        let secrets = sandbox.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: secrets, withIntermediateDirectories: true)
        let victim = secrets.appendingPathComponent("taxes.pdf")
        try Data(repeating: 0x43, count: 128).write(to: victim)

        // A hand-built item, i.e. exactly the shape a bug elsewhere in the tool would produce.
        let smuggled = LeftoverItem(
            candidate: LeftoverCandidate(url: victim, label: "Caches", scope: .user, match: .bundleIdentifier),
            bytes: 128
        )

        let result = LeftoverScanner.moveToTrash([smuggled], userLibrary: userLibrary, systemLibrary: systemLibrary)

        XCTAssertEqual(result.trashedCount, 0)
        XCTAssertEqual(result.trashedBytes, 0)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path), "the fence must leave a refused path untouched")
    }

    func testMoveToTrashRefusesAnEscapingSymlinkWithoutFollowingIt() throws {
        let secrets = sandbox.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: secrets, withIntermediateDirectories: true)
        let victim = secrets.appendingPathComponent("taxes.pdf")
        try Data(repeating: 0x44, count: 128).write(to: victim)

        let planted = userLibrary.appendingPathComponent("Caches/com.example.app")
        try FileManager.default.createSymbolicLink(at: planted, withDestinationURL: secrets)

        let smuggled = LeftoverItem(
            candidate: LeftoverCandidate(url: planted, label: "Caches", scope: .user, match: .bundleIdentifier),
            bytes: 128
        )

        let result = LeftoverScanner.moveToTrash([smuggled], userLibrary: userLibrary, systemLibrary: systemLibrary)

        XCTAssertEqual(result.trashedCount, 0)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path))
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: planted.path))
    }

    func testMoveToTrashOnNothingIsANoOp() {
        let result = LeftoverScanner.moveToTrash([], userLibrary: userLibrary, systemLibrary: systemLibrary)

        XCTAssertEqual(result, LeftoverRemovalResult())
    }

    // MARK: - What the review sheet says out loud

    /// The row's checkbox draws no label of its own, so without this every row on the sheet
    /// announces itself as an identical unlabelled checkbox — on the one screen whose entire job
    /// is letting the user decide, row by row, what gets deleted.
    func testEveryReviewRowAnnouncesItsLocationAndPath() {
        let item = LeftoverItem(
            candidate: LeftoverCandidate(
                url: userLibrary.appendingPathComponent("Caches/com.example.app"),
                label: "Caches",
                scope: .user,
                match: .bundleIdentifier
            ),
            bytes: 1_024
        )

        XCTAssertEqual(item.accessibilityLabel, "Caches, \(item.candidate.displayPath)")
        XCTAssertFalse(item.accessibilityLabel.contains("matched by name"))
        XCTAssertFalse(item.accessibilityLabel.contains("system-wide"))
    }

    /// The two badges are warnings, not decoration, so they are spoken too: a reader who cannot
    /// see "matched by name" is exactly the reader who needs to hear it.
    func testAReviewRowSpeaksTheBadgesThatMakeItRisky() {
        let item = LeftoverItem(
            candidate: LeftoverCandidate(
                url: systemLibrary.appendingPathComponent("Logs/Fantastical"),
                label: "Logs",
                scope: .system,
                match: .appName
            ),
            bytes: 1_024
        )

        XCTAssertEqual(
            item.accessibilityLabel,
            "Logs, \(item.candidate.displayPath), matched by name, system-wide"
        )
    }

    // MARK: - Selection arithmetic

    func testSelectedBytesCountsOnlyTheTickedRows() {
        let items = candidates(bundleIdentifier: "com.example.app")
            .prefix(3)
            .enumerated()
            .map { LeftoverItem(candidate: $1, bytes: UInt64(($0 + 1) * 100)) }

        XCTAssertEqual(UninstallerLeftovers.selectedBytes(in: items, selection: []), 0)
        XCTAssertEqual(UninstallerLeftovers.selectedBytes(in: items, selection: [items[0].id, items[2].id]), 400)
        XCTAssertEqual(UninstallerLeftovers.selectedBytes(in: items, selection: Set(items.map(\.id))), 600)
    }

    func testSelectedBytesIgnoresIdentifiersThatAreNotInTheList() {
        let items = candidates(bundleIdentifier: "com.example.app")
            .prefix(1)
            .map { LeftoverItem(candidate: $0, bytes: 500) }

        XCTAssertEqual(UninstallerLeftovers.selectedBytes(in: items, selection: ["/some/other/path"]), 0)
    }
}
