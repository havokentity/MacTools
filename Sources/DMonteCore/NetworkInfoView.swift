import AppKit
import SwiftUI

/// The floating Network Info popover: the primary interface and its kind, the local addresses
/// (IPv4, subnet, router, IPv6), the configured DNS resolvers, and an explicitly user-initiated
/// public-IP lookup. Every value row is click-to-copy. Content is scaled to match the
/// menu-bar/display scale so it fits the scaled panel (same approach as the other tools).
public struct NetworkInfoPopoverView: View {
    @ObservedObject var controller: NetworkInfoController
    var onQuit: () -> Void

    @State private var isShowingSettings = false
    private let scale = NetworkInfoSizing.currentScale

    public init(controller: NetworkInfoController, onQuit: @escaping () -> Void) {
        self.controller = controller
        self.onQuit = onQuit
    }

    private func s(_ value: CGFloat) -> CGFloat { value * scale }

    private var accent: Color { .teal }

    public var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                Divider().opacity(0.6)

                ScrollView {
                    VStack(spacing: s(10)) {
                        connectionSection
                        addressSection
                        dnsSection
                        publicIPSection
                    }
                    .padding(.horizontal, s(16))
                    .padding(.vertical, s(12))
                }

                Spacer(minLength: 0)
                footer
            }

            if isShowingSettings {
                PreferencesOverlay(cornerRadius: 18) {
                    NetworkInfoSettingsView(
                        controller: controller,
                        onQuit: onQuit,
                        onClose: { isShowingSettings = false }
                    )
                }
            }
        }
        .frame(width: NetworkInfoSizing.preferredSize().width, height: NetworkInfoSizing.preferredSize().height)
        .frostedPanel(cornerRadius: 18)
        .onAppear {
            controller.start()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: s(8)) {
            Image(systemName: controller.snapshot.hasConnection ? controller.snapshot.kind.symbolName : "wifi.slash")
                .font(.system(size: s(15), weight: .semibold))
                .foregroundStyle(controller.snapshot.hasConnection ? accent : Color.secondary)

            Text("Network Info")
                .font(.system(size: s(15), weight: .bold))
                .foregroundStyle(.primary.opacity(0.9))

            Spacer()

            Button {
                controller.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: s(13), weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Re-read the local network details")

            Button {
                isShowingSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: s(14), weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, s(16))
        .padding(.top, s(14))
        .padding(.bottom, s(10))
    }

    // MARK: - Connection

    private var connectionSection: some View {
        section(title: "CONNECTION") {
            if controller.snapshot.hasConnection {
                valueRow(label: "Interface", value: interfaceValue)
                valueRow(label: "Type", value: controller.snapshot.kind.displayName)
            } else {
                emptyRow("No active network connection")
            }
        }
    }

    /// "Wi‑Fi (en0)" when SystemConfiguration names the interface, otherwise the bare BSD name —
    /// tunnels created by VPN clients are unnamed and would render as an empty parenthesis.
    private var interfaceValue: String {
        let bsdName = controller.snapshot.interfaceBSDName ?? "—"
        guard let displayName = controller.snapshot.interfaceDisplayName, !displayName.isEmpty else {
            return bsdName
        }
        return "\(displayName) (\(bsdName))"
    }

    // MARK: - Addresses

    private var addressSection: some View {
        section(title: "ADDRESSES") {
            valueRow(label: "IPv4", value: controller.snapshot.ipv4)
            valueRow(label: "Subnet", value: controller.snapshot.subnetDescription)
            valueRow(label: "Router", value: controller.snapshot.router)
            valueRow(label: "IPv6", value: controller.snapshot.ipv6)
        }
    }

    // MARK: - DNS

    private var dnsSection: some View {
        section(title: "DNS SERVERS") {
            if controller.snapshot.dnsServers.isEmpty {
                emptyRow("None configured")
            } else {
                // Indexed so two interfaces handing out the same resolver still get distinct rows.
                ForEach(Array(controller.snapshot.dnsServers.enumerated()), id: \.offset) { index, server in
                    valueRow(label: "DNS \(index + 1)", value: server)
                }
            }
        }
    }

    // MARK: - Public IP

    private var publicIPSection: some View {
        section(title: "PUBLIC IP") {
            if let publicIP = controller.publicIP {
                valueRow(label: "Public", value: publicIP)
            }

            if let status = controller.publicIPStatus {
                Text(status)
                    .font(.system(size: s(11)))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                controller.fetchPublicIP()
            } label: {
                HStack(spacing: s(7)) {
                    Image(systemName: "globe")
                        .font(.system(size: s(12), weight: .semibold))
                    Text(controller.publicIP == nil ? "Look Up Public IP" : "Check Again")
                        .font(.system(size: s(12), weight: .semibold))
                }
                .foregroundStyle(controller.isFetchingPublicIP ? Color.secondary : Color.primary)
                .frame(maxWidth: .infinity)
                .frame(height: s(32))
                .background(
                    RoundedRectangle(cornerRadius: s(8), style: .continuous)
                        .fill(Color.secondary.opacity(0.14))
                )
                .contentShape(RoundedRectangle(cornerRadius: s(8), style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(controller.isFetchingPublicIP)

            // Naming the service on the face of the button, not buried in settings, is the point:
            // this is the only control in the tool that talks to anyone but the local machine.
            Text(publicIPDisclosure)
                .font(.system(size: s(11)))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The second half of this sentence has to track the preference: claiming "nothing is sent
    /// until you press the button" while the automatic lookup is switched on would be a plain
    /// falsehood, and this disclosure is the whole basis on which the user consents.
    private var publicIPDisclosure: String {
        let opening = "Sends one request to \(NetworkInfoKit.publicIPServiceHost), which replies with the address your traffic appears to come from."
        guard controller.fetchesPublicIPAutomatically else {
            return "\(opening) Nothing is sent until you press the button."
        }
        return "\(opening) Automatic lookup is on, so this also runs whenever the network changes."
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text(controller.snapshot.hasConnection ? "Updates when the network changes" : "Waiting for a connection")
                .font(.system(size: s(11), weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Button {
                onQuit()
            } label: {
                Label("Quit", systemImage: "power")
                    .font(.system(size: s(12), weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, s(16))
        .padding(.top, s(8))
        .padding(.bottom, s(14))
    }

    // MARK: - Building blocks

    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: s(6)) {
            Text(title)
                .font(.system(size: s(9), weight: .bold))
                .foregroundStyle(.secondary)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A copyable value row. The whole row is the button rather than just a trailing icon, so a
    /// long address stays easy to hit; the icon flips to a checkmark for a moment after a copy.
    private func valueRow(label: String, value: String?) -> some View {
        let resolved = value ?? "—"
        let isCopyable = value != nil
        let isCopied = controller.copiedRowID == label

        return Button {
            guard let value else { return }
            controller.copy(value, rowID: label)
        } label: {
            HStack(spacing: s(8)) {
                Text(label)
                    .font(.system(size: s(9), weight: .bold))
                    .foregroundStyle(Color.secondary)
                    .frame(width: s(52), alignment: .leading)

                Text(resolved)
                    .font(.system(size: s(11.5), design: .monospaced))
                    .foregroundStyle(isCopyable ? Color.primary.opacity(0.9) : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: s(11), weight: .semibold))
                    .foregroundStyle(isCopied ? Color.green : Color.secondary)
                    .opacity(isCopyable ? 1 : 0)
            }
            .padding(.horizontal, s(10))
            .frame(height: s(28))
            .background(
                RoundedRectangle(cornerRadius: s(7), style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .contentShape(RoundedRectangle(cornerRadius: s(7), style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isCopyable)
        .help(isCopyable ? "Copy \(label)" : "Not available on this network")
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: s(11.5)))
            .foregroundStyle(.secondary)
            .padding(.horizontal, s(10))
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: s(28))
            .background(
                RoundedRectangle(cornerRadius: s(7), style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
    }
}

// MARK: - Settings

private struct NetworkInfoSettingsView: View {
    @ObservedObject var controller: NetworkInfoController
    var onQuit: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Network Info Settings")
                    .font(.system(size: 16, weight: .bold))
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }

            settingRow(title: "Look up public IP automatically") {
                GreenSwitch(isOn: Binding(
                    get: { controller.fetchesPublicIPAutomatically },
                    set: { controller.setFetchesPublicIPAutomatically($0) }
                ))
            }

            Text("Off by default. When on, \(NetworkInfoKit.publicIPServiceHost) is queried whenever the network changes, which tells that service your address each time. Everything else this tool shows is read from your Mac and never leaves it.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if controller.publicIP != nil {
                Button {
                    controller.clearPublicIP()
                } label: {
                    Label("Clear Public IP", systemImage: "eye.slash")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Divider()

            Button(role: .destructive) {
                onClose()
                onQuit()
            } label: {
                Label("Quit Network Info", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()
        }
        .padding(20)
        .frame(width: 340, height: 300)
    }

    private func settingRow<Trailing: View>(title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            trailing()
        }
    }
}
