import AppKit
import XCTest
@testable import DMonteCore

final class ColorKitTests: XCTestCase {

    // MARK: - Helpers

    private func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    // MARK: - Hex strings

    func testHexStringRed() {
        XCTAssertEqual(ColorKit.hexString(srgb(1, 0, 0), includeAlpha: false), "#FF0000")
    }

    func testHexStringGreen() {
        XCTAssertEqual(ColorKit.hexString(srgb(0, 1, 0), includeAlpha: false), "#00FF00")
    }

    func testHexStringBlue() {
        XCTAssertEqual(ColorKit.hexString(srgb(0, 0, 1), includeAlpha: false), "#0000FF")
    }

    func testHexStringBlackAndWhite() {
        XCTAssertEqual(ColorKit.hexString(srgb(0, 0, 0), includeAlpha: false), "#000000")
        XCTAssertEqual(ColorKit.hexString(srgb(1, 1, 1), includeAlpha: false), "#FFFFFF")
    }

    func testHexStringWithAlpha() {
        // Fully opaque red carries an FF alpha byte.
        XCTAssertEqual(ColorKit.hexString(srgb(1, 0, 0, 1), includeAlpha: true), "#FF0000FF")
        // Half alpha rounds to 0x80.
        XCTAssertEqual(ColorKit.hexString(srgb(0, 0, 0, 128.0 / 255.0), includeAlpha: true), "#00000080")
    }

    // MARK: - RGB components

    func testRGBComponentsGreen() {
        let c = ColorKit.rgbComponents(srgb(0, 1, 0))
        XCTAssertEqual(c.r, 0)
        XCTAssertEqual(c.g, 255)
        XCTAssertEqual(c.b, 0)
        XCTAssertEqual(c.a, 255)
    }

    func testRGBComponentsMidGrayRounds() {
        // 0.5 * 255 = 127.5 -> rounds to 128.
        let c = ColorKit.rgbComponents(srgb(0.5, 0.5, 0.5))
        XCTAssertEqual(c.r, 128)
        XCTAssertEqual(c.g, 128)
        XCTAssertEqual(c.b, 128)
    }

    func testRGBStringFormat() {
        XCTAssertEqual(ColorKit.rgbString(srgb(0, 1, 0)), "rgb(0, 255, 0)")
    }

    // MARK: - Parsing

    func testColorFromHexGreen() {
        guard let color = ColorKit.color(fromHex: "#00FF00") else {
            return XCTFail("Expected a colour for #00FF00")
        }
        let c = ColorKit.rgbComponents(color)
        XCTAssertEqual(c.r, 0)
        XCTAssertEqual(c.g, 255)
        XCTAssertEqual(c.b, 0)
    }

    func testColorFromHexWithoutHash() {
        guard let color = ColorKit.color(fromHex: "0000FF") else {
            return XCTFail("Expected a colour for 0000FF")
        }
        let c = ColorKit.rgbComponents(color)
        XCTAssertEqual(c.r, 0)
        XCTAssertEqual(c.g, 0)
        XCTAssertEqual(c.b, 255)
    }

    func testColorFromShorthandHex() {
        // #F00 expands to #FF0000.
        guard let color = ColorKit.color(fromHex: "#F00") else {
            return XCTFail("Expected a colour for #F00")
        }
        XCTAssertEqual(ColorKit.hexString(color, includeAlpha: false), "#FF0000")
    }

    func testColorFromHexWithAlpha() {
        guard let color = ColorKit.color(fromHex: "#00000080") else {
            return XCTFail("Expected a colour for #00000080")
        }
        let c = ColorKit.rgbComponents(color)
        XCTAssertEqual(c.a, 128)
    }

    func testColorFromHexInvalidReturnsNil() {
        XCTAssertNil(ColorKit.color(fromHex: "#ZZZ"))
        XCTAssertNil(ColorKit.color(fromHex: ""))
        XCTAssertNil(ColorKit.color(fromHex: "#"))
        XCTAssertNil(ColorKit.color(fromHex: "#12345"))
    }

    // MARK: - Round trips

    func testRoundTripBlackWhiteRedMidGray() {
        for hex in ["#000000", "#FFFFFF", "#FF0000", "#808080"] {
            guard let color = ColorKit.color(fromHex: hex) else {
                return XCTFail("Expected a colour for \(hex)")
            }
            XCTAssertEqual(ColorKit.hexString(color, includeAlpha: false), hex)
        }
    }

    // MARK: - HSL

    func testHSLRedApproximate() {
        let c = ColorKit.hslComponents(srgb(1, 0, 0))
        XCTAssertEqual(c.h, 0, accuracy: 1)
        XCTAssertEqual(c.s, 100, accuracy: 1)
        XCTAssertEqual(c.l, 50, accuracy: 1)
    }

    func testHSLWhiteAndBlack() {
        let white = ColorKit.hslComponents(srgb(1, 1, 1))
        XCTAssertEqual(white.s, 0, accuracy: 1)
        XCTAssertEqual(white.l, 100, accuracy: 1)

        let black = ColorKit.hslComponents(srgb(0, 0, 0))
        XCTAssertEqual(black.s, 0, accuracy: 1)
        XCTAssertEqual(black.l, 0, accuracy: 1)
    }

    func testHSLGreenAndBlueHues() {
        let green = ColorKit.hslComponents(srgb(0, 1, 0))
        XCTAssertEqual(green.h, 120, accuracy: 1)

        let blue = ColorKit.hslComponents(srgb(0, 0, 1))
        XCTAssertEqual(blue.h, 240, accuracy: 1)
    }

    func testHSLStringFormat() {
        XCTAssertEqual(ColorKit.hslString(srgb(1, 0, 0)), "hsl(0, 100%, 50%)")
    }

    // MARK: - SwiftUI literal

    func testSwiftUILiteralRed() {
        XCTAssertEqual(
            ColorKit.swiftUILiteral(srgb(1, 0, 0)),
            "Color(red: 1.000, green: 0.000, blue: 0.000)"
        )
    }

    func testSwiftUILiteralMidGray() {
        XCTAssertEqual(
            ColorKit.swiftUILiteral(srgb(0.5, 0.5, 0.5)),
            "Color(red: 0.500, green: 0.500, blue: 0.500)"
        )
    }
}
