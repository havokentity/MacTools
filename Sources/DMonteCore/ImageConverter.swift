import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Pure, testable image conversion core. Foundation + ImageIO + CoreGraphics +
/// UniformTypeIdentifiers only — no AppKit/SwiftUI — so it is safe to run off the
/// main actor inside `Task.detached`. Everything here is `nonisolated`.
public enum ImageConverterKit {
    /// Output container formats the converter can write.
    public enum ImageFormat: String, CaseIterable, Sendable, Identifiable {
        case jpeg
        case png
        case heic
        case tiff

        public var id: String { rawValue }

        /// Whether this format honours `kCGImageDestinationLossyCompressionQuality`.
        public var isLossy: Bool {
            switch self {
            case .jpeg, .heic: true
            case .png, .tiff: false
            }
        }

        /// Human-facing label for pickers.
        public var displayName: String {
            switch self {
            case .jpeg: "JPEG"
            case .png: "PNG"
            case .heic: "HEIC"
            case .tiff: "TIFF"
            }
        }

        public var utType: UTType {
            switch self {
            case .jpeg: .jpeg
            case .png: .png
            case .heic: .heic
            case .tiff: .tiff
            }
        }

        public var fileExtension: String {
            switch self {
            case .jpeg: "jpg"
            case .png: "png"
            case .heic: "heic"
            case .tiff: "tiff"
            }
        }
    }

    /// Result of a successful conversion.
    public struct ConvertedImage: Sendable, Equatable {
        public var outputURL: URL
        public var byteCount: UInt64
        public var pixelWidth: Int
        public var pixelHeight: Int

        public init(outputURL: URL, byteCount: UInt64, pixelWidth: Int, pixelHeight: Int) {
            self.outputURL = outputURL
            self.byteCount = byteCount
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
        }
    }

    /// Why a conversion failed, with a user-readable `message` mirroring the
    /// skip-reporting ethos used elsewhere in the app.
    public enum ConvertError: Error, Sendable, Equatable {
        case unreadableSource
        case decodeFailed
        case unwritableDestination
        case encodeFailed
        case sizingFailed

        public var message: String {
            switch self {
            case .unreadableSource: "Couldn't read the source image"
            case .decodeFailed: "Couldn't decode the image data"
            case .unwritableDestination: "Couldn't create the output file"
            case .encodeFailed: "Couldn't encode to the chosen format"
            case .sizingFailed: "Couldn't read the image dimensions"
            }
        }
    }

    /// Converts `source` into `format`, optionally downscaling so its longest edge
    /// is at most `maxDimension` pixels (aspect ratio preserved), and writes the
    /// result into `outputDirectory`. Lossy formats use `quality` (0...1 — values
    /// outside that range are clamped). Returns the written file plus its size and
    /// pixel dimensions, or a descriptive failure.
    ///
    /// Pure and `nonisolated`: pass only `Sendable` values (URLs, the format enum,
    /// numbers) so it can be invoked from a detached, off-main task.
    public static func convert(
        source: URL,
        to format: ImageFormat,
        quality: Double,
        maxDimension: Int?,
        outputDirectory: URL
    ) -> Result<ConvertedImage, ConvertError> {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              CGImageSourceGetCount(imageSource) > 0 else {
            return .failure(.unreadableSource)
        }

        let cgImage: CGImage
        if let maxDimension, maxDimension > 0 {
            // Let ImageIO produce a correctly-oriented, downsampled image in one
            // step — far cheaper than decoding full-size then scaling ourselves.
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxDimension
            ]
            guard let scaled = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
                return .failure(.decodeFailed)
            }
            cgImage = scaled
        } else {
            guard let full = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
                return .failure(.decodeFailed)
            }
            cgImage = full
        }

        let pixelWidth = cgImage.width
        let pixelHeight = cgImage.height
        guard pixelWidth > 0, pixelHeight > 0 else {
            return .failure(.sizingFailed)
        }

        let outputURL = uniqueOutputURL(
            for: source,
            format: format,
            in: outputDirectory
        )

        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            format.utType.identifier as CFString,
            1,
            nil
        ) else {
            return .failure(.unwritableDestination)
        }

        var properties: [CFString: Any] = [:]
        if format.isLossy {
            let clamped = min(max(quality, 0), 1)
            properties[kCGImageDestinationLossyCompressionQuality] = clamped
        }

        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            // Don't leave a half-written stub behind.
            try? FileManager.default.removeItem(at: outputURL)
            return .failure(.encodeFailed)
        }

        let byteCount = fileSize(at: outputURL)

        return .success(
            ConvertedImage(
                outputURL: outputURL,
                byteCount: byteCount,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight
            )
        )
    }

    /// Byte size of a file on disk, or 0 if it can't be read.
    public static func fileSize(at url: URL) -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? UInt64) ?? 0
    }

    /// Builds a non-colliding destination URL: `<name>.<ext>`, and if a conversion
    /// in place would overwrite the source (or a previous run), appends ` 1`, ` 2`…
    /// so nothing is clobbered.
    public static func uniqueOutputURL(
        for source: URL,
        format: ImageFormat,
        in directory: URL
    ) -> URL {
        let baseName = source.deletingPathExtension().lastPathComponent
        let ext = format.fileExtension

        var candidate = directory
            .appendingPathComponent(baseName)
            .appendingPathExtension(ext)

        // Avoid overwriting the source itself (same dir + same effective name) and
        // any file already at the candidate path.
        var counter = 1
        let fileManager = FileManager.default
        while fileManager.fileExists(atPath: candidate.path)
            || candidate.standardizedFileURL == source.standardizedFileURL {
            candidate = directory
                .appendingPathComponent("\(baseName) \(counter)")
                .appendingPathExtension(ext)
            counter += 1
        }

        return candidate
    }
}
