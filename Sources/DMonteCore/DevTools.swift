import CryptoKit
import Foundation

/// Pure, UI-free developer utilities. Every function here is deterministic and depends only on
/// Foundation + CryptoKit, so the whole surface can be unit-tested without spinning up AppKit.
public enum DevToolsKit {

    // MARK: - Errors

    public enum DevToolsError: Error, Equatable, Sendable {
        case invalidJSON(String)
        case invalidBase64
        case invalidURLEncoding
        case invalidEpoch
        case emptyInput
    }

    // MARK: - JSON

    /// Pretty-prints or minifies a JSON string.
    /// - Parameters:
    ///   - input: Raw JSON text.
    ///   - pretty: When `true`, output is indented and key-sorted; otherwise it is compact.
    /// - Returns: The reformatted JSON, or a descriptive error for invalid input.
    public static func formatJSON(_ input: String, pretty: Bool) -> Result<String, DevToolsError> {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.emptyInput)
        }

        guard let data = trimmed.data(using: .utf8) else {
            return .failure(.invalidJSON("Input is not valid UTF-8 text."))
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            return .failure(.invalidJSON(error.localizedDescription))
        }

        var options: JSONSerialization.WritingOptions = [.fragmentsAllowed]
        if pretty {
            options.insert(.prettyPrinted)
            options.insert(.sortedKeys)
            options.insert(.withoutEscapingSlashes)
        } else {
            options.insert(.withoutEscapingSlashes)
        }

        guard let output = try? JSONSerialization.data(withJSONObject: object, options: options),
              let string = String(data: output, encoding: .utf8) else {
            return .failure(.invalidJSON("Could not re-serialize the parsed JSON."))
        }

        return .success(string)
    }

    // MARK: - Base64

    /// Encodes UTF-8 text to a base64 string.
    public static func base64Encode(_ input: String) -> String {
        Data(input.utf8).base64EncodedString()
    }

    /// Decodes a base64 string back to UTF-8 text.
    public static func base64Decode(_ input: String) -> Result<String, DevToolsError> {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.emptyInput)
        }

        guard let data = Data(base64Encoded: trimmed, options: [.ignoreUnknownCharacters]),
              let string = String(data: data, encoding: .utf8) else {
            return .failure(.invalidBase64)
        }

        return .success(string)
    }

    // MARK: - URL

    /// Percent-encodes text so it is safe inside a URL query component.
    public static func urlEncode(_ input: String) -> String {
        // Start from the query-allowed set, then remove the sub-delimiters that commonly need
        // escaping so the result is safe to drop into a query value verbatim.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=?#%/:;@$,!'()*[] ")
        return input.addingPercentEncoding(withAllowedCharacters: allowed) ?? input
    }

    /// Decodes a percent-encoded string.
    public static func urlDecode(_ input: String) -> Result<String, DevToolsError> {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.emptyInput)
        }

        guard let decoded = trimmed.removingPercentEncoding else {
            return .failure(.invalidURLEncoding)
        }

        return .success(decoded)
    }

    // MARK: - Hashes

    public static func md5(_ input: String) -> String {
        hexString(Insecure.MD5.hash(data: Data(input.utf8)))
    }

    public static func sha1(_ input: String) -> String {
        hexString(Insecure.SHA1.hash(data: Data(input.utf8)))
    }

    public static func sha256(_ input: String) -> String {
        hexString(SHA256.hash(data: Data(input.utf8)))
    }

    public static func sha512(_ input: String) -> String {
        hexString(SHA512.hash(data: Data(input.utf8)))
    }

    private static func hexString<H: Sequence>(_ digest: H) -> String where H.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - UUID

    /// Generates a fresh UUID string.
    public static func uuid(uppercase: Bool) -> String {
        let value = UUID().uuidString
        return uppercase ? value.uppercased() : value.lowercased()
    }

    // MARK: - Unix timestamp

    /// Converts epoch seconds to a localized, human-readable date string (UTC).
    public static func epochToDate(_ epoch: Double) -> Result<String, DevToolsError> {
        guard epoch.isFinite else {
            return .failure(.invalidEpoch)
        }

        let date = Date(timeIntervalSince1970: epoch)
        return .success(isoFormatter.string(from: date))
    }

    /// Parses epoch seconds from a string (accepts seconds or millisecond timestamps).
    public static func parseEpoch(_ input: String) -> Result<Double, DevToolsError> {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.emptyInput)
        }

        guard let value = Double(trimmed) else {
            return .failure(.invalidEpoch)
        }

        // Heuristic: 13+ digit integers are almost certainly milliseconds.
        if trimmed.allSatisfy(\.isNumber), trimmed.count >= 13 {
            return .success(value / 1000)
        }

        return .success(value)
    }

    /// Converts an ISO-8601 (UTC) date string back to epoch seconds.
    public static func dateToEpoch(_ input: String) -> Result<Double, DevToolsError> {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.emptyInput)
        }

        if let date = isoFormatter.date(from: trimmed) {
            return .success(date.timeIntervalSince1970.rounded())
        }

        // Fall back to a fractional-seconds ISO parser for richer inputs.
        if let date = isoFractionalFormatter.date(from: trimmed) {
            return .success(date.timeIntervalSince1970.rounded())
        }

        return .failure(.invalidEpoch)
    }

    /// Current epoch in whole seconds.
    public static func currentEpoch() -> Int {
        Int(Date().timeIntervalSince1970)
    }

    // `ISO8601DateFormatter` is not `Sendable`, but these instances are immutable after init and
    // only ever read, which is thread-safe — so the unchecked annotation is sound under Swift 6.
    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    nonisolated(unsafe) private static let isoFractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    // MARK: - Case conversion

    public enum CaseStyle: String, CaseIterable, Identifiable, Sendable {
        case lower
        case upper
        case title
        case camel
        case snake
        case kebab

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .lower: "lower"
            case .upper: "UPPER"
            case .title: "Title"
            case .camel: "camelCase"
            case .snake: "snake_case"
            case .kebab: "kebab-case"
            }
        }
    }

    /// Converts arbitrary text to the requested case style.
    public static func convertCase(_ input: String, to style: CaseStyle) -> String {
        switch style {
        case .lower:
            return input.lowercased()
        case .upper:
            return input.uppercased()
        case .title:
            return titleCased(input)
        case .camel:
            return camelCased(words(in: input))
        case .snake:
            return joinedLowercased(words(in: input), separator: "_")
        case .kebab:
            return joinedLowercased(words(in: input), separator: "-")
        }
    }

    /// Title-cases each whitespace-separated word while preserving the original spacing.
    private static func titleCased(_ input: String) -> String {
        input
            .split(separator: " ", omittingEmptySubsequences: false)
            .map { piece -> String in
                guard let first = piece.first else { return String(piece) }
                return first.uppercased() + piece.dropFirst().lowercased()
            }
            .joined(separator: " ")
    }

    private static func camelCased(_ words: [String]) -> String {
        guard let first = words.first else { return "" }
        let tail = words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
        return ([first.lowercased()] + tail).joined()
    }

    private static func joinedLowercased(_ words: [String], separator: String) -> String {
        words.map { $0.lowercased() }.joined(separator: separator)
    }

    /// Splits arbitrary text into word tokens, understanding spaces, common delimiters, and
    /// camelCase/PascalCase boundaries so any input can be re-cased cleanly.
    private static func words(in input: String) -> [String] {
        var tokens: [String] = []
        var current = ""

        func flush() {
            if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }

        let characters = Array(input)
        for (index, character) in characters.enumerated() {
            if character == " " || character == "_" || character == "-" || character == "." || character == "/" {
                flush()
                continue
            }

            // Break before an uppercase letter that follows a lowercase letter or digit
            // (camelCase / PascalCase boundary), e.g. "myValue" -> ["my", "Value"].
            if character.isUppercase, index > 0 {
                let previous = characters[index - 1]
                if previous.isLowercase || previous.isNumber {
                    flush()
                }
            }

            current.append(character)
        }
        flush()

        return tokens
    }
}
