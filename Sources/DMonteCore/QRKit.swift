import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import Vision

/// Pure, UI-free QR/barcode pipeline used by DMonte QR. Generation uses CoreImage's
/// QR generator and scales the raw matrix up with a nearest-neighbour transform so the
/// rendered code stays crisp; decoding uses Vision's barcode detector and returns the raw
/// payload strings. It also builds the structured payloads the content templates emit
/// (`WIFI:`, `mailto:`, vCard, …), which is where the escaping rules those formats demand
/// live. Everything here is synchronous and side-effect free so it can be unit tested
/// end-to-end (build payload → generate → render to PNG → decode → compare payload).
public enum QRKit {
    /// Renders `string` as a QR code image. `scale` multiplies the native QR matrix size so
    /// the result is sharp at display sizes (a value around 10 gives a clean, large image).
    /// Returns `nil` for empty input or if CoreImage fails to produce an image.
    public static func generate(_ string: String, scale: CGFloat = 10) -> NSImage? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        guard let payload = string.data(using: .utf8) else {
            return nil
        }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = payload
        // "M" tolerates ~15% damage — a good balance of density and resilience for URLs/text.
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else {
            return nil
        }

        // Nearest-neighbour upscale keeps the modules as hard-edged squares instead of
        // blurring them, so the code reads reliably and looks intentional rather than fuzzy.
        let effectiveScale = max(1, scale)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: effectiveScale, y: effectiveScale))

        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else {
            return nil
        }

        let size = NSSize(width: scaled.extent.width, height: scaled.extent.height)
        return NSImage(cgImage: cgImage, size: size)
    }

    /// Decodes any QR codes / barcodes found in the image at `url`, returning each payload
    /// string. Returns an empty array if the file can't be read or no codes are found.
    /// Synchronous so callers can run it off the main actor via `Task.detached`.
    public static func decode(imageAt url: URL) -> [String] {
        if case let .payloads(payloads) = decodeResult(imageAt: url) {
            return payloads
        }
        return []
    }

    /// Decodes the image at `url`, distinguishing the three ways this can go wrong so the UI
    /// can say something useful instead of a blanket "nothing found". Synchronous so callers
    /// can run it off the main actor via `Task.detached` — a full-resolution photo can keep
    /// Vision busy for seconds.
    public static func decodeResult(imageAt url: URL) -> QRFileDecodeOutcome {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            return .unreadable
        }

        if let cgImage = loadCGImage(at: url) {
            return .payloads(decode(cgImage: cgImage))
        }

        // Fallback: NSImage understands some formats CGImageSource may not load directly.
        if let image = NSImage(contentsOf: url),
           let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return .payloads(decode(cgImage: cgImage))
        }

        // The file exists and is readable but no image loader could make sense of it.
        return .notAnImage
    }

    /// Decodes any QR codes / barcodes found in `cgImage`. Returns an empty array if none.
    public static func decode(cgImage: CGImage) -> [String] {
        let request = VNDetectBarcodesRequest()
        // Restrict to symbologies the tool advertises: QR plus the common 1D/2D barcodes.
        request.symbologies = [.qr, .aztec, .dataMatrix, .pdf417, .ean13, .ean8, .code128, .code39, .code93, .upce]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
        } catch {
            return []
        }

        guard let results = request.results else {
            return []
        }

        return results.compactMap { observation in
            let payload = observation.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (payload?.isEmpty == false) ? payload : nil
        }
    }

    /// Writes `image` to `url` as PNG. Returns `true` on success.
    @discardableResult
    public static func writePNG(_ image: NSImage, to url: URL) -> Bool {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return false
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        bitmap.size = image.size
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            return false
        }

        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Private

    private static func loadCGImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

// MARK: - File decoding

/// Why a decode-from-file attempt produced no payloads. Kept separate from `[String]` so the
/// UI can tell "that PDF isn't an image" apart from "that photo has no code in it".
public enum QRFileDecodeOutcome: Equatable, Sendable {
    /// The file was decoded. The array is empty when the image simply contains no code.
    case payloads([String])
    /// The file loaded but no image decoder recognised it (a text file, an archive, …).
    case notAnImage
    /// The file is missing or unreadable (deleted between the drop and the decode, no access).
    case unreadable
}

// MARK: - Templates

/// The structured payload formats QR Studio can build. Raw values are persisted, so they are
/// spelled out rather than derived from the case order.
public enum QRTemplate: String, CaseIterable, Identifiable, Sendable {
    case text
    case url
    case wifi
    case email
    case sms
    case phone
    case contact

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .text: "Text"
        case .url: "URL"
        case .wifi: "Wi-Fi"
        case .email: "Email"
        case .sms: "SMS"
        case .phone: "Phone"
        case .contact: "Contact"
        }
    }

    public var iconName: String {
        switch self {
        case .text: "text.alignleft"
        case .url: "link"
        case .wifi: "wifi"
        case .email: "envelope"
        case .sms: "message"
        case .phone: "phone"
        case .contact: "person.crop.square"
        }
    }
}

/// Security modes the Wi-Fi template offers. Raw values are the exact tokens the `WIFI:`
/// format's `T:` field expects, so they can be written into the payload unmodified.
public enum QRWiFiSecurity: String, CaseIterable, Identifiable, Sendable {
    /// Covers WPA, WPA2 and WPA3 — the format has no way to distinguish them and joining
    /// hardware negotiates the actual protocol anyway.
    case wpa = "WPA"
    case wep = "WEP"
    case none = "nopass"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .wpa: "WPA/WPA2"
        case .wep: "WEP"
        case .none: "None"
        }
    }
}

/// A Wi-Fi network as carried by a `WIFI:` payload, with every value already unescaped.
public struct QRWiFiNetwork: Equatable, Sendable {
    public var ssid: String
    public var password: String
    public var security: QRWiFiSecurity
    public var isHidden: Bool

    public init(ssid: String, password: String, security: QRWiFiSecurity, isHidden: Bool) {
        self.ssid = ssid
        self.password = password
        self.security = security
        self.isHidden = isHidden
    }
}

/// The fields the contact template collects, mapped onto a vCard 3.0 card.
public struct QRContact: Equatable, Sendable {
    public var firstName: String
    public var lastName: String
    public var organization: String
    public var jobTitle: String
    public var phone: String
    public var email: String
    public var url: String
    public var note: String

    public init(
        firstName: String = "",
        lastName: String = "",
        organization: String = "",
        jobTitle: String = "",
        phone: String = "",
        email: String = "",
        url: String = "",
        note: String = ""
    ) {
        self.firstName = firstName
        self.lastName = lastName
        self.organization = organization
        self.jobTitle = jobTitle
        self.phone = phone
        self.email = email
        self.url = url
        self.note = note
    }

    /// True when nothing at all has been entered, so the caller can emit no payload rather
    /// than a skeleton card that scans to an empty contact.
    public var isEmpty: Bool {
        [firstName, lastName, organization, jobTitle, phone, email, url, note]
            .allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

/// Every field any template can collect, held as one value so the UI binds to a single piece
/// of state and the payload stays a pure function of it — no per-template view plumbing and
/// no chance of the preview drifting from what the fields say.
public struct QRTemplateDraft: Equatable, Sendable {
    public var text: String
    public var url: String
    public var wifiSSID: String
    public var wifiPassword: String
    public var wifiSecurity: QRWiFiSecurity
    public var wifiIsHidden: Bool
    public var emailAddress: String
    public var emailSubject: String
    public var emailBody: String
    public var smsNumber: String
    public var smsMessage: String
    public var phoneNumber: String
    public var contact: QRContact

    public init(
        text: String = "",
        url: String = "",
        wifiSSID: String = "",
        wifiPassword: String = "",
        wifiSecurity: QRWiFiSecurity = .wpa,
        wifiIsHidden: Bool = false,
        emailAddress: String = "",
        emailSubject: String = "",
        emailBody: String = "",
        smsNumber: String = "",
        smsMessage: String = "",
        phoneNumber: String = "",
        contact: QRContact = QRContact()
    ) {
        self.text = text
        self.url = url
        self.wifiSSID = wifiSSID
        self.wifiPassword = wifiPassword
        self.wifiSecurity = wifiSecurity
        self.wifiIsHidden = wifiIsHidden
        self.emailAddress = emailAddress
        self.emailSubject = emailSubject
        self.emailBody = emailBody
        self.smsNumber = smsNumber
        self.smsMessage = smsMessage
        self.phoneNumber = phoneNumber
        self.contact = contact
    }
}

public extension QRKit {
    // MARK: Payload construction

    /// Builds the payload for `template` out of `draft`. Returns an empty string when the
    /// template's required field is blank; `generate` already declines empty input, so the
    /// preview stays on its placeholder instead of encoding a half-filled record.
    static func payload(for template: QRTemplate, draft: QRTemplateDraft) -> String {
        switch template {
        case .text:
            return textPayload(draft.text)
        case .url:
            return urlPayload(draft.url)
        case .wifi:
            return wifiPayload(
                ssid: draft.wifiSSID,
                password: draft.wifiPassword,
                security: draft.wifiSecurity,
                isHidden: draft.wifiIsHidden
            )
        case .email:
            return emailPayload(address: draft.emailAddress, subject: draft.emailSubject, body: draft.emailBody)
        case .sms:
            return smsPayload(number: draft.smsNumber, message: draft.smsMessage)
        case .phone:
            return phonePayload(draft.phoneNumber)
        case .contact:
            return contactPayload(draft.contact)
        }
    }

    /// Free text is encoded verbatim — no format wraps it, so nothing may be rewritten.
    static func textPayload(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : text
    }

    /// A URL payload. A bare `example.com` is what people type, but scanners only offer to
    /// open a code that carries a scheme, so one is added rather than emitting a dead code.
    static func urlPayload(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }
        return hasURLScheme(trimmed) ? trimmed : "https://" + trimmed
    }

    /// A `WIFI:` payload as understood by iOS and Android camera apps:
    /// `WIFI:T:WPA;S:<ssid>;P:<password>;H:true;;`.
    ///
    /// SSIDs and passwords are *not* trimmed: both may legitimately start or end with a
    /// space, and silently dropping one produces a code that fails to join with no clue why.
    static func wifiPayload(ssid: String, password: String, security: QRWiFiSecurity, isHidden: Bool) -> String {
        guard !ssid.isEmpty else {
            return ""
        }

        var payload = "WIFI:T:\(security.rawValue);S:\(escapedWiFiValue(ssid));"
        // An open network has no key; emitting an empty P: field makes some scanners prompt
        // for a password that does not exist.
        if security != .none {
            payload += "P:\(escapedWiFiValue(password));"
        }
        if isHidden {
            payload += "H:true;"
        }
        // The format terminates with an empty field, i.e. a second trailing semicolon.
        return payload + ";"
    }

    /// A `mailto:` payload, with the subject and body carried as percent-encoded query items.
    static func emailPayload(address: String, subject: String, body: String) -> String {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else {
            return ""
        }

        // "@" is legal in the path of a mailto URI and encoding it makes the address
        // unreadable to humans peeking at the payload, so it stays literal.
        var payload = "mailto:" + percentEncoded(address, alsoAllowing: "@")

        var items: [String] = []
        if !subject.isEmpty {
            items.append("subject=" + percentEncoded(subject))
        }
        if !body.isEmpty {
            items.append("body=" + percentEncoded(body))
        }
        if !items.isEmpty {
            payload += "?" + items.joined(separator: "&")
        }
        return payload
    }

    /// An `SMSTO:` payload. The scheme is matched case-insensitively by scanners; uppercase
    /// matches the `WIFI:` family this tool already emits. The message runs to the end of the
    /// payload, so colons inside it need no escaping.
    static func smsPayload(number: String, message: String) -> String {
        let dialable = dialableNumber(number)
        guard !dialable.isEmpty else {
            return ""
        }

        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "SMSTO:\(dialable)" : "SMSTO:\(dialable):\(message)"
    }

    /// A `tel:` payload.
    static func phonePayload(_ number: String) -> String {
        let dialable = dialableNumber(number)
        return dialable.isEmpty ? "" : "tel:" + dialable
    }

    /// A vCard 3.0 payload. 3.0 rather than 4.0 because iOS and Android contact importers
    /// still handle it most reliably, and empty properties are omitted entirely so scanners
    /// don't create a contact full of blank fields.
    static func contactPayload(_ contact: QRContact) -> String {
        guard !contact.isEmpty else {
            return ""
        }

        let firstName = contact.firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastName = contact.lastName.trimmingCharacters(in: .whitespacesAndNewlines)
        let organization = contact.organization.trimmingCharacters(in: .whitespacesAndNewlines)

        var lines = ["BEGIN:VCARD", "VERSION:3.0"]

        // N is a structured property: family;given;additional;prefix;suffix. Its own
        // semicolons are separators, so only the escaped values go between them.
        lines.append("N:\(escapedVCardValue(lastName));\(escapedVCardValue(firstName));;;")

        // FN is mandatory in 3.0 and an empty one imports as a nameless card, so it falls back
        // through everything that can stand in for a label: company, then the contact details
        // themselves. Only a phone number or an email is enough to make a card worth sharing.
        let fullName = [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
        let displayName = [
            fullName,
            organization,
            contact.email.trimmingCharacters(in: .whitespacesAndNewlines),
            contact.phone.trimmingCharacters(in: .whitespacesAndNewlines)
        ].first { !$0.isEmpty } ?? ""
        lines.append("FN:\(escapedVCardValue(displayName))")

        if !organization.isEmpty {
            lines.append("ORG:\(escapedVCardValue(organization))")
        }
        appendVCardLine(&lines, name: "TITLE", value: contact.jobTitle)
        appendVCardLine(&lines, name: "TEL;TYPE=CELL", value: contact.phone)
        appendVCardLine(&lines, name: "EMAIL;TYPE=INTERNET", value: contact.email)
        appendVCardLine(&lines, name: "URL", value: contact.url)
        appendVCardLine(&lines, name: "NOTE", value: contact.note)

        lines.append("END:VCARD")
        // CRLF is what RFC 2426 specifies; some Android importers reject bare LF cards.
        return lines.joined(separator: "\r\n")
    }

    // MARK: Escaping

    /// Escapes a value for the `WIFI:` format, which reserves backslash, semicolon, comma,
    /// colon and double-quote. Without this an SSID or password containing any of them
    /// silently truncates at the reserved character and the code fails to join.
    static func escapedWiFiValue(_ value: String) -> String {
        var escaped = ""
        for character in value {
            if wifiReservedCharacters.contains(character) {
                escaped.append("\\")
            }
            escaped.append(character)
        }

        // The format reads an all-hex value as raw hex bytes; quoting it forces the literal
        // reading, so an SSID of "CAFE" joins the network called CAFE and not 0xCAFE.
        if !value.isEmpty, value.allSatisfy(\.isHexDigit) {
            return "\"\(escaped)\""
        }
        return escaped
    }

    /// Inverse of `escapedWiFiValue`, including the optional quoting of all-hex values.
    static func unescapedWiFiValue(_ value: String) -> String {
        var characters = Array(value)

        // Strip the format's own quotes, but not a quote the user typed (which arrives here
        // escaped, so it is preceded by an odd number of backslashes).
        if characters.count >= 2,
           characters[0] == "\"",
           characters[characters.count - 1] == "\"",
           !isEscaped(index: characters.count - 1, in: characters) {
            characters = Array(characters[1..<(characters.count - 1)])
        }

        var result = ""
        var index = 0
        while index < characters.count {
            if characters[index] == "\\", index + 1 < characters.count {
                result.append(characters[index + 1])
                index += 2
            } else {
                result.append(characters[index])
                index += 1
            }
        }
        return result
    }

    /// Escapes a value for a vCard property, per RFC 2426: backslash, comma, semicolon and
    /// newlines. Colon and double-quote are deliberately *not* escaped — a vCard value runs
    /// to the end of the line, so a colon is unambiguous there, and `\:` is not a defined
    /// escape; emitting it would put a literal backslash into URLs and notes.
    static func escapedVCardValue(_ value: String) -> String {
        var escaped = ""
        for character in value {
            switch character {
            case "\\", ",", ";":
                escaped.append("\\")
                escaped.append(character)
            // Tested against `isNewline` rather than "\n": Swift treats CRLF as a single
            // Character, so matching the two literals separately misses the Windows form and
            // lets a raw line break through, which would end the property and truncate the card.
            case _ where character.isNewline:
                escaped.append("\\n")
            default:
                escaped.append(character)
            }
        }
        return escaped
    }

    /// Inverse of `escapedVCardValue`.
    static func unescapedVCardValue(_ value: String) -> String {
        let characters = Array(value)
        var result = ""
        var index = 0
        while index < characters.count {
            if characters[index] == "\\", index + 1 < characters.count {
                let next = characters[index + 1]
                result.append(next == "n" || next == "N" ? "\n" : next)
                index += 2
            } else {
                result.append(characters[index])
                index += 1
            }
        }
        return result
    }

    // MARK: Parsing

    /// Parses a `WIFI:` payload back into its fields, unescaping every value. Returns `nil`
    /// for anything that isn't a Wi-Fi payload. Used to prove escaping round-trips, and to
    /// describe a decoded Wi-Fi code in plain language.
    static func parseWiFiPayload(_ payload: String) -> QRWiFiNetwork? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 5, trimmed.prefix(5).uppercased() == "WIFI:" else {
            return nil
        }

        var ssid = ""
        var password = ""
        var security = QRWiFiSecurity.none
        var isHidden = false

        for field in splitUnescaped(String(trimmed.dropFirst(5)), on: ";") {
            guard let separator = indexOfUnescaped(":", in: field) else {
                continue
            }
            let key = String(field[field.startIndex..<separator]).uppercased()
            let raw = String(field[field.index(after: separator)...])

            switch key {
            case "S": ssid = unescapedWiFiValue(raw)
            case "P": password = unescapedWiFiValue(raw)
            case "T": security = wifiSecurity(fromToken: unescapedWiFiValue(raw))
            case "H": isHidden = unescapedWiFiValue(raw).lowercased() == "true"
            default: continue
            }
        }

        guard !ssid.isEmpty else {
            return nil
        }
        return QRWiFiNetwork(ssid: ssid, password: password, security: security, isHidden: isHidden)
    }

    /// A short human-readable description of a decoded payload, or `nil` when the payload is
    /// just text and the payload itself already reads fine.
    static func payloadSummary(_ payload: String) -> String? {
        if let network = parseWiFiPayload(payload) {
            return "Wi-Fi network “\(network.ssid)”"
        }

        let lowercased = payload.lowercased()
        if lowercased.hasPrefix("begin:vcard") {
            return "Contact card"
        }
        if lowercased.hasPrefix("mailto:") {
            return "Email address"
        }
        if lowercased.hasPrefix("smsto:") || lowercased.hasPrefix("sms:") {
            return "Text message"
        }
        if lowercased.hasPrefix("tel:") {
            return "Phone number"
        }
        if lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") {
            return "Link"
        }
        return nil
    }

    /// The URL the Open button should hand to the system, or `nil` to hide the button.
    ///
    /// An allow-list rather than "anything with a host": payloads now arrive from image files
    /// that came from anywhere, so one click must not be able to launch an arbitrary registered
    /// handler (`smb:`, `vnc:`, some other app's private scheme) off the back of a code someone
    /// else generated. Copy still works for everything, so nothing is unreachable.
    public static func openableURL(from payload: String) -> URL? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)

        // `SMSTO:` is what this tool emits and what most writers produce, but nothing on the
        // system registers a handler for it, so allow-listing the scheme alone would still
        // leave the Open button dead. Rewrite it as the `sms:` URI Messages does answer to.
        if let sms = smsURL(fromSMSTO: trimmed) {
            return sms
        }

        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            return nil
        }

        switch scheme {
        // A web link with no host is malformed, and "http:///" opens a blank window.
        case "http", "https": return url.host == nil ? nil : url
        case "mailto", "tel", "sms", "facetime": return url
        default: return nil
        }
    }
}

// MARK: - Private template helpers

private extension QRKit {
    /// Characters the `WIFI:` format reserves as field and record separators.
    static var wifiReservedCharacters: Set<Character> { ["\\", ";", ",", ":", "\""] }

    /// Unreserved characters per RFC 3986. Everything else — including "+", which some mail
    /// clients would otherwise read as a space — is percent-encoded.
    static var percentEncodingAllowed: CharacterSet {
        CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    }

    static func percentEncoded(_ value: String, alsoAllowing extra: String = "") -> String {
        var allowed = percentEncodingAllowed
        allowed.insert(charactersIn: extra)
        // Only fails on unpaired surrogates, which a Swift String cannot hold.
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// Reduces a typed phone number to what a dialler accepts: digits, a leading "+", and the
    /// "*"/"#" keys. Spaces, dashes and brackets are how people write numbers but are not valid
    /// in a `tel:` URI, and stripping them beats emitting a URI scanners refuse to act on.
    ///
    /// "*" and "#" are kept because RFC 3966 counts them as digits: dropping them turned "*611"
    /// into "611" and silently produced a code that dials a different number.
    static func dialableNumber(_ number: String) -> String {
        var result = ""
        for character in number {
            if character.isASCII, character.isNumber || character == "*" || character == "#" {
                result.append(character)
            } else if character == "+", result.isEmpty {
                result.append(character)
            }
        }
        // Punctuation alone ("+", "**") is not a number; requiring a digit keeps `tel:*` out.
        return result.contains(where: { $0.isASCII && $0.isNumber }) ? result : ""
    }

    /// Rewrites `SMSTO:<number>[:<message>]` as the equivalent `sms:` URI, or `nil` when the
    /// payload is not an SMSTO one. The message becomes a `body` query item per RFC 5724; a
    /// handler that ignores it still opens a new message to the right number.
    static func smsURL(fromSMSTO payload: String) -> URL? {
        guard payload.lowercased().hasPrefix("smsto:") else {
            return nil
        }

        // The message runs to the end of the payload, so only the first separator splits.
        let fields = payload.dropFirst("smsto:".count)
            .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let number = dialableNumber(String(fields.first ?? ""))
        guard !number.isEmpty else {
            return nil
        }

        let message = fields.count > 1 ? String(fields[1]) : ""
        guard !message.isEmpty else {
            return URL(string: "sms:" + number)
        }
        return URL(string: "sms:\(number)?body=\(percentEncoded(message))")
    }

    /// Maps a `T:` token onto a security mode. Writers in the wild emit WPA2/WPA3 even though
    /// the format only defines WPA, and an absent or empty token means an open network.
    static func wifiSecurity(fromToken token: String) -> QRWiFiSecurity {
        switch token.uppercased() {
        case "WEP": .wep
        case "", "NOPASS", "NONE": .none
        default: .wpa
        }
    }

    static func hasURLScheme(_ value: String) -> Bool {
        guard let colon = value.firstIndex(of: ":") else {
            return false
        }
        let scheme = value[value.startIndex..<colon]
        guard let first = scheme.first, first.isLetter else {
            return false
        }
        // RFC 3986 permits "." inside a scheme, but nobody types one: what actually looks like
        // this is a host and port ("example.com:8080", "nas.local:5000"). Reading that as a
        // scheme emitted a code no scanner would open, so a dotted prefix means host, not scheme.
        guard !scheme.contains(".") else {
            return false
        }
        guard scheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" }) else {
            return false
        }
        // The dotless sibling of the same problem: "localhost:8080" is a legal scheme by the
        // grammar but is always a host and a port. A digit straight after the colon means port,
        // except for the handful of schemes whose value genuinely starts with one.
        let afterColon = value.index(after: colon)
        if afterColon < value.endIndex, value[afterColon].isASCII, value[afterColon].isNumber {
            return digitLeadingSchemes.contains(scheme.lowercased())
        }
        return true
    }

    /// Schemes whose value legitimately begins with a digit, so a digit after the colon does
    /// not mean the prefix was really a host.
    static var digitLeadingSchemes: Set<String> { ["tel", "sms", "smsto", "fax", "facetime", "callto"] }

    static func appendVCardLine(_ lines: inout [String], name: String, value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        lines.append("\(name):\(escapedVCardValue(trimmed))")
    }

    /// True when the character at `index` is preceded by an odd number of backslashes, i.e.
    /// it is escaped rather than acting as a separator.
    static func isEscaped(index: Int, in characters: [Character]) -> Bool {
        var backslashes = 0
        var cursor = index - 1
        while cursor >= 0, characters[cursor] == "\\" {
            backslashes += 1
            cursor -= 1
        }
        return backslashes % 2 == 1
    }

    static func splitUnescaped(_ value: String, on separator: Character) -> [String] {
        let characters = Array(value)
        var fields: [String] = []
        var current = ""
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count {
                // Keep the escape intact — unescaping happens per field, after splitting.
                current.append(character)
                current.append(characters[index + 1])
                index += 2
                continue
            }
            if character == separator {
                fields.append(current)
                current = ""
            } else {
                current.append(character)
            }
            index += 1
        }

        fields.append(current)
        return fields.filter { !$0.isEmpty }
    }

    static func indexOfUnescaped(_ target: Character, in value: String) -> String.Index? {
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            if character == "\\" {
                index = value.index(index, offsetBy: 2, limitedBy: value.endIndex) ?? value.endIndex
                continue
            }
            if character == target {
                return index
            }
            index = value.index(after: index)
        }
        return nil
    }
}
