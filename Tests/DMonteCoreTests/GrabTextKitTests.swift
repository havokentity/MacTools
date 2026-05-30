import XCTest
import AppKit
import CoreGraphics
@testable import DMonteCore

final class GrabTextKitTests: XCTestCase {

    /// Temp files created during a test, cleaned up in `tearDown`.
    private var tempURLs: [URL] = []

    override func tearDown() {
        for url in tempURLs {
            try? FileManager.default.removeItem(at: url)
        }
        tempURLs.removeAll()
        super.tearDown()
    }

    /// Renders `string` into a PNG on disk and returns the file URL.
    ///
    /// IMPORTANT: In a headless `swift test` run, `NSImage.lockFocus()` renders
    /// BLANK. We must draw into an `NSBitmapImageRep`-backed `NSGraphicsContext`
    /// instead, which renders correctly without a window server.
    private func renderTextPNG(
        _ string: String,
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

        // White background.
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        // Black bold text, large enough for accurate recognition.
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 72),
            .foregroundColor: NSColor.black
        ]
        let attributed = NSAttributedString(string: string, attributes: attributes)
        let textSize = attributed.size()
        let origin = NSPoint(
            x: (CGFloat(width) - textSize.width) / 2,
            y: (CGFloat(height) - textSize.height) / 2
        )
        attributed.draw(at: origin)

        context.flushGraphics()
        NSGraphicsContext.current = previous

        let data = try XCTUnwrap(
            rep.representation(using: .png, properties: [:]),
            "Could not encode PNG."
        )

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dmonte-grabtext-test-\(UUID().uuidString).png")
        try data.write(to: url)
        tempURLs.append(url)
        return url
    }

    func testRecognizesRenderedText() throws {
        let url = try renderTextPNG("HELLO WORLD")
        let lines = GrabTextKit.recognizeText(in: url)
        let joined = lines.joined(separator: "\n")

        XCTAssertFalse(joined.isEmpty, "Vision should recognize some text.")
        XCTAssertTrue(
            joined.uppercased().contains("HELLO"),
            "Recognized text should contain HELLO, got: \(joined)"
        )
    }

    func testMissingFileReturnsEmpty() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("dmonte-grabtext-missing-\(UUID().uuidString).png")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))

        let lines = GrabTextKit.recognizeText(in: missing)
        XCTAssertTrue(lines.isEmpty, "Missing file should yield an empty array.")
    }
}
