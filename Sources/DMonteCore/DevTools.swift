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
        /// The token did not have the three dot-separated segments a compact JWS requires; the
        /// payload is the count actually found, so the message can distinguish a JWE (five) from
        /// a truncated paste.
        case invalidJWTStructure(Int)
        case invalidJWTSegment(JWTSegment)
        case invalidJWTJSON(JWTSegment)
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

        guard let data = base64DecodedData(trimmed), !data.isEmpty,
              let string = String(data: data, encoding: .utf8) else {
            return .failure(.invalidBase64)
        }

        return .success(string)
    }

    /// Decodes base64 in either alphabet, padded or not, to raw bytes.
    ///
    /// Two independent leniencies live here. The *alphabet*: base64url (RFC 4648 §5) swaps "+"
    /// and "/" for "-" and "_", which `Data(base64Encoded:)` does not know about. The *padding*:
    /// JWS segments (RFC 7515 §2) and plenty of CLI output drop the trailing "=", which the same
    /// initializer insists on. Everything else stays strict, so genuinely invalid input (e.g.
    /// "@@@@") still fails rather than decoding to empty.
    static func base64DecodedData(_ input: String) -> Data? {
        let cleaned = input
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Append the padding rather than `padding(toLength:)`: that API measures in UTF-16
        // units while `count` measures Characters, so a non-ASCII paste could silently get
        // truncated instead of padded.
        let padded = cleaned + String(repeating: "=", count: (4 - cleaned.count % 4) % 4)
        return Data(base64Encoded: padded)
    }

    // MARK: - JWT

    /// One of the two decodable segments of a compact JWS, so a failure can name the part that
    /// went wrong instead of reporting a shapeless “bad token”.
    public enum JWTSegment: Equatable, Sendable {
        case header
        case payload

        public var label: String {
            switch self {
            case .header: "header"
            case .payload: "payload"
            }
        }
    }

    /// A well-known NumericDate claim (RFC 7519 §4.1) rendered for a human reader.
    public struct JWTTimeClaim: Equatable, Sendable {
        /// The claim name exactly as it appears in the payload, e.g. "exp".
        public let name: String
        /// What the claim means in words, e.g. "Expires".
        public let label: String
        /// Epoch seconds as the token carried them, kept so the reader can cross-check the date.
        public let epoch: Double
        /// Absolute time in UTC. Tokens are minted against UTC and the neighbouring raw epoch is
        /// UTC too, so rendering local time here would invite a mis-comparison.
        public let date: String
        /// Signed hint against the reference instant, e.g. "in 2 hours" / "5 minutes ago".
        public let relative: String
    }

    /// What `exp` and `nbf` say about a token at a given instant. This is a claims-only verdict:
    /// nothing here implies the signature is genuine.
    public enum JWTValidity: Equatable, Sendable {
        case active
        case expired
        case notYetValid
        /// The token carries no usable `exp`, so it cannot be called live or dead.
        case unknown

        public var label: String {
            switch self {
            case .active: "Active"
            case .expired: "Expired"
            case .notYetValid: "Not yet valid"
            case .unknown: "No expiry claim"
            }
        }
    }

    /// A decoded compact JWS. The signature is carried through verbatim and never checked —
    /// verification needs the issuer's key and a policy for which algorithms to trust, neither of
    /// which a paste-in decoder can honestly supply.
    public struct DecodedJWT: Equatable, Sendable {
        /// Pretty-printed header JSON.
        public let header: String
        /// Pretty-printed payload JSON.
        public let payload: String
        /// The third segment verbatim, still base64url. Opaque by design.
        public let signature: String
        /// `alg` from the header, when present and a string.
        public let algorithm: String?
        /// `typ` from the header, when present and a string.
        public let type: String?
        /// `iat`, `nbf` and `exp` in that chronological reading order, skipping absent claims.
        public let timeClaims: [JWTTimeClaim]
        public let validity: JWTValidity

        /// Fixed wording shown beside the signature so nobody reads a successful decode as a
        /// successful verification.
        public static let signatureNotice =
            "Not verified — decoding a JWT says nothing about whether it is authentic."

        /// What to render in the signature field. An empty third segment means one of two very
        /// different things, and only the header can tell them apart: `alg: none` is the unsecured
        /// JWS of RFC 7519 §6, while any real algorithm with nothing to show means the signature
        /// went missing — almost always a truncated paste. Calling the second case “unsecured”
        /// would tell the reader the token is something it is not.
        public var signatureDisplay: String {
            guard signature.isEmpty else { return signature }

            guard let algorithm else {
                return "missing — the header declares no alg, so this token looks truncated"
            }

            guard algorithm.lowercased() != "none" else {
                return "none — unsecured token (alg: none)"
            }

            return "missing — the header declares alg: \(algorithm), so this token looks truncated"
        }
    }

    /// Decodes a compact JWS into its header, payload and (unverified) signature.
    /// - Parameters:
    ///   - input: The pasted token. A leading "Bearer " and any wrapping whitespace are tolerated.
    ///   - now: The instant the `exp`/`nbf` verdict and relative hints are measured against;
    ///     injectable so the rendering is testable without a clock.
    public static func decodeJWT(_ input: String, now: Date = Date()) -> Result<DecodedJWT, DevToolsError> {
        var trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.emptyInput)
        }

        // Tokens are most often copied straight out of an Authorization header, so drop the
        // scheme instead of failing on it.
        if let scheme = trimmed.range(of: "Bearer ", options: [.caseInsensitive, .anchored]) {
            trimmed = String(trimmed[scheme.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Wrapped pastes carry newlines mid-token; the compact serialization never does.
        let compact = trimmed.components(separatedBy: .whitespacesAndNewlines).joined()
        let segments = compact.components(separatedBy: ".")
        guard segments.count == 3 else {
            return .failure(.invalidJWTStructure(segments.count))
        }

        let header: (text: String, object: [String: Any])
        switch decodeJWTSegment(segments[0], as: .header) {
        case let .success(value): header = value
        case let .failure(error): return .failure(error)
        }

        let payload: (text: String, object: [String: Any])
        switch decodeJWTSegment(segments[1], as: .payload) {
        case let .success(value): payload = value
        case let .failure(error): return .failure(error)
        }

        let reference = now.timeIntervalSince1970
        // Read order follows the token's own lifecycle rather than the alphabet, so the pane
        // reads top-to-bottom as issued -> usable -> dead.
        let wellKnown: [(name: String, label: String)] = [
            ("iat", "Issued at"),
            ("nbf", "Not before"),
            ("exp", "Expires")
        ]
        let timeClaims: [JWTTimeClaim] = wellKnown.compactMap { claim in
            guard let epoch = numericDate(payload.object[claim.name]) else { return nil }
            guard case let .success(date) = epochToDate(epoch) else { return nil }
            return JWTTimeClaim(
                name: claim.name,
                label: claim.label,
                epoch: epoch,
                date: date,
                relative: relativeHint(secondsFromNow: epoch - reference)
            )
        }

        let expiry = numericDate(payload.object["exp"])
        let notBefore = numericDate(payload.object["nbf"])
        let validity: JWTValidity
        if let expiry, expiry <= reference {
            // Expiry beats "not yet valid": a dead token is dead whatever its nbf claims.
            validity = .expired
        } else if let notBefore, notBefore > reference {
            validity = .notYetValid
        } else if expiry != nil {
            validity = .active
        } else {
            validity = .unknown
        }

        return .success(
            DecodedJWT(
                header: header.text,
                payload: payload.text,
                signature: segments[2],
                algorithm: header.object["alg"] as? String,
                type: header.object["typ"] as? String,
                timeClaims: timeClaims,
                validity: validity
            )
        )
    }

    /// Base64url-decodes one JWT segment and pretty-prints it as a JSON object.
    private static func decodeJWTSegment(
        _ segment: String,
        as part: JWTSegment
    ) -> Result<(text: String, object: [String: Any]), DevToolsError> {
        guard let data = base64DecodedData(segment), !data.isEmpty else {
            return .failure(.invalidJWTSegment(part))
        }

        // Both segments are defined as JSON *objects*; a bare array or number decoding cleanly
        // still means this is not a JWT, so reject it rather than showing a confusing fragment.
        guard let parsed = try? JSONSerialization.jsonObject(with: data),
              let object = parsed as? [String: Any] else {
            return .failure(.invalidJWTJSON(part))
        }

        // Sorted keys keep the rendering stable across pastes; a claims set is an unordered JSON
        // object, so there is no authored order worth preserving.
        guard let pretty = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ), let text = String(data: pretty, encoding: .utf8) else {
            return .failure(.invalidJWTJSON(part))
        }

        return .success((text, object))
    }

    /// Reads a NumericDate claim. RFC 7519 §2 defines it as a JSON number, but issuers do ship it
    /// as a string, so accept both rather than silently dropping the claim.
    private static func numericDate(_ value: Any?) -> Double? {
        let seconds: Double?
        if let number = value as? NSNumber {
            // `true`/`false` arrive as `NSNumber` too and would otherwise render as 1970. Test the
            // CoreFoundation type rather than `is Bool`: that cast succeeds for *any* NSNumber
            // losslessly convertible to a boolean, so it also swallows the numbers 0 and 1 — and
            // `exp: 0` is a real (if sloppy) way to say "already expired".
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            seconds = number.doubleValue
        } else if let string = value as? String {
            seconds = Double(string)
        } else {
            seconds = nil
        }

        // Reject anything outside the four-digit-year window the ISO-8601 output can represent.
        // `ISO8601DateFormatter` silently clamps an out-of-range date instead of failing, and a
        // clamped value reads as a confident far-future timestamp — worse than no row at all.
        // The raw number is still visible in the payload JSON, so nothing is hidden by dropping it.
        guard let seconds, seconds.isFinite,
              seconds >= -62_167_219_200, seconds <= 253_402_300_799 else {
            return nil
        }

        return seconds
    }

    /// Renders a signed offset from "now" as a short hint like "in 2 hours" or "5 minutes ago".
    /// Hand-rolled rather than `RelativeDateTimeFormatter` because that formatter's wording shifts
    /// with locale and OS version, and this string is asserted on in tests.
    static func relativeHint(secondsFromNow seconds: Double) -> String {
        guard seconds.isFinite else { return "unknown" }
        // `Int(_: Double)` traps above `Int.max` and the reference instant is caller-supplied, so
        // cap the offset before converting rather than letting an absurd `now` crash the decoder.
        let magnitude = min(abs(seconds), 1e15)
        guard magnitude >= 1 else { return "now" }

        // Round first, then promote to the next unit if the count reached that unit's limit —
        // otherwise the last half-second before a boundary reads "in 60 minutes" rather than
        // "in 1 hour", which is exactly when someone is staring at a token about to expire.
        let units: [(seconds: Double, name: String, limit: Int)] = [
            (1, "second", 60),
            (60, "minute", 60),
            (3600, "hour", 24),
            (86_400, "day", .max)
        ]
        var count = 0
        var unit = ""
        for candidate in units {
            count = Int((magnitude / candidate.seconds).rounded())
            unit = candidate.name
            if count < candidate.limit { break }
        }

        let phrase = "\(count) \(unit)\(count == 1 ? "" : "s")"
        return seconds >= 0 ? "in \(phrase)" : "\(phrase) ago"
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
