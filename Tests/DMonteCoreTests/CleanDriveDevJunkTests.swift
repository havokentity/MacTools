import XCTest
@testable import DMonteCore

final class CleanDriveDevJunkTests: XCTestCase {
    private let home = "/Users/tester"

    // MARK: - Path primitives

    func testStrictDescendantIsComponentWiseNotStringPrefix() {
        // The whole feature turns on this: a plain hasPrefix test would say the backup folder
        // lives inside the project, and that is how a cleaner ends up deleting someone's source.
        XCTAssertFalse(DevJunkPaths.isStrictDescendant("/Users/tester/Code/MyApp-backup", of: "/Users/tester/Code/MyApp"))
        XCTAssertTrue(DevJunkPaths.isStrictDescendant("/Users/tester/Code/MyApp/src", of: "/Users/tester/Code/MyApp"))
        XCTAssertFalse(DevJunkPaths.isStrictDescendant("/Users/tester/Code/MyApp", of: "/Users/tester/Code/MyApp"))
    }

    func testDescendantOrSelfAcceptsTheRootItself() {
        XCTAssertTrue(DevJunkPaths.isDescendantOrSelf("/Users/tester/Code", of: "/Users/tester/Code"))
        XCTAssertTrue(DevJunkPaths.isDescendantOrSelf("/Users/tester/Code/App", of: "/Users/tester/Code"))
        XCTAssertFalse(DevJunkPaths.isDescendantOrSelf("/Users/tester", of: "/Users/tester/Code"))
    }

    func testDirectChildIsExactlyOneLevelDown() {
        XCTAssertTrue(DevJunkPaths.isDirectChild("/a/b/c", of: "/a/b"))
        XCTAssertFalse(DevJunkPaths.isDirectChild("/a/b/c/d", of: "/a/b"))
        XCTAssertFalse(DevJunkPaths.isDirectChild("/a/b", of: "/a/b"))
    }

    func testNormalizeCollapsesRedundantSeparators() {
        XCTAssertEqual(DevJunkPaths.normalize("/a//b/"), "/a/b")
        XCTAssertEqual(DevJunkPaths.normalize("/"), "/")
    }

    func testExpandOnlyHandlesTheCurrentUsersTilde() {
        XCTAssertEqual(DevJunkPaths.expand("~/Library", home: home), "/Users/tester/Library")
        XCTAssertEqual(DevJunkPaths.expand("~", home: home), home)
        XCTAssertEqual(DevJunkPaths.expand("/absolute", home: home), "/absolute")
        // "~someone" belongs to another account and must be left alone rather than mangled.
        XCTAssertEqual(DevJunkPaths.expand("~other/Library", home: home), "~other/Library")
    }

    func testAbbreviateOnlyShortensPathsInsideHome() {
        XCTAssertEqual(DevJunkPaths.abbreviate("/Users/tester/Code/App", home: home), "~/Code/App")
        XCTAssertEqual(DevJunkPaths.abbreviate("/Users/other/Code", home: home), "/Users/other/Code")
    }

    func testDisplayNameNamesProjectEntriesAfterTheirProject() {
        // A drill-down list of twenty rows all reading "node_modules" tells the user nothing.
        XCTAssertEqual(
            DevJunkPaths.displayName(forPath: "/Users/tester/Code/MyApp/node_modules", category: .nodeModules),
            "MyApp/node_modules"
        )
        XCTAssertEqual(
            DevJunkPaths.displayName(
                forPath: "/Users/tester/Library/Developer/Xcode/DerivedData/App-abc",
                category: .xcodeDerivedData
            ),
            "App-abc"
        )
    }

    // MARK: - Category acceptance: the positive cases

    func testEachFixedCategoryAcceptsAKnownEntryUnderItsOwnRoot() {
        let cases: [(DevJunkCategoryID, String)] = [
            (.xcodeDerivedData, "~/Library/Developer/Xcode/DerivedData/MyApp-abcdefgh"),
            (.xcodeArchives, "~/Library/Developer/Xcode/Archives/2026-07-21"),
            (.deviceSupport, "~/Library/Developer/Xcode/iOS DeviceSupport/17.0 (21A342)"),
            (.simulatorCaches, "~/Library/Developer/CoreSimulator/Caches/dyld"),
            (.cocoaPodsCache, "~/Library/Caches/CocoaPods/Pods"),
            (.jvmCaches, "~/.gradle/caches/modules-2"),
            (.jvmCaches, "~/.m2/repository/org"),
            (.scriptingCaches, "~/.npm/_cacache"),
            (.scriptingCaches, "~/Library/Caches/pip/wheels"),
            (.homebrewCache, "~/Library/Caches/Homebrew/downloads"),
            (.dockerLeftovers, "~/Library/Containers/com.docker.docker/Data/log/host")
        ]

        for (category, path) in cases {
            XCTAssertTrue(
                category.accepts(path: path, home: home),
                "\(category.rawValue) should accept its own entry \(path)"
            )
        }
    }

    func testProjectCategoriesAcceptDirectoriesInsideTheProjectRoots() {
        XCTAssertTrue(DevJunkCategoryID.nodeModules.accepts(path: "~/Developer/MyApp/node_modules", home: home))
        XCTAssertTrue(DevJunkCategoryID.nodeModules.accepts(path: "~/Documents/work/site/node_modules", home: home))
        XCTAssertTrue(DevJunkCategoryID.swiftPackageBuilds.accepts(path: "~/Code/MyLib/.build", home: home))
    }

    // MARK: - Category acceptance: nothing outside its intended root

    /// Paths that are either the user's own work or something a toolchain cannot regenerate. If any
    /// category ever claims one of these, the feature deletes something it must not.
    private var sacredPaths: [String] {
        [
            // Source trees that sit right next to the junk.
            "~/Developer/MyApp",
            "~/Developer/MyApp/src",
            "~/Documents/Taxes",
            "~/Documents/MyApp/Sources/main.swift",
            "~/Desktop/screenshot.png",
            "~/Code/MyLib/Package.swift",
            // Look-alike names a substring match would happily eat.
            "~/Developer/node_modules_backup",
            "~/Developer/MyApp/node_modules.zip",
            "~/Developer/MyApp/.buildkite",
            // Xcode state that is not a cache.
            "~/Library/Developer/Xcode/UserData/FontAndColorThemes/Mine.xccolortheme",
            "~/Library/Developer/Xcode/Templates",
            "~/Library/Developer/Xcode/DerivedData",
            // Simulator devices hold installed apps and their data, not caches.
            "~/Library/Developer/CoreSimulator/Devices/8F0C-DEAD-BEEF",
            "~/Library/Developer/CoreSimulator/Devices",
            // Gradle distributions are pinned by checksum; Maven settings are configuration.
            "~/.gradle/wrapper/dists/gradle-8.5-bin",
            "~/.gradle/gradle.properties",
            "~/.m2/settings.xml",
            // npm/pip configuration and logs, not download caches.
            "~/.npmrc",
            "~/.npm/_logs",
            // A private CocoaPods spec repo is a git checkout that may not be re-clonable.
            "~/.cocoapods/repos/private-specs",
            // Installed Homebrew software, as opposed to the downloads that produced it.
            "/opt/homebrew/Cellar/git/2.44.0",
            "/usr/local/Cellar/git/2.44.0",
            // The Docker disk image holds every image, container and volume the user owns.
            "~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw",
            "~/Library/Containers/com.docker.docker/Data",
            // An installed application's own bundled dependencies. Electron apps ship
            // Contents/Resources/app/node_modules with a package.json beside it, so the sibling test
            // passes and only the bundle veto stands between the user and a broken application.
            "~/Desktop/Cursor.app/Contents/Resources/app/node_modules",
            "~/Documents/Visual Studio Code.app/Contents/Resources/app/node_modules",
            "~/Developer/Widget.framework/Versions/A/Resources/.build",
            // Traversal: textually inside a search root, resolving somewhere else entirely.
            "~/Documents/../.ssh/node_modules",
            "~/Documents/../../../etc/node_modules",
            "~/Developer/./MyApp/node_modules",
            // Unrelated user data and system files.
            "~/Library/Mail",
            "~/Library/Application Support/MobileSync/Backup",
            "~/.ssh/id_ed25519",
            "~/.Trash/MyApp/node_modules",
            "/System/Library/CoreServices",
            "/Applications/Xcode.app",
            "/",
            ""
        ]
    }

    func testNoCategoryAcceptsAnythingOutsideItsIntendedRoot() {
        for category in DevJunkCategoryID.allCases {
            for path in sacredPaths {
                XCTAssertFalse(
                    category.accepts(path: path, home: home),
                    "\(category.rawValue) must not accept \(path)"
                )
            }
        }
    }

    func testCategoriesDoNotPoachEachOthersEntries() {
        // Every category's own entry must be rejected by all the others, so a mis-tagged entry
        // cannot survive the pre-delete revalidation.
        let owned: [(DevJunkCategoryID, String)] = [
            (.xcodeDerivedData, "~/Library/Developer/Xcode/DerivedData/MyApp-abcdefgh"),
            (.xcodeArchives, "~/Library/Developer/Xcode/Archives/2026-07-21"),
            (.deviceSupport, "~/Library/Developer/Xcode/iOS DeviceSupport/17.0 (21A342)"),
            (.simulatorCaches, "~/Library/Developer/CoreSimulator/Caches/dyld"),
            (.nodeModules, "~/Developer/MyApp/node_modules"),
            (.swiftPackageBuilds, "~/Developer/MyLib/.build"),
            (.cocoaPodsCache, "~/Library/Caches/CocoaPods/Pods"),
            (.jvmCaches, "~/.gradle/caches/modules-2"),
            (.scriptingCaches, "~/.npm/_cacache"),
            (.homebrewCache, "~/Library/Caches/Homebrew/downloads"),
            (.dockerLeftovers, "~/Library/Containers/com.docker.docker/Data/log/host")
        ]

        for (owner, path) in owned {
            for category in DevJunkCategoryID.allCases where category != owner {
                XCTAssertFalse(
                    category.accepts(path: path, home: home),
                    "\(category.rawValue) must not claim \(owner.rawValue)'s entry \(path)"
                )
            }
        }
    }

    func testFixedCategoriesOnlyAcceptDirectChildrenNotDeeperPaths() {
        // Handing the remover a nested path would let it delete a fragment of a cache and leave
        // the toolchain with a half-populated directory.
        XCTAssertFalse(
            DevJunkCategoryID.xcodeDerivedData.accepts(
                path: "~/Library/Developer/Xcode/DerivedData/MyApp-abc/Build/Products",
                home: home
            )
        )
        XCTAssertFalse(
            DevJunkCategoryID.homebrewCache.accepts(path: "~/Library/Caches/Homebrew/downloads/abc.tar.gz", home: home)
        )
    }

    func testProjectCategoriesRejectMatchesOutsideTheSearchRoots() {
        // ~/Library is not a project root, and neither is an arbitrary volume.
        XCTAssertFalse(DevJunkCategoryID.nodeModules.accepts(path: "~/Library/Caches/thing/node_modules", home: home))
        XCTAssertFalse(DevJunkCategoryID.nodeModules.accepts(path: "/Volumes/Backup/MyApp/node_modules", home: home))
        XCTAssertFalse(DevJunkCategoryID.nodeModules.accepts(path: "~/node_modules", home: home))
        XCTAssertFalse(DevJunkCategoryID.swiftPackageBuilds.accepts(path: "/tmp/.build", home: home))
    }

    func testProjectCategoriesRejectNestedAndMisnamedDirectories() {
        // A node_modules inside another one is already covered by its ancestor.
        XCTAssertFalse(
            DevJunkCategoryID.nodeModules.accepts(path: "~/Developer/app/node_modules/dep/node_modules", home: home)
        )
        // ...and anything reached through a VCS or package store is off limits entirely.
        XCTAssertFalse(DevJunkCategoryID.nodeModules.accepts(path: "~/Developer/app/.git/node_modules", home: home))
        XCTAssertFalse(DevJunkCategoryID.swiftPackageBuilds.accepts(path: "~/Developer/app/Pods/.build", home: home))
        // The last component must match exactly, not merely start or end with the name.
        XCTAssertFalse(DevJunkCategoryID.nodeModules.accepts(path: "~/Developer/app/node_modules2", home: home))
        XCTAssertFalse(DevJunkCategoryID.swiftPackageBuilds.accepts(path: "~/Developer/app/build", home: home))
    }

    func testPruneNamesOnlyVetoComponentsBelowTheSearchRoot() {
        // A component of the *home directory* is not part of the user's project structure, so a
        // home that happens to sit under a folder named like a package store must not make every
        // project inside it unmatchable. Home directories on external volumes hit this.
        let awkwardHome = "/Volumes/Pods/tester"
        XCTAssertTrue(
            DevJunkCategoryID.nodeModules.accepts(path: "/Volumes/Pods/tester/Developer/App/node_modules", home: awkwardHome)
        )

        // Below the root the veto still applies.
        XCTAssertFalse(
            DevJunkCategoryID.nodeModules.accepts(path: "/Volumes/Pods/tester/Developer/Pods/App/node_modules", home: awkwardHome)
        )
    }

    // MARK: - Bundles

    func testBundleNamesAreRecognisedAndOrdinaryFoldersAreNot() {
        for name in ["Cursor.app", "Visual Studio Code.APP", "Widget.framework", "Thing.bundle", "Trip.photoslibrary"] {
            XCTAssertTrue(DevJunkPaths.isBundleName(name), "\(name) should read as a bundle")
        }

        for name in ["MyApp", "node_modules", "app", ".app", "notes.txt", "release.app.zip", "Package.swift"] {
            XCTAssertFalse(DevJunkPaths.isBundleName(name), "\(name) should not read as a bundle")
        }
    }

    func testProjectCategoriesRejectAnythingInsideABundle() {
        // The application's own dependencies sit beside a real package.json, so the sibling test
        // that keeps this feature conservative is no defence at all here — and unlike a project's
        // node_modules, this one cannot be restored by running npm install.
        XCTAssertFalse(
            DevJunkCategoryID.nodeModules.accepts(
                path: "~/Desktop/Cursor.app/Contents/Resources/app/node_modules",
                home: home
            )
        )
        XCTAssertFalse(
            DevJunkCategoryID.nodeModules.accepts(
                path: "~/Documents/Tools/Slack.APP/Contents/Resources/app/node_modules",
                home: home
            )
        )
        XCTAssertFalse(
            DevJunkCategoryID.swiftPackageBuilds.accepts(path: "~/Developer/Thing.bundle/Contents/.build", home: home)
        )
        XCTAssertFalse(
            DevJunkCategoryID.nodeModules.accepts(path: "~/Documents/Trip.photoslibrary/private/node_modules", home: home)
        )

        // A folder that merely has a dot in its name is still an ordinary project folder.
        XCTAssertTrue(DevJunkCategoryID.nodeModules.accepts(path: "~/Developer/my.site/node_modules", home: home))
    }

    func testScanLeavesAnApplicationsOwnDependenciesAlone() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(atPath: sandbox) }

        // Exactly the Electron layout, on the Desktop, where the walk's depth cap still reaches it:
        // Desktop/Cursor.app/Contents/Resources/app/node_modules is five levels below the root.
        let bundledApp = DevJunkPaths.joined(sandbox, "Desktop/Cursor.app/Contents/Resources/app")
        try writeFile(DevJunkPaths.joined(bundledApp, "package.json"))
        try writeFile(DevJunkPaths.joined(bundledApp, "node_modules/electron-log/index.js"))

        // A genuine project on the same Desktop still has to be found, or the veto is too wide.
        try writeFile(DevJunkPaths.joined(sandbox, "Desktop/Site/package.json"))
        try writeFile(DevJunkPaths.joined(sandbox, "Desktop/Site/node_modules/left-pad/index.js"))

        let entries = DevJunkScanner.entries(for: .nodeModules, home: sandbox)
        let paths = Set(entries.map(\.path))

        XCTAssertFalse(paths.contains(DevJunkPaths.joined(bundledApp, "node_modules")))
        XCTAssertTrue(paths.contains(DevJunkPaths.joined(sandbox, "Desktop/Site/node_modules")))

        // The pre-delete gate is the last line of defence, so it must refuse the bundled copy too
        // even if some future scanner change hands it over.
        XCTAssertFalse(
            DevJunkCategoryID.nodeModules.accepts(
                path: DevJunkPaths.joined(bundledApp, "node_modules"),
                home: sandbox
            )
        )
    }

    // MARK: - Path traversal

    func testAcceptsRejectsPathsContainingTraversalComponents() {
        // normalize() does not resolve "..", so containment is textual: without this rule
        // "~/Documents/../.ssh/node_modules" reads as living under the Documents search root while
        // resolving into ~/.ssh, and "../../../etc" escapes home entirely.
        XCTAssertFalse(DevJunkCategoryID.nodeModules.accepts(path: "/Users/tester/Documents/../.ssh/node_modules", home: home))
        XCTAssertFalse(
            DevJunkCategoryID.nodeModules.accepts(path: "/Users/tester/Documents/../../../etc/node_modules", home: home)
        )
        XCTAssertFalse(DevJunkCategoryID.swiftPackageBuilds.accepts(path: "/Users/tester/Code/../Library/.build", home: home))
        XCTAssertFalse(
            DevJunkCategoryID.xcodeDerivedData.accepts(
                path: "/Users/tester/Library/Developer/Xcode/DerivedData/../../../Mail",
                home: home
            )
        )
        // "." is harmless in itself but arrives from the same class of unnormalised input, and
        // accepting it would mean two spellings of one path disagree about eligibility.
        XCTAssertFalse(DevJunkCategoryID.nodeModules.accepts(path: "/Users/tester/Developer/./App/node_modules", home: home))
    }

    func testValidateRejectsATraversalPathBeforeItReachesTheRemover() {
        let forged = DevJunkEntry(
            category: .nodeModules,
            path: "/Users/tester/Documents/../.ssh/node_modules",
            size: 999
        )
        let genuine = DevJunkEntry(category: .nodeModules, path: "/Users/tester/Developer/App/node_modules", size: 10)

        let (allowed, rejected) = DevJunkRemover.validate([forged, genuine], home: home)

        XCTAssertEqual(allowed, [genuine])
        XCTAssertEqual(rejected, [forged])
    }

    func testEveryCategoryStaysInsideTheUsersHomeDirectory() {
        for category in DevJunkCategoryID.allCases {
            for root in category.allowedRoots(home: home) {
                XCTAssertTrue(
                    DevJunkPaths.isStrictDescendant(root, of: home),
                    "\(category.rawValue) declares a root outside home: \(root)"
                )
            }
        }
    }

    func testArchivesAreTheOnlyCategoryOffByDefault() {
        // Archives carry the dSYMs that make old crash reports readable, which is the one thing
        // here that does not come back.
        for category in DevJunkCategoryID.allCases {
            XCTAssertEqual(
                category.isSelectedByDefault,
                category != .xcodeArchives,
                "\(category.rawValue) default selection changed"
            )
        }
    }

    // MARK: - Selection

    private func report(_ category: DevJunkCategoryID, _ paths: [(String, UInt64)]) -> DevJunkCategoryReport {
        DevJunkCategoryReport(
            category: category,
            entries: paths.map { DevJunkEntry(category: category, path: $0.0, size: $0.1) }
        )
    }

    private var sampleReports: [DevJunkCategoryReport] {
        [
            report(.xcodeDerivedData, [
                ("/Users/tester/Library/Developer/Xcode/DerivedData/A-1", 100),
                ("/Users/tester/Library/Developer/Xcode/DerivedData/B-2", 200)
            ]),
            report(.xcodeArchives, [
                ("/Users/tester/Library/Developer/Xcode/Archives/2026-07-21", 500)
            ])
        ]
    }

    func testDefaultSelectionSkipsArchives() {
        let reports = sampleReports
        let selection = DevJunkSelection(defaultsFor: reports)

        XCTAssertEqual(selection.state(for: reports[0]), .all)
        XCTAssertEqual(selection.state(for: reports[1]), .none)
        XCTAssertEqual(selection.selectedBytes(in: reports), 300)
    }

    func testDeselectingOneEntryLeavesTheCategoryPartial() {
        let reports = sampleReports
        var selection = DevJunkSelection(defaultsFor: reports)

        selection.toggle(reports[0].entries[0])

        XCTAssertEqual(selection.state(for: reports[0]), .partial)
        XCTAssertEqual(selection.selectedBytes(in: reports), 200)
    }

    func testTogglingAPartialCategorySelectsAllOfIt() {
        // A half-checked box should be one click from full, not one click from empty.
        let reports = sampleReports
        var selection = DevJunkSelection(defaultsFor: reports)
        selection.toggle(reports[0].entries[0])

        selection.toggle(reports[0])

        XCTAssertEqual(selection.state(for: reports[0]), .all)

        selection.toggle(reports[0])
        XCTAssertEqual(selection.state(for: reports[0]), .none)
    }

    func testEmptyCategoryReadsAsUnselected() {
        let empty = report(.nodeModules, [])
        let selection = DevJunkSelection(defaultsFor: [empty])

        XCTAssertEqual(selection.state(for: empty), .none)
    }

    func testReconcileDropsPathsTheLatestScanNoLongerReports() {
        let reports = sampleReports
        var selection = DevJunkSelection(defaultsFor: reports)

        let shrunk = [report(.xcodeDerivedData, [("/Users/tester/Library/Developer/Xcode/DerivedData/A-1", 100)])]
        selection.reconcile(with: shrunk)

        XCTAssertEqual(selection.selectedBytes(in: shrunk), 100)
        // The vanished path must not come back if the same report is offered again.
        XCTAssertEqual(selection.selectedBytes(in: reports), 100)
    }

    // MARK: - Removal safety

    func testValidateRejectsAnEntryPointingOutsideItsCategory() {
        // Entries survive across rescans and across the confirmation alert, so the remover
        // re-checks every one rather than trusting that nothing moved in between.
        let forged = DevJunkEntry(category: .nodeModules, path: "/Users/tester/Documents/Taxes", size: 999)
        let genuine = DevJunkEntry(category: .nodeModules, path: "/Users/tester/Developer/App/node_modules", size: 10)

        let (allowed, rejected) = DevJunkRemover.validate([forged, genuine], home: home)

        XCTAssertEqual(allowed, [genuine])
        XCTAssertEqual(rejected, [forged])
    }

    func testConfirmationMessageNamesTheCountAndTotal() {
        let entries = [
            DevJunkEntry(category: .nodeModules, path: "/Users/tester/Developer/A/node_modules", size: 1_000_000),
            DevJunkEntry(category: .nodeModules, path: "/Users/tester/Developer/B/node_modules", size: 2_000_000)
        ]

        let message = DevJunkRemover.confirmationMessage(for: entries)

        XCTAssertTrue(message.contains("2 items"), message)
        XCTAssertTrue(message.contains(UInt64(3_000_000).diskBytesString), message)
    }

    func testTrashStreamLeavesARejectedPathOnDisk() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(atPath: sandbox) }

        let sourceDirectory = DevJunkPaths.joined(sandbox, "Documents/Taxes")
        try FileManager.default.createDirectory(atPath: sourceDirectory, withIntermediateDirectories: true)
        let forged = DevJunkEntry(category: .nodeModules, path: sourceDirectory, size: 1)

        var result = DevJunkRemovalResult(trashedBytes: 0, trashedCount: 0, failures: [])
        for await event in DevJunkRemover.trashStream(entries: [forged], home: sandbox) {
            if case let .finished(finished) = event {
                result = finished
            }
        }

        XCTAssertEqual(result.trashedCount, 0)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceDirectory))
    }

    // MARK: - Scanning a real directory tree

    private func makeSandbox() throws -> String {
        let root = DevJunkPaths.joined(NSTemporaryDirectory(), "DevJunkTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return DevJunkPaths.normalize(root)
    }

    private func writeFile(_ path: String, bytes: Int = 4_096) throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let data = Data(repeating: 0x41, count: bytes)
        try data.write(to: URL(fileURLWithPath: path))
    }

    /// Builds a home directory holding one of everything: a real npm project, a real SwiftPM
    /// package, a real DerivedData entry, and three decoys that a sloppier matcher would eat.
    private func populateSandbox(_ home: String) throws {
        try writeFile(DevJunkPaths.joined(home, "Developer/MyApp/package.json"))
        try writeFile(DevJunkPaths.joined(home, "Developer/MyApp/node_modules/left-pad/index.js"))
        try writeFile(DevJunkPaths.joined(home, "Developer/MyApp/src/main.js"))

        try writeFile(DevJunkPaths.joined(home, "Developer/MyLib/Package.swift"))
        try writeFile(DevJunkPaths.joined(home, "Developer/MyLib/.build/debug/MyLib.o"))
        try writeFile(DevJunkPaths.joined(home, "Developer/MyLib/Sources/MyLib/MyLib.swift"))

        // Decoy 1: a folder named node_modules with no package.json beside it.
        try writeFile(DevJunkPaths.joined(home, "Developer/Notes/node_modules/reading-list.md"))
        // Decoy 2: a look-alike name.
        try writeFile(DevJunkPaths.joined(home, "Developer/node_modules_backup/archive.tar"))
        // Decoy 3: a .build belonging to something that is not a SwiftPM package.
        try writeFile(DevJunkPaths.joined(home, "Developer/Website/.build/output.css"))

        try writeFile(DevJunkPaths.joined(home, "Library/Developer/Xcode/DerivedData/MyApp-abc/Build/MyApp.o"))
        try writeFile(DevJunkPaths.joined(home, "Library/Developer/Xcode/UserData/FontAndColorThemes/Mine.xccolortheme"))
    }

    private func scan(home: String) async -> [DevJunkCategoryReport] {
        var reports: [DevJunkCategoryReport] = []
        for await event in DevJunkScanner.scanStream(home: home) {
            if case let .finished(finished) = event {
                reports = finished
            }
        }
        return reports
    }

    func testScanFindsRealProjectJunkAndIgnoresTheDecoys() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(atPath: sandbox) }
        try populateSandbox(sandbox)

        let reports = await scan(home: sandbox)
        let paths = Set(reports.flatMap(\.entries).map(\.path))

        XCTAssertTrue(paths.contains(DevJunkPaths.joined(sandbox, "Developer/MyApp/node_modules")))
        XCTAssertTrue(paths.contains(DevJunkPaths.joined(sandbox, "Developer/MyLib/.build")))
        XCTAssertTrue(paths.contains(DevJunkPaths.joined(sandbox, "Library/Developer/Xcode/DerivedData/MyApp-abc")))

        XCTAssertFalse(paths.contains(DevJunkPaths.joined(sandbox, "Developer/Notes/node_modules")))
        XCTAssertFalse(paths.contains(DevJunkPaths.joined(sandbox, "Developer/node_modules_backup")))
        XCTAssertFalse(paths.contains(DevJunkPaths.joined(sandbox, "Developer/Website/.build")))
    }

    func testScanNeverListsAPathOutsideSomeCategoryRoot() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(atPath: sandbox) }
        try populateSandbox(sandbox)

        let reports = await scan(home: sandbox)

        for report in reports {
            for entry in report.entries {
                XCTAssertEqual(entry.category, report.category)
                XCTAssertTrue(
                    entry.category.accepts(path: entry.path, home: sandbox),
                    "scan produced \(entry.path) which its own category rejects"
                )
                XCTAssertTrue(
                    entry.category.allowedRoots(home: sandbox).contains {
                        DevJunkPaths.isDescendantOrSelf(entry.path, of: $0)
                    },
                    "scan produced \(entry.path) outside \(entry.category.rawValue)'s roots"
                )
            }
        }

        // The source trees and Xcode's user settings must not appear anywhere in the results.
        let paths = Set(reports.flatMap(\.entries).map(\.path))
        for survivor in [
            "Developer/MyApp/src",
            "Developer/MyLib/Sources",
            "Library/Developer/Xcode/UserData"
        ] {
            XCTAssertFalse(paths.contains(DevJunkPaths.joined(sandbox, survivor)), survivor)
        }
    }

    func testScanReportsEveryCategoryAndSizesWhatItFinds() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(atPath: sandbox) }
        try populateSandbox(sandbox)

        let reports = await scan(home: sandbox)

        XCTAssertEqual(reports.map(\.category), DevJunkCategoryID.allCases)

        let nodeModules = try XCTUnwrap(reports.first { $0.category == .nodeModules })
        XCTAssertEqual(nodeModules.entries.count, 1)
        XCTAssertGreaterThan(nodeModules.totalSize, 0)
        XCTAssertEqual(nodeModules.entries[0].displayName, "MyApp/node_modules")
    }

    func testScanStreamStopsWhenTheConsumerWalksAway() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(atPath: sandbox) }
        try populateSandbox(sandbox)

        // Breaking out of the loop terminates the stream, which must cancel the producing task
        // rather than leaving it walking node_modules for a panel that is already closed.
        var seen = 0
        for await _ in DevJunkScanner.scanStream(home: sandbox) {
            seen += 1
            break
        }

        XCTAssertEqual(seen, 1)
    }

    func testEntriesForCategoryAreOrderedLargestFirst() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(atPath: sandbox) }

        let derivedData = DevJunkPaths.joined(sandbox, "Library/Developer/Xcode/DerivedData")
        try writeFile(DevJunkPaths.joined(derivedData, "Small-1/a.o"), bytes: 1_024)
        try writeFile(DevJunkPaths.joined(derivedData, "Large-2/a.o"), bytes: 512 * 1_024)

        let entries = DevJunkScanner.entries(for: .xcodeDerivedData, home: sandbox)

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].displayName, "Large-2")
        XCTAssertGreaterThan(entries[0].size, entries[1].size)
    }
}
