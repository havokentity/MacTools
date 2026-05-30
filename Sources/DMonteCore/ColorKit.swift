import AppKit

/// Pure, testable colour-conversion helpers used by the Color Picker tool.
///
/// Every function normalises its input through the sRGB colour space before reading
/// components so results are stable regardless of the colour's originating space
/// (catalog colours, pattern colours, display-P3, etc.). Components are read in the
/// 0...1 range and rounded to the nearest integer for the textual representations.
public enum ColorKit {

    // MARK: - Component extraction

    /// Returns the 0...255 RGB(A) components of `color` after converting it to sRGB.
    /// Falls back to opaque black if the colour cannot be expressed in sRGB.
    public static func rgbComponents(_ color: NSColor) -> (r: Int, g: Int, b: Int, a: Int) {
        guard let srgb = color.usingColorSpace(.sRGB) else {
            return (0, 0, 0, 255)
        }
        let r = Int((srgb.redComponent * 255).rounded())
        let g = Int((srgb.greenComponent * 255).rounded())
        let b = Int((srgb.blueComponent * 255).rounded())
        let a = Int((srgb.alphaComponent * 255).rounded())
        return (clamp(r), clamp(g), clamp(b), clamp(a))
    }

    /// Returns the HSL components of `color`: hue 0...360, saturation 0...100, lightness 0...100.
    public static func hslComponents(_ color: NSColor) -> (h: Int, s: Int, l: Int) {
        guard let srgb = color.usingColorSpace(.sRGB) else {
            return (0, 0, 0)
        }
        let r = srgb.redComponent
        let g = srgb.greenComponent
        let b = srgb.blueComponent

        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let delta = maxC - minC

        let lightness = (maxC + minC) / 2

        var hue: CGFloat = 0
        var saturation: CGFloat = 0

        if delta != 0 {
            saturation = delta / (1 - abs(2 * lightness - 1))

            if maxC == r {
                hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxC == g {
                hue = ((b - r) / delta) + 2
            } else {
                hue = ((r - g) / delta) + 4
            }
            hue *= 60
            if hue < 0 { hue += 360 }
        }

        return (
            clampHue(Int(hue.rounded())),
            clampPercent(Int((saturation * 100).rounded())),
            clampPercent(Int((lightness * 100).rounded()))
        )
    }

    // MARK: - String representations

    /// Returns a hex string such as `#RRGGBB`, or `#RRGGBBAA` when `includeAlpha` is true.
    public static func hexString(_ color: NSColor, includeAlpha: Bool) -> String {
        let c = rgbComponents(color)
        if includeAlpha {
            return String(format: "#%02X%02X%02X%02X", c.r, c.g, c.b, c.a)
        }
        return String(format: "#%02X%02X%02X", c.r, c.g, c.b)
    }

    /// Returns a CSS `rgb(r, g, b)` string with 0...255 channels.
    public static func rgbString(_ color: NSColor) -> String {
        let c = rgbComponents(color)
        return "rgb(\(c.r), \(c.g), \(c.b))"
    }

    /// Returns a CSS `hsl(h, s%, l%)` string.
    public static func hslString(_ color: NSColor) -> String {
        let c = hslComponents(color)
        return "hsl(\(c.h), \(c.s)%, \(c.l)%)"
    }

    /// Returns a SwiftUI initialiser literal, e.g. `Color(red: 1.000, green: 0.000, blue: 0.000)`.
    public static func swiftUILiteral(_ color: NSColor) -> String {
        guard let srgb = color.usingColorSpace(.sRGB) else {
            return "Color(red: 0.000, green: 0.000, blue: 0.000)"
        }
        let r = String(format: "%.3f", srgb.redComponent)
        let g = String(format: "%.3f", srgb.greenComponent)
        let b = String(format: "%.3f", srgb.blueComponent)
        return "Color(red: \(r), green: \(g), blue: \(b))"
    }

    // MARK: - Parsing

    /// Parses a hex string into an `NSColor` in the sRGB space.
    ///
    /// Accepts `#RRGGBB`, `RRGGBB`, `#RGB`, `RGB`, `#RRGGBBAA`, and `RRGGBBAA`
    /// (with or without a leading `#`, case-insensitive). Returns `nil` for any
    /// other length or for non-hex characters.
    public static func color(fromHex hex: String) -> NSColor? {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") {
            cleaned.removeFirst()
        }
        guard !cleaned.isEmpty else { return nil }

        let upper = cleaned.uppercased()
        guard upper.allSatisfy({ $0.isHexDigit }) else { return nil }

        let chars = Array(upper)
        let r: CGFloat
        let g: CGFloat
        let b: CGFloat
        var a: CGFloat = 1

        switch chars.count {
        case 3:
            // #RGB shorthand: each nibble is doubled (F -> FF).
            r = component(chars[0], chars[0])
            g = component(chars[1], chars[1])
            b = component(chars[2], chars[2])
        case 6:
            r = component(chars[0], chars[1])
            g = component(chars[2], chars[3])
            b = component(chars[4], chars[5])
        case 8:
            r = component(chars[0], chars[1])
            g = component(chars[2], chars[3])
            b = component(chars[4], chars[5])
            a = component(chars[6], chars[7])
        default:
            return nil
        }

        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    // MARK: - Private helpers

    private static func component(_ high: Character, _ low: Character) -> CGFloat {
        let value = (hexValue(high) << 4) | hexValue(low)
        return CGFloat(value) / 255
    }

    private static func hexValue(_ char: Character) -> Int {
        char.hexDigitValue ?? 0
    }

    private static func clamp(_ value: Int) -> Int {
        min(255, max(0, value))
    }

    private static func clampPercent(_ value: Int) -> Int {
        min(100, max(0, value))
    }

    private static func clampHue(_ value: Int) -> Int {
        min(360, max(0, value))
    }
}
