import Foundation

/// One of the directories macOS lets an application scatter per-app state into, described as a
/// *rule* ("a child of `<Library>/Caches` named after the app") rather than as a finished path.
/// Keeping it a rule is what lets the same eight entries cover both `~/Library` and `/Library`
/// without a second, drift-prone copy of the list.
public struct LeftoverLocation: Sendable, Hashable {
    /// Path of the container directory relative to a Library root, e.g. `Application Support`.
    public let subpath: String

    /// Appended to the identifier to form the leaf name. macOS spells two of these with an
    /// extension (`…​.plist`, `…​.savedState`); the rest are plain directories.
    public let suffix: String

    /// Human label for the review sheet.
    public let label: String

    /// Whether a leaf here is ever named after the app's *display name* rather than its bundle
    /// identifier. Only Application Support, Caches and Logs are — Containers, HTTPStorages,
    /// WebKit, Saved Application State and Preferences are keyed by bundle identifier by macOS
    /// itself, so a display-name guess in those could only ever land on another app's data.
    public let supportsNameFallback: Bool

    public init(subpath: String, suffix: String = "", label: String, supportsNameFallback: Bool = false) {
        self.subpath = subpath
        self.suffix = suffix
        self.label = label
        self.supportsNameFallback = supportsNameFallback
    }
}

/// Which Library a candidate came from. Shown in the review sheet because removing something out
/// of `/Library` is a machine-wide change and usually needs an admin prompt, whereas `~/Library`
/// is the user's own data.
public enum LeftoverScope: String, Sendable, Hashable {
    case user
    case system

    public var label: String {
        switch self {
        case .user: "~/Library"
        case .system: "/Library"
        }
    }
}

/// How a candidate was matched. This is not cosmetic: it decides whether the row is ticked when
/// the review sheet opens. Bundle-identifier matches are exact and safe to pre-select; display
/// name matches are a heuristic and start unticked so nothing is ever removed on a guess the
/// user did not look at.
public enum LeftoverMatch: String, Sendable, Hashable {
    case bundleIdentifier
    case appName
}

/// A path that *might* hold leftovers for the app being uninstalled. Derivation is pure — nothing
/// here has looked at the disk yet.
public struct LeftoverCandidate: Identifiable, Sendable, Hashable {
    public let url: URL
    public let label: String
    public let scope: LeftoverScope
    public let match: LeftoverMatch

    public var id: String { url.path }

    public init(url: URL, label: String, scope: LeftoverScope, match: LeftoverMatch) {
        self.url = url
        self.label = label
        self.scope = scope
        self.match = match
    }

    /// Path as the user thinks of it, with their home directory written as `~`.
    public var displayPath: String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}

/// A candidate that was found on disk, with its measured size.
public struct LeftoverItem: Identifiable, Sendable, Hashable {
    public let candidate: LeftoverCandidate
    public let bytes: UInt64

    public var id: String { candidate.id }
    public var url: URL { candidate.url }

    /// Ticked when the review sheet opens. See `LeftoverMatch`.
    public var isSelectedByDefault: Bool {
        candidate.match == .bundleIdentifier
    }

    public init(candidate: LeftoverCandidate, bytes: UInt64) {
        self.candidate = candidate
        self.bytes = bytes
    }
}

/// Something that survived the safety check but that macOS still refused to move.
public struct LeftoverRemovalFailure: Sendable, Equatable {
    public let path: String
    public let reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

public struct LeftoverRemovalResult: Sendable, Equatable {
    public var trashedCount: Int
    public var trashedBytes: UInt64
    public var failures: [LeftoverRemovalFailure]

    public init(trashedCount: Int = 0, trashedBytes: UInt64 = 0, failures: [LeftoverRemovalFailure] = []) {
        self.trashedCount = trashedCount
        self.trashedBytes = trashedBytes
        self.failures = failures
    }
}

/// Path derivation and the safety predicate for the Uninstaller's leftover sweep.
///
/// This is the dangerous part of the tool, so it is deliberately pure and `nonisolated`: every
/// rule below is a function of its arguments and is exercised directly by the test target, with
/// no window, no app list and no privileged state involved.
///
/// Two independent ideas keep it safe, and both must agree before anything is offered:
///
/// 1. **Derivation is exact.** A leaf is only ever `<allowed root>/<identifier><suffix>`, where
///    the identifier is the app's bundle identifier (or, in the three directories that use one,
///    its display name). There is no prefix, glob or substring matching anywhere, so
///    `com.example.app` can never pull in `com.example.app.helper`'s data.
/// 2. **Removal is fenced.** `isRemovable(_:allowedRoots:)` re-derives the verdict from the URL
///    alone immediately before the trash call. A path only passes if it is a *direct child* of a
///    known Library container **and** still resolves inside one after symlinks are followed, so a
///    traversal attempt or a planted symlink pointing at the user's documents is refused rather
///    than followed.
public enum UninstallerLeftovers {

    // MARK: - The known locations

    /// The eight directories swept, in the order they are shown. Anything not in this list is,
    /// by construction, not reachable by this feature.
    public static let locations: [LeftoverLocation] = [
        LeftoverLocation(subpath: "Application Support", label: "Application Support", supportsNameFallback: true),
        LeftoverLocation(subpath: "Caches", label: "Caches", supportsNameFallback: true),
        LeftoverLocation(subpath: "Preferences", suffix: ".plist", label: "Preferences"),
        LeftoverLocation(subpath: "Containers", label: "Container"),
        LeftoverLocation(subpath: "Saved Application State", suffix: ".savedState", label: "Saved Application State"),
        LeftoverLocation(subpath: "Logs", label: "Logs", supportsNameFallback: true),
        LeftoverLocation(subpath: "HTTPStorages", label: "HTTP Storage"),
        LeftoverLocation(subpath: "WebKit", label: "WebKit Data")
    ]

    public static var defaultUserLibrary: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
    }

    public static let defaultSystemLibrary = URL(fileURLWithPath: "/Library")

    /// Every directory this feature is allowed to remove a child from. Both Libraries are folded
    /// into one flat list because the safety predicate only ever asks "is this URL a child of one
    /// of these?" — it does not care which Library the answer came from.
    public static func allowedRoots(userLibrary: URL, systemLibrary: URL) -> [URL] {
        [userLibrary, systemLibrary].flatMap { library in
            locations.map { library.appendingPathComponent($0.subpath) }
        }
    }

    // MARK: - Identifier hygiene

    /// Bundle identifiers arrive from `Info.plist` files this app did not write, so they are
    /// untrusted input that is about to be pasted into a filesystem path. Anything that could
    /// change the *shape* of that path — a separator, a relative reference, a control character —
    /// is rejected outright rather than escaped, because a rejected identifier costs the user a
    /// manual cleanup while a mis-escaped one costs them a directory.
    public static func sanitizedIdentifier(_ raw: String?) -> String? {
        guard let raw else {
            return nil
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return nil
        }

        // A single path component cannot exceed 255 bytes on APFS/HFS+, so a longer identifier
        // could not name a real directory anyway.
        guard trimmed.utf8.count <= 255 else {
            return nil
        }

        // "/" is the obvious traversal vector; ":" is the classic HFS separator and is still
        // translated by some Carbon-era paths.
        guard !trimmed.contains("/"), !trimmed.contains(":") else {
            return nil
        }

        guard trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }

        // Covers "." and ".." as well as hidden names. No shipping bundle identifier starts with
        // a dot, so refusing them costs nothing and removes a whole class of surprise.
        guard trimmed.first != "." else {
            return nil
        }

        // `appendingPathComponent` treats a leading "~" as an ordinary character, but
        // `NSString.expandingTildeInPath` — which any future caller might reasonably reach for —
        // turns it into the home directory. Refusing it here means that difference can never
        // become a bug.
        guard trimmed.first != "~" else {
            return nil
        }

        return trimmed
    }

    /// Directory names that hold more than one vendor's — or more than one app's — data. The
    /// display-name fallback must never produce one of these, because `~/Library/Application
    /// Support/Google` is Chrome's *and* Drive's *and* Earth's, and uninstalling any one of them
    /// must not take the other two with it.
    private static let sharedDirectoryNames: Set<String> = [
        "adobe", "apple", "google", "microsoft", "mozilla", "steam", "unity", "jetbrains",
        "app", "apps", "application", "applications", "backup", "backups", "cache", "caches",
        "common", "crashreporter", "data", "default", "defaults", "desktop", "documents",
        "downloads", "files", "helper", "helpers", "home", "info", "install", "installer",
        "library", "log", "logs", "mail", "main", "media", "music", "notes", "photos",
        "preferences", "private", "public", "setup", "shared", "support", "system", "temp",
        "test", "tests", "tmp", "update", "updater", "user", "users", "utilities", "utility"
    ]

    /// Whether the app's display name is specific enough to guess a directory from.
    ///
    /// The fallback only exists for the handful of apps whose bundle identifier cannot be read,
    /// and it is the one place a wrong answer deletes a *different* app's data, so three things
    /// have to hold: the name has to survive the same path hygiene a bundle identifier does, it
    /// has to be long enough that a collision is unlikely (three characters or fewer is a
    /// coin-flip: "Go", "IDE", "Zip"), and it must not be a directory that is known to be shared.
    /// Finally, if another installed app answers to the same name the guess is ambiguous by
    /// definition and is refused.
    public static func isNameSpecificEnough(_ rawName: String, otherAppNames: [String] = []) -> Bool {
        guard let name = sanitizedIdentifier(rawName) else {
            return false
        }

        guard name.count >= 4 else {
            return false
        }

        let folded = normalized(name)

        guard !sharedDirectoryNames.contains(folded) else {
            return false
        }

        return !otherAppNames.contains { normalized($0) == folded }
    }

    private static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    // MARK: - Derivation

    /// Every place the app being uninstalled *could* have left something. Nothing here touches
    /// the disk; `LeftoverScanner` is what decides which of these actually exist.
    ///
    /// Bundle-identifier candidates come first and cover all eight locations. Display-name
    /// candidates are appended only for the three directories that are ever named that way, and
    /// only when the name clears `isNameSpecificEnough`.
    public static func candidates(
        bundleIdentifier: String?,
        appName: String,
        userLibrary: URL,
        systemLibrary: URL,
        otherAppNames: [String] = []
    ) -> [LeftoverCandidate] {
        let libraries: [(scope: LeftoverScope, url: URL)] = [
            (.user, userLibrary),
            (.system, systemLibrary)
        ]

        let identifier = sanitizedIdentifier(bundleIdentifier)
        let nameIdentifier = isNameSpecificEnough(appName, otherAppNames: otherAppNames)
            ? sanitizedIdentifier(appName)
            : nil
        let roots = allowedRoots(userLibrary: userLibrary, systemLibrary: systemLibrary)

        var candidates: [LeftoverCandidate] = []
        var seenPaths = Set<String>()

        func append(_ leafIdentifier: String, match: LeftoverMatch, onlyNameable: Bool) {
            for library in libraries {
                for location in locations where !onlyNameable || location.supportsNameFallback {
                    let url = library.url
                        .appendingPathComponent(location.subpath)
                        .appendingPathComponent(leafIdentifier + location.suffix)

                    // Belt and braces: derivation is exact, but the leaf still has to satisfy the
                    // same fence that gates the trash call. If the two ever disagree, the
                    // candidate is dropped here rather than surfacing as an un-removable row.
                    guard isRemovable(url, allowedRoots: roots) else {
                        continue
                    }

                    guard seenPaths.insert(url.standardizedFileURL.path).inserted else {
                        continue
                    }

                    candidates.append(
                        LeftoverCandidate(url: url, label: location.label, scope: library.scope, match: match)
                    )
                }
            }
        }

        if let identifier {
            append(identifier, match: .bundleIdentifier, onlyNameable: false)
        }

        if let nameIdentifier, nameIdentifier != identifier {
            append(nameIdentifier, match: .appName, onlyNameable: true)
        }

        return candidates
    }

    // MARK: - The safety predicate

    /// The single gate every removal passes through, and the only thing standing between a
    /// malformed bundle identifier and someone's home directory.
    ///
    /// A URL is removable only when **both** hold:
    ///
    /// - Lexically it is a direct child of one of `allowedRoots`. Anything with `..` in it
    ///   collapses during standardisation and lands somewhere that is not a known root, so a
    ///   traversal attempt fails this half.
    /// - After symlinks are resolved on both the URL and the roots, it is still inside a root.
    ///   A planted `~/Library/Caches/com.evil.app -> ~/Documents` therefore fails this half even
    ///   though it passes the first, which is exactly the case the first half cannot see.
    ///
    /// Roots shallower than three path components (`/`, `/Users`, `/Library`) are ignored on
    /// principle: no matter how this is called, the feature can never be pointed at a directory
    /// whose children are whole volumes, user accounts or system frameworks.
    public static func isRemovable(_ url: URL, allowedRoots: [URL]) -> Bool {
        let standardized = url.standardizedFileURL
        let leafName = standardized.lastPathComponent

        guard !leafName.isEmpty, leafName != "/", leafName != ".", leafName != ".." else {
            return false
        }

        // A root is allowed to be spelled two ways, because `/var`, `/tmp` and `/etc` are symlinks
        // into `/private` and Foundation is inconsistent about which spelling it hands back. Both
        // spellings name the same directory, so accepting either is not a widening of the fence —
        // whereas accepting only one would make the resolved-path half below fail on paths that
        // are perfectly legitimate.
        let rootIdentities = allowedRoots
            .map(\.standardizedFileURL)
            .filter { $0.pathComponents.count >= 3 }
            .flatMap { [$0, $0.resolvingSymlinksInPath().standardizedFileURL] }

        guard !rootIdentities.isEmpty else {
            return false
        }

        let parentPath = standardized.deletingLastPathComponent().standardizedFileURL.path
        guard rootIdentities.contains(where: { $0.path == parentPath }) else {
            return false
        }

        // Deliberately the *resolved* URL only. Checking the unresolved spelling as a fallback
        // here would hand a planted symlink the pass this half exists to deny it.
        let resolved = standardized.resolvingSymlinksInPath().standardizedFileURL
        return rootIdentities.contains { isStrictlyContained(resolved, in: $0) }
    }

    /// Containment compared component-by-component rather than by string prefix, so that
    /// `/Library/CachesElsewhere/x` is not mistaken for a child of `/Library/Caches`.
    private static func isStrictlyContained(_ url: URL, in root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let urlComponents = url.pathComponents

        guard urlComponents.count > rootComponents.count else {
            return false
        }

        return Array(urlComponents.prefix(rootComponents.count)) == rootComponents
    }

    // MARK: - Selection arithmetic

    /// IDs ticked when the review sheet opens: exact bundle-identifier matches only.
    public static func defaultSelection(for items: [LeftoverItem]) -> Set<String> {
        Set(items.filter(\.isSelectedByDefault).map(\.id))
    }

    /// Total of the ticked rows, so the sheet can say how much is about to move.
    public static func selectedBytes(in items: [LeftoverItem], selection: Set<String>) -> UInt64 {
        items.reduce(UInt64(0)) { total, item in
            selection.contains(item.id) ? total + item.bytes : total
        }
    }
}

/// The I/O half: which candidates exist, how big they are, and moving the chosen ones to Trash.
///
/// Every entry point re-runs `UninstallerLeftovers.isRemovable` against freshly computed roots
/// rather than trusting the caller's list, so a stale or hand-built `LeftoverItem` cannot become
/// a delete.
public enum LeftoverScanner {

    public static func scan(
        bundleIdentifier: String?,
        appName: String,
        otherAppNames: [String] = [],
        userLibrary: URL = UninstallerLeftovers.defaultUserLibrary,
        systemLibrary: URL = UninstallerLeftovers.defaultSystemLibrary
    ) -> [LeftoverItem] {
        let candidates = UninstallerLeftovers.candidates(
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            userLibrary: userLibrary,
            systemLibrary: systemLibrary,
            otherAppNames: otherAppNames
        )

        return candidates.compactMap { candidate in
            guard exists(at: candidate.url) else {
                return nil
            }

            return LeftoverItem(candidate: candidate, bytes: size(of: candidate.url))
        }
    }

    /// Moves the given items to Trash — never `removeItem`. A leftover sweep is a heuristic by
    /// nature, and the Trash is what makes a wrong guess a nuisance instead of a data loss.
    public static func moveToTrash(
        _ items: [LeftoverItem],
        userLibrary: URL = UninstallerLeftovers.defaultUserLibrary,
        systemLibrary: URL = UninstallerLeftovers.defaultSystemLibrary
    ) -> LeftoverRemovalResult {
        let roots = UninstallerLeftovers.allowedRoots(userLibrary: userLibrary, systemLibrary: systemLibrary)
        var result = LeftoverRemovalResult()

        for item in items {
            guard UninstallerLeftovers.isRemovable(item.url, allowedRoots: roots) else {
                result.failures.append(
                    LeftoverRemovalFailure(
                        path: item.candidate.displayPath,
                        reason: "outside the app-support folders this tool is allowed to touch"
                    )
                )
                continue
            }

            do {
                var resultingURL: NSURL?
                try FileManager.default.trashItem(at: item.url, resultingItemURL: &resultingURL)
                result.trashedCount += 1
                result.trashedBytes += item.bytes
            } catch {
                result.failures.append(
                    LeftoverRemovalFailure(path: item.candidate.displayPath, reason: error.localizedDescription)
                )
            }
        }

        return result
    }

    /// `fileExists` follows symlinks, which would hide a dangling link and — worse — report a
    /// link to somewhere else as present. `attributesOfItem` does not follow, so a symlink is
    /// reported on its own terms and the safety predicate gets to rule on where it points.
    private static func exists(at url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    /// Allocated size on disk. Symlinks are counted as themselves: the enumerator does not
    /// descend through them, so a link's target is never billed to the app being uninstalled.
    private static func size(of url: URL) -> UInt64 {
        let sizeKeys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return 0
        }

        if !isDirectory.boolValue {
            let values = try? url.resourceValues(forKeys: sizeKeys)
            return UInt64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(sizeKeys),
            options: []
        ) else {
            return 0
        }

        return enumerator.reduce(UInt64(0)) { partialResult, entry in
            guard let fileURL = entry as? URL,
                  let values = try? fileURL.resourceValues(forKeys: sizeKeys) else {
                return partialResult
            }

            return partialResult + UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
    }
}
