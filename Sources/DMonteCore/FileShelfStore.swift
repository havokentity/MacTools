import AppKit
import Foundation

public extension DefaultsKey {
    /// Whether Clear Shelf asks for a second press before emptying the shelf. Clearing is the one
    /// action here the user cannot undo — the files are untouched, but the collection they were
    /// deliberately gathering is gone — so the integrator registers a default of `true`.
    static let fileShelfConfirmsClearAll = "tool.fileShelf.confirmsClearAll"
}

/// Owns the shelf: the ordered list of shelved files, their resolution against the file system,
/// and the JSON file in Application Support that carries them across a relaunch.
///
/// Nothing here copies bytes. Shelving a file records a bookmark to it and nothing else, so
/// parking a 40 GB video costs the same as parking a text file, and dragging it back out hands
/// the receiving app the original rather than a duplicate.
///
/// All the interesting rules live in `FileShelfKit` as pure functions over values; this type is
/// the main-actor shell that owns the state, the security-scoped access, and the file.
@MainActor
public final class FileShelfStore: ObservableObject {
    /// The shelf, newest first.
    @Published public private(set) var items: [ShelfItem] = []

    /// `true` once Clear Shelf has been requested and is waiting for the confirming press.
    @Published public private(set) var isConfirmingClearAll = false

    /// Persisted preference: require a second press for Clear Shelf.
    @Published public private(set) var confirmsClearAll: Bool

    /// The most recent thing worth saying out loud — a drop that added nothing, a reveal that
    /// found nothing. `nil` most of the time; the popover only shows the line when there is one.
    @Published public private(set) var statusMessage: String?

    private let shelfFileURL: URL
    private let defaults: UserDefaults

    /// URLs this process called `startAccessingSecurityScopedResource()` on, keyed by the entry
    /// that owns the claim. Security scopes are reference-counted per process, so every start has
    /// to be balanced exactly once — hence a dictionary rather than a bare set, which would lose
    /// track of the second claim on the same URL.
    private var accessedURLs: [UUID: URL] = [:]

    public convenience init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        self.init(
            directory: base.appendingPathComponent("DMonteFileShelf", isDirectory: true),
            defaults: AppDefaults.shared
        )
    }

    /// Directory- and defaults-injecting initializer. Internal so tests can point the store at a
    /// temporary directory and its own preferences suite, exercising the real load/save path
    /// without touching the user's own shelf or settings.
    init(directory: URL, defaults: UserDefaults) {
        self.defaults = defaults
        confirmsClearAll = defaults.bool(forKey: DefaultsKey.fileShelfConfirmsClearAll)
        shelfFileURL = directory.appendingPathComponent("shelf.json")
        FileShelfKit.prepareDirectory(directory)

        // Resolve at startup rather than lazily per row: the count in the menu bar has to be
        // truthful the moment the icon appears, and that means knowing what is still there.
        adopt(FileShelfKit.load(from: shelfFileURL).map { FileShelfKit.resolveItem($0) }, persist: false)
    }

    // MARK: - Shelving

    /// Shelves each URL, newest first, and returns how many rows the shelf actually gained.
    ///
    /// A re-drop of something already shelved counts as zero: it moved a row rather than adding
    /// one, and reporting "1 added" when the list is the same length reads as a bug.
    @discardableResult
    public func shelve(urls: [URL]) -> Int {
        // Filtered here rather than trusted from the callers, because only one of the two drop
        // paths filters on its own: the menu-bar overlay reads the pasteboard with
        // `urlReadingFileURLsOnly`, while the popover asks `NSItemProvider` for a `URL` and gets
        // back whatever representation the provider preferred — which, for a drag that carries
        // both a file and a web address, can be the web address. A non-file URL is not merely
        // useless on a shelf, it is actively wrong: `makeItem` reduces a URL to its path, and the
        // path of `https://example.com/tmp` is `/tmp` — which exists. The row would come out
        // *available*, carrying the device/inode of the local `/tmp`, and would then collide with
        // a genuine drop of that folder.
        let candidates = urls.filter(\.isFileURL).map { FileShelfKit.makeItem(for: $0) }
        guard !candidates.isEmpty else { return 0 }

        // Re-resolve the whole shelf before comparing anything against it, because the identities
        // already on `items` were computed the last time the shelf was resolved — startup, or the
        // last popover open — and a device/inode pair does not survive a safe-save. Every app that
        // writes atomically (TextEdit, Preview, Xcode, anything built on NSDocument or
        // `FileManager.replaceItemAt`) swaps in a fresh inode, so the cached identity stops
        // describing the file the bookmark still points at. A drop straight onto the menu-bar icon
        // never opens the popover, so this is the only chance to notice; without it, re-dropping a
        // file that has been edited since fails to match and mints a second, permanent row that
        // nothing ever collapses.
        let current = resolvedItems()

        // Counted from identities rather than from the length of the list before and after.
        // A shelf already at `maximumCount` stays exactly that long when something is added, so
        // the length would report every drop onto a full shelf as a duplicate.
        var seenIdentities = Set(current.compactMap(\.identity))
        let added = candidates.reduce(into: 0) { total, candidate in
            guard let identity = candidate.identity else {
                // Nothing to collide with, so it is guaranteed to get a row of its own.
                total += 1
                return
            }
            if seenIdentities.insert(identity).inserted {
                total += 1
            }
        }

        adopt(FileShelfKit.adding(candidates, to: current), persist: true)

        // A drop that only re-shelved things is still worth acknowledging, because otherwise the
        // list looks untouched and the user cannot tell the drop landed at all.
        if added == 0 {
            statusMessage = candidates.count == 1
                ? "“\(candidates[0].displayName)” is already on the shelf"
                : "Already on the shelf"
        } else {
            statusMessage = nil
        }

        return added
    }

    // MARK: - Removal

    public func remove(id: UUID) {
        // Clearing is armed against the list the user was looking at; removing a row changes that
        // list, so the arming is dropped rather than being carried onto a different shelf.
        isConfirmingClearAll = false
        adopt(FileShelfKit.removing(id: id, from: items), persist: true)
        statusMessage = nil
    }

    /// Asks to empty the shelf. With confirmation enabled the first call only arms the action; the
    /// second (`confirmClearAll()`) performs it.
    public func requestClearAll() {
        guard !items.isEmpty else { return }

        if confirmsClearAll, !isConfirmingClearAll {
            isConfirmingClearAll = true
            return
        }

        confirmClearAll()
    }

    /// Empties the shelf. The files themselves are never touched — only this tool's references to
    /// them — which is why this needs a confirmation rather than an undo.
    public func confirmClearAll() {
        isConfirmingClearAll = false
        adopt([], persist: true)
        statusMessage = nil
    }

    public func cancelClearAll() {
        isConfirmingClearAll = false
    }

    // MARK: - Row actions

    /// Re-resolves every entry against the file system. Cheap enough to run on every popover open,
    /// which is what keeps a row honest after the user deleted the file behind the shelf's back.
    public func refresh() {
        adopt(resolvedItems(), persist: true)
    }

    /// Shows the file in Finder. An entry that no longer resolves says so instead of opening a
    /// Finder window on nothing.
    public func revealInFinder(id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }

        guard item.isAvailable, let url = item.url else {
            statusMessage = "“\(item.displayName)” isn’t there any more"
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([url])
        statusMessage = nil
    }

    /// Copies the file's path. Offered even for an entry that has stopped resolving: the last
    /// known path is often exactly what someone needs in order to go and find it.
    public func copyPath(id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.displayPath, forType: .string)
        statusMessage = "Copied path"
    }

    public func clearStatus() {
        statusMessage = nil
    }

    public func setConfirmsClearAll(_ newValue: Bool) {
        guard newValue != confirmsClearAll else { return }

        confirmsClearAll = newValue
        defaults.set(newValue, forKey: DefaultsKey.fileShelfConfirmsClearAll)
        // Turning confirmation off must not silently fire the press that is already pending.
        isConfirmingClearAll = false
    }

    /// Releases every security scope this process is holding. Called at termination: the scopes
    /// die with the process anyway, but balancing them explicitly keeps the accounting honest and
    /// makes a leak visible in testing rather than in a long-running session.
    public func releaseAllAccess() {
        accessedURLs.values.forEach { $0.stopAccessingSecurityScopedResource() }
        accessedURLs.removeAll()
    }

    // MARK: - Private

    /// Every entry re-resolved against the file system as it is right now.
    ///
    /// Shared by `refresh()` and `shelve(urls:)` on purpose: a drop has to be judged against the
    /// same truth the popover would show, because anything `items` is still carrying was computed
    /// at some earlier resolve and a file can have been moved, deleted or re-saved since.
    private func resolvedItems() -> [ShelfItem] {
        items.map { FileShelfKit.resolveItem($0.file) }
    }

    /// The single place `items` is assigned. It reconciles security-scoped access with the new
    /// list and, when asked, writes the shelf out.
    ///
    /// The write is synchronous rather than debounced: shelf edits are a handful of deliberate
    /// clicks, never a keystroke stream, and a menu-bar helper can be killed at any moment. Paying
    /// a few hundred microseconds per click is the cheaper trade.
    private func adopt(_ newItems: [ShelfItem], persist: Bool) {
        reconcileAccess(with: newItems)
        items = newItems

        if persist {
            FileShelfKit.write(newItems.map(\.file), to: shelfFileURL)
        }
    }

    /// Starts a security scope for every newly-reachable entry and stops the ones that left.
    ///
    /// The scope is held for as long as the file is on the shelf rather than being taken and
    /// released around each drag. The receiving app reads the file *after* the drop completes, on
    /// its own schedule, so a scope that ended when the drag did would be gone by the time it
    /// mattered.
    private func reconcileAccess(with newItems: [ShelfItem]) {
        var retained: [UUID: URL] = [:]

        for item in newItems {
            guard item.isAvailable, let url = item.url else { continue }

            if let existing = accessedURLs[item.id], existing == url {
                retained[item.id] = existing
                accessedURLs[item.id] = nil
                continue
            }

            // A `false` return means the URL carries no security scope — an ordinary bookmark
            // outside the sandbox — which is not a failure and needs no matching stop.
            if url.startAccessingSecurityScopedResource() {
                retained[item.id] = url
            }
        }

        // Whatever is left in `accessedURLs` belongs to a row that is gone or has moved.
        accessedURLs.values.forEach { $0.stopAccessingSecurityScopedResource() }
        accessedURLs = retained
    }
}
