import XCTest
@testable import DMonteCore

/// Exercises the parsing half of `NetworkInfoKit` against fixture strings. Nothing here opens a
/// socket, reads `/etc/resolv.conf`, or touches SystemConfiguration — the system-reading half is
/// deliberately kept out of the suite because it would depend on whatever network the test
/// machine happens to be on.
final class NetworkInfoKitTests: XCTestCase {

    // MARK: - Address validation

    func testValidIPv4Addresses() {
        XCTAssertTrue(NetworkInfoKit.isValidIPv4("192.168.1.1"))
        XCTAssertTrue(NetworkInfoKit.isValidIPv4("0.0.0.0"))
        XCTAssertTrue(NetworkInfoKit.isValidIPv4("255.255.255.255"))
    }

    func testInvalidIPv4Addresses() {
        XCTAssertFalse(NetworkInfoKit.isValidIPv4("256.1.1.1"))
        XCTAssertFalse(NetworkInfoKit.isValidIPv4("192.168.1"))
        XCTAssertFalse(NetworkInfoKit.isValidIPv4(""))
        XCTAssertFalse(NetworkInfoKit.isValidIPv4("not an address"))
    }

    func testValidIPv6Addresses() {
        XCTAssertTrue(NetworkInfoKit.isValidIPv6("::1"))
        XCTAssertTrue(NetworkInfoKit.isValidIPv6("2001:db8::1"))
        XCTAssertTrue(NetworkInfoKit.isValidIPv6("fe80:0000:0000:0000:0aaa:bbff:fecc:ddee"))
    }

    /// A zone id is part of the presentation form macOS hands back for link-local addresses, so it
    /// must validate even though `inet_pton` alone rejects it.
    func testIPv6WithZoneIdentifierIsValid() {
        XCTAssertTrue(NetworkInfoKit.isValidIPv6("fe80::1%en0"))
        XCTAssertTrue(NetworkInfoKit.isValidIPAddress("fe80::aaaa:bbbb:cccc:dddd%en1"))
    }

    func testInvalidIPv6Addresses() {
        XCTAssertFalse(NetworkInfoKit.isValidIPv6("2001:db8:::1"))
        XCTAssertFalse(NetworkInfoKit.isValidIPv6("gggg::1"))
        XCTAssertFalse(NetworkInfoKit.isValidIPv6(""))
    }

    // MARK: - Subnet masks

    func testPrefixLengthForCommonMasks() {
        XCTAssertEqual(NetworkInfoKit.prefixLength(forIPv4Mask: "255.255.255.0"), 24)
        XCTAssertEqual(NetworkInfoKit.prefixLength(forIPv4Mask: "255.255.0.0"), 16)
        XCTAssertEqual(NetworkInfoKit.prefixLength(forIPv4Mask: "255.0.0.0"), 8)
        XCTAssertEqual(NetworkInfoKit.prefixLength(forIPv4Mask: "255.255.255.252"), 30)
    }

    func testPrefixLengthAtBothExtremes() {
        XCTAssertEqual(NetworkInfoKit.prefixLength(forIPv4Mask: "0.0.0.0"), 0)
        XCTAssertEqual(NetworkInfoKit.prefixLength(forIPv4Mask: "255.255.255.255"), 32)
    }

    /// A mask with a gap in its bit run is configurable but has no CIDR form; reporting one would
    /// be a lie, so the Kit returns nil and the view falls back to the dotted mask alone.
    func testPrefixLengthRejectsNonContiguousMask() {
        XCTAssertNil(NetworkInfoKit.prefixLength(forIPv4Mask: "255.0.255.0"))
        XCTAssertNil(NetworkInfoKit.prefixLength(forIPv4Mask: "255.255.255.1"))
        XCTAssertNil(NetworkInfoKit.prefixLength(forIPv4Mask: "0.0.0.255"))
    }

    func testPrefixLengthRejectsMalformedMask() {
        XCTAssertNil(NetworkInfoKit.prefixLength(forIPv4Mask: "not a mask"))
        XCTAssertNil(NetworkInfoKit.prefixLength(forIPv4Mask: ""))
        XCTAssertNil(NetworkInfoKit.prefixLength(forIPv4Mask: "::1"))
    }

    // MARK: - IPv6 preference

    func testPreferredIPv6PrefersGlobalUnicast() {
        let candidates = ["fe80::1%en0", "fd00::5", "2001:db8::42"]
        XCTAssertEqual(NetworkInfoKit.preferredIPv6(from: candidates), "2001:db8::42")
    }

    func testPreferredIPv6FallsBackToUniqueLocalBeforeLinkLocal() {
        let candidates = ["fe80::1%en0", "fd00::5"]
        XCTAssertEqual(NetworkInfoKit.preferredIPv6(from: candidates), "fd00::5")
    }

    func testPreferredIPv6FallsBackToLinkLocalWhenItIsAllThereIs() {
        XCTAssertEqual(NetworkInfoKit.preferredIPv6(from: ["fe80::1%en0"]), "fe80::1%en0")
    }

    func testPreferredIPv6IgnoresLoopback() {
        XCTAssertNil(NetworkInfoKit.preferredIPv6(from: ["::1"]))
        XCTAssertEqual(NetworkInfoKit.preferredIPv6(from: ["::1", "2001:db8::9"]), "2001:db8::9")
    }

    func testPreferredIPv6WithNoCandidates() {
        XCTAssertNil(NetworkInfoKit.preferredIPv6(from: []))
    }

    // MARK: - resolv.conf parsing

    func testResolvConfParsesNameservers() {
        let fixture = """
        #
        # macOS Notice
        #
        nameserver 192.168.1.1
        nameserver 8.8.8.8
        """

        XCTAssertEqual(NetworkInfoKit.dnsServers(fromResolvConf: fixture), ["192.168.1.1", "8.8.8.8"])
    }

    func testResolvConfIgnoresNonNameserverDirectives() {
        let fixture = """
        search lan example.com
        domain lan
        options ndots:1
        nameserver 1.1.1.1
        """

        XCTAssertEqual(NetworkInfoKit.dnsServers(fromResolvConf: fixture), ["1.1.1.1"])
    }

    func testResolvConfHandlesTabsAndExtraSpacing() {
        let fixture = "nameserver\t10.0.0.1\n   nameserver    10.0.0.2   \n"
        XCTAssertEqual(NetworkInfoKit.dnsServers(fromResolvConf: fixture), ["10.0.0.1", "10.0.0.2"])
    }

    func testResolvConfDropsDuplicatesPreservingOrder() {
        let fixture = "nameserver 9.9.9.9\nnameserver 1.1.1.1\nnameserver 9.9.9.9\n"
        XCTAssertEqual(NetworkInfoKit.dnsServers(fromResolvConf: fixture), ["9.9.9.9", "1.1.1.1"])
    }

    func testResolvConfDropsMalformedEntries() {
        let fixture = """
        nameserver
        nameserver localhost
        nameserver 999.999.999.999
        nameserver 2606:4700:4700::1111
        """

        XCTAssertEqual(NetworkInfoKit.dnsServers(fromResolvConf: fixture), ["2606:4700:4700::1111"])
    }

    func testResolvConfIgnoresCommentedNameservers() {
        let fixture = "# nameserver 8.8.8.8\n; nameserver 8.8.4.4\nnameserver 192.168.0.1\n"
        XCTAssertEqual(NetworkInfoKit.dnsServers(fromResolvConf: fixture), ["192.168.0.1"])
    }

    func testResolvConfWithNoNameservers() {
        XCTAssertTrue(NetworkInfoKit.dnsServers(fromResolvConf: "search lan\n").isEmpty)
        XCTAssertTrue(NetworkInfoKit.dnsServers(fromResolvConf: "").isEmpty)
    }

    // MARK: - Public IP response validation

    func testPublicIPAcceptsBareAddress() {
        XCTAssertEqual(NetworkInfoKit.publicIPAddress(fromResponseBody: "203.0.113.7"), "203.0.113.7")
    }

    func testPublicIPTrimsSurroundingWhitespace() {
        XCTAssertEqual(NetworkInfoKit.publicIPAddress(fromResponseBody: "  203.0.113.7\n"), "203.0.113.7")
        XCTAssertEqual(NetworkInfoKit.publicIPAddress(fromResponseBody: "2001:db8::1\r\n"), "2001:db8::1")
    }

    /// The endpoint is a third party: a captive portal or an outage can put an HTML page behind
    /// the same URL, and that must never be shown to the user as their address.
    func testPublicIPRejectsNonAddressBodies() {
        XCTAssertNil(NetworkInfoKit.publicIPAddress(fromResponseBody: "<html><body>Login</body></html>"))
        XCTAssertNil(NetworkInfoKit.publicIPAddress(fromResponseBody: "Service temporarily unavailable"))
        XCTAssertNil(NetworkInfoKit.publicIPAddress(fromResponseBody: "{\"ip\":\"203.0.113.7\"}"))
    }

    func testPublicIPRejectsEmptyBody() {
        XCTAssertNil(NetworkInfoKit.publicIPAddress(fromResponseBody: ""))
        XCTAssertNil(NetworkInfoKit.publicIPAddress(fromResponseBody: "   \n  "))
    }

    func testPublicIPRejectsOversizedBody() {
        let padded = String(repeating: "8", count: NetworkInfoKit.maximumPublicIPResponseBytes + 1)
        XCTAssertNil(NetworkInfoKit.publicIPAddress(fromResponseBody: padded))
    }

    func testPublicIPRejectsAddressWithTrailingContent() {
        XCTAssertNil(NetworkInfoKit.publicIPAddress(fromResponseBody: "203.0.113.7 and more"))
    }

    // MARK: - Interface classification

    func testKindForSystemConfigurationInterfaceTypes() {
        XCTAssertEqual(NetworkInfoKit.kind(forInterfaceType: "IEEE80211"), .wiFi)
        XCTAssertEqual(NetworkInfoKit.kind(forInterfaceType: "Ethernet"), .ethernet)
        XCTAssertEqual(NetworkInfoKit.kind(forInterfaceType: "Bridge"), .ethernet)
        XCTAssertEqual(NetworkInfoKit.kind(forInterfaceType: "WWAN"), .cellular)
        XCTAssertEqual(NetworkInfoKit.kind(forInterfaceType: "Bluetooth"), .bluetooth)
        XCTAssertEqual(NetworkInfoKit.kind(forInterfaceType: "PPP"), .vpn)
        XCTAssertEqual(NetworkInfoKit.kind(forInterfaceType: "IPSec"), .vpn)
    }

    func testKindForUnknownOrMissingInterfaceType() {
        XCTAssertEqual(NetworkInfoKit.kind(forInterfaceType: "SomethingNew"), .other)
        XCTAssertEqual(NetworkInfoKit.kind(forInterfaceType: nil), .other)
    }

    /// `enN` must NOT be guessed as Ethernet — on Apple silicon it is the Wi‑Fi interface too, and
    /// the name-based path exists only for tunnels SystemConfiguration does not enumerate.
    func testKindForBSDNameFallback() {
        XCTAssertEqual(NetworkInfoKit.kind(forBSDName: "utun4"), .vpn)
        XCTAssertEqual(NetworkInfoKit.kind(forBSDName: "ipsec0"), .vpn)
        XCTAssertEqual(NetworkInfoKit.kind(forBSDName: "lo0"), .loopback)
        XCTAssertEqual(NetworkInfoKit.kind(forBSDName: "en0"), .other)
    }

    func testEveryLinkKindHasDisplayNameAndSymbol() {
        for kind in NetworkLinkKind.allCases {
            XCTAssertFalse(kind.displayName.isEmpty, "\(kind) has no display name")
            XCTAssertFalse(kind.symbolName.isEmpty, "\(kind) has no SF Symbol")
        }
    }

    // MARK: - Snapshot presentation

    func testSnapshotSubnetDescriptionIncludesPrefixLength() {
        let snapshot = NetworkSnapshot(subnetMask: "255.255.255.0", subnetPrefixLength: 24)
        XCTAssertEqual(snapshot.subnetDescription, "255.255.255.0 (/24)")
    }

    func testSnapshotSubnetDescriptionOmitsPrefixWhenNonContiguous() {
        let snapshot = NetworkSnapshot(subnetMask: "255.0.255.0", subnetPrefixLength: nil)
        XCTAssertEqual(snapshot.subnetDescription, "255.0.255.0")
    }

    func testSnapshotSubnetDescriptionIsNilWithoutMask() {
        XCTAssertNil(NetworkSnapshot().subnetDescription)
    }

    func testSnapshotHasConnectionRequiresAnInterfaceAndAnAddress() {
        XCTAssertFalse(NetworkSnapshot().hasConnection)
        // Mid-DHCP: the interface is primary but has no address yet.
        XCTAssertFalse(NetworkSnapshot(interfaceBSDName: "en0").hasConnection)
        XCTAssertFalse(NetworkSnapshot(ipv4: "10.0.0.2").hasConnection)
        XCTAssertTrue(NetworkSnapshot(interfaceBSDName: "en0", ipv4: "10.0.0.2").hasConnection)
        // IPv6-only networks are a connection too.
        XCTAssertTrue(NetworkSnapshot(interfaceBSDName: "en0", ipv6: "2001:db8::1").hasConnection)
    }

    // MARK: - Endpoint wiring

    /// The label the UI shows and the URL actually contacted must not drift apart — the whole
    /// consent story rests on the user being told the right hostname.
    func testPublicIPEndpointMatchesAdvertisedHost() {
        XCTAssertEqual(NetworkInfoKit.publicIPEndpoint.host, NetworkInfoKit.publicIPServiceHost)
        XCTAssertEqual(NetworkInfoKit.publicIPEndpoint.scheme, "https")
    }
}
