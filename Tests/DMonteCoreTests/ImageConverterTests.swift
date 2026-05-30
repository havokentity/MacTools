import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import DMonteCore

final class ImageConverterTests: XCTestCase {
    private var workingDirectory: URL!
    private var sourcePNG: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()

        workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageConverterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        // Build a 64x64 test image straight from CoreGraphics (no AppKit needed) and
        // write it out as the PNG that every conversion case will read from.
        sourcePNG = try writeTestPNG(width: 64, height: 64)
    }

    override func tearDownWithError() throws {
        if let workingDirectory {
            try? FileManager.default.removeItem(at: workingDirectory)
        }
        workingDirectory = nil
        sourcePNG = nil
        try super.tearDownWithError()
    }

    // MARK: Format conversions

    func testConvertPNGToJPEGProducesValidImage() throws {
        let result = ImageConverterKit.convert(
            source: sourcePNG,
            to: .jpeg,
            quality: 0.8,
            maxDimension: nil,
            outputDirectory: workingDirectory
        )

        let converted = try result.get()
        XCTAssertEqual(converted.outputURL.pathExtension, "jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: converted.outputURL.path))
        XCTAssertGreaterThan(converted.byteCount, 0)
        XCTAssertEqual(converted.pixelWidth, 64)
        XCTAssertEqual(converted.pixelHeight, 64)
        assertValidImage(at: converted.outputURL)
    }

    func testConvertPNGToPNGProducesValidImage() throws {
        let result = ImageConverterKit.convert(
            source: sourcePNG,
            to: .png,
            quality: 1.0,
            maxDimension: nil,
            outputDirectory: workingDirectory
        )

        let converted = try result.get()
        XCTAssertEqual(converted.outputURL.pathExtension, "png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: converted.outputURL.path))
        XCTAssertGreaterThan(converted.byteCount, 0)
        assertValidImage(at: converted.outputURL)
    }

    // MARK: Resizing

    func testResizeClampsLongestEdgeToMaxDimension() throws {
        let result = ImageConverterKit.convert(
            source: sourcePNG,
            to: .png,
            quality: 1.0,
            maxDimension: 32,
            outputDirectory: workingDirectory
        )

        let converted = try result.get()
        XCTAssertLessThanOrEqual(converted.pixelWidth, 32)
        XCTAssertLessThanOrEqual(converted.pixelHeight, 32)

        // The written file's pixel dimensions should match what we reported.
        let (width, height) = try pixelSize(of: converted.outputURL)
        XCTAssertLessThanOrEqual(width, 32)
        XCTAssertLessThanOrEqual(height, 32)
    }

    // MARK: Failure handling

    func testConvertMissingSourceFails() {
        let missing = workingDirectory.appendingPathComponent("does-not-exist.png")
        let result = ImageConverterKit.convert(
            source: missing,
            to: .jpeg,
            quality: 0.8,
            maxDimension: nil,
            outputDirectory: workingDirectory
        )

        switch result {
        case .success:
            XCTFail("Converting a missing source should fail")
        case let .failure(error):
            XCTAssertEqual(error, .unreadableSource)
        }
    }

    // MARK: Unique naming

    func testUniqueOutputURLAvoidsCollisions() throws {
        let first = ImageConverterKit.uniqueOutputURL(for: sourcePNG, format: .jpeg, in: workingDirectory)
        FileManager.default.createFile(atPath: first.path, contents: Data([0x00]))

        let second = ImageConverterKit.uniqueOutputURL(for: sourcePNG, format: .jpeg, in: workingDirectory)
        XCTAssertNotEqual(first.standardizedFileURL, second.standardizedFileURL)
    }

    // MARK: Format metadata

    func testFormatMetadata() {
        XCTAssertTrue(ImageConverterKit.ImageFormat.jpeg.isLossy)
        XCTAssertTrue(ImageConverterKit.ImageFormat.heic.isLossy)
        XCTAssertFalse(ImageConverterKit.ImageFormat.png.isLossy)
        XCTAssertFalse(ImageConverterKit.ImageFormat.tiff.isLossy)

        XCTAssertEqual(ImageConverterKit.ImageFormat.jpeg.fileExtension, "jpg")
        XCTAssertEqual(ImageConverterKit.ImageFormat.png.utType, .png)
        XCTAssertEqual(ImageConverterKit.ImageFormat.allCases.count, 4)
    }

    // MARK: Helpers

    private func writeTestPNG(width: Int, height: Int) throws -> URL {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        // Fill with a recognisable colour and a contrasting block so encoders have
        // real (non-uniform) content to compress.
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.95, green: 0.85, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))

        let cgImage = try XCTUnwrap(context.makeImage())

        let url = workingDirectory.appendingPathComponent("source.png")
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, cgImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func assertValidImage(at url: URL, file: StaticString = #filePath, line: UInt = #line) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            XCTFail("Output at \(url.path) is not a valid image", file: file, line: line)
            return
        }
    }

    private func pixelSize(of url: URL) throws -> (Int, Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)
        return (width, height)
    }
}
