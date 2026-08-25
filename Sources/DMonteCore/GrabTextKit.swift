import AppKit
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

    /// Interprets one finished `screencapture -i` run. Pure, so the decision that matters most —
    /// telling a missing Screen Recording grant apart from an ordinary cancel or a text-free
    /// region — is unit-tested rather than inferred from a live TCC state we can't script.
    ///
    /// The distinction exists because the two look identical from here: without the grant,
    /// `screencapture` either writes nothing at all or writes a frame with every other app's
    /// windows redacted, and both shapes are exactly what a user pressing Esc or grabbing a blank
    /// patch of desktop produces. Reporting those as "no text found" sends the user hunting for a
    /// problem in their selection when the actual blocker is a permission they have to grant.
    ///
    /// The cost of resolving the ambiguity this way is that cancelling with Esc *while the grant
    /// is missing* also reads as a permission problem. That is the right trade: the permission is
    /// a real blocker the user has to clear before any grab can work, so saying so early is more
    /// useful than a "cancelled" they already knew about.
    public static func classifyCapture(
        fileWritten: Bool,
        recognizedText: String,
        hasScreenRecordingAccess: Bool
    ) -> GrabTextOutcome {
        if hasScreenRecordingAccess {
            return fileWritten ? .success(recognizedText) : .cancelled
        }
        if !fileWritten || recognizedText.isEmpty {
            return .needsScreenRecordingPermission
        }
        // Text came back despite the preflight saying no — believe the pixels, not the flag.
        return .success(recognizedText)
    }
}

/// What one capture-and-recognize attempt produced.
public enum GrabTextOutcome: Equatable, Sendable {
    /// The region was captured; the payload is the recognized text, which may be empty when the
    /// region genuinely holds none.
    case success(String)
    /// The user dismissed the region selector.
    case cancelled
    /// The Screen Recording TCC grant is missing, so nothing usable could be captured.
    case needsScreenRecordingPermission
    /// Something else went wrong; the payload is a sentence to show the user.
    case failure(String)
}

/// One capture attempt. A closure type rather than a direct call so `GrabTextController` can be
/// driven headlessly: the real implementation spawns `/usr/sbin/screencapture`, which needs both a
/// GUI session and a human to drag a rectangle.
public typealias GrabTextCapture = @Sendable () async -> GrabTextOutcome

/// This process's Screen Recording (TCC) state. Screen capture is gated on it, and unlike
/// Accessibility there is no notification when it changes, so callers re-read it around each grab.
public enum ScreenRecordingAccess {
    /// Whether the grant is currently held. `CGPreflightScreenCaptureAccess` only reads the stored
    /// decision — it never prompts — so it is safe to call on every capture.
    public static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Asks for the grant. `CGRequestScreenCaptureAccess` shows the system prompt the first time
    /// only; on every later call it silently returns the stored answer, which would look like the
    /// button did nothing. Opening the Settings pane as well means the button always leads
    /// somewhere the user can act.
    @discardableResult
    public static func request() -> Bool {
        let granted = CGRequestScreenCaptureAccess()
        if !granted,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        return granted
    }
}

/// Runs the interactive screen capture and Vision OCR off the main actor. The heavy work (spawning
/// `screencapture` and running Vision) happens in a detached task; the result is returned to the
/// awaiting caller, which is back on its original actor.
public enum GrabTextCapturer {
    public static func grabRegion() async -> GrabTextOutcome {
        await Task.detached(priority: .userInitiated) { () -> GrabTextOutcome in
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("dmonte-grabtext-\(UUID().uuidString).png")

            defer {
                try? FileManager.default.removeItem(at: tempURL)
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            // -i: interactive region selection, -x: silence the capture sound.
            process.arguments = ["-i", "-x", tempURL.path]

            do {
                try process.run()
            } catch {
                return .failure("Couldn't start screen capture: \(error.localizedDescription)")
            }

            process.waitUntilExit()

            // Read the grant *after* the run: the first attempt is what triggers the system
            // prompt, so a preflight taken beforehand would report "denied" for the very grab the
            // user just approved.
            let hasAccess = ScreenRecordingAccess.isGranted
            let fileWritten = FileManager.default.fileExists(atPath: tempURL.path)
            let text = fileWritten
                ? GrabTextKit.recognizeText(in: tempURL)
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                : ""

            return GrabTextKit.classifyCapture(
                fileWritten: fileWritten,
                recognizedText: text,
                hasScreenRecordingAccess: hasAccess
            )
        }.value
    }
}
