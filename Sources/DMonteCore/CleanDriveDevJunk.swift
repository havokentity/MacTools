import Foundation

/// The developer-detritus categories Clean Drive can reclaim. These are deliberately kept apart
/// from `CleanDriveCategoryID`: the system categories sweep whole well-known cache roots, whereas
/// developer junk is enumerated entry by entry so the user can drill in and keep individual
/// projects. Every category here regenerates — the worst case for deleting one is a rebuild or a
/// re-download, never lost work — which is the bar a category must clear to be listed at all.
public enum DevJunkCategoryID: String, CaseIterable, Identifiable, Sendable {
    case xcodeDerivedData
    case xcodeArchives
    case deviceSupport
    case simulatorCaches
    case nodeModules
    case swiftPackageBuilds
    case cocoaPodsCache
    case jvmCaches
    case scriptingCaches
    case homebrewCache
    case dockerLeftovers

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .xcodeDerivedData: "Xcode DerivedData"
        case .xcodeArchives: "Xcode Archives"
        case .deviceSupport: "Device Support"
        case .simulatorCaches: "Simulator caches"
        case .nodeModules: "node_modules"
        case .swiftPackageBuilds: "SwiftPM .build"
        case .cocoaPodsCache: "CocoaPods cache"
        case .jvmCaches: "Gradle / Maven caches"
        case .scriptingCaches: "pip / npm / yarn caches"
        case .homebrewCache: "Homebrew cache"
        case .dockerLeftovers: "Docker leftovers"
        }
    }

    /// The honest one-liner shown under the title. It always says what it costs to delete the
    /// entries, because "reclaimable" is not the same as "free" — a node_modules tree costs an
    /// `npm install` to get back, and on a slow connection that is a real price.
    public var detail: String {
        switch self {
        case .xcodeDerivedData:
            "Build intermediates and indexes. Xcode rebuilds them on the next build."
        case .xcodeArchives:
            "Shipped-build archives with their dSYMs. Deleting them means old crash reports can no longer be symbolicated."
        case .deviceSupport:
            "Symbols copied from devices you have attached. Re-copied the next time you plug the device in."
        case .simulatorCaches:
            "Simulator caches and logs. Simulator devices and their installed apps are never touched."
        case .nodeModules:
            "Installed npm dependencies. Restored by running npm install again in that project."
        case .swiftPackageBuilds:
            "SwiftPM build products and checkouts. Restored by the next swift build."
        case .cocoaPodsCache:
            "Downloaded pod archives. Re-fetched by the next pod install."
        case .jvmCaches:
            "Downloaded Gradle and Maven artifacts. Re-fetched by the next build."
        case .scriptingCaches:
            "Download caches for pip, npm and yarn. Installed packages are not touched."
        case .homebrewCache:
            "Downloaded bottles and installers. Installed formulae are not touched."
        case .dockerLeftovers:
            "Docker Desktop logs. Images, containers and volumes are never touched."
        }
    }

    /// Archives are the one category that loses something you cannot regenerate — the dSYMs that
    /// make an old crash report readable — so it starts unchecked even though it is usually the
    /// biggest single win on a shipping developer's disk.
    public var isSelectedByDefault: Bool {
        self != .xcodeArchives
    }

    /// Fixed, well-known directories owned by a toolchain. Nothing is inferred here: if a path is
    /// not spelled out in this table it can never be listed, let alone deleted.
    var fixedTargets: [DevJunkTarget] {
        switch self {
        case .xcodeDerivedData:
            [DevJunkTarget("~/Library/Developer/Xcode/DerivedData", granularity: .children)]
        case .xcodeArchives:
            [DevJunkTarget("~/Library/Developer/Xcode/Archives", granularity: .children)]
        case .deviceSupport:
            [
                DevJunkTarget("~/Library/Developer/Xcode/iOS DeviceSupport", granularity: .children),
                DevJunkTarget("~/Library/Developer/Xcode/watchOS DeviceSupport", granularity: .children),
                DevJunkTarget("~/Library/Developer/Xcode/tvOS DeviceSupport", granularity: .children),
                DevJunkTarget("~/Library/Developer/Xcode/visionOS DeviceSupport", granularity: .children)
            ]
        case .simulatorCaches:
            // Deliberately excludes ~/Library/Developer/CoreSimulator/Devices: those are the
            // simulators themselves, complete with installed apps and their data, and wiping
            // them is a destructive act rather than a cache eviction.
            [
                DevJunkTarget("~/Library/Developer/CoreSimulator/Caches", granularity: .children),
                DevJunkTarget("~/Library/Logs/CoreSimulator", granularity: .children)
            ]
        case .nodeModules, .swiftPackageBuilds:
            []
        case .cocoaPodsCache:
            // ~/.cocoapods/repos is left alone on purpose: it is a git checkout the user may have
            // pointed at a private spec repo, and re-cloning it is neither cheap nor always possible.
            [DevJunkTarget("~/Library/Caches/CocoaPods", granularity: .children)]
        case .jvmCaches:
            // ~/.gradle/wrapper holds the Gradle distributions a project pins by checksum, and
            // ~/.m2 outside repository/ holds settings.xml, so both stay out of range.
            [
                DevJunkTarget("~/.gradle/caches", granularity: .children),
                DevJunkTarget("~/.m2/repository", granularity: .children)
            ]
        case .scriptingCaches:
            [
                DevJunkTarget("~/Library/Caches/pip", granularity: .children),
                DevJunkTarget("~/.cache/pip", granularity: .children),
                DevJunkTarget("~/.npm/_cacache", granularity: .wholeDirectory),
                DevJunkTarget("~/Library/Caches/Yarn", granularity: .children),
                DevJunkTarget("~/.cache/yarn", granularity: .children),
                DevJunkTarget("~/.yarn/berry/cache", granularity: .wholeDirectory)
            ]
        case .homebrewCache:
            [
                DevJunkTarget("~/Library/Caches/Homebrew", granularity: .children)
            ]
        case .dockerLeftovers:
            // Only logs. The Docker.raw disk image under Data/vms holds every image, container and
            // volume the user has, so the container root is never a target — only its log folder.
            [
                DevJunkTarget("~/Library/Containers/com.docker.docker/Data/log", granularity: .children),
                DevJunkTarget("~/Library/Group Containers/group.com.docker/log", granularity: .children)
            ]
        }
    }

    /// Set for the two categories that live in the user's own project folders rather than at a
    /// fixed path, and therefore have to be found by walking. Nothing is matched on name alone —
    /// see `DevJunkProjectScan.requiredSibling`.
    var projectScan: DevJunkProjectScan? {
        switch self {
        case .nodeModules:
            DevJunkProjectScan(directoryName: "node_modules", requiredSibling: "package.json")
        case .swiftPackageBuilds:
            DevJunkProjectScan(directoryName: ".build", requiredSibling: "Package.swift")
        default:
            nil
        }
    }

    /// Every directory tree this category is allowed to touch, expanded against `home`. A path
    /// that is not inside one of these can never belong to the category, whatever it is named.
    public func allowedRoots(home: String) -> [String] {
        if projectScan != nil {
            return DevJunkPaths.projectSearchRoots(home: home)
        }

        return fixedTargets.map { DevJunkPaths.expand($0.path, home: home) }
    }

    /// The single gate every candidate must pass before it can be listed in the UI or handed to
    /// the remover. It is intentionally the *only* way a path becomes eligible, and it is applied
    /// twice: once when the scanner discovers the path and again immediately before deletion, so a
    /// stale entry from a previous scan cannot be used to delete something that is now a source
    /// directory.
    public func accepts(path: String, home: String) -> Bool {
        let normalized = DevJunkPaths.normalize(DevJunkPaths.expand(path, home: home))
        let components = DevJunkPaths.components(normalized)

        guard !components.isEmpty else {
            return false
        }

        // `normalize` deliberately does not resolve ".." — it is a pure function and must not touch
        // the filesystem — so containment here is purely textual. That makes
        // "~/Documents/../.ssh/node_modules" look like it lives under a search root when it resolves
        // somewhere else entirely. Rather than teach the helpers to resolve traversal, refuse the
        // syntax: the scanner never produces it, so the only paths it can rule out are forged ones.
        guard !components.contains(where: { $0 == "." || $0 == ".." }) else {
            return false
        }

        // Nothing under a denied root is eligible unless this category's own target table spells
        // the path out. The Xcode and CoreSimulator caches genuinely live inside ~/Library, but a
        // directory merely *discovered* by walking never may. This is the backstop, not the
        // primary check: the granularity rules below still have to agree.
        let isUnderOwnTarget = fixedTargets.contains { target in
            DevJunkPaths.isDescendantOrSelf(normalized, of: DevJunkPaths.expand(target.path, home: home))
        }
        if !isUnderOwnTarget,
           DevJunkPaths.deniedRoots(home: home).contains(where: { DevJunkPaths.isDescendantOrSelf(normalized, of: $0) }) {
            return false
        }

        if let scan = projectScan {
            guard components.last == scan.directoryName else {
                return false
            }

            guard let root = DevJunkPaths.projectSearchRoots(home: home).first(
                where: { DevJunkPaths.isStrictDescendant(normalized, of: $0) }
            ) else {
                return false
            }

            // A node_modules inside another node_modules (or inside a .build, or a stray copy in a
            // .git object store) is already covered by its ancestor and must not be listed twice.
            // A node_modules inside a bundle is worse than redundant: Electron applications ship
            // their dependencies at Contents/Resources/app/node_modules with a package.json beside
            // them, so the sibling test passes and trashing it breaks an installed application that
            // no `npm install` can repair. Only the components below the search root are examined:
            // the components of the home directory itself are not the user's project structure and
            // must not veto a match.
            let ancestors = components.dropLast().dropFirst(DevJunkPaths.components(root).count)
            return !ancestors.contains {
                DevJunkPaths.prunedDirectoryNames.contains($0) || DevJunkPaths.isBundleName($0)
            }
        }

        return fixedTargets.contains { target in
            let root = DevJunkPaths.expand(target.path, home: home)
            return switch target.granularity {
            case .children:
                // Only the direct children of the root are entries; the root itself stays put so
                // the toolchain does not have to recreate it.
                DevJunkPaths.isDirectChild(normalized, of: root)
            case .wholeDirectory:
                DevJunkPaths.normalize(root) == normalized
            }
        }
    }
}

/// A fixed directory a category owns, plus whether the entries are the directory itself or its
/// immediate children. Children give the user something to drill into; `wholeDirectory` is for
/// caches whose internals are opaque hash buckets that nobody can meaningfully choose between.
struct DevJunkTarget: Sendable, Equatable {
    enum Granularity: Sendable, Equatable {
        case wholeDirectory
        case children
    }

    var path: String
    var granularity: Granularity

    init(_ path: String, granularity: Granularity) {
        self.path = path
        self.granularity = granularity
    }
}

/// How a category that lives in the user's own project folders is discovered. The required sibling
/// is what keeps this conservative: a directory called `node_modules` only counts when its parent
/// also contains a `package.json`, so a folder someone named `node_modules` to hold notes about npm
/// is never touched, and neither is a `.build` directory belonging to a build system that is not
/// SwiftPM.
struct DevJunkProjectScan: Sendable, Equatable {
    var directoryName: String
    var requiredSibling: String
    /// How deep below a search root a project may sit. Four levels covers
    /// ~/Developer/org/repo/package/node_modules without walking an entire home directory.
    var maximumDepth: Int = 4
}

public enum DevJunkPaths {
    /// Directory names the project walk refuses to descend into and refuses to accept as an
    /// ancestor of a match. Package stores and VCS stores can contain anything, including copies
    /// of the very directories being looked for.
    static let prunedDirectoryNames: Set<String> = [
        "node_modules",
        ".build",
        ".git",
        "Pods",
        "Carthage",
        "DerivedData",
        "Library",
        ".Trash"
    ]

    /// Extensions that make a directory a bundle — something macOS presents, and the user thinks
    /// of, as a single opaque item rather than a folder to walk into. The list is deliberately wider
    /// than "applications": an Electron app keeps its dependencies at
    /// Contents/Resources/app/node_modules complete with a package.json, a plug-in or framework can
    /// carry the same, and a photo or Final Cut library is user data that must never be walked at
    /// all. Everything inside one of these is installed or authored content, never project state, so
    /// deleting a piece of it breaks the item and no package manager can put it back.
    static let bundleExtensions: Set<String> = [
        "app",
        "appex",
        "framework",
        "bundle",
        "plugin",
        "xpc",
        "kext",
        "dext",
        "systemextension",
        "prefpane",
        "qlgenerator",
        "mdimporter",
        "component",
        "vst",
        "vst3",
        "audiounit",
        "docset",
        "photoslibrary",
        "photolibrary",
        "musiclibrary",
        "tvlibrary",
        "imovielibrary",
        "fcpbundle",
        "logicx",
        "band",
        "sparsebundle",
        "rtfd"
    ]

    /// True when a single path component names a bundle. Matching is case-insensitive because the
    /// boot volume is, so "Foo.APP" is the same directory as "Foo.app". A leading dot does not
    /// count: ".app" is an ordinary hidden folder, not an application.
    static func isBundleName(_ component: String) -> Bool {
        guard let dot = component.lastIndex(of: "."), dot != component.startIndex else {
            return false
        }

        return bundleExtensions.contains(component[component.index(after: dot)...].lowercased())
    }

    /// The only places a project-scanned category is allowed to look. Home itself is not on the
    /// list: walking all of ~ would be slow and would sweep in ~/Library, and a project sitting
    /// loose in the home directory is rare enough not to justify either cost.
    public static func projectSearchRoots(home: String) -> [String] {
        [
            "Developer",
            "Projects",
            "Documents",
            "Desktop",
            "Code",
            "src",
            "dev",
            "git",
            "repos",
            "workspace",
            "Sites"
        ].map { normalize(joined(home, $0)) }
    }

    /// Trees that are off limits regardless of what a category asks for. These are either the
    /// user's data, the system's own files, or somewhere a delete would be actively harmful.
    public static func deniedRoots(home: String) -> [String] {
        [
            normalize(joined(home, "Library")),
            normalize(joined(home, ".Trash")),
            "/System",
            "/Library",
            "/usr",
            "/bin",
            "/sbin",
            "/opt",
            "/Applications"
        ]
    }

    public static func expand(_ path: String, home: String) -> String {
        guard path.hasPrefix("~") else {
            return path
        }

        if path == "~" {
            return home
        }

        guard path.hasPrefix("~/") else {
            // A "~otheruser" style path is not ours to expand, so leave it exactly as given and
            // let the containment checks reject it.
            return path
        }

        return joined(home, String(path.dropFirst(2)))
    }

    /// Collapses repeated and trailing separators so that "/a//b/" and "/a/b" compare equal.
    /// Deliberately does not resolve symlinks or "..": the scanner never produces such paths, and
    /// resolving them would mean touching the filesystem from what must stay a pure function.
    public static func normalize(_ path: String) -> String {
        let parts = components(path)
        guard !parts.isEmpty else {
            return path.hasPrefix("/") ? "/" : ""
        }

        let prefix = path.hasPrefix("/") ? "/" : ""
        return prefix + parts.joined(separator: "/")
    }

    public static func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// Component-wise containment. A plain string prefix test would say that
    /// "~/Documents/MyApp-backup" lives inside "~/Documents/MyApp", which is exactly the class of
    /// bug that would make this feature delete someone's source tree.
    public static func isStrictDescendant(_ path: String, of ancestor: String) -> Bool {
        let pathComponents = components(path)
        let ancestorComponents = components(ancestor)

        guard pathComponents.count > ancestorComponents.count else {
            return false
        }

        return Array(pathComponents.prefix(ancestorComponents.count)) == ancestorComponents
    }

    public static func isDescendantOrSelf(_ path: String, of ancestor: String) -> Bool {
        components(path) == components(ancestor) || isStrictDescendant(path, of: ancestor)
    }

    public static func isDirectChild(_ path: String, of parent: String) -> Bool {
        components(path).count == components(parent).count + 1 && isStrictDescendant(path, of: parent)
    }

    static func joined(_ base: String, _ component: String) -> String {
        base.hasSuffix("/") ? base + component : base + "/" + component
    }

    /// The label shown in the drill-down list. Fixed-root entries are identified by their own
    /// name; a project entry is named after the project that owns it, because a list of twenty
    /// rows all reading "node_modules" tells the user nothing.
    public static func displayName(forPath path: String, category: DevJunkCategoryID) -> String {
        let parts = components(path)
        guard let last = parts.last else {
            return path
        }

        guard category.projectScan != nil, parts.count >= 2 else {
            return last
        }

        return parts[parts.count - 2] + "/" + last
    }

    /// The tilde-abbreviated path shown as the row's tooltip, so the user can always see exactly
    /// which directory a row would delete.
    public static func abbreviate(_ path: String, home: String) -> String {
        guard isDescendantOrSelf(normalize(path), of: normalize(home)) else {
            return path
        }

        let suffix = components(path).dropFirst(components(home).count)
        return suffix.isEmpty ? "~" : "~/" + suffix.joined(separator: "/")
    }
}

// MARK: - Scan results

public struct DevJunkEntry: Identifiable, Sendable, Equatable, Hashable {
    public var category: DevJunkCategoryID
    public var path: String
    public var size: UInt64

    public var id: String { path }

    public init(category: DevJunkCategoryID, path: String, size: UInt64) {
        self.category = category
        self.path = path
        self.size = size
    }

    public var displayName: String {
        DevJunkPaths.displayName(forPath: path, category: category)
    }
}

public struct DevJunkCategoryReport: Identifiable, Sendable, Equatable {
    public var category: DevJunkCategoryID
    public var entries: [DevJunkEntry]

    public var id: DevJunkCategoryID { category }

    public init(category: DevJunkCategoryID, entries: [DevJunkEntry]) {
        self.category = category
        self.entries = entries
    }

    public var totalSize: UInt64 {
        entries.reduce(UInt64(0)) { $0 &+ $1.size }
    }
}

// MARK: - Selection

public enum DevJunkSelectionState: Sendable, Equatable {
    case none
    case partial
    case all
}

/// Tracks which individual entries are checked. Selection is stored per entry path rather than per
/// category so that drilling into a category and unchecking one project survives the category-level
/// checkbox continuing to read "partial" — and so a rescan can drop entries that no longer exist
/// without silently carrying a stale path into a delete.
public struct DevJunkSelection: Sendable, Equatable {
    private var selectedPaths: Set<String>

    public init() {
        selectedPaths = []
    }

    /// Seeds the selection from the categories' defaults. Every entry of a default-on category
    /// starts checked; Archives, which can lose symbolication, starts unchecked.
    public init(defaultsFor reports: [DevJunkCategoryReport]) {
        selectedPaths = Set(
            reports
                .filter(\.category.isSelectedByDefault)
                .flatMap(\.entries)
                .map(\.path)
        )
    }

    public func isSelected(_ entry: DevJunkEntry) -> Bool {
        selectedPaths.contains(entry.path)
    }

    public func state(for report: DevJunkCategoryReport) -> DevJunkSelectionState {
        guard !report.entries.isEmpty else {
            return .none
        }

        let selected = report.entries.filter { selectedPaths.contains($0.path) }.count
        if selected == 0 {
            return .none
        }
        return selected == report.entries.count ? .all : .partial
    }

    public mutating func toggle(_ entry: DevJunkEntry) {
        if selectedPaths.contains(entry.path) {
            selectedPaths.remove(entry.path)
        } else {
            selectedPaths.insert(entry.path)
        }
    }

    /// Toggling a category checkbox is "select all" unless everything is already selected, which
    /// makes the half-checked state a single click away from full rather than from empty.
    public mutating func toggle(_ report: DevJunkCategoryReport) {
        setCategory(report, selected: state(for: report) != .all)
    }

    public mutating func setCategory(_ report: DevJunkCategoryReport, selected: Bool) {
        for entry in report.entries {
            if selected {
                selectedPaths.insert(entry.path)
            } else {
                selectedPaths.remove(entry.path)
            }
        }
    }

    /// Applies one freshly scanned category's default. Categories land one at a time as a scan
    /// streams them in, so the defaults have to be seeded per category rather than in a single pass
    /// at the end; seeding every category of a scan this way is equivalent to `init(defaultsFor:)`.
    ///
    /// Only ever correct for a *fresh* scan. A default-on category is seeded wholesale, so applying
    /// this during a rescan would re-tick the entries the user had deliberately unchecked.
    public mutating func seedDefaults(for report: DevJunkCategoryReport) {
        guard report.category.isSelectedByDefault else {
            return
        }
        setCategory(report, selected: true)
    }

    /// Drops paths that the latest scan no longer reports. Without this, a path deleted in a
    /// previous pass (or one that the user removed in Finder) would stay checked forever and keep
    /// inflating the "will free" total.
    public mutating func reconcile(with reports: [DevJunkCategoryReport]) {
        let live = Set(reports.flatMap(\.entries).map(\.path))
        selectedPaths.formIntersection(live)
    }

    public func selectedEntries(in reports: [DevJunkCategoryReport]) -> [DevJunkEntry] {
        reports.flatMap(\.entries).filter { selectedPaths.contains($0.path) }
    }

    public func selectedBytes(in reports: [DevJunkCategoryReport]) -> UInt64 {
        selectedEntries(in: reports).reduce(UInt64(0)) { $0 &+ $1.size }
    }
}

// MARK: - Removal

public struct DevJunkRemovalFailure: Sendable, Equatable {
    public var path: String
    public var reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

public struct DevJunkRemovalResult: Sendable, Equatable {
    public var trashedBytes: UInt64
    public var trashedCount: Int
    public var failures: [DevJunkRemovalFailure]

    public init(trashedBytes: UInt64, trashedCount: Int, failures: [DevJunkRemovalFailure]) {
        self.trashedBytes = trashedBytes
        self.trashedCount = trashedCount
        self.failures = failures
    }
}

public enum DevJunkRemovalEvent: Sendable {
    case progress(trashedBytes: UInt64, currentPath: String)
    case finished(DevJunkRemovalResult)
}

public enum DevJunkRemover {
    /// Re-runs every entry through its category's gate. The UI already only offers what the scanner
    /// found, but the entries survive across rescans and across the confirmation alert, and a delete
    /// is not the place to trust that nothing moved in between.
    public static func validate(
        _ entries: [DevJunkEntry],
        home: String
    ) -> (allowed: [DevJunkEntry], rejected: [DevJunkEntry]) {
        var allowed: [DevJunkEntry] = []
        var rejected: [DevJunkEntry] = []

        for entry in entries {
            if entry.category.accepts(path: entry.path, home: home) {
                allowed.append(entry)
            } else {
                rejected.append(entry)
            }
        }

        return (allowed, rejected)
    }

    /// The text of the confirmation the user has to accept before anything moves. It names the
    /// count and the total so a mis-click on "select all" is visible before it is irreversible.
    public static func confirmationMessage(for entries: [DevJunkEntry]) -> String {
        let bytes = entries.reduce(UInt64(0)) { $0 &+ $1.size }
        let noun = entries.count == 1 ? "item" : "items"
        return "Move \(entries.count) \(noun) (\(bytes.diskBytesString)) to the Trash?"
    }

    /// Moves the validated entries to the Trash one at a time, streaming progress. The Trash is
    /// used rather than an outright delete because these are the user's project folders: if the
    /// heuristics ever get something wrong, the mistake has to be undoable. Space is therefore not
    /// reclaimed until the Trash is emptied, which the UI says out loud.
    public static func trashStream(entries: [DevJunkEntry], home: String) -> AsyncStream<DevJunkRemovalEvent> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let (allowed, rejected) = validate(entries, home: home)
                var trashedBytes: UInt64 = 0
                var trashedCount = 0
                var failures = rejected.map {
                    DevJunkRemovalFailure(path: $0.path, reason: "No longer matches a developer-junk category")
                }

                for entry in allowed {
                    if Task.isCancelled {
                        break
                    }

                    let url = URL(fileURLWithPath: entry.path)
                    guard FileManager.default.fileExists(atPath: entry.path) else {
                        // Already gone (a previous pass, or the user's own cleanup). Not a failure
                        // worth reporting, but it must not count toward the reclaimed total.
                        continue
                    }

                    do {
                        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                        trashedBytes &+= entry.size
                        trashedCount += 1
                        continuation.yield(.progress(trashedBytes: trashedBytes, currentPath: entry.path))
                    } catch {
                        failures.append(
                            DevJunkRemovalFailure(path: entry.path, reason: (error as NSError).localizedDescription)
                        )
                    }
                }

                continuation.yield(
                    .finished(
                        DevJunkRemovalResult(trashedBytes: trashedBytes, trashedCount: trashedCount, failures: failures)
                    )
                )
                continuation.finish()
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Scanning

public enum DevJunkScanEvent: Sendable {
    /// Fraction of the categories finished, plus the label of the one being worked on, so the UI
    /// can show honest progress without knowing anything about the filesystem.
    case progress(fraction: Double, label: String)
    case category(DevJunkCategoryReport)
    case finished([DevJunkCategoryReport])
}

/// A path the scanner has found but not yet vetted. `knownSize` is only meaningful for files,
/// whose size the bulk directory read already produced.
private struct DevJunkCandidate: Sendable {
    var path: String
    var isDirectory: Bool
    var knownSize: UInt64
}

public enum DevJunkScanner {
    /// Walks every category off the main actor, emitting each finished category as it lands so the
    /// list fills in progressively instead of staying empty until the slowest tree (invariably
    /// node_modules) is done. Cancellation is cooperative and checked between directories, so
    /// closing the panel mid-scan stops the walk rather than leaving it churning.
    public static func scanStream(home: String = NSHomeDirectory()) -> AsyncStream<DevJunkScanEvent> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                var reports: [DevJunkCategoryReport] = []
                let categories = DevJunkCategoryID.allCases

                for (index, category) in categories.enumerated() {
                    if Task.isCancelled {
                        break
                    }

                    continuation.yield(
                        .progress(fraction: Double(index) / Double(categories.count), label: category.title)
                    )

                    let report = DevJunkCategoryReport(
                        category: category,
                        entries: entries(for: category, home: home)
                    )
                    reports.append(report)
                    continuation.yield(.category(report))
                }

                if !Task.isCancelled {
                    continuation.yield(.progress(fraction: 1, label: ""))
                    continuation.yield(.finished(reports))
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Discovers and sizes one category. Every candidate goes through `category.accepts` even
    /// though the discovery already constrained it — the gate is cheap and it means the acceptance
    /// rules are enforced in exactly one place.
    static func entries(for category: DevJunkCategoryID, home: String) -> [DevJunkEntry] {
        var entries: [DevJunkEntry] = []

        var candidates: [DevJunkCandidate] = []

        if let scan = category.projectScan {
            candidates += projectDirectories(scan: scan, home: home).map {
                DevJunkCandidate(path: $0, isDirectory: true, knownSize: 0)
            }
        }

        for target in category.fixedTargets {
            let root = DevJunkPaths.normalize(DevJunkPaths.expand(target.path, home: home))
            switch target.granularity {
            case .wholeDirectory:
                candidates.append(DevJunkCandidate(path: root, isDirectory: true, knownSize: 0))
            case .children:
                candidates += childCandidates(of: root)
            }
        }

        for candidate in candidates where category.accepts(path: candidate.path, home: home) {
            if Task.isCancelled {
                return entries.sorted { $0.size > $1.size }
            }

            // Loose files in a cache root already carry their size from the bulk read; only
            // directories need the full recursive walk.
            let size = candidate.isDirectory ? allocatedSize(at: candidate.path) : candidate.knownSize
            if size > 0 {
                entries.append(DevJunkEntry(category: category, path: candidate.path, size: size))
            }
        }

        return entries.sorted { $0.size > $1.size }
    }

    /// Immediate children of a cache root. Symlinks are skipped: Homebrew's cache in particular is
    /// full of links pointing back into its own downloads folder, and following them would both
    /// double-count the bytes and offer the user two rows for one file.
    private static func childCandidates(of root: String) -> [DevJunkCandidate] {
        guard let result = BulkDirectoryReader.read(at: root) else {
            return []
        }

        return result.entries
            .filter { !$0.isSymlink }
            .map {
                DevJunkCandidate(
                    path: DevJunkPaths.joined(root, $0.name),
                    isDirectory: $0.isDirectory,
                    knownSize: $0.allocatedSize
                )
            }
            .sorted { $0.path < $1.path }
    }

    /// Breadth-first walk of the project roots, depth-capped and pruned. Breadth-first matters:
    /// projects sit near the top of these roots, so the interesting matches are found long before
    /// the walk exhausts the deep corners of ~/Documents.
    private static func projectDirectories(scan: DevJunkProjectScan, home: String) -> [String] {
        var found: [String] = []
        var seen: Set<String> = []
        var frontier = DevJunkPaths.projectSearchRoots(home: home).filter { isDirectory($0) }
        var depth = 0

        while !frontier.isEmpty, depth <= scan.maximumDepth {
            if Task.isCancelled {
                return found
            }

            var next: [String] = []

            for directory in frontier {
                if Task.isCancelled {
                    return found
                }

                guard let result = BulkDirectoryReader.read(at: directory) else {
                    continue
                }

                let names = Set(result.entries.map(\.name))
                for entry in result.entries where entry.isDirectory && !entry.isSymlink {
                    let childPath = DevJunkPaths.joined(directory, entry.name)

                    if entry.name == scan.directoryName {
                        // The sibling manifest is the whole safety argument: a directory only
                        // counts when the folder holding it is demonstrably a project of the right
                        // kind, not merely a folder that happens to use the same name.
                        // Search roots can overlap (a symlinked ~/Developer, a project reachable
                        // from two of them), so the same directory must not be listed twice.
                        if names.contains(scan.requiredSibling), seen.insert(childPath).inserted {
                            found.append(childPath)
                        }
                        continue
                    }

                    // Bundles are stepped over rather than into. An application on the Desktop is
                    // exactly five components from the search root, so without this the walk reaches
                    // an Electron app's Contents/Resources/app/node_modules on its last permitted
                    // iteration and offers to delete the application's own dependencies.
                    if DevJunkPaths.prunedDirectoryNames.contains(entry.name)
                        || DevJunkPaths.isBundleName(entry.name)
                        || entry.name.hasPrefix(".") {
                        continue
                    }

                    next.append(childPath)
                }
            }

            frontier = next
            depth += 1
        }

        return found
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    /// Sums allocated size for a whole subtree using the bulk directory reader, checking for
    /// cancellation between directories. A node_modules tree can hold six figures of tiny files, so
    /// this is the part that must never run on the main actor and must be able to stop early.
    static func allocatedSize(at path: String) -> UInt64 {
        var total: UInt64 = 0
        var stack = [path]

        while let current = stack.popLast() {
            if Task.isCancelled {
                return total
            }

            guard let result = BulkDirectoryReader.read(at: current) else {
                continue
            }

            for entry in result.entries where !entry.isSymlink {
                if entry.isDirectory {
                    stack.append(DevJunkPaths.joined(current, entry.name))
                } else {
                    total &+= entry.allocatedSize
                }
            }
        }

        return total
    }
}
