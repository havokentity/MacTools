import Foundation

/// Whether a shelved entry can still be handed to another app.
///
/// An entry is never silently dropped when it stops being usable. The shelf is a place people
/// park things on their way somewhere else, so "the file I put here is gone" has to be visible —
/// a row that quietly disappeared would read as the shelf having lost it.
public enum ShelfAvailability: String, Codable, Sendable, Equatable {
    /// The bookmark resolved and something is at the other end.
    case available

    /// The bookmark resolved, but nothing is there any more: deleted, or on a volume that is not
    /// mounted right now. Plugging the disk back in makes this entry work again, which is exactly
    /// why it is kept rather than pruned.
    case missing

    /// The bookmark itself no longer decodes to a location at all. Recoverable only by shelving
    /// the file again, but still worth showing so the user can see what they have lost.
    case unresolvable
}

/// The persisted form of one shelved file.
///
/// The bookmark — not the path — is the identity of record. A shelf whose entries were paths
/// would break the moment someone renamed a file in Finder or moved it between folders, which is
/// precisely the kind of tidying people do while a file is parked here on its way somewhere else.
/// `displayName` and `lastKnownPath` exist only to label a row whose bookmark has stopped
/// resolving; while the bookmark works, the live URL wins.
public struct ShelvedFile: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID

    /// Security-scoped bookmark data produced by `FileShelfKit.bookmarkData(for:)`. Refreshed in
    /// place whenever resolution reports it as stale, so a file that keeps moving does not slowly
    /// accumulate resolution work on every launch.
    public var bookmark: Data

    /// The file's name when it was last successfully resolved.
    public var displayName: String

    /// The file's path when it was last successfully resolved. Shown greyed-out on an entry that
    /// no longer resolves, because "which file was that?" is the only question left to answer.
    public var lastKnownPath: String

    /// When the file was last put on the shelf. Re-dropping something already shelved refreshes
    /// this rather than creating a second row.
    public var shelved: Date

    public init(
        id: UUID = UUID(),
        bookmark: Data,
        displayName: String,
        lastKnownPath: String,
        shelved: Date = Date()
    ) {
        self.id = id
        self.bookmark = bookmark
        self.displayName = displayName
        self.lastKnownPath = lastKnownPath
        self.shelved = shelved
    }
}

/// A shelved file after its bookmark has been resolved: the record, where the file actually is
/// right now, and whether it can be handed to another app.
///
/// This is the type the list operations work on, and it carries `identity` so de-duplication can
/// compare *live* locations. Storing the identity on the record instead would defeat the point:
/// a device/inode pair is not stable across a restart, so it has to be recomputed from whatever
/// the bookmark resolves to today.
public struct ShelfItem: Sendable, Identifiable, Equatable {
    public var file: ShelvedFile

    /// Where the file is right now; `nil` when the bookmark no longer resolves.
    public var url: URL?

    public var availability: ShelfAvailability

    /// `FileShelfKit.identity(for:)` of `url`. `nil` when nothing resolved, or when the resolved
    /// location has no file behind it — an entry with no identity can never collide with anything.
    public var identity: String?

    public var id: UUID { file.id }

    public init(file: ShelvedFile, url: URL?, availability: ShelfAvailability, identity: String?) {
        self.file = file
        self.url = url
        self.availability = availability
        self.identity = identity
    }

    /// The live name when the file is still reachable, otherwise the one recorded at shelving time.
    public var displayName: String {
        url?.lastPathComponent ?? file.displayName
    }

    /// The live path when the file is still reachable, otherwise the one recorded at shelving time.
    public var displayPath: String {
        url?.path ?? file.lastKnownPath
    }

    public var isAvailable: Bool {
        availability == .available
    }
}

/// A bookmark that resolved, plus whether the system wants it rewritten.
public struct ResolvedShelfBookmark: Sendable, Equatable {
    public let url: URL

    /// `true` when macOS decided the bookmark's cached information has drifted far enough that it
    /// should be re-created. Ignoring this is what makes a bookmark eventually stop resolving.
    public let isStale: Bool

    public init(url: URL, isStale: Bool) {
        self.url = url
        self.isStale = isStale
    }
}

/// Pure, UI-free logic behind DMonte File Shelf: bookmark creation and resolution, file identity,
/// the ordering/de-duplication rules for the shelf list, and the on-disk format.
///
/// Everything here is either a pure function over values or an explicitly file-touching helper
/// that takes the URL it should touch, so the whole layer is exercisable from tests against a
/// temporary directory without a menu bar, a window, or the user's real shelf.
public enum FileShelfKit {
    /// How many files the shelf holds before the oldest falls off the bottom.
    ///
    /// A staging area is not an archive. Without a cap a shelf someone forgot about keeps every
    /// bookmark they ever dropped and re-resolves all of them on every launch; with one, the list
    /// stays scannable and the oldest thing — the one least likely to still be wanted — is what
    /// makes room.
    public static let maximumCount = 50

    /// Above this the badge stops counting and just says "there are a lot", because a three-digit
    /// number in the menu bar is wider than the icon it is annotating.
    public static let maximumBadgeCount = 99

    // MARK: - Status badge

    /// The count drawn next to the menu-bar icon. `nil` when the shelf is empty, so an unused
    /// shelf is just an icon rather than a permanent "0" taking up menu-bar width.
    public static func badgeTitle(for count: Int) -> String? {
        guard count > 0 else { return nil }
        guard count <= maximumBadgeCount else { return "\(maximumBadgeCount)+" }
        return "\(count)"
    }

    // MARK: - File identity

    /// A key that identifies *the file itself* rather than the name it currently goes by.
    ///
    /// Device number plus inode: the same pair for a file reached through a symlink, through
    /// `/tmp` versus `/private/tmp`, or after a rename — which is what de-duplication has to
    /// survive, since the shelf deliberately follows files as they move. Falls back to the
    /// standardized path when the file cannot be stat'ed at all (it is gone, or on a volume that
    /// has been unplugged), because a path is the only identity left at that point.
    ///
    /// Deliberately not persisted: inode numbers are reused after a file is deleted, so a stored
    /// identity could later match a completely unrelated file.
    public static func identity(for url: URL) -> String {
        let standardized = url.standardizedFileURL.resolvingSymlinksInPath()

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: standardized.path),
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else {
            return standardized.path
        }

        return "\(device.uint64Value):\(inode.uint64Value)"
    }

    // MARK: - Bookmarks

    /// Bookmark data for `url`, or `nil` when the file cannot be bookmarked at all.
    ///
    /// The security-scoped variant is tried first because it is what keeps working if this tool is
    /// ever sandboxed. Outside the App Sandbox the scope buys nothing and the scoped variant can
    /// be refused outright, so a plain bookmark is the fallback: it still survives a relaunch and
    /// still follows a rename, which is the whole reason the shelf stores bookmarks and not paths.
    public static func bookmarkData(for url: URL) -> Data? {
        if let scoped = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            return scoped
        }

        return try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// Resolves bookmark data back to a location, or `nil` when it no longer resolves.
    ///
    /// Mirrors `bookmarkData(for:)`: a plain bookmark throws if resolved *with* the security
    /// scope, so both shapes are attempted. `.withoutUI` and `.withoutMounting` matter more than
    /// they look — without them, resolving an entry that lives on an unplugged disk pops a system
    /// "please insert the disk" panel from a background menu-bar app during a routine refresh.
    public static func resolve(_ bookmark: Data) -> ResolvedShelfBookmark? {
        if let scoped = resolve(bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting]) {
            return scoped
        }

        return resolve(bookmark, options: [.withoutUI, .withoutMounting])
    }

    private static func resolve(_ bookmark: Data, options: URL.BookmarkResolutionOptions) -> ResolvedShelfBookmark? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: options,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }

        return ResolvedShelfBookmark(url: url, isStale: isStale)
    }

    /// Turns a dropped URL into a shelf item.
    ///
    /// A file that cannot be bookmarked at all is still shelved, with empty bookmark data: it is
    /// usable for the rest of this session (the URL is right there) and will read as unresolvable
    /// after a relaunch. Refusing the drop outright would be worse — the user would see a drag
    /// that silently did nothing — and quietly substituting the recorded path on the next launch
    /// would be worse still, because a path can be reused by an unrelated file and this tool's
    /// entire job is to hand over *the* file.
    public static func makeItem(for url: URL, shelved: Date = Date()) -> ShelfItem {
        let standardized = url.standardizedFileURL
        let file = ShelvedFile(
            bookmark: bookmarkData(for: standardized) ?? Data(),
            displayName: standardized.lastPathComponent,
            lastKnownPath: standardized.path,
            shelved: shelved
        )

        let exists = FileManager.default.fileExists(atPath: standardized.path)
        return ShelfItem(
            file: file,
            url: standardized,
            availability: exists ? .available : .missing,
            identity: exists ? identity(for: standardized) : nil
        )
    }

    /// Re-resolves a stored record into a live item.
    ///
    /// A stale-but-resolvable bookmark is rewritten in the returned record, so the caller only has
    /// to persist what it gets back. A bookmark that resolves to nothing yields `.missing` rather
    /// than `.unresolvable`: the difference is "the disk is not here" versus "this data is junk",
    /// and only the first one comes back on its own.
    public static func resolveItem(_ file: ShelvedFile) -> ShelfItem {
        guard let resolved = resolve(file.bookmark) else {
            return ShelfItem(file: file, url: nil, availability: .unresolvable, identity: nil)
        }

        var updated = file
        if resolved.isStale, let refreshed = bookmarkData(for: resolved.url) {
            updated.bookmark = refreshed
        }

        guard FileManager.default.fileExists(atPath: resolved.url.path) else {
            return ShelfItem(file: updated, url: resolved.url, availability: .missing, identity: nil)
        }

        updated.displayName = resolved.url.lastPathComponent
        updated.lastKnownPath = resolved.url.path

        return ShelfItem(
            file: updated,
            url: resolved.url,
            availability: .available,
            identity: identity(for: resolved.url)
        )
    }

    // MARK: - List operations

    /// Puts `item` at the top of `items`, collapsing a file that is already shelved onto its
    /// existing row.
    ///
    /// Newest-first because a shelf is read from the top: the thing just dropped is the thing most
    /// likely to be dragged out next. Re-dropping something already on the shelf moves that row
    /// back to the top rather than doing nothing at all — a drop that appeared to have no effect
    /// reads as a drop that was not registered — but keeps the original row's `id` so the list
    /// does not lose scroll position or a hover state to a fresh identity.
    ///
    /// The cap is applied from the bottom, so an add can never fail: the oldest entry makes room.
    public static func adding(_ item: ShelfItem, to items: [ShelfItem]) -> [ShelfItem] {
        var newItem = item
        var remaining = items

        // Only a real identity can collide. Two entries that both failed to resolve are not
        // "the same file" just because neither of them could be found.
        if let identity = item.identity,
           let existingIndex = remaining.firstIndex(where: { $0.identity == identity }) {
            newItem.file = ShelvedFile(
                id: remaining[existingIndex].id,
                bookmark: item.file.bookmark,
                displayName: item.file.displayName,
                lastKnownPath: item.file.lastKnownPath,
                shelved: item.file.shelved
            )
            remaining.remove(at: existingIndex)
        }

        remaining.removeAll { $0.id == newItem.id }
        remaining.insert(newItem, at: 0)
        return Array(remaining.prefix(maximumCount))
    }

    /// Adds several dropped files at once, preserving the order they were dropped in: the first
    /// URL of a multi-file drag ends up at the top, matching how the drag was assembled.
    public static func adding(_ newItems: [ShelfItem], to items: [ShelfItem]) -> [ShelfItem] {
        newItems.reversed().reduce(items) { partial, item in adding(item, to: partial) }
    }

    public static func removing(id: UUID, from items: [ShelfItem]) -> [ShelfItem] {
        items.filter { $0.id != id }
    }

    // MARK: - Storage

    /// Creates `directory` if needed, restricted to the current user.
    ///
    /// The shelf file is a list of paths to whatever someone was moving around — a contract, a
    /// medical scan, an unreleased build — so 0700 is the right default. Returns false unless a
    /// real directory is in place afterwards.
    @discardableResult
    public static func prepareDirectory(_ directory: URL) -> Bool {
        let ownerOnly: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: ownerOnly
        )
        // Re-asserted separately: createDirectory only applies its attributes to directories it
        // actually creates, so a directory from an earlier build would keep its old mode.
        try? FileManager.default.setAttributes(ownerOnly, ofItemAtPath: directory.path)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
    }

    /// Reads the shelf from disk. A missing or unreadable file is an empty shelf, not an error —
    /// there is nothing to recover and nothing the user could do about it.
    public static func load(from url: URL) -> [ShelvedFile] {
        guard let data = try? Data(contentsOf: url) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ShelvedFile].self, from: data)) ?? []
    }

    /// Writes the shelf atomically, so an interrupted save leaves the previous shelf intact rather
    /// than a half-written file that would read back as empty.
    @discardableResult
    public static func write(_ files: [ShelvedFile], to url: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(files) else { return false }
        guard (try? data.write(to: url, options: .atomic)) != nil else { return false }

        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return true
    }
}
