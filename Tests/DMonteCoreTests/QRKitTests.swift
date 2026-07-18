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

    // MARK: - Wi-Fi escaping

    func testWiFiValueEscapesEveryReservedCharacter() {
        XCTAssertEqual(QRKit.escapedWiFiValue("a;b"), #"a\;b"#)
        XCTAssertEqual(QRKit.escapedWiFiValue("a,b"), #"a\,b"#)
        XCTAssertEqual(QRKit.escapedWiFiValue("a:b"), #"a\:b"#)
        XCTAssertEqual(QRKit.escapedWiFiValue(#"a\b"#), #"a\\b"#)
        XCTAssertEqual(QRKit.escapedWiFiValue("a\"b"), #"a\"b"#)
    }

    func testWiFiValueQuotesAllHexValues() {
        // "CAFE" would otherwise be read as raw hex bytes rather than the literal name.
        XCTAssertEqual(QRKit.escapedWiFiValue("CAFE"), "\"CAFE\"")
        XCTAssertEqual(QRKit.escapedWiFiValue("1234"), "\"1234\"")
        XCTAssertEqual(QRKit.escapedWiFiValue("CAFE!"), "CAFE!")
        XCTAssertEqual(QRKit.escapedWiFiValue(""), "")
    }

    func testWiFiValueEscapingRoundTrips() {
        let values = [
            "plain",
            "semi;colon",
            "two;;semis",
            "comma,separated",
            "colon:value",
            #"back\slash"#,
            #"back\\slash"#,
            "quote\"inside",
            "\"already quoted\"",
            "CAFE",
            "deadbeef",
            "everything \\ ; , : \" at once",
            "  leading and trailing  ",
            "café ☕️ 网络",
            ";",
            "\\",
            ""
        ]

        for value in values {
            XCTAssertEqual(
                QRKit.unescapedWiFiValue(QRKit.escapedWiFiValue(value)),
                value,
                "Escaping then unescaping should be lossless for \(value.debugDescription)"
            )
        }
    }

    // MARK: - Wi-Fi payloads

    func testWiFiPayloadShape() {
        XCTAssertEqual(
            QRKit.wifiPayload(ssid: "Home", password: "secret", security: .wpa, isHidden: false),
            "WIFI:T:WPA;S:Home;P:secret;;"
        )
    }

    func testWiFiPayloadHiddenNetworkCarriesFlag() {
        XCTAssertEqual(
            QRKit.wifiPayload(ssid: "Home", password: "secret", security: .wpa, isHidden: true),
            "WIFI:T:WPA;S:Home;P:secret;H:true;;"
        )
    }

    func testWiFiPayloadOpenNetworkOmitsPassword() {
        XCTAssertEqual(
            QRKit.wifiPayload(ssid: "Cafe Guest", password: "ignored", security: .none, isHidden: false),
            "WIFI:T:nopass;S:Cafe Guest;;"
        )
    }

    func testWiFiPayloadEscapesSSIDAndPassword() {
        XCTAssertEqual(
            QRKit.wifiPayload(ssid: "Guest;Net", password: "p:a,s\"s", security: .wpa, isHidden: false),
            #"WIFI:T:WPA;S:Guest\;Net;P:p\:a\,s\"s;;"#
        )
    }

    func testWiFiPayloadKeepsSurroundingSpaces() {
        // An SSID may legitimately end in a space; trimming would produce a code that never joins.
        XCTAssertEqual(
            QRKit.wifiPayload(ssid: " Lobby ", password: " pw ", security: .wpa, isHidden: false),
            "WIFI:T:WPA;S: Lobby ;P: pw ;;"
        )
    }

    func testWiFiPayloadIsEmptyWithoutSSID() {
        XCTAssertEqual(QRKit.wifiPayload(ssid: "", password: "secret", security: .wpa, isHidden: false), "")
    }

    func testWiFiPayloadParsesBackToItsFields() {
        let awkward = [
            QRWiFiNetwork(ssid: "Guest;Net", password: "p;w", security: .wpa, isHidden: false),
            QRWiFiNetwork(ssid: "a:b,c", password: #"back\slash"#, security: .wep, isHidden: true),
            QRWiFiNetwork(ssid: "CAFE", password: "beef", security: .wpa, isHidden: false),
            QRWiFiNetwork(ssid: "quote\"ssid", password: "quote\"pw", security: .wpa, isHidden: true),
            QRWiFiNetwork(ssid: "café ☕️", password: "påsswörd", security: .wpa, isHidden: false),
            QRWiFiNetwork(ssid: "Open Network", password: "", security: .none, isHidden: false),
            QRWiFiNetwork(ssid: ";;;", password: ";;;", security: .wpa, isHidden: true)
        ]

        for network in awkward {
            let payload = QRKit.wifiPayload(
                ssid: network.ssid,
                password: network.password,
                security: network.security,
                isHidden: network.isHidden
            )
            XCTAssertEqual(
                QRKit.parseWiFiPayload(payload),
                network,
                "Payload \(payload.debugDescription) should parse back to its fields"
            )
        }
    }

    func testParseWiFiPayloadRejectsNonWiFiPayloads() {
        XCTAssertNil(QRKit.parseWiFiPayload("https://example.com"))
        XCTAssertNil(QRKit.parseWiFiPayload("WIFI:"))
        XCTAssertNil(QRKit.parseWiFiPayload("WIFI:T:WPA;P:secret;;"), "A payload with no SSID is not usable")
    }

    func testParseWiFiPayloadAcceptsWPA2AndWPA3Tokens() {
        XCTAssertEqual(QRKit.parseWiFiPayload("WIFI:T:WPA2;S:Home;P:pw;;")?.security, .wpa)
        XCTAssertEqual(QRKit.parseWiFiPayload("WIFI:T:WPA3;S:Home;P:pw;;")?.security, .wpa)
        XCTAssertEqual(QRKit.parseWiFiPayload("WIFI:S:Home;;")?.security, QRWiFiSecurity.none)
    }

    // MARK: - vCard escaping

    func testVCardValueEscapesStructuralCharactersOnly() {
        XCTAssertEqual(QRKit.escapedVCardValue("Doe, John"), #"Doe\, John"#)
        XCTAssertEqual(QRKit.escapedVCardValue("a;b"), #"a\;b"#)
        XCTAssertEqual(QRKit.escapedVCardValue(#"a\b"#), #"a\\b"#)
        XCTAssertEqual(QRKit.escapedVCardValue("line1\nline2"), #"line1\nline2"#)
        // A colon is unambiguous inside a vCard value, and "\:" is not a defined escape —
        // escaping it would put a stray backslash into every URL.
        XCTAssertEqual(QRKit.escapedVCardValue("https://example.com"), "https://example.com")
        XCTAssertEqual(QRKit.escapedVCardValue("say \"hi\""), "say \"hi\"")
    }

    func testVCardValueEscapingRoundTrips() {
        let values = [
            "plain",
            "Doe, John",
            "a;b;c",
            #"back\slash"#,
            "multi\nline\ntext",
            "https://example.com/a,b;c",
            "quote\"inside",
            "café ☕️ 网络",
            ",",
            ";",
            "\\",
            ""
        ]

        for value in values {
            XCTAssertEqual(
                QRKit.unescapedVCardValue(QRKit.escapedVCardValue(value)),
                value,
                "Escaping then unescaping should be lossless for \(value.debugDescription)"
            )
        }
    }

    func testVCardValueDropsCarriageReturns() {
        // A raw CR would terminate the property line early and truncate the card.
        XCTAssertEqual(QRKit.escapedVCardValue("line1\r\nline2"), #"line1\nline2"#)
    }

    // MARK: - Contact payloads

    func testContactPayloadOmitsEmptyProperties() {
        let contact = QRContact(firstName: "Ada", lastName: "Lovelace")
        let payload = QRKit.contactPayload(contact)

        XCTAssertEqual(
            payload,
            [
                "BEGIN:VCARD",
                "VERSION:3.0",
                "N:Lovelace;Ada;;;",
                "FN:Ada Lovelace",
                "END:VCARD"
            ].joined(separator: "\r\n")
        )
        XCTAssertFalse(payload.contains("TEL"), "An unset phone should not produce an empty property")
    }

    func testContactPayloadIncludesEveryFilledProperty() {
        let contact = QRContact(
            firstName: "Ada",
            lastName: "Lovelace",
            organization: "Analytical Engines, Ltd",
            jobTitle: "Mathematician",
            phone: "+1 555 0100",
            email: "ada@example.com",
            url: "https://example.com",
            note: "Note; with, punctuation"
        )
        let payload = QRKit.contactPayload(contact)

        XCTAssertTrue(payload.contains(#"ORG:Analytical Engines\, Ltd"#))
        XCTAssertTrue(payload.contains("TITLE:Mathematician"))
        XCTAssertTrue(payload.contains("TEL;TYPE=CELL:+1 555 0100"))
        XCTAssertTrue(payload.contains("EMAIL;TYPE=INTERNET:ada@example.com"))
        XCTAssertTrue(payload.contains("URL:https://example.com"))
        XCTAssertTrue(payload.contains(#"NOTE:Note\; with\, punctuation"#))
        XCTAssertTrue(payload.hasSuffix("END:VCARD"))
    }

    func testContactPayloadEscapesNameSeparators() {
        // The semicolons in N: are structure; the ones the user typed must not be.
        let contact = QRContact(firstName: "A;B", lastName: "C;D")
        XCTAssertTrue(QRKit.contactPayload(contact).contains(#"N:C\;D;A\;B;;;"#))
    }

    func testContactPayloadFallsBackToOrganizationForFullName() {
        let contact = QRContact(organization: "Acme")
        let payload = QRKit.contactPayload(contact)
        XCTAssertTrue(payload.contains("FN:Acme"), "FN is mandatory in vCard 3.0. Payload: \(payload)")
    }

    func testContactPayloadIsEmptyForEmptyContact() {
        XCTAssertEqual(QRKit.contactPayload(QRContact()), "")
        XCTAssertEqual(QRKit.contactPayload(QRContact(firstName: "   ", note: "\n")), "")
    }

    // MARK: - URL, email, SMS and phone payloads

    func testURLPayloadAddsSchemeOnlyWhenMissing() {
        XCTAssertEqual(QRKit.urlPayload("example.com"), "https://example.com")
        XCTAssertEqual(QRKit.urlPayload("  example.com/a?b=c  "), "https://example.com/a?b=c")
        XCTAssertEqual(QRKit.urlPayload("https://example.com"), "https://example.com")
        XCTAssertEqual(QRKit.urlPayload("HTTP://example.com"), "HTTP://example.com")
        XCTAssertEqual(QRKit.urlPayload("mailto:a@example.com"), "mailto:a@example.com")
        XCTAssertEqual(QRKit.urlPayload("ftp://example.com"), "ftp://example.com")
        XCTAssertEqual(QRKit.urlPayload(""), "")
        XCTAssertEqual(QRKit.urlPayload("   "), "")
    }

    func testEmailPayloadPercentEncodesQueryItems() {
        XCTAssertEqual(QRKit.emailPayload(address: "ada@example.com", subject: "", body: ""), "mailto:ada@example.com")
        XCTAssertEqual(
            QRKit.emailPayload(address: "ada@example.com", subject: "Hi there", body: "a&b=c"),
            "mailto:ada@example.com?subject=Hi%20there&body=a%26b%3Dc"
        )
        // "+" must be encoded: some clients would otherwise read it back as a space.
        XCTAssertEqual(
            QRKit.emailPayload(address: "ada+qr@example.com", subject: "", body: ""),
            "mailto:ada%2Bqr@example.com"
        )
        XCTAssertEqual(QRKit.emailPayload(address: "  ", subject: "Hi", body: ""), "")
    }

    func testSMSPayloadStripsFormattingFromTheNumber() {
        XCTAssertEqual(QRKit.smsPayload(number: "+1 (555) 010-0", message: ""), "SMSTO:+15550100")
        XCTAssertEqual(QRKit.smsPayload(number: "+1 555 0100", message: "On my way"), "SMSTO:+15550100:On my way")
        // The message runs to the end of the payload, so its colons need no escaping.
        XCTAssertEqual(QRKit.smsPayload(number: "5550100", message: "ETA: 10:30"), "SMSTO:5550100:ETA: 10:30")
        XCTAssertEqual(QRKit.smsPayload(number: "", message: "Hello"), "")
        XCTAssertEqual(QRKit.smsPayload(number: "+", message: "Hello"), "")
    }

    func testPhonePayloadKeepsOnlyDialableCharacters() {
        XCTAssertEqual(QRKit.phonePayload("+1 (555) 010-0"), "tel:+15550100")
        XCTAssertEqual(QRKit.phonePayload("555.0100"), "tel:5550100")
        XCTAssertEqual(QRKit.phonePayload("call me"), "")
        XCTAssertEqual(QRKit.phonePayload(""), "")
        // A "+" that isn't leading is punctuation, not a country-code marker.
        XCTAssertEqual(QRKit.phonePayload("555+0100"), "tel:5550100")
    }

    func testTextPayloadIsVerbatim() {
        XCTAssertEqual(QRKit.textPayload("  keeps  spacing  "), "  keeps  spacing  ")
        XCTAssertEqual(QRKit.textPayload("   \n "), "")
    }

    // MARK: - Draft to payload

    func testPayloadForTemplateUsesOnlyThatTemplatesFields() {
        var draft = QRTemplateDraft()
        draft.text = "free text"
        draft.url = "example.com"
        draft.wifiSSID = "Home"
        draft.wifiPassword = "secret"
        draft.emailAddress = "ada@example.com"
        draft.smsNumber = "5550100"
        draft.phoneNumber = "5550100"
        draft.contact = QRContact(firstName: "Ada")

        XCTAssertEqual(QRKit.payload(for: .text, draft: draft), "free text")
        XCTAssertEqual(QRKit.payload(for: .url, draft: draft), "https://example.com")
        XCTAssertEqual(QRKit.payload(for: .wifi, draft: draft), "WIFI:T:WPA;S:Home;P:secret;;")
        XCTAssertEqual(QRKit.payload(for: .email, draft: draft), "mailto:ada@example.com")
        XCTAssertEqual(QRKit.payload(for: .sms, draft: draft), "SMSTO:5550100")
        XCTAssertEqual(QRKit.payload(for: .phone, draft: draft), "tel:5550100")
        XCTAssertTrue(QRKit.payload(for: .contact, draft: draft).hasPrefix("BEGIN:VCARD"))
    }

    func testEmptyDraftProducesNoPayloadForAnyTemplate() {
        let draft = QRTemplateDraft()
        for template in QRTemplate.allCases {
            XCTAssertEqual(
                QRKit.payload(for: template, draft: draft),
                "",
                "\(template.title) should produce nothing from an empty draft"
            )
            XCTAssertNil(
                QRKit.generate(QRKit.payload(for: template, draft: draft), scale: 4),
                "\(template.title) should leave the preview empty rather than encode a blank record"
            )
        }
    }

    // MARK: - Payload summaries

    func testPayloadSummaryNamesKnownFormats() {
        XCTAssertEqual(QRKit.payloadSummary("WIFI:T:WPA;S:Home;P:pw;;"), "Wi-Fi network “Home”")
        XCTAssertEqual(QRKit.payloadSummary("BEGIN:VCARD\r\nVERSION:3.0\r\nEND:VCARD"), "Contact card")
        XCTAssertEqual(QRKit.payloadSummary("mailto:ada@example.com"), "Email address")
        XCTAssertEqual(QRKit.payloadSummary("SMSTO:5550100:hi"), "Text message")
        XCTAssertEqual(QRKit.payloadSummary("tel:5550100"), "Phone number")
        XCTAssertEqual(QRKit.payloadSummary("https://example.com"), "Link")
        XCTAssertNil(QRKit.payloadSummary("just some text"))
    }

    // MARK: - Template round trips

    func testEveryTemplateRoundTripsThroughRenderAndDecode() throws {
        var draft = QRTemplateDraft()
        // Deliberately loaded with the characters each format reserves.
        draft.text = "plain text; with, punctuation"
        draft.url = "example.com/path?q=a&b=c"
        draft.wifiSSID = "Guest;Net"
        draft.wifiPassword = #"p:a,s"s\word"#
        draft.wifiIsHidden = true
        draft.emailAddress = "ada@example.com"
        draft.emailSubject = "Hi there"
        draft.emailBody = "Line one & line two"
        draft.smsNumber = "+1 (555) 010-0"
        draft.smsMessage = "ETA: 10:30"
        draft.phoneNumber = "+1 555 0100"
        draft.contact = QRContact(
            firstName: "Ada",
            lastName: "Lovelace",
            organization: "Analytical Engines, Ltd",
            jobTitle: "Mathematician",
            phone: "+15550100",
            email: "ada@example.com",
            url: "https://example.com",
            note: "Note; with, punctuation"
        )

        for template in QRTemplate.allCases {
            let payload = QRKit.payload(for: template, draft: draft)
            XCTAssertFalse(payload.isEmpty, "\(template.title) should build a payload from a filled draft")

            let image = try XCTUnwrap(QRKit.generate(payload, scale: 10), "\(template.title) should render")

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("qrkit-\(template.rawValue)-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: tempURL) }

            XCTAssertTrue(QRKit.writePNG(image, to: tempURL), "\(template.title) should write a PNG")

            let decoded = QRKit.decode(imageAt: tempURL)
            XCTAssertTrue(
                decoded.contains(payload),
                "\(template.title) should decode back to its payload. Wanted \(payload.debugDescription), got \(decoded)"
            )
        }
    }

    func testWiFiPayloadSurvivesRenderDecodeAndParse() throws {
        let network = QRWiFiNetwork(
            ssid: #"Guest;Net,2 "A":B\C"#,
            password: #"p;a,s:s"w\d"#,
            security: .wpa,
            isHidden: true
        )
        let payload = QRKit.wifiPayload(
            ssid: network.ssid,
            password: network.password,
            security: network.security,
            isHidden: network.isHidden
        )

        let image = try XCTUnwrap(QRKit.generate(payload, scale: 10))
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("qrkit-wifi-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        XCTAssertTrue(QRKit.writePNG(image, to: tempURL))

        let decoded = QRKit.decode(imageAt: tempURL)
        let network2 = decoded.compactMap(QRKit.parseWiFiPayload).first
        XCTAssertEqual(network2, network, "The whole pipeline should preserve every reserved character")
    }

    // MARK: - Decoding from a file

    func testDecodeResultReportsUnreadableFile() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).png")
        XCTAssertEqual(QRKit.decodeResult(imageAt: missing), .unreadable)
    }

    func testDecodeResultReportsNonImageFile() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("qrkit-not-an-image-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        // A .png extension over text: the extension must not be what decides this.
        try "this is not an image".write(to: tempURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(QRKit.decodeResult(imageAt: tempURL), .notAnImage)
    }

    func testDecodeResultReportsAnImageWithNoCode() throws {
        let blank = try XCTUnwrap(Self.solidImage(width: 300, height: 300))
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("qrkit-blank-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        XCTAssertTrue(QRKit.writePNG(blank, to: tempURL))

        XCTAssertEqual(QRKit.decodeResult(imageAt: tempURL), .payloads([]))
    }

    func testDecodeResultFindsEveryCodeInOneImage() throws {
        let first = "https://example.com/first"
        let second = "https://example.com/second"

        let composed = try XCTUnwrap(
            Self.sideBySide(
                XCTUnwrap(QRKit.generate(first, scale: 8)),
                XCTUnwrap(QRKit.generate(second, scale: 8))
            )
        )

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("qrkit-multi-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        XCTAssertTrue(QRKit.writePNG(composed, to: tempURL))

        guard case let .payloads(payloads) = QRKit.decodeResult(imageAt: tempURL) else {
            return XCTFail("A composed image of two QR codes should decode")
        }
        XCTAssertTrue(payloads.contains(first), "Decoded: \(payloads)")
        XCTAssertTrue(payloads.contains(second), "Decoded: \(payloads)")
    }

    // MARK: - Helpers

    /// A plain white image — stands in for a photo that happens to contain no code at all.
    private static func solidImage(width: Int, height: Int) -> NSImage? {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        return image
    }

    /// Draws two codes onto one white canvas with wide margins, so each keeps the quiet zone
    /// a decoder needs. Mirrors the real case of photographing a page with several codes.
    private static func sideBySide(_ left: NSImage, _ right: NSImage) -> NSImage? {
        let margin: CGFloat = 40
        let width = left.size.width + right.size.width + margin * 3
        let height = max(left.size.height, right.size.height) + margin * 2

        let canvas = NSImage(size: NSSize(width: width, height: height))
        canvas.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.current?.imageInterpolation = .none
        left.draw(at: NSPoint(x: margin, y: margin), from: .zero, operation: .sourceOver, fraction: 1)
        right.draw(
            at: NSPoint(x: margin * 2 + left.size.width, y: margin),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        canvas.unlockFocus()
        return canvas
    }
}
