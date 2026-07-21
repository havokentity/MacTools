import Foundation

/// Owns the snippet library and its JSON file in Application Support. Mutation happens on the
/// main actor; the write is debounced and pushed onto a background executor so typing in the
/// editor never waits on disk.
///
/// The debounce means the last edits exist only in memory for a moment, and the save task dies
/// with the process — so `flushPendingSave()` must run at termination, exactly as `ClipboardStore`
/// does, or quitting right after "Save" loses the snippet the user just wrote.
@MainActor
public final class SnippetsStore: ObservableObject {
    @Published public private(set) var snippets: [Snippet] = []

    private let directory: URL
    private let libraryFileURL: URL
    private var saveTask: Task<Void, Never>?
    private var saveGeneration: UInt64 = 0
    private let writer = SnippetsLibraryWriter()

    /// How long edits are held in memory before the write goes out. Matches `ClipboardStore`:
    /// long enough to coalesce a burst of reorder taps, short enough that a crash loses nothing
    /// the user would notice.
    private static let saveDebounce: UInt64 = 400_000_000

    public convenience init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        self.init(directory: base.appendingPathComponent("DMonteSnippets", isDirectory: true))
    }

    /// Directory-injecting initializer. Internal so tests can point the store at a temp directory
    /// and exercise the real save/load path without touching the user's Application Support.
    init(directory: URL) {
        self.directory = directory
        libraryFileURL = directory.appendingPathComponent("snippets.json")

        // Snippets routinely hold private boilerplate — addresses, account numbers, signatures —
        // so lock the storage to the current user (0700). The POSIX attribute only applies to
        // directories createDirectory actually creates, so re-assert it for a pre-existing one.
        let ownerOnly: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: ownerOnly
        )
        try? FileManager.default.setAttributes(ownerOnly, ofItemAtPath: directory.path)
        snippets = SnippetsKit.load(from: libraryFileURL)
    }

    // MARK: - Public API

    public func snippet(with id: Snippet.ID) -> Snippet? {
        snippets.first { $0.id == id }
    }

    /// Appends a new snippet and returns it, so the caller can select the row it just created.
    @discardableResult
    public func add(title: String, body: String, expandsPlaceholders: Bool) -> Snippet {
        let snippet = Snippet(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            body: body,
            expandsPlaceholders: expandsPlaceholders
        )
        snippets.append(snippet)
        scheduleSave()
        return snippet
    }

    public func update(id: Snippet.ID, title: String, body: String, expandsPlaceholders: Bool) {
        guard let index = snippets.firstIndex(where: { $0.id == id }) else { return }
        snippets[index].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        snippets[index].body = body
        snippets[index].expandsPlaceholders = expandsPlaceholders
        scheduleSave()
    }

    public func delete(id: Snippet.ID) {
        guard let index = snippets.firstIndex(where: { $0.id == id }) else { return }
        snippets.remove(at: index)
        scheduleSave()
    }

    /// Moves a snippet `offset` places in the library. A move that would fall off either end is a
    /// no-op and is not persisted, so hammering the up arrow on the top row writes nothing.
    public func move(id: Snippet.ID, by offset: Int) {
        let reordered = SnippetsKit.moved(snippets, id: id, by: offset)
        guard reordered != snippets else { return }
        snippets = reordered
        scheduleSave()
    }

    /// Writes the debounced save immediately. Call from `applicationWillTerminate`: the save task
    /// is detached and dies with the process, so without this the last few hundred milliseconds of
    /// edits never reach disk. A no-op once the pending generation is already on disk.
    public func flushPendingSave() {
        saveTask?.cancel()
        saveTask = nil
        writer.write(snippets, to: libraryFileURL, generation: saveGeneration)
    }

    // MARK: - Private

    private func scheduleSave() {
        saveTask?.cancel()
        saveGeneration &+= 1
        let generation = saveGeneration
        let snapshot = snippets
        let url = libraryFileURL
        let writer = self.writer
        // Task.detached takes a @Sendable closure, so it does NOT inherit this method's
        // @MainActor isolation — the encode and write run on a background executor.
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: Self.saveDebounce)
            if Task.isCancelled { return }
            writer.write(snapshot, to: url, generation: generation)
        }
    }
}

/// Serializes library writes and drops any snapshot older than one already on disk. Debounced
/// save tasks are independent and unordered: a large snapshot can still be encoding when a
/// smaller, newer one — a deletion, say — is written, and its atomic rename would then land last
/// and resurrect the deleted snippet. The generation is claimed inside the queue, so the flush at
/// termination cannot race an in-flight write either. Encoding stays outside the queue; only the
/// write itself is serialized.
private final class SnippetsLibraryWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.havokentity.mactools.snippets.library-write", qos: .utility)
    private var lastWrittenGeneration: UInt64 = 0

    func write(_ snippets: [Snippet], to url: URL, generation: UInt64) {
        guard let data = SnippetsKit.encode(snippets) else { return }
        queue.sync {
            guard generation > lastWrittenGeneration else { return }
            lastWrittenGeneration = generation
            try? data.write(to: url, options: .atomic)
            // The library holds the user's own private boilerplate; restrict it to the owner.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}
