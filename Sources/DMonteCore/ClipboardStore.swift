import AppKit
import CryptoKit

/// Persists clipboard history as a small JSON metadata file plus on-disk image/thumbnail files,
/// kept in Application Support. Deduplicates by content hash, caps the unpinned history, and
/// keeps pinned entries forever. All mutation happens on the main actor; disk writes and image
/// encoding are offloaded so the capture path never blocks the UI.
@MainActor
public final class ClipboardStore: ObservableObject {
    @Published public private(set) var entries: [ClipboardEntry] = []

    private let directory: URL
    private let imagesDirectory: URL
    private let historyFileURL: URL
    private var saveTask: Task<Void, Never>?
    private var saveGeneration: UInt64 = 0
    private let writer = ClipboardHistoryWriter()
    private let thumbnailCache = NSCache<NSString, NSImage>()

    public init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        directory = base.appendingPathComponent("DMonteClipboard", isDirectory: true)
        imagesDirectory = directory.appendingPathComponent("Images", isDirectory: true)
        historyFileURL = directory.appendingPathComponent("history.json")

        // Clipboard history can contain sensitive copied text/images, so lock the storage
        // down to the current user (0700). createDirectory's POSIX attribute applies to dirs
        // it creates; we also re-assert it in case the directory predates this hardening.
        let ownerOnly: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try? FileManager.default.createDirectory(
            at: imagesDirectory,
            withIntermediateDirectories: true,
            attributes: ownerOnly
        )
        try? FileManager.default.setAttributes(ownerOnly, ofItemAtPath: directory.path)
        try? FileManager.default.setAttributes(ownerOnly, ofItemAtPath: imagesDirectory.path)
        load()
    }

    private var maxHistory: Int {
        let stored = AppDefaults.shared.integer(forKey: DefaultsKey.clipboardMaxHistory)
        return stored > 0 ? stored : 200
    }

    // MARK: - Capture

    /// Records a freshly captured pasteboard. Hashing and image encoding run off the main actor;
    /// a duplicate of an existing entry is promoted to the top instead of inserted again.
    public func record(_ captured: CapturedPasteboard) async {
        guard !captured.isEmpty else { return }

        let hash = await Self.contentHash(for: captured)

        if promoteEntry(matching: hash) { return }

        guard let entry = await Self.makeEntry(captured, hash: hash, imagesDirectory: imagesDirectory) else {
            return
        }

        // makeEntry suspends, and for a large image its thumbnail encode plus atomic write can
        // outlast the monitor's poll interval — so re-check: an identical capture may have been
        // recorded while we were away, and inserting now would duplicate it (files and all).
        if promoteEntry(matching: hash) {
            deleteFiles(for: entry)
            return
        }

        entries.insert(entry, at: 0)
        evictOverflow()
        scheduleSave()
    }

    /// Moves an existing entry with `hash` to the top of the history; false when there is none.
    private func promoteEntry(matching hash: String) -> Bool {
        guard let index = entries.firstIndex(where: { $0.contentHash == hash }) else { return false }
        var existing = entries.remove(at: index)
        existing.date = Date()
        entries.insert(existing, at: 0)
        scheduleSave()
        return true
    }

    // MARK: - Mutation

    public func togglePin(_ id: ClipboardEntry.ID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].pinned.toggle()
        // Surface pinned items by recency among pins; keep simple by re-sorting pinned-first.
        scheduleSave()
    }

    public func delete(_ id: ClipboardEntry.ID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let removed = entries.remove(at: index)
        deleteFiles(for: removed)
        scheduleSave()
    }

    /// Clears history. Pinned entries are kept unless `includingPinned` is true.
    public func clear(includingPinned: Bool) {
        let kept = includingPinned ? [] : entries.filter(\.pinned)
        let removed = entries.filter { entry in !kept.contains(where: { $0.id == entry.id }) }
        removed.forEach(deleteFiles(for:))
        entries = kept
        scheduleSave()
    }

    /// Removes unpinned entries copied at or after `cutoff` — the "clear last N minutes" gesture.
    public func clear(after cutoff: Date) {
        let removed = entries.filter { !$0.pinned && $0.date >= cutoff }
        guard !removed.isEmpty else { return }
        removed.forEach(deleteFiles(for:))
        entries.removeAll { !$0.pinned && $0.date >= cutoff }
        scheduleSave()
    }

    public func imagesURL(for fileName: String) -> URL {
        imagesDirectory.appendingPathComponent(fileName)
    }

    public func image(for entry: ClipboardEntry) -> NSImage? {
        guard let name = entry.imageFileName else { return nil }
        return NSImage(contentsOf: imagesDirectory.appendingPathComponent(name))
    }

    public func thumbnail(for entry: ClipboardEntry) -> NSImage? {
        guard let name = entry.thumbnailFileName ?? entry.imageFileName else { return nil }
        if let cached = thumbnailCache.object(forKey: name as NSString) {
            return cached
        }
        guard let loaded = NSImage(contentsOf: imagesDirectory.appendingPathComponent(name)) else {
            return nil
        }
        thumbnailCache.setObject(loaded, forKey: name as NSString)
        return loaded
    }

    // MARK: - Eviction & persistence

    /// Applies the current "History size" setting to the history already in memory. Eviction
    /// otherwise only runs when a brand-new entry is recorded, so lowering the limit would leave
    /// the surplus entries (and their image files) in place until the next fresh copy — which
    /// never arrives for a user who only re-copies content they already have.
    public func applyHistoryLimit() {
        let before = entries.count
        evictOverflow()
        guard entries.count != before else { return }
        scheduleSave()
    }

    private func evictOverflow() {
        let unpinned = entries.filter { !$0.pinned }
        guard unpinned.count > maxHistory else { return }
        let overflow = unpinned.suffix(unpinned.count - maxHistory)
        let overflowIDs = Set(overflow.map(\.id))
        overflow.forEach(deleteFiles(for:))
        entries.removeAll { overflowIDs.contains($0.id) }
    }

    private func deleteFiles(for entry: ClipboardEntry) {
        for name in [entry.imageFileName, entry.thumbnailFileName].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: imagesDirectory.appendingPathComponent(name))
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: historyFileURL),
              let decoded = try? JSONDecoder().decode([ClipboardEntry].self, from: data) else {
            return
        }
        entries = decoded
        // The limit may have been lowered while we weren't running.
        applyHistoryLimit()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveGeneration &+= 1
        let generation = saveGeneration
        let snapshot = entries
        let url = historyFileURL
        let writer = self.writer
        // Task.detached takes a @Sendable closure, so it does NOT inherit this method's
        // @MainActor isolation — the write runs cleanly on a background executor.
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            writer.write(snapshot, to: url, generation: generation)
        }
    }

    /// Writes the debounced save right now. The save task is detached and dies with the process,
    /// so without a flush at termination the last 400ms of mutations never reach disk: a quit
    /// straight after "Clear History" leaves the supposedly-erased entries in history.json,
    /// pointing at image files `clear` already deleted. A no-op once the pending generation has
    /// already been written.
    public func flushPendingSave() {
        saveTask?.cancel()
        saveTask = nil
        writer.write(entries, to: historyFileURL, generation: saveGeneration)
    }

    // MARK: - Off-main builders

    /// The dedup key for a capture. Internal (not private) so the representation priority and
    /// namespacing are unit-testable without a store touching Application Support.
    static func contentHash(for captured: CapturedPasteboard) async -> String {
        await Task.detached {
            var hasher = SHA256()
            // Namespaced by representation, and evaluated in the same priority order makeEntry
            // classifies by. Without both, copying the file /a/b.txt and then its path text via
            // Finder's Copy as Pathname hash alike, and the second copy silently promotes the
            // first entry instead of being recorded.
            if let paths = captured.filePaths, !paths.isEmpty {
                hasher.update(data: Data("file:".utf8))
                hasher.update(data: Data(paths.joined(separator: "\n").utf8))
            } else if let imageData = captured.imageData {
                hasher.update(data: Data("image:".utf8))
                hasher.update(data: imageData)
            } else {
                // Formatting is part of a text entry's identity — "Total" in red and "Total" in
                // blue are separate copies, not a duplicate to promote. HTML stays out of the key
                // whenever a plain string or RTF carries the content: apps such as Google Docs
                // stamp a fresh GUID into every HTML export, which would defeat dedup for repeat
                // copies. An empty string carries nothing, though — some apps pair `public.html`
                // with a blank `public.utf8-plain-text`, and skipping the HTML for those would
                // hash every one of them to the same "no content" key and collapse them into a
                // single history entry.
                let string = captured.string ?? ""
                let stringData = Data(string.utf8)
                // Length-prefix the plain string so its bytes can't run together with the RTF/HTML
                // that follows: without a boundary, "AB"+"CD" and "ABC"+"D" hash alike.
                hasher.update(data: Data("text:\(stringData.count):".utf8))
                hasher.update(data: stringData)
                if let rtf = captured.rtfData {
                    hasher.update(data: rtf)
                } else if string.isEmpty, let html = captured.htmlData {
                    hasher.update(data: html)
                }
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    private static func makeEntry(
        _ captured: CapturedPasteboard,
        hash: String,
        imagesDirectory: URL
    ) async -> ClipboardEntry? {
        await Task.detached {
            // File entry first: a real file URL is a file even if the app also attached an
            // icon/preview image to the pasteboard.
            if let paths = captured.filePaths, !paths.isEmpty {
                return ClipboardEntry(
                    kind: .file,
                    text: captured.string,
                    filePaths: paths,
                    sourceAppBundleID: captured.sourceAppBundleID,
                    sourceAppName: captured.sourceAppName,
                    contentHash: hash,
                    byteCount: paths.joined().utf8.count
                )
            }

            // Image entry: write full image + a downscaled thumbnail to disk.
            if let imageData = captured.imageData {
                let id = UUID()
                let fullName = "\(id.uuidString).\(captured.imageIsPNG ? "png" : "tiff")"
                let thumbName = "\(id.uuidString)_thumb.png"
                let fullURL = imagesDirectory.appendingPathComponent(fullName)
                // Without the full image on disk the entry would render and paste as nothing, so
                // drop the capture rather than record a reference to a file that never existed.
                guard (try? imageData.write(to: fullURL, options: .atomic)) != nil else { return nil }

                var thumbStored: String?
                if let thumbData = Self.thumbnailData(from: imageData, maxPixel: 480) {
                    let thumbURL = imagesDirectory.appendingPathComponent(thumbName)
                    if (try? thumbData.write(to: thumbURL, options: .atomic)) != nil {
                        thumbStored = thumbName
                    }
                }

                let pixelSize = Self.pixelSize(of: imageData)
                return ClipboardEntry(
                    id: id,
                    kind: .image,
                    imageFileName: fullName,
                    thumbnailFileName: thumbStored,
                    sourceAppBundleID: captured.sourceAppBundleID,
                    sourceAppName: captured.sourceAppName,
                    contentHash: hash,
                    byteCount: imageData.count,
                    pixelWidth: pixelSize.map { Int($0.width) },
                    pixelHeight: pixelSize.map { Int($0.height) }
                )
            }

            // Text / rich text / link entry.
            let string = captured.string ?? ""
            let kind: ClipboardKind = {
                if captured.rtfData != nil || captured.htmlData != nil { return .richText }
                if Self.looksLikeURL(string) { return .link }
                return .text
            }()

            return ClipboardEntry(
                kind: kind,
                text: string,
                rtfData: captured.rtfData,
                htmlData: captured.htmlData,
                sourceAppBundleID: captured.sourceAppBundleID,
                sourceAppName: captured.sourceAppName,
                contentHash: hash,
                byteCount: string.utf8.count
            )
        }.value
    }

    private nonisolated static func looksLikeURL(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(" "), trimmed.count > 6, trimmed.count < 2048 else { return false }
        guard trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") else { return false }
        return URL(string: trimmed) != nil
    }

    private nonisolated static func thumbnailData(from imageData: Data, maxPixel: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgThumb)
        return rep.representation(using: .png, properties: [:])
    }

    private nonisolated static func pixelSize(of imageData: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue
        guard let width, let height else { return nil }
        return CGSize(width: width, height: height)
    }
}

/// Serializes history writes and drops any snapshot older than one already on disk. The store's
/// debounced save tasks are independent and unordered: a big snapshot (rtf/html blobs are
/// base64-inlined) can still be encoding when a smaller, newer one — a bulk clear, say — is
/// written, and its atomic rename would then land last and resurrect the cleared entries. The
/// generation is claimed inside the queue, so the flush at termination can't race an in-flight
/// write either. Encoding stays outside the queue; only the write itself is serialized.
private final class ClipboardHistoryWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.havokentity.mactools.clipboard.history-write", qos: .utility)
    private var lastWrittenGeneration: UInt64 = 0

    func write(_ entries: [ClipboardEntry], to url: URL, generation: UInt64) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        queue.sync {
            guard generation > lastWrittenGeneration else { return }
            lastWrittenGeneration = generation
            try? data.write(to: url, options: .atomic)
            // The history file holds copied text verbatim; restrict it to the owner (0600).
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}
