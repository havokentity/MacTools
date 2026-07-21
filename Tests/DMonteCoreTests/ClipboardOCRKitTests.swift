import XCTest
import AppKit
@testable import DMonteCore

/// Covers `ClipboardOCRKit`, the layer behind Clipboard History's "Copy Text from Image".
/// The distinctions it draws decide what the user is told and — more importantly — whether the
/// pasteboard is overwritten at all, so each outcome branch is pinned down here.
final class ClipboardOCRKitTests: XCTestCase {

    /// Temp files created during a test, cleaned up in `tearDown`.
    private var tempURLs: [URL] = []

    override func tearDown() {
        for url in tempURLs {
            try? FileManager.default.removeItem(at: url)
        }
        tempURLs.removeAll()
        super.tearDown()
    }

    /// Renders `string` (or a blank page when nil) into a PNG on disk and returns the file URL.
    ///
    /// IMPORTANT: In a headless `swift test` run, `NSImage.lockFocus()` renders BLANK. We must
    /// draw into an `NSBitmapImageRep`-backed `NSGraphicsContext` instead, which renders
    /// correctly without a window server.
    private func renderPNG(
        text string: String?,
        width: Int = 700,
        height: Int = 200
    ) throws -> URL {
        let rep = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ),
            "Could not create bitmap representation."
        )

        let context = try XCTUnwrap(
            NSGraphicsContext(bitmapImageRep: rep),
            "Could not create graphics context."
        )

        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = context

        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        if let string {
            // Black bold text, large enough for accurate recognition.
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 72),
                .foregroundColor: NSColor.black
            ]
            let attributed = NSAttributedString(string: string, attributes: attributes)
            let textSize = attributed.size()
            attributed.draw(at: NSPoint(
                x: (CGFloat(width) - textSize.width) / 2,
                y: (CGFloat(height) - textSize.height) / 2
            ))
        }

        context.flushGraphics()
        NSGraphicsContext.current = previous

        let data = try XCTUnwrap(
            rep.representation(using: .png, properties: [:]),
            "Could not encode PNG."
        )

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dmonte-clipboard-ocr-test-\(UUID().uuidString).png")
        try data.write(to: url)
        tempURLs.append(url)
        return url
    }

    // MARK: - Outcome classification

    func testNoObservationsIsNoText() {
        XCTAssertEqual(ClipboardOCRKit.outcome(forRecognizedLines: []), .noText)
    }

    /// Vision can return observations that hold nothing but spaces. Copying those would clear
    /// the user's real clipboard contents and put a blank string in their place, while the UI
    /// happily reported success.
    func testWhitespaceOnlyObservationsAreNoText() {
        XCTAssertEqual(ClipboardOCRKit.outcome(forRecognizedLines: ["   ", "\n", "\t"]), .noText)
    }

    func testObservationsAreJoinedWithNewlinesInOrder() {
        let outcome = ClipboardOCRKit.outcome(forRecognizedLines: ["first", "second", "third"])
        XCTAssertEqual(outcome, .text("first\nsecond\nthird"))
    }

    /// Leading/trailing blank observations are trimmed away, but interior ones are structure —
    /// a paragraph break in the source image — and must survive.
    func testSurroundingWhitespaceIsTrimmedButInteriorBlanksSurvive() {
        let outcome = ClipboardOCRKit.outcome(forRecognizedLines: ["  ", "top", "", "bottom", " "])
        XCTAssertEqual(outcome, .text("top\n\nbottom"))
    }

    // MARK: - Reading the backing file

    /// A history entry can outlive its image file, and reporting that as "no text found" would
    /// send the user hunting for a problem with the picture instead of the missing file.
    func testMissingBackingFileIsUnavailableNotNoText() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("dmonte-clipboard-ocr-missing-\(UUID().uuidString).png")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))

        XCTAssertEqual(ClipboardOCRKit.recognize(imageURL: missing), .imageUnavailable)
    }

    func testUndecodableFileIsUnavailable() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dmonte-clipboard-ocr-junk-\(UUID().uuidString).png")
        try Data("not an image".utf8).write(to: url)
        tempURLs.append(url)

        XCTAssertEqual(ClipboardOCRKit.recognize(imageURL: url), .imageUnavailable)
    }

    /// A zero-byte file is what a half-finished or interrupted image write leaves behind. It
    /// exists, so the existence check waves it through — only the decode can reject it.
    func testEmptyFileIsUnavailable() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dmonte-clipboard-ocr-empty-\(UUID().uuidString).png")
        try Data().write(to: url)
        tempURLs.append(url)

        XCTAssertEqual(ClipboardOCRKit.recognize(imageURL: url), .imageUnavailable)
    }

    /// A directory passes `fileExists(atPath:)`, so this is the case a bare existence check
    /// would let through to the decoder.
    func testDirectoryPathIsUnavailable() {
        let url = FileManager.default.temporaryDirectory
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        XCTAssertEqual(ClipboardOCRKit.recognize(imageURL: url), .imageUnavailable)
    }

    func testRecognizesTextInABackingImage() throws {
        let url = try renderPNG(text: "HELLO WORLD")

        guard case let .text(recognized) = ClipboardOCRKit.recognize(imageURL: url) else {
            return XCTFail("Expected recognized text from a rendered image.")
        }
        XCTAssertTrue(
            recognized.uppercased().contains("HELLO"),
            "Recognized text should contain HELLO, got: \(recognized)"
        )
    }

    func testBlankImageYieldsNoText() throws {
        let url = try renderPNG(text: nil)
        XCTAssertEqual(ClipboardOCRKit.recognize(imageURL: url), .noText)
    }

    // MARK: - Status messages

    func testStatusMessagesDistinguishEveryOutcome() {
        let success = ClipboardOCRKit.statusMessage(for: .text("abc"))
        let noText = ClipboardOCRKit.statusMessage(for: .noText)
        let unavailable = ClipboardOCRKit.statusMessage(for: .imageUnavailable)

        XCTAssertTrue(success.contains("3 characters"))
        XCTAssertEqual(Set([success, noText, unavailable]).count, 3)
        // Failure must not be dressed up as a copy that happened.
        XCTAssertFalse(noText.contains("Copied"))
        XCTAssertFalse(unavailable.contains("Copied"))
    }

    func testSingleCharacterResultIsNotPluralized() {
        XCTAssertTrue(ClipboardOCRKit.statusMessage(for: .text("x")).contains("1 character "))
    }

    /// The count the user is shown must match what a person would count on screen, not UTF-16
    /// units: a flag or a family emoji is one character, and reporting "Copied 11 characters"
    /// for a single glyph would look like the copy grabbed something else.
    func testCharacterCountIsGraphemesNotCodeUnits() {
        XCTAssertTrue(ClipboardOCRKit.statusMessage(for: .text("👨‍👩‍👧‍👦")).contains("1 character "))
        XCTAssertTrue(ClipboardOCRKit.statusMessage(for: .text("é🇯🇵")).contains("2 characters"))
    }

    /// House typography: real ellipsis, never three periods.
    func testInProgressMessageUsesARealEllipsis() {
        XCTAssertTrue(ClipboardOCRKit.inProgressMessage.hasSuffix("…"))
        XCTAssertFalse(ClipboardOCRKit.inProgressMessage.contains("..."))
    }
}

/// Covers `ClipboardPaste.copyRecognizedText`, whose exact pasteboard shape carries the
/// feature's central safety claim: the result is marker-free so the monitor records it as a
/// new text entry, and it is plain text only so nothing of the image tags along.
///
/// Everything runs against a private named pasteboard — the user's real clipboard is never
/// touched, and no Accessibility permission or frontmost app is involved.
@MainActor
final class ClipboardRecognizedTextPasteTests: XCTestCase {

    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: .init("com.havokentity.mactools.tests.ocr-\(UUID().uuidString)"))
    }

    override func tearDown() {
        pasteboard?.releaseGlobally()
        pasteboard = nil
        super.tearDown()
    }

    func testWritesThePlainString() {
        ClipboardPaste.copyRecognizedText("recognized line\nsecond line", to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "recognized line\nsecond line")
    }

    /// The whole "the result shows up in history" behaviour hangs on this: every other writer in
    /// `ClipboardPaste` stamps `org.nspasteboard.source`, and the monitor drops anything wearing
    /// it. Stamp this one by accident and the recognized text silently never gets recorded.
    func testIsNotStampedWithTheSourceMarkerSoTheMonitorRecordsIt() {
        ClipboardPaste.copyRecognizedText("hello", to: pasteboard)

        let sourceType = NSPasteboard.PasteboardType("org.nspasteboard.source")
        XCTAssertNil(pasteboard.string(forType: sourceType))
        XCTAssertFalse(pasteboard.types?.contains(sourceType) ?? false)
    }

    /// Plain text only. An image representation riding along would make the monitor record the
    /// picture again — the very entry the user asked to read text out of — and the store's
    /// capture prefers an image over text whenever both are present.
    ///
    /// Asserted as an absence rather than `types == [.string]`: AppKit adds the legacy
    /// `NSStringPboardType` alias next to `public.utf8-plain-text` on its own.
    func testWritesTextOnlyWithNoImageOrRichRepresentations() {
        ClipboardPaste.copyRecognizedText("hello", to: pasteboard)

        let types = Set(pasteboard.types ?? [])
        XCTAssertTrue(types.contains(.string))
        for unwanted: NSPasteboard.PasteboardType in [.png, .tiff, .rtf, .html, .fileURL] {
            XCTAssertFalse(types.contains(unwanted), "Unexpected \(unwanted.rawValue) on the pasteboard.")
        }
    }

    /// A second run must not leave the previous result appended or lingering under another type.
    func testReplacesPreviousContents() {
        pasteboard.clearContents()
        pasteboard.setString("older clipboard contents", forType: .string)

        ClipboardPaste.copyRecognizedText("newer", to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "newer")
    }
}
