import AppKit
import XCTest
@testable import DMonteCore

final class QRKitTests: XCTestCase {
    func testGenerateReturnsImageForNonEmptyText() {
        let image = QRKit.generate("https://example.com", scale: 8)
        XCTAssertNotNil(image, "Generating a QR for a valid string should return an image")
        if let image {
            XCTAssertGreaterThan(image.size.width, 0)
            XCTAssertGreaterThan(image.size.height, 0)
        }
    }

    func testGenerateReturnsNilForEmptyString() {
        XCTAssertNil(QRKit.generate("", scale: 8))
    }

    func testGenerateReturnsNilForWhitespaceOnlyString() {
        XCTAssertNil(QRKit.generate("   \n\t ", scale: 8))
    }

    func testRoundTripGenerateRenderDecode() throws {
        let payload = "https://dmonte.example/round-trip-\(UUID().uuidString)"

        let image = try XCTUnwrap(
            QRKit.generate(payload, scale: 12),
            "Generation should succeed for a known payload"
        )

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("qrkit-test-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        XCTAssertTrue(
            QRKit.writePNG(image, to: tempURL),
            "Rendering the generated QR to a PNG file should succeed"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))

        let decoded = QRKit.decode(imageAt: tempURL)
        XCTAssertTrue(
            decoded.contains(payload),
            "Decoding the rendered QR should recover the original payload. Decoded: \(decoded)"
        )
    }

    func testDecodeMissingFileReturnsEmpty() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).png")
        XCTAssertEqual(QRKit.decode(imageAt: missing), [])
    }
}
