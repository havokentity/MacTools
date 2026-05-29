import AppKit

/// The dominant content type of a clipboard entry, used for the row icon and type filtering.
public enum ClipboardKind: String, Codable, Sendable, CaseIterable {
    case text
    case richText
    case link
    case image
    case file
    case color

    public var iconName: String {
        switch self {
        case .text: "text.alignleft"
        case .richText: "doc.richtext"
        case .link: "link"
        case .image: "photo"
        case .file: "doc"
        case .color: "paintpalette.fill"
        }
    }

    public var label: String {
        switch self {
        case .text: "Text"
        case .richText: "Rich Text"
        case .link: "Link"
        case .image: "Image"
        case .file: "File"
        case .color: "Color"
        }
    }
}

/// A single recorded clipboard item. All representations captured from one pasteboard change
/// are stored together so the same entry can be pasted with or without formatting. Images live
/// on disk (full + thumbnail) and are referenced by file name to keep the metadata store small.
public struct ClipboardEntry: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var kind: ClipboardKind
    public var text: String?
    public var rtfData: Data?
    public var htmlData: Data?
    public var imageFileName: String?
    public var thumbnailFileName: String?
    public var filePaths: [String]?
    public var sourceAppBundleID: String?
    public var sourceAppName: String?
    public var date: Date
    public var pinned: Bool
    public var contentHash: String
    public var byteCount: Int
    public var pixelWidth: Int?
    public var pixelHeight: Int?

    public init(
        id: UUID = UUID(),
        kind: ClipboardKind,
        text: String? = nil,
        rtfData: Data? = nil,
        htmlData: Data? = nil,
        imageFileName: String? = nil,
        thumbnailFileName: String? = nil,
        filePaths: [String]? = nil,
        sourceAppBundleID: String? = nil,
        sourceAppName: String? = nil,
        date: Date = Date(),
        pinned: Bool = false,
        contentHash: String,
        byteCount: Int = 0,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.rtfData = rtfData
        self.htmlData = htmlData
        self.imageFileName = imageFileName
        self.thumbnailFileName = thumbnailFileName
        self.filePaths = filePaths
        self.sourceAppBundleID = sourceAppBundleID
        self.sourceAppName = sourceAppName
        self.date = date
        self.pinned = pinned
        self.contentHash = contentHash
        self.byteCount = byteCount
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// One-line preview used for the list row, search, and the entry title.
    public var previewText: String {
        switch kind {
        case .image:
            let dimensions = (pixelWidth.map { "\($0)" } ?? "?") + " × " + (pixelHeight.map { "\($0)" } ?? "?")
            return "Image · \(dimensions)"
        case .file:
            let names = (filePaths ?? []).map { ($0 as NSString).lastPathComponent }
            if names.count > 1 {
                return "\(names.first ?? "") +\(names.count - 1) more"
            }
            return names.first ?? (text ?? "File")
        default:
            let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? kind.label : trimmed
        }
    }

    /// Full multi-line text shown in the preview pane (single-line collapses to previewText).
    public var fullText: String {
        switch kind {
        case .file:
            return (filePaths ?? []).joined(separator: "\n")
        default:
            return text ?? previewText
        }
    }

    /// The text a substring/fuzzy search matches against.
    public var searchableText: String {
        switch kind {
        case .file:
            return ((filePaths ?? []).joined(separator: " ") + " " + (sourceAppName ?? "")).lowercased()
        case .image:
            return ("image " + (sourceAppName ?? "")).lowercased()
        default:
            return ((text ?? "") + " " + (sourceAppName ?? "")).lowercased()
        }
    }
}

/// The raw representations read from the pasteboard on a single change, before any disk work
/// (hashing / thumbnailing) happens. `Sendable` so it can cross to a background task.
public struct CapturedPasteboard: Sendable {
    public var string: String?
    public var rtfData: Data?
    public var htmlData: Data?
    public var imageData: Data?
    public var imageIsPNG: Bool
    public var filePaths: [String]?
    public var sourceAppBundleID: String?
    public var sourceAppName: String?

    public init(
        string: String? = nil,
        rtfData: Data? = nil,
        htmlData: Data? = nil,
        imageData: Data? = nil,
        imageIsPNG: Bool = false,
        filePaths: [String]? = nil,
        sourceAppBundleID: String? = nil,
        sourceAppName: String? = nil
    ) {
        self.string = string
        self.rtfData = rtfData
        self.htmlData = htmlData
        self.imageData = imageData
        self.imageIsPNG = imageIsPNG
        self.filePaths = filePaths
        self.sourceAppBundleID = sourceAppBundleID
        self.sourceAppName = sourceAppName
    }

    public var isEmpty: Bool {
        (string?.isEmpty ?? true)
            && rtfData == nil
            && htmlData == nil
            && imageData == nil
            && (filePaths?.isEmpty ?? true)
    }
}
