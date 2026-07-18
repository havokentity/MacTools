import Darwin
import Foundation
import SystemConfiguration

/// How the primary network service reaches the outside world. Drives the row label and glyph, and
/// is derived from SystemConfiguration's interface type rather than the BSD name, because `enN`
/// covers both Wi-Fi and Ethernet on Apple silicon and guessing from the name gets it wrong.
public enum NetworkLinkKind: String, Sendable, CaseIterable {
    case wiFi
    case ethernet
    case cellular
    case bluetooth
    case vpn
    case loopback
    case other

    /// Sentence-case name shown in the "Type" row.
    public var displayName: String {
        switch self {
        case .wiFi: return "Wi‑Fi"
        case .ethernet: return "Ethernet"
        case .cellular: return "Cellular"
        case .bluetooth: return "Bluetooth"
        case .vpn: return "VPN"
        case .loopback: return "Loopback"
        case .other: return "Other"
        }
    }

    /// SF Symbol for the header glyph.
    public var symbolName: String {
        switch self {
        case .wiFi: return "wifi"
        case .ethernet: return "cable.connector"
        case .cellular: return "antenna.radiowaves.left.and.right"
        case .bluetooth: return "dot.radiowaves.right"
        case .vpn: return "lock.shield"
        case .loopback: return "arrow.triangle.2.circlepath"
        case .other: return "network"
        }
    }
}

/// Everything the tool knows about the current network, captured in one read so the UI never
/// shows an IPv4 from one interface next to a router from another. Value type so a background
/// read can hand it to the main actor.
public struct NetworkSnapshot: Sendable, Equatable {
    /// BSD name of the primary interface, e.g. `en0`. `nil` when there is no primary service,
    /// which is how "offline" is represented — there is no separate `isOnline` flag to fall out
    /// of sync with the addresses.
    public var interfaceBSDName: String?

    /// SystemConfiguration's localized name, e.g. "Wi‑Fi" or "USB 10/100/1000 LAN".
    public var interfaceDisplayName: String?

    public var kind: NetworkLinkKind
    public var ipv4: String?
    public var subnetMask: String?

    /// CIDR prefix length matching `subnetMask`, or `nil` if the mask was non-contiguous.
    public var subnetPrefixLength: Int?

    /// Best routable IPv6 on the primary interface; see `preferredIPv6(from:)` for the ordering.
    public var ipv6: String?

    public var router: String?
    public var dnsServers: [String]

    public init(
        interfaceBSDName: String? = nil,
        interfaceDisplayName: String? = nil,
        kind: NetworkLinkKind = .other,
        ipv4: String? = nil,
        subnetMask: String? = nil,
        subnetPrefixLength: Int? = nil,
        ipv6: String? = nil,
        router: String? = nil,
        dnsServers: [String] = []
    ) {
        self.interfaceBSDName = interfaceBSDName
        self.interfaceDisplayName = interfaceDisplayName
        self.kind = kind
        self.ipv4 = ipv4
        self.subnetMask = subnetMask
        self.subnetPrefixLength = subnetPrefixLength
        self.ipv6 = ipv6
        self.router = router
        self.dnsServers = dnsServers
    }

    /// True once the Mac has a primary service with at least one address on it. A primary
    /// interface with no address yet (mid-DHCP) is not "connected" for display purposes.
    public var hasConnection: Bool {
        interfaceBSDName != nil && (ipv4 != nil || ipv6 != nil)
    }

    /// "255.255.255.0 (/24)" — the prefix length is appended only when the mask was contiguous,
    /// since a non-contiguous mask has no meaningful CIDR form.
    public var subnetDescription: String? {
        guard let subnetMask else { return nil }
        guard let subnetPrefixLength else { return subnetMask }
        return "\(subnetMask) (/\(subnetPrefixLength))"
    }
}

/// Read-only network facts plus the parsing that turns raw system output into display strings.
///
/// Everything here is synchronous and free of AppKit so a caller can hop the whole snapshot off
/// the main actor with `Task.detached`. The parsing half (`dnsServers(fromResolvConf:)`,
/// `prefixLength(forIPv4Mask:)`, `publicIPAddress(fromResponseBody:)`, …) takes strings rather
/// than touching the system, which is what makes it testable in a headless suite.
///
/// Nothing in this type performs a network request. The public-IP lookup is deliberately left to
/// the controller, and only its *endpoint* and *response validation* live here — see
/// `publicIPEndpoint`.
public enum NetworkInfoKit {

    // MARK: - Public IP endpoint

    /// Hostname shown in the UI so the user knows exactly who is being asked before they press
    /// the button. Kept as the single source of truth for both the label and the URL below.
    public static let publicIPServiceHost = "api.ipify.org"

    /// Plain-text endpoint that answers with nothing but the caller's address — no JSON, no
    /// tracking pixels, no redirect chain — which keeps the validation below trivially strict.
    public static let publicIPEndpoint = URL(string: "https://\(publicIPServiceHost)")!

    /// Longest a legitimate response can be. The maximum textual IPv6 length is 45 characters
    /// (an IPv4-mapped address with a zone id); anything longer is a redirect page or an error
    /// body, not an address, and is rejected without being shown.
    public static let maximumPublicIPResponseBytes = 64

    /// Validates the body of a `publicIPEndpoint` response. Returns the address only if the whole
    /// body — after trimming — is a single well-formed IP literal. A third-party endpoint can
    /// return anything at all (a captive-portal login page, an HTML error, a tracking blob), so
    /// the body is never surfaced to the user unvalidated.
    public static func publicIPAddress(fromResponseBody body: String) -> String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maximumPublicIPResponseBytes else {
            return nil
        }
        return isValidIPAddress(trimmed) ? trimmed : nil
    }

    // MARK: - Address validation

    /// True when `text` parses as either an IPv4 or an IPv6 literal. Uses `inet_pton` rather than
    /// a regular expression so the accepted grammar is exactly the system's.
    public static func isValidIPAddress(_ text: String) -> Bool {
        isValidIPv4(text) || isValidIPv6(text)
    }

    public static func isValidIPv4(_ text: String) -> Bool {
        var buffer = in_addr()
        return inet_pton(AF_INET, text, &buffer) == 1
    }

    public static func isValidIPv6(_ text: String) -> Bool {
        // A zone id ("fe80::1%en0") is valid in presentation form but `inet_pton` rejects it, so
        // it is stripped before parsing and the address half is what gets validated.
        let literal = text.split(separator: "%", maxSplits: 1).first.map(String.init) ?? text
        var buffer = in6_addr()
        return inet_pton(AF_INET6, literal, &buffer) == 1
    }

    // MARK: - Subnet masks

    /// CIDR prefix length for a dotted-quad mask, or `nil` when the mask is malformed or its bits
    /// are non-contiguous (e.g. `255.0.255.0`). A non-contiguous mask is legal to configure but
    /// has no CIDR equivalent, so callers show the dotted form alone rather than inventing one.
    public static func prefixLength(forIPv4Mask mask: String) -> Int? {
        var buffer = in_addr()
        guard inet_pton(AF_INET, mask, &buffer) == 1 else { return nil }

        let bits = UInt32(bigEndian: buffer.s_addr)
        guard bits != 0 else { return 0 }

        // A contiguous mask is a run of high bits followed by zeros, so its complement is a run of
        // low bits — and a low-bit run is exactly the set of values where `n & (n + 1)` is zero.
        // The all-zero mask is excluded above, so the complement can never overflow here.
        let inverted = ~bits
        guard inverted & (inverted &+ 1) == 0 else { return nil }

        return bits.nonzeroBitCount
    }

    // MARK: - IPv6 selection

    /// Picks the address most useful to show: a global unicast address first, then a unique-local
    /// one, and a link-local `fe80::` only as a last resort. An interface commonly holds several
    /// IPv6 addresses at once (SLAAC, privacy extension, link-local) and showing whichever
    /// `getifaddrs` happened to list first would flip between them for no visible reason.
    public static func preferredIPv6(from candidates: [String]) -> String? {
        let usable = candidates.filter { !isLoopbackIPv6($0) }
        return usable.first { !isLinkLocalIPv6($0) && !isUniqueLocalIPv6($0) }
            ?? usable.first { !isLinkLocalIPv6($0) }
            ?? usable.first
    }

    public static func isLinkLocalIPv6(_ text: String) -> Bool {
        text.lowercased().hasPrefix("fe80:")
    }

    /// `fc00::/7` — the IPv6 equivalent of RFC 1918 space, so the first hex digit pair is fc or fd.
    public static func isUniqueLocalIPv6(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.hasPrefix("fc") || lowered.hasPrefix("fd")
    }

    public static func isLoopbackIPv6(_ text: String) -> Bool {
        let literal = text.split(separator: "%", maxSplits: 1).first.map(String.init) ?? text
        return literal == "::1"
    }

    // MARK: - resolv.conf

    /// Extracts `nameserver` entries from the contents of a `resolv.conf`-formatted file, in file
    /// order and de-duplicated. Comment lines (`#` or `;`), `search`/`domain`/`options` lines and
    /// anything that is not a valid IP literal are dropped, so a malformed file degrades to fewer
    /// servers rather than to garbage in the UI.
    public static func dnsServers(fromResolvConf text: String) -> [String] {
        var seen = Set<String>()
        var servers: [String] = []

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), !line.hasPrefix(";") else { continue }

            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2, fields[0] == "nameserver" else { continue }

            let address = String(fields[1])
            guard isValidIPAddress(address), seen.insert(address).inserted else { continue }
            servers.append(address)
        }

        return servers
    }

    // MARK: - Interface classification

    /// Maps a SystemConfiguration interface type (`kSCNetworkInterfaceType…`) to a display kind.
    /// Takes the raw string rather than the CF constant so it can be exercised without a live
    /// network configuration.
    public static func kind(forInterfaceType type: String?) -> NetworkLinkKind {
        switch type {
        case "IEEE80211": return .wiFi
        case "Ethernet", "Bridge": return .ethernet
        case "WWAN": return .cellular
        case "Bluetooth": return .bluetooth
        case "PPP", "IPSec", "VPN", "L2TP": return .vpn
        case "Loopback": return .loopback
        default: return .other
        }
    }

    /// Fallback classification for interfaces SystemConfiguration does not enumerate — chiefly the
    /// `utunN` tunnels a VPN client creates on the fly. `enN` deliberately maps to `.other`
    /// because the name alone cannot distinguish Wi‑Fi from Ethernet.
    public static func kind(forBSDName name: String) -> NetworkLinkKind {
        if name.hasPrefix("lo") { return .loopback }
        if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") { return .vpn }
        return .other
    }

    // MARK: - System reads

    /// One consistent read of the primary service and its addresses. Synchronous and safe to run
    /// off the main actor; returns an empty snapshot rather than failing when there is no network.
    public static func snapshot() -> NetworkSnapshot {
        guard let primary = primaryService() else {
            // Still report DNS: a Mac with no primary service can have resolvers configured, and
            // showing them beats a screen of dashes while diagnosing exactly that situation.
            return NetworkSnapshot(dnsServers: systemDNSServers())
        }

        let addresses = self.addresses(forInterface: primary.interfaceName)
        let description = interfaceDescription(forBSDName: primary.interfaceName)

        return NetworkSnapshot(
            interfaceBSDName: primary.interfaceName,
            interfaceDisplayName: description.displayName,
            kind: description.kind,
            ipv4: addresses.ipv4,
            subnetMask: addresses.subnetMask,
            subnetPrefixLength: addresses.subnetMask.flatMap(prefixLength(forIPv4Mask:)),
            ipv6: preferredIPv6(from: addresses.ipv6Candidates),
            router: primary.router,
            dnsServers: systemDNSServers()
        )
    }

    /// The interface carrying default traffic, plus its gateway. Read from the dynamic store's
    /// global state rather than the routing table because that is where macOS already resolves
    /// "which of several live interfaces is primary" — including while a VPN is up.
    static func primaryService() -> (interfaceName: String, router: String?)? {
        guard let store = SCDynamicStoreCreate(nil, "com.havokentity.mactools.networkinfo" as CFString, nil, nil) else {
            return nil
        }

        let ipv4 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        let ipv6 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv6" as CFString) as? [String: Any]

        // IPv6-only networks have no global IPv4 dictionary at all, so fall back to the IPv6 one
        // before concluding the Mac is offline.
        guard let global = ipv4 ?? ipv6,
              let interfaceName = global["PrimaryInterface"] as? String else {
            return nil
        }

        let router = (ipv4?["Router"] as? String) ?? (ipv6?["Router"] as? String)
        return (interfaceName, router)
    }

    /// Resolvers from the dynamic store, falling back to `/etc/resolv.conf`. The store is
    /// preferred because it reflects per-scope resolvers immediately, whereas `resolv.conf` is a
    /// legacy mirror that a few configurations (some VPN clients) never update.
    static func systemDNSServers() -> [String] {
        if let store = SCDynamicStoreCreate(nil, "com.havokentity.mactools.networkinfo.dns" as CFString, nil, nil),
           let dns = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any],
           let servers = dns["ServerAddresses"] as? [String] {
            let valid = servers.filter(isValidIPAddress)
            if !valid.isEmpty { return valid }
        }

        guard let text = try? String(contentsOfFile: "/etc/resolv.conf", encoding: .utf8) else {
            return []
        }
        return dnsServers(fromResolvConf: text)
    }

    /// Localized name and kind for a BSD interface name, falling back to a name-based guess for
    /// tunnels SystemConfiguration does not list.
    static func interfaceDescription(forBSDName bsdName: String) -> (displayName: String?, kind: NetworkLinkKind) {
        if let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for interface in interfaces where SCNetworkInterfaceGetBSDName(interface) as String? == bsdName {
                return (
                    SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?,
                    kind(forInterfaceType: SCNetworkInterfaceGetInterfaceType(interface) as String?)
                )
            }
        }

        return (nil, kind(forBSDName: bsdName))
    }

    /// Addresses configured on one interface, read straight from `getifaddrs`.
    struct InterfaceAddresses {
        var ipv4: String?
        var subnetMask: String?
        var ipv6Candidates: [String] = []
    }

    static func addresses(forInterface name: String) -> InterfaceAddresses {
        var result = InterfaceAddresses()

        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else {
            return result
        }

        defer {
            freeifaddrs(list)
        }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard String(cString: entry.ifa_name) == name, let address = entry.ifa_addr else {
                continue
            }

            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                // Aliases mean an interface can hold several IPv4 addresses; the first one is the
                // primary and is what every other tool (ifconfig, Network settings) shows first.
                guard result.ipv4 == nil else { continue }
                result.ipv4 = ipv4String(from: address)
                result.subnetMask = entry.ifa_netmask.flatMap(ipv4String(from:))

            case AF_INET6:
                if let text = ipv6String(from: address) {
                    result.ipv6Candidates.append(text)
                }

            default:
                continue
            }
        }

        return result
    }

    // MARK: - sockaddr formatting

    private static func ipv4String(from address: UnsafeMutablePointer<sockaddr>) -> String? {
        var raw = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &raw, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
            return nil
        }
        return String(cString: buffer)
    }

    /// `getnameinfo` rather than `inet_ntop` because macOS stores a link-local address's scope id
    /// inside the address bytes (the KAME convention); `getnameinfo` un-embeds it and appends the
    /// `%en0` zone, whereas `inet_ntop` would print the raw, wrong bytes.
    private static func ipv6String(from address: UnsafeMutablePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let length = socklen_t(MemoryLayout<sockaddr_in6>.size)

        guard getnameinfo(address, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else {
            return nil
        }
        return String(cString: buffer)
    }
}
