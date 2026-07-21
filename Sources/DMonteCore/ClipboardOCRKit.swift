import Foundation

/// Pure, UI-free layer behind Clipboard History's "Copy Text from Image" action: it turns an
/// image entry's backing file into either recognized text, an honest "nothing there" answer, or
/// an honest "couldn't read it" answer. Recognition itself is delegated to `GrabTextKit` so the
/// suite keeps exactly one Vision pipeline (accurate level, language correction on).
///
/// Everything here is synchronous and side-effect free so callers can run it off the main actor
/// via `Task.detached` and so the headless test target can drive it end to end.
public enum ClipboardOCRKit {
    /// What an OCR run over a history entry produced. `imageUnavailable` is kept distinct from
    /// `noText` on purpose: a history entry can outlive its backing file (a manual purge of
    /// Application Support, a half-finished write), and telling the user "no text found" for a
    /// file we never managed to open would be a lie.
    public enum Outcome: Sendable, Equatable {
        case text(String)
        case noText
        case imageUnavailable
    }

    /// Recognizes text in the image file at `imageURL`. Synchronous and slow (Vision's accurate
    /// level runs for hundreds of milliseconds on a screenshot), so callers must hop off the
    /// main actor first.
    ///
    /// The decode goes through `GrabTextKit.loadImage(at:)` rather than its `recognizeText(in:)`
    /// because that entry point collapses "file is gone", "file is not an image" and "image
    /// holds no text" into one empty array — and this feature has to tell those apart to report
    /// honestly. The decoder itself is still Grab Text's, so there is only one of it.
    public static func recognize(imageURL: URL) -> Outcome {
        guard let cgImage = GrabTextKit.loadImage(at: imageURL) else {
            return .imageUnavailable
        }

        return outcome(forRecognizedLines: GrabTextKit.recognizeText(cgImage: cgImage))
    }

    /// Classifies Vision's per-observation strings into an outcome. Split out from `recognize`
    /// so the joining and the empty-result rule are testable without rendering an image.
    ///
    /// Observations arrive in reading order and are joined with newlines, matching what Grab
    /// Text puts on the clipboard for the same picture. A run that only found whitespace counts
    /// as no text: copying a lone space over whatever the user already had would be a silent
    /// loss dressed up as success.
    public static func outcome(forRecognizedLines lines: [String]) -> Outcome {
        let joined = lines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? .noText : .text(joined)
    }

    /// The inline status line shown under the history list once a run finishes. Every branch
    /// says what actually happened — there is no alert and no thrown error to fall back on.
    public static func statusMessage(for outcome: Outcome) -> String {
        switch outcome {
        case let .text(text):
            let count = text.count
            return "Copied \(count) \(count == 1 ? "character" : "characters") of text to the clipboard."
        case .noText:
            return "No text found in that image."
        case .imageUnavailable:
            return "Couldn't read that image — its file is missing or unreadable."
        }
    }

    /// Shown while the detached run is in flight, so the row's spinner has a caption.
    public static let inProgressMessage = "Reading text from the image…"
}
