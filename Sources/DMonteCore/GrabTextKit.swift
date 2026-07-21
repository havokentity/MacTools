import Foundation
import Vision
import ImageIO
import CoreGraphics

/// Pure, UI-free OCR pipeline used by DMonte Grab Text. Recognition uses Vision's
/// text recognizer (accurate level, language correction on) and returns the top
/// candidate string for each recognized observation. Everything here is synchronous
/// and side-effect free so it can be unit tested end-to-end (render text → PNG →
/// recognize → compare) and run off the main actor via `Task.detached`.
public enum GrabTextKit {
    /// Recognizes text in the image at `imageURL`, returning one string per
    /// recognized line/observation in Vision's natural reading order. Returns an
    /// empty array if the file is missing, can't be decoded, or holds no text.
    /// Synchronous so callers can run it off the main actor via `Task.detached`.
    public static func recognizeText(in imageURL: URL) -> [String] {
        guard let cgImage = loadImage(at: imageURL) else { return [] }
        return recognizeText(cgImage: cgImage)
    }

    /// Decodes the image file at `imageURL`, or nil when it is missing or is not something
    /// ImageIO can read. Exposed separately because `recognizeText(in:)` folds both of those
    /// into the same empty array as "this image has no text", and a caller that must report
    /// the difference to the user (Clipboard History's Copy Text from Image) needs to see it.
    public static func loadImage(at imageURL: URL) -> CGImage? {
        guard FileManager.default.fileExists(atPath: imageURL.path) else { return nil }

        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Recognizes text in `cgImage` using Vision. Returns the top candidate string
    /// for each observation; an empty array if none.
    public static func recognizeText(cgImage: CGImage) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

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
            observation.topCandidates(1).first?.string
        }
    }
}
