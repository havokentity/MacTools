import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import Vision

/// Pure, UI-free QR/barcode pipeline used by DMonte QR. Generation uses CoreImage's
/// QR generator and scales the raw matrix up with a nearest-neighbour transform so the
/// rendered code stays crisp; decoding uses Vision's barcode detector and returns the raw
/// payload strings. Everything here is synchronous and side-effect free so it can be unit
/// tested end-to-end (generate → render to PNG → decode → compare payload).
public enum QRKit {
    /// Renders `string` as a QR code image. `scale` multiplies the native QR matrix size so
    /// the result is sharp at display sizes (a value around 10 gives a clean, large image).
    /// Returns `nil` for empty input or if CoreImage fails to produce an image.
    public static func generate(_ string: String, scale: CGFloat = 10) -> NSImage? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        guard let payload = string.data(using: .utf8) else {
            return nil
        }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = payload
        // "M" tolerates ~15% damage — a good balance of density and resilience for URLs/text.
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else {
            return nil
        }

        // Nearest-neighbour upscale keeps the modules as hard-edged squares instead of
        // blurring them, so the code reads reliably and looks intentional rather than fuzzy.
        let effectiveScale = max(1, scale)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: effectiveScale, y: effectiveScale))

        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else {
            return nil
        }

        let size = NSSize(width: scaled.extent.width, height: scaled.extent.height)
        return NSImage(cgImage: cgImage, size: size)
    }

    /// Decodes any QR codes / barcodes found in the image at `url`, returning each payload
    /// string. Returns an empty array if the file can't be read or no codes are found.
    /// Synchronous so callers can run it off the main actor via `Task.detached`.
    public static func decode(imageAt url: URL) -> [String] {
        if let cgImage = loadCGImage(at: url) {
            return decode(cgImage: cgImage)
        }

        // Fallback: NSImage understands some formats CGImageSource may not load directly.
        if let image = NSImage(contentsOf: url),
           let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return decode(cgImage: cgImage)
        }

        return []
    }

    /// Decodes any QR codes / barcodes found in `cgImage`. Returns an empty array if none.
    public static func decode(cgImage: CGImage) -> [String] {
        let request = VNDetectBarcodesRequest()
        // Restrict to symbologies the tool advertises: QR plus the common 1D/2D barcodes.
        request.symbologies = [.qr, .aztec, .dataMatrix, .pdf417, .ean13, .ean8, .code128, .code39, .code93, .upce]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
        } catch {
            return []
        }

        guard let results = request.results else {
            return []
        }

        return results.compactMap { observation in
            let payload = observation.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (payload?.isEmpty == false) ? payload : nil
        }
    }

    /// Writes `image` to `url` as PNG. Returns `true` on success.
    @discardableResult
    public static func writePNG(_ image: NSImage, to url: URL) -> Bool {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return false
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        bitmap.size = image.size
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            return false
        }

        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Private

    private static func loadCGImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
