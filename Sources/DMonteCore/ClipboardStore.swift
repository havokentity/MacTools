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
    private let thumbnailCache = NSCache<NSString, NSImage>()

    public init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        directory = base.appendingPathComponent("DMonteClipboard", isDirectory: true)
        imagesDirectory = directory.appendingPathComponent("Images", isDirectory: true)
        historyFileURL = directory.appendingPathComponent("history.json")

        try? FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
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

        if let index = entries.firstIndex(where: { $0.contentHash == hash }) {
            var existing = entries.remove(at: index)
            existing.date = Date()
            entries.insert(existing, at: 0)
            scheduleSave()
            return
        }

        guard let entry = await Self.makeEntry(captured, hash: hash, imagesDirectory: imagesDirectory) else {
            return
        }

        entries.insert(entry, at: 0)
        evictOverflow()
        scheduleSave()
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
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = entries
        let url = historyFileURL
        // Task.detached takes a @Sendable closure, so it does NOT inherit this method's
        // @MainActor isolation — the write runs cleanly on a background executor.
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            Self.writeHistory(snapshot, to: url)
        }
    }

    private nonisolated static func writeHistory(_ entries: [ClipboardEntry], to url: URL) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Off-main builders

    private static func contentHash(for captured: CapturedPasteboard) async -> String {
        await Task.detached {
            var hasher = SHA256()
            if let data = captured.imageData {
                hasher.update(data: data)
            } else if let paths = captured.filePaths, !paths.isEmpty {
                hasher.update(data: Data(paths.joined(separator: "\n").utf8))
            } else if let string = captured.string {
                hasher.update(data: Data(string.utf8))
            } else if let rtf = captured.rtfData {
                hasher.update(data: rtf)
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
                try? imageData.write(to: fullURL, options: .atomic)

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
