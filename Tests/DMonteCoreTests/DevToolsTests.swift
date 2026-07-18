import XCTest
@testable import DMonteCore

final class DevToolsTests: XCTestCase {

    // MARK: - JSON

    func testFormatJSONPrettyPrintsAndSortsKeys() {
        let input = "{\"b\":1,\"a\":2}"
        let result = DevToolsKit.formatJSON(input, pretty: true)
        switch result {
        case let .success(output):
            // Sorted keys means "a" precedes "b" and pretty printing adds newlines.
            XCTAssertTrue(output.contains("\"a\""))
            XCTAssertTrue(output.contains("\"b\""))
            XCTAssertTrue(output.contains("\n"))
            let aIndex = output.range(of: "\"a\"")!.lowerBound
            let bIndex = output.range(of: "\"b\"")!.lowerBound
            XCTAssertLessThan(aIndex, bIndex)
        case let .failure(error):
            XCTFail("Expected success, got \(error)")
        }
    }

    func testFormatJSONMinifyRemovesWhitespace() {
        let input = """
        {
            "name": "value",
            "count": 3
        }
        """
        let result = DevToolsKit.formatJSON(input, pretty: false)
        switch result {
        case let .success(output):
            XCTAssertFalse(output.contains("\n"))
            XCTAssertFalse(output.contains("  "))
            XCTAssertTrue(output.contains("\"name\":\"value\""))
        case let .failure(error):
            XCTFail("Expected success, got \(error)")
        }
    }

    func testFormatJSONInvalidReturnsError() {
        let result = DevToolsKit.formatJSON("{not valid}", pretty: true)
        switch result {
        case .success:
            XCTFail("Expected failure for invalid JSON")
        case let .failure(error):
            guard case .invalidJSON = error else {
                return XCTFail("Expected invalidJSON, got \(error)")
            }
        }
    }

    func testFormatJSONEmptyReturnsEmptyError() {
        let result = DevToolsKit.formatJSON("   ", pretty: true)
        XCTAssertEqual(result, .failure(.emptyInput))
    }

    func testFormatJSONHandlesArrayFragment() {
        let result = DevToolsKit.formatJSON("[1,2,3]", pretty: false)
        XCTAssertEqual(result, .success("[1,2,3]"))
    }

    // MARK: - Base64

    func testBase64RoundTrip() {
        let original = "Hello, world! 🌍"
        let encoded = DevToolsKit.base64Encode(original)
        XCTAssertEqual(DevToolsKit.base64Decode(encoded), .success(original))
    }

    func testBase64EncodeKnownVector() {
        XCTAssertEqual(DevToolsKit.base64Encode("abc"), "YWJj")
    }

    func testBase64DecodeKnownVector() {
        XCTAssertEqual(DevToolsKit.base64Decode("YWJj"), .success("abc"))
    }

    func testBase64DecodeAcceptsUnpaddedInput() {
        XCTAssertEqual(DevToolsKit.base64Decode("aGVsbG8"), .success("hello"))
    }

    func testBase64DecodeAcceptsUnpaddedJWTSegment() {
        // JWS/JWT payload segments are base64url with the padding stripped (RFC 7515).
        XCTAssertEqual(
            DevToolsKit.base64Decode("eyJzdWIiOiIxMjM0NTY3ODkwIn0"),
            .success(#"{"sub":"1234567890"}"#)
        )
    }

    func testBase64DecodeAcceptsBase64URLAlphabet() {
        // base64url swaps "+" and "/" for "-" and "_": "Pz8+"/"Pz8/" become "Pz8-"/"Pz8_".
        XCTAssertEqual(DevToolsKit.base64Decode("Pz8-"), .success("??>"))
        XCTAssertEqual(DevToolsKit.base64Decode("Pz8_"), .success("???"))
    }

    func testBase64DecodeInvalidReturnsError() {
        // "@@@@" cannot decode to valid UTF-8 text.
        let result = DevToolsKit.base64Decode("@@@@")
        XCTAssertEqual(result, .failure(.invalidBase64))
    }

    func testBase64DecodeRejectsNonASCIIInput() {
        // Padding is computed from `count` (Characters) but applied by string concatenation,
        // so multi-unit scalars must still fall through to a clean error rather than being
        // truncated into something that decodes.
        XCTAssertEqual(DevToolsKit.base64Decode("🌍🌍🌍"), .failure(.invalidBase64))
        XCTAssertEqual(DevToolsKit.base64Decode("YWJj🌍"), .failure(.invalidBase64))
    }

    func testBase64DecodeEmptyReturnsEmptyError() {
        XCTAssertEqual(DevToolsKit.base64Decode(""), .failure(.emptyInput))
    }

    // MARK: - JWT

    // The canonical HS256 example token: {"alg":"HS256","typ":"JWT"} over
    // {"sub":"1234567890","name":"John Doe","iat":1516239022}. Its payload segment is 74
    // characters, so decoding it at all proves unpadded input is handled.
    private static let classicJWT = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
        + ".eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ"
        + ".SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"

    /// A fixed observation instant (2020-09-13T12:26:40Z) so expiry verdicts never depend on
    /// when the suite happens to run.
    private static let reference = Date(timeIntervalSince1970: 1_600_000_000)

    private func decode(_ token: String, at now: Date = DevToolsTests.reference) -> DevToolsKit.DecodedJWT? {
        switch DevToolsKit.decodeJWT(token, now: now) {
        case let .success(value):
            return value
        case let .failure(error):
            XCTFail("Expected a decoded token, got \(error)")
            return nil
        }
    }

    private func decodeError(_ token: String) -> DevToolsKit.DevToolsError? {
        switch DevToolsKit.decodeJWT(token, now: DevToolsTests.reference) {
        case let .success(value):
            XCTFail("Expected a failure, decoded \(value.payload)")
            return nil
        case let .failure(error):
            return error
        }
    }

    func testDecodeJWTHeaderAndPayload() {
        guard let token = decode(Self.classicJWT) else { return }
        XCTAssertEqual(token.algorithm, "HS256")
        XCTAssertEqual(token.type, "JWT")
        XCTAssertTrue(token.header.contains("\"HS256\""))
        XCTAssertTrue(token.payload.contains("\"John Doe\""))
        // Pretty printing means the payload spans multiple lines rather than one compact blob.
        XCTAssertTrue(token.payload.contains("\n"))
    }

    func testDecodeJWTKeepsSignatureOpaque() {
        guard let token = decode(Self.classicJWT) else { return }
        XCTAssertEqual(token.signature, "SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c")
        XCTAssertEqual(token.signatureDisplay, token.signature)
        XCTAssertTrue(DevToolsKit.DecodedJWT.signatureNotice.lowercased().contains("not verified"))
    }

    func testDecodeJWTAcceptsBase64URLAlphabet() {
        // The payload segment "eyJzdWIiOiI_cFQ-eCJ9" carries both "_" and "-", the two characters
        // base64url substitutes for "/" and "+".
        let token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiI_cFQ-eCJ9.sig"
        guard let decoded = decode(token) else { return }
        XCTAssertTrue(decoded.payload.contains("?pT>x"))
    }

    func testDecodeJWTAcceptsUnpaddedSegments() {
        // "eyJhbGciOiJub25lIn0" is 19 characters, so it needs one "=" restored before it decodes.
        guard let token = decode("eyJhbGciOiJub25lIn0.eyJzdWIiOiJ4In0.") else { return }
        XCTAssertEqual(token.algorithm, "none")
        XCTAssertTrue(token.payload.contains("\"x\""))
    }

    func testDecodeJWTUnsecuredTokenNamesTheEmptySignature() {
        guard let token = decode("eyJhbGciOiJub25lIn0.eyJzdWIiOiJ4In0.") else { return }
        XCTAssertEqual(token.signature, "")
        XCTAssertTrue(token.signatureDisplay.contains("unsecured"))
    }

    func testDecodeJWTUnsecuredVerdictIgnoresAlgorithmCasing() {
        // "eyJhbGciOiJOT05FIn0" is {"alg":"NONE"} — still the unsecured JWS, just shouted.
        guard let token = decode("eyJhbGciOiJOT05FIn0.eyJzdWIiOiJ4In0.") else { return }
        XCTAssertTrue(token.signatureDisplay.contains("unsecured"))
    }

    func testDecodeJWTEmptySignatureWithRealAlgorithmReadsAsTruncated() {
        // A signed token whose third segment was lost in the paste is not an unsecured token, and
        // saying "alg: none" here would describe a security property the header flatly denies.
        guard let token = decode("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ4In0.") else { return }
        XCTAssertEqual(token.algorithm, "HS256")
        XCTAssertEqual(token.signature, "")
        XCTAssertTrue(token.signatureDisplay.contains("truncated"))
        XCTAssertTrue(token.signatureDisplay.contains("HS256"))
        XCTAssertFalse(token.signatureDisplay.contains("unsecured"))
        XCTAssertFalse(token.signatureDisplay.contains("alg: none"))
    }

    func testDecodeJWTEmptySignatureWithNoAlgorithmReadsAsTruncated() {
        // No `alg` at all is not a claim of being unsecured either, so it gets the same treatment.
        guard let token = decode("eyJ0eXAiOiJKV1QifQ.eyJzdWIiOiJ4In0.") else { return }
        XCTAssertNil(token.algorithm)
        XCTAssertTrue(token.signatureDisplay.contains("truncated"))
        XCTAssertFalse(token.signatureDisplay.contains("unsecured"))
    }

    func testDecodeJWTExpiredToken() {
        // exp = 1516242622 (2018), well before the reference instant.
        let token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
            + ".eyJzdWIiOiJhYmMiLCJpYXQiOjE1MTYyMzkwMjIsIm5iZiI6MTUxNjIzOTAyMiwiZXhwIjoxNTE2MjQyNjIyfQ"
            + ".sig"
        guard let decoded = decode(token) else { return }
        XCTAssertEqual(decoded.validity, .expired)
        XCTAssertEqual(decoded.validity.label, "Expired")
        XCTAssertEqual(decoded.timeClaims.map(\.name), ["iat", "nbf", "exp"])
        let expiry = decoded.timeClaims.last
        XCTAssertEqual(expiry?.date, "2018-01-18T02:30:22Z")
        XCTAssertEqual(expiry?.epoch, 1_516_242_622)
        XCTAssertTrue(expiry?.relative.hasSuffix("ago") == true)
    }

    func testDecodeJWTLiveToken() {
        // exp = 4102444800 (2100-01-01), comfortably after the reference instant.
        let token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJhYmMiLCJleHAiOjQxMDI0NDQ4MDB9.sig"
        guard let decoded = decode(token) else { return }
        XCTAssertEqual(decoded.validity, .active)
        XCTAssertEqual(decoded.timeClaims.map(\.name), ["exp"])
        XCTAssertEqual(decoded.timeClaims.first?.date, "2100-01-01T00:00:00Z")
        XCTAssertTrue(decoded.timeClaims.first?.relative.hasPrefix("in ") == true)
    }

    func testDecodeJWTNotYetValidToken() {
        // nbf = 4102444800 with no exp: usable later, so neither expired nor active.
        let token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJuYmYiOjQxMDI0NDQ4MDB9.sig"
        guard let decoded = decode(token) else { return }
        XCTAssertEqual(decoded.validity, .notYetValid)
    }

    func testDecodeJWTWithoutExpiryClaimIsUnknown() {
        // The classic token carries only "iat", so no live/dead verdict can be honestly given.
        guard let token = decode(Self.classicJWT) else { return }
        XCTAssertEqual(token.validity, .unknown)
        XCTAssertEqual(token.timeClaims.map(\.name), ["iat"])
    }

    func testDecodeJWTMissingClaimsYieldNoTimeRows() {
        // No iat/nbf/exp at all: an empty list, not placeholder rows.
        guard let token = decode("eyJhbGciOiJub25lIn0.eyJzdWIiOiJ4In0.") else { return }
        XCTAssertTrue(token.timeClaims.isEmpty)
        XCTAssertEqual(token.validity, .unknown)
    }

    func testDecodeJWTAcceptsStringNumericDate() {
        // Some issuers ship exp as a JSON string; dropping the claim would hide the expiry.
        let token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOiIxNTE2MjQyNjIyIn0.sig"
        guard let decoded = decode(token) else { return }
        XCTAssertEqual(decoded.validity, .expired)
        XCTAssertEqual(decoded.timeClaims.first?.date, "2018-01-18T02:30:22Z")
    }

    func testDecodeJWTIgnoresBooleanExpiry() {
        // `true` bridges to NSNumber and would otherwise render as 1970 and read "expired".
        let token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOnRydWV9.sig"
        guard let decoded = decode(token) else { return }
        XCTAssertTrue(decoded.timeClaims.isEmpty)
        XCTAssertEqual(decoded.validity, .unknown)
    }

    func testDecodeJWTKeepsEpochZeroExpiry() {
        // exp = 0 is a sloppy but real way to mint a dead token. It must not be mistaken for the
        // boolean `false`, which shares NSNumber's bridging.
        let token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjB9.sig"
        guard let decoded = decode(token) else { return }
        XCTAssertEqual(decoded.validity, .expired)
        XCTAssertEqual(decoded.timeClaims.first?.date, "1970-01-01T00:00:00Z")
    }

    func testDecodeJWTKeepsEpochOneClaims() {
        // Likewise the number 1 casts to `true`, so an unguarded Bool check would drop this row.
        let token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpYXQiOjAsImV4cCI6MX0.sig"
        guard let decoded = decode(token) else { return }
        XCTAssertEqual(decoded.timeClaims.map(\.name), ["iat", "exp"])
        XCTAssertEqual(decoded.timeClaims.last?.date, "1970-01-01T00:00:01Z")
    }

    func testDecodeJWTExpiredBeatsNotYetValid() {
        // nbf in the far future *and* exp in the past: dead wins, whatever nbf claims.
        let token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJuYmYiOjQxMDI0NDQ4MDAsImV4cCI6MTUxNjI0MjYyMn0.sig"
        guard let decoded = decode(token) else { return }
        XCTAssertEqual(decoded.validity, .expired)
    }

    func testDecodeJWTIgnoresOutOfRangeExpiry() {
        // exp = 1e300 would be clamped by ISO8601DateFormatter into a confident-looking year
        // 5828963 date; no row is more honest than a fabricated one.
        let token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjFlKzMwMH0.sig"
        guard let decoded = decode(token) else { return }
        XCTAssertTrue(decoded.timeClaims.isEmpty)
        XCTAssertEqual(decoded.validity, .unknown)
    }

    func testDecodeJWTAcceptsFarFutureButRepresentableExpiry() {
        // Year 3000 is unusual but perfectly representable, so it must not be filtered out.
        let token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjMyNTAzNjgwMDAwfQ.sig"
        guard let decoded = decode(token) else { return }
        XCTAssertEqual(decoded.validity, .active)
        XCTAssertEqual(decoded.timeClaims.first?.date, "3000-01-01T00:00:00Z")
    }

    func testDecodeJWTStripsBearerPrefix() {
        guard let token = decode("Bearer " + Self.classicJWT) else { return }
        XCTAssertEqual(token.algorithm, "HS256")
    }

    func testDecodeJWTToleratesWrappedPaste() {
        // Terminals and log viewers wrap long tokens; the compact form never contains newlines.
        let wrapped = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.\neyJzdWIiOiJhYmMiLCJleHAiOjQxMDI0NDQ4MDB9\n.sig"
        guard let decoded = decode(wrapped) else { return }
        XCTAssertEqual(decoded.validity, .active)
    }

    func testDecodeJWTRejectsWrongSegmentCount() {
        XCTAssertEqual(decodeError("abc"), .invalidJWTStructure(1))
        XCTAssertEqual(decodeError("abc.def"), .invalidJWTStructure(2))
        XCTAssertEqual(decodeError("a.b.c.d.e"), .invalidJWTStructure(5))
    }

    func testDecodeJWTRejectsInvalidBase64Segment() {
        XCTAssertEqual(decodeError("@@@@.eyJzdWIiOiJ4In0.sig"), .invalidJWTSegment(.header))
        XCTAssertEqual(decodeError("eyJhbGciOiJub25lIn0.@@@@.sig"), .invalidJWTSegment(.payload))
    }

    func testDecodeJWTRejectsEmptySegment() {
        XCTAssertEqual(decodeError("..sig"), .invalidJWTSegment(.header))
        XCTAssertEqual(decodeError("eyJhbGciOiJub25lIn0..sig"), .invalidJWTSegment(.payload))
    }

    func testDecodeJWTRejectsNonJSONSegment() {
        // "bm90IGpzb24gYXQgYWxs" is valid base64 for "not json at all".
        XCTAssertEqual(
            decodeError("eyJhbGciOiJub25lIn0.bm90IGpzb24gYXQgYWxs.sig"),
            .invalidJWTJSON(.payload)
        )
    }

    func testDecodeJWTRejectsNonObjectJSON() {
        // "WzEsMiwzXQ" decodes to the array [1,2,3], which is JSON but not a claims set.
        XCTAssertEqual(
            decodeError("eyJhbGciOiJub25lIn0.WzEsMiwzXQ.sig"),
            .invalidJWTJSON(.payload)
        )
    }

    func testDecodeJWTEmptyInputReturnsEmptyError() {
        XCTAssertEqual(decodeError("   "), .emptyInput)
    }

    func testJWTSegmentLabels() {
        XCTAssertEqual(DevToolsKit.JWTSegment.header.label, "header")
        XCTAssertEqual(DevToolsKit.JWTSegment.payload.label, "payload")
    }

    func testRelativeHintFutureAndPast() {
        XCTAssertEqual(DevToolsKit.relativeHint(secondsFromNow: 0), "now")
        XCTAssertEqual(DevToolsKit.relativeHint(secondsFromNow: 1), "in 1 second")
        XCTAssertEqual(DevToolsKit.relativeHint(secondsFromNow: -1), "1 second ago")
        XCTAssertEqual(DevToolsKit.relativeHint(secondsFromNow: 120), "in 2 minutes")
        XCTAssertEqual(DevToolsKit.relativeHint(secondsFromNow: -7200), "2 hours ago")
        XCTAssertEqual(DevToolsKit.relativeHint(secondsFromNow: 172_800), "in 2 days")
        XCTAssertEqual(DevToolsKit.relativeHint(secondsFromNow: -86_400), "1 day ago")
    }

    func testRelativeHintPromotesAtUnitBoundaries() {
        // Rounding within a unit must not produce that unit's own limit: a token issued for an
        // hour and read a fraction of a second later is "in 1 hour", never "in 60 minutes".
        XCTAssertEqual(DevToolsKit.relativeHint(secondsFromNow: 59.6), "in 1 minute")
        XCTAssertEqual(DevToolsKit.relativeHint(secondsFromNow: 3_599.6), "in 1 hour")
        XCTAssertEqual(DevToolsKit.relativeHint(secondsFromNow: -86_399.6), "1 day ago")
        // Values comfortably inside a unit still read in that unit.
        XCTAssertEqual(DevToolsKit.relativeHint(secondsFromNow: 3_000), "in 50 minutes")
        XCTAssertEqual(DevToolsKit.relativeHint(secondsFromNow: 82_800), "in 23 hours")
    }

    func testRelativeHintSurvivesAbsurdReferenceInstants() {
        // `now` is caller-supplied, and `Int(_: Double)` traps past `Int.max`; these must return
        // a string rather than crash the decoder.
        XCTAssertEqual(DevToolsKit.relativeHint(secondsFromNow: .infinity), "unknown")
        XCTAssertEqual(DevToolsKit.relativeHint(secondsFromNow: .nan), "unknown")
        XCTAssertFalse(DevToolsKit.relativeHint(secondsFromNow: -.greatestFiniteMagnitude).isEmpty)
    }

    func testJWTValidityLabelsAreStable() {
        XCTAssertEqual(DevToolsKit.JWTValidity.active.label, "Active")
        XCTAssertEqual(DevToolsKit.JWTValidity.expired.label, "Expired")
        XCTAssertEqual(DevToolsKit.JWTValidity.notYetValid.label, "Not yet valid")
        XCTAssertEqual(DevToolsKit.JWTValidity.unknown.label, "No expiry claim")
    }

    // MARK: - URL

    func testURLRoundTrip() {
        let original = "key=value & more/stuff?x=1"
        let encoded = DevToolsKit.urlEncode(original)
        XCTAssertFalse(encoded.contains(" "))
        XCTAssertEqual(DevToolsKit.urlDecode(encoded), .success(original))
    }

    func testURLEncodeEscapesSpaceAndAmpersand() {
        let encoded = DevToolsKit.urlEncode("a b&c")
        XCTAssertEqual(encoded, "a%20b%26c")
    }

    func testURLDecodeKnownVector() {
        XCTAssertEqual(DevToolsKit.urlDecode("a%20b%26c"), .success("a b&c"))
    }

    func testURLDecodeInvalidReturnsError() {
        // A lone, malformed percent escape is not decodable.
        let result = DevToolsKit.urlDecode("%zz")
        XCTAssertEqual(result, .failure(.invalidURLEncoding))
    }

    func testURLDecodeEmptyReturnsEmptyError() {
        XCTAssertEqual(DevToolsKit.urlDecode("  "), .failure(.emptyInput))
    }

    // MARK: - Hashes

    func testMD5KnownVector() {
        XCTAssertEqual(DevToolsKit.md5("abc"), "900150983cd24fb0d6963f7d28e17f72")
    }

    func testSHA1KnownVector() {
        XCTAssertEqual(DevToolsKit.sha1("abc"), "a9993e364706816aba3e25717850c26c9cd0d89d")
    }

    func testSHA256KnownVector() {
        XCTAssertEqual(
            DevToolsKit.sha256("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testSHA512KnownVector() {
        XCTAssertEqual(
            DevToolsKit.sha512("abc"),
            "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a"
                + "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"
        )
    }

    func testHashesAreLowercaseHex() {
        let hash = DevToolsKit.sha256("anything")
        XCTAssertEqual(hash.count, 64)
        XCTAssertTrue(hash.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    func testEmptyStringHashes() {
        // Empty input still produces a valid digest of the expected length.
        XCTAssertEqual(DevToolsKit.md5("").count, 32)
        XCTAssertEqual(DevToolsKit.sha1("").count, 40)
        XCTAssertEqual(DevToolsKit.sha256("").count, 64)
        XCTAssertEqual(DevToolsKit.sha512("").count, 128)
    }

    // MARK: - UUID

    func testUUIDFormatAndLength() {
        let lower = DevToolsKit.uuid(uppercase: false)
        XCTAssertEqual(lower.count, 36)
        XCTAssertEqual(lower.filter { $0 == "-" }.count, 4)
        XCTAssertEqual(lower, lower.lowercased())
        XCTAssertNotNil(UUID(uuidString: lower))
    }

    func testUUIDUppercase() {
        let upper = DevToolsKit.uuid(uppercase: true)
        XCTAssertEqual(upper, upper.uppercased())
        XCTAssertNotNil(UUID(uuidString: upper))
    }

    func testUUIDsAreUnique() {
        let first = DevToolsKit.uuid(uppercase: false)
        let second = DevToolsKit.uuid(uppercase: false)
        XCTAssertNotEqual(first, second)
    }

    // MARK: - Timestamp

    func testEpochToDateKnownVector() {
        // 1700000000 == 2023-11-14T22:13:20Z
        let result = DevToolsKit.epochToDate(1_700_000_000)
        XCTAssertEqual(result, .success("2023-11-14T22:13:20Z"))
    }

    func testDateToEpochKnownVector() {
        let result = DevToolsKit.dateToEpoch("2023-11-14T22:13:20Z")
        XCTAssertEqual(result, .success(1_700_000_000))
    }

    func testEpochDateRoundTrip() {
        let epoch: Double = 1_650_000_000
        guard case let .success(dateString) = DevToolsKit.epochToDate(epoch) else {
            return XCTFail("Expected date string")
        }
        XCTAssertEqual(DevToolsKit.dateToEpoch(dateString), .success(epoch))
    }

    func testParseEpochTreatsLongValuesAsMilliseconds() {
        // 13-digit input is interpreted as milliseconds and divided down to seconds.
        XCTAssertEqual(DevToolsKit.parseEpoch("1700000000000"), .success(1_700_000_000))
    }

    func testParseEpochSeconds() {
        XCTAssertEqual(DevToolsKit.parseEpoch("1700000000"), .success(1_700_000_000))
    }

    func testParseEpochInvalidReturnsError() {
        XCTAssertEqual(DevToolsKit.parseEpoch("not-a-number"), .failure(.invalidEpoch))
    }

    func testDateToEpochInvalidReturnsError() {
        XCTAssertEqual(DevToolsKit.dateToEpoch("not-a-date"), .failure(.invalidEpoch))
    }

    func testCurrentEpochIsPositive() {
        XCTAssertGreaterThan(DevToolsKit.currentEpoch(), 1_600_000_000)
    }

    // MARK: - Case conversion

    func testConvertCaseLower() {
        XCTAssertEqual(DevToolsKit.convertCase("Hello World", to: .lower), "hello world")
    }

    func testConvertCaseUpper() {
        XCTAssertEqual(DevToolsKit.convertCase("Hello World", to: .upper), "HELLO WORLD")
    }

    func testConvertCaseTitle() {
        XCTAssertEqual(DevToolsKit.convertCase("hello world", to: .title), "Hello World")
    }

    func testConvertCaseCamelFromSpaces() {
        XCTAssertEqual(DevToolsKit.convertCase("hello world foo", to: .camel), "helloWorldFoo")
    }

    func testConvertCaseCamelFromSnake() {
        XCTAssertEqual(DevToolsKit.convertCase("my_variable_name", to: .camel), "myVariableName")
    }

    func testConvertCaseSnakeFromCamel() {
        XCTAssertEqual(DevToolsKit.convertCase("myVariableName", to: .snake), "my_variable_name")
    }

    func testConvertCaseSnakeFromSpaces() {
        XCTAssertEqual(DevToolsKit.convertCase("Hello World", to: .snake), "hello_world")
    }

    func testConvertCaseKebabFromCamel() {
        XCTAssertEqual(DevToolsKit.convertCase("myVariableName", to: .kebab), "my-variable-name")
    }

    func testConvertCaseKebabFromMixedDelimiters() {
        XCTAssertEqual(DevToolsKit.convertCase("foo_bar-baz qux", to: .kebab), "foo-bar-baz-qux")
    }

    func testConvertCasePascalCaseInputToSnake() {
        // Boundaries are inserted before an uppercase letter that follows a lowercase letter,
        // so a run of capitals stays together: "MyHTTPServer" -> ["My", "HTTPServer"].
        XCTAssertEqual(DevToolsKit.convertCase("MyHTTPServer", to: .snake), "my_httpserver")
    }

    func testConvertCasePascalCaseToCamel() {
        XCTAssertEqual(DevToolsKit.convertCase("FooBar", to: .camel), "fooBar")
    }

    func testConvertCaseEmptyInput() {
        XCTAssertEqual(DevToolsKit.convertCase("", to: .camel), "")
    }

    func testCaseStyleLabelsAreStable() {
        XCTAssertEqual(DevToolsKit.CaseStyle.camel.label, "camelCase")
        XCTAssertEqual(DevToolsKit.CaseStyle.snake.label, "snake_case")
        XCTAssertEqual(DevToolsKit.CaseStyle.kebab.label, "kebab-case")
        XCTAssertEqual(DevToolsKit.CaseStyle.allCases.count, 6)
    }
}
