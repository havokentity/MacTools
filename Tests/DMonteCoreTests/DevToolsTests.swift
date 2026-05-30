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

    func testBase64DecodeInvalidReturnsError() {
        // "@@@@" cannot decode to valid UTF-8 text.
        let result = DevToolsKit.base64Decode("@@@@")
        XCTAssertEqual(result, .failure(.invalidBase64))
    }

    func testBase64DecodeEmptyReturnsEmptyError() {
        XCTAssertEqual(DevToolsKit.base64Decode(""), .failure(.emptyInput))
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
