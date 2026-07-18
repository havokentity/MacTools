import AppKit
import Foundation
import Network

public extension DefaultsKey {
    /// Whether the public-IP lookup may run on its own — on open and after each network change —
    /// instead of only when the user presses the button. Opt-in: the integrator should register a
    /// default of `false`, because every automatic lookup discloses the user's address to a third
    /// party that they never asked to contact.
    static let networkInfoFetchesPublicIPAutomatically = "tool.networkInfo.fetchesPublicIPAutomatically"
}

/// Owns the current `NetworkSnapshot`, the path monitor that refreshes it when the network
/// changes, and the opt-in public-IP lookup. All published state is mutated on the main actor;
/// the two slow operations (the `getifaddrs`/SystemConfiguration read and the HTTPS request) are
/// hopped off it explicitly.
@MainActor
public final class NetworkInfoController: ObservableObject {
    /// Local network facts. Starts empty and is filled by the first `refresh()`, so the popover
    /// can be constructed before any system read has happened.
    @Published public private(set) var snapshot = NetworkSnapshot()

    /// Public address as last reported by `NetworkInfoKit.publicIPServiceHost`, or `nil` if it has
    /// never been fetched successfully in this session. Deliberately not persisted — a stale
    /// public IP shown as current is worse than showing nothing.
    @Published public private(set) var publicIP: String?

    /// Inline status for the public-IP row: in-progress text, or an honest failure sentence. `nil`
    /// once an address is showing and nothing needs saying.
    @Published public private(set) var publicIPStatus: String?

    @Published public private(set) var isFetchingPublicIP = false

    /// See `DefaultsKey.networkInfoFetchesPublicIPAutomatically`.
    @Published public private(set) var fetchesPublicIPAutomatically: Bool

    /// Set for a few seconds after a successful copy so the view can flash a checkmark on the row
    /// that was copied. Holds the row's label, not its value, so two rows sharing a value (an
    /// IPv4 router equal to a DNS server, which is the common home-router case) don't both flash.
    @Published public private(set) var copiedRowID: String?

    /// Recreated by each `start()` rather than held for the process lifetime: `NWPathMonitor` is
    /// single-use, and calling `start(queue:)` on one that has already been cancelled silently
    /// never delivers an update — a stop/start cycle would leave the tool frozen on a stale
    /// snapshot with no sign anything was wrong.
    private var pathMonitor: NWPathMonitor?
    private let pathMonitorQueue = DispatchQueue(label: "com.havokentity.mactools.networkinfo.path")

    private var copiedResetTask: Task<Void, Never>?
    private var publicIPTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    /// Ephemeral so the public-IP request leaves no cookie, credential or cache trace on disk, and
    /// short-timeout so a captive portal that black-holes the connection surfaces as a failure
    /// message within a few seconds instead of spinning indefinitely. `nonisolated` so the request
    /// below can run off the main actor.
    private nonisolated static let publicIPSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.waitsForConnectivity = false
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration)
    }()

    public init() {
        fetchesPublicIPAutomatically = AppDefaults.shared.bool(forKey: DefaultsKey.networkInfoFetchesPublicIPAutomatically)
    }

    deinit {
        // `deinit` is nonisolated; cancel the monitor directly so its dispatch source is torn down
        // even on a path that never reaches `applicationWillTerminate`. `cancel()` on an
        // already-cancelled monitor is a no-op.
        pathMonitor?.cancel()
    }

    // MARK: - Public API

    /// Starts watching for network changes and takes the first reading. Safe to call more than
    /// once; the monitor is only started on the first call.
    public func start() {
        refresh()

        guard pathMonitor == nil else { return }

        // `NWPathMonitor` fires for interface, address and reachability changes alike, which is
        // exactly the set of events that can invalidate the snapshot — polling on a timer would
        // either lag behind a Wi‑Fi switch or burn wakeups doing nothing.
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                self?.handlePathChange()
            }
        }
        pathMonitor = monitor
        monitor.start(queue: pathMonitorQueue)
    }

    /// Stops the path monitor and abandons every task still in flight. Called from
    /// `applicationWillTerminate` so the monitor's queue is torn down before the process exits
    /// rather than during deallocation. A later `start()` builds a fresh monitor.
    public func stop() {
        pathMonitor?.cancel()
        pathMonitor = nil
        refreshTask?.cancel()
        refreshTask = nil

        // A public-IP request that outlived `stop()` would keep talking to a third party after the
        // tool was told to stand down — the one thing this lookup is deliberately user-initiated to
        // avoid. Cancelling propagates into `URLSession`, and the state its completion would have
        // cleared has to be cleared here because that completion now never runs.
        publicIPTask?.cancel()
        publicIPTask = nil
        isFetchingPublicIP = false
        publicIPStatus = nil

        copiedResetTask?.cancel()
        copiedResetTask = nil
        copiedRowID = nil
    }

    /// Re-reads the local network facts. The read touches `getifaddrs` and SystemConfiguration, so
    /// it runs detached and only the resulting value crosses back to the main actor.
    public func refresh() {
        // A network transition makes `NWPathMonitor` fire several times in quick succession, so
        // supersede the previous read instead of letting reads pile up: without this they race,
        // and a slower earlier read can land last and overwrite the newer snapshot with stale data.
        let previous = refreshTask
        previous?.cancel()

        // The read itself is the detached task, not a nested one whose handle is dropped: an
        // unretained child ignores this cancellation entirely, so the supersede above would be
        // decorative and every callback in a burst would still reach `snapshot()`.
        refreshTask = Task.detached(priority: .userInitiated) { [weak self] in
            // Cancelling cannot interrupt a synchronous `getifaddrs`/SystemConfiguration walk that
            // has already begun, so waiting the previous read out is what actually keeps the burst
            // serial. Superseded reads bail at the check below without touching the system.
            await previous?.value

            guard !Task.isCancelled else { return }
            let reading = NetworkInfoKit.snapshot()
            guard !Task.isCancelled, let self else { return }

            await self.publish(reading)
        }
    }

    /// Asks `NetworkInfoKit.publicIPServiceHost` for this Mac's public address. Never called
    /// implicitly at launch — only from the button, or from `handlePathChange()` when the user has
    /// explicitly opted in.
    public func fetchPublicIP() {
        guard !isFetchingPublicIP else { return }

        isFetchingPublicIP = true
        publicIPStatus = "Asking \(NetworkInfoKit.publicIPServiceHost)…"

        publicIPTask?.cancel()
        publicIPTask = Task { [weak self] in
            let outcome = await Self.requestPublicIP()

            guard let self, !Task.isCancelled else { return }
            self.isFetchingPublicIP = false

            switch outcome {
            case .success(let address):
                self.publicIP = address
                self.publicIPStatus = nil
            case .failure(let message):
                // Keep any previously fetched address on screen rather than blanking it: a failed
                // refresh does not mean the last good answer became wrong.
                self.publicIPStatus = message
            }
        }
    }

    /// Turns the automatic lookup on or off. Turning it on fetches immediately, because the user
    /// just consented and would otherwise stare at an empty row until the next network change.
    public func setFetchesPublicIPAutomatically(_ newValue: Bool) {
        guard newValue != fetchesPublicIPAutomatically else { return }
        fetchesPublicIPAutomatically = newValue
        AppDefaults.shared.set(newValue, forKey: DefaultsKey.networkInfoFetchesPublicIPAutomatically)

        if newValue {
            fetchPublicIP()
        }
    }

    /// Copies `value` to the general pasteboard and flashes `rowID` for a moment.
    public func copy(_ value: String, rowID: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)

        copiedRowID = rowID
        copiedResetTask?.cancel()
        copiedResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard let self, !Task.isCancelled else { return }
            self.copiedRowID = nil
        }
    }

    /// Clears the public address without touching the preference — used when the user wants the
    /// value off the screen (e.g. before sharing a screenshot).
    public func clearPublicIP() {
        publicIPTask?.cancel()
        publicIPTask = nil
        isFetchingPublicIP = false
        publicIP = nil
        publicIPStatus = nil
    }

    // MARK: - Private

    /// Lands a completed read back on the main actor. Republishing an identical snapshot would
    /// redraw the popover and rewrite the tray icon for nothing on every path callback.
    private func publish(_ reading: NetworkSnapshot) {
        guard reading != snapshot else { return }
        snapshot = reading
    }

    private func handlePathChange() {
        refresh()

        // Any lookup already in flight was issued against the previous path, so its answer is not
        // trustworthy as the new network's address — abandon it before deciding what comes next.
        // Cancelling also clears `isFetchingPublicIP`, which would otherwise leave the button
        // disabled with no status text once the branch below wipes the "Asking…" line.
        publicIPTask?.cancel()
        publicIPTask = nil
        isFetchingPublicIP = false

        guard fetchesPublicIPAutomatically else {
            // The cached address almost certainly belongs to the previous network, so drop it
            // rather than let it masquerade as current until the user presses refresh.
            publicIP = nil
            publicIPStatus = nil
            return
        }

        fetchPublicIP()
    }

    private enum PublicIPOutcome: Sendable {
        case success(String)
        case failure(String)
    }

    /// Performs the lookup off the main actor and reduces every possible outcome to one of two
    /// display-ready cases — no error ever escapes to become an alert. Explicitly `nonisolated`:
    /// the main actor must stay free while the request is in flight.
    private nonisolated static func requestPublicIP() async -> PublicIPOutcome {
        let host = NetworkInfoKit.publicIPServiceHost

        do {
            var request = URLRequest(url: NetworkInfoKit.publicIPEndpoint)
            request.setValue("text/plain", forHTTPHeaderField: "Accept")
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

            let (data, response) = try await publicIPSession.data(for: request)

            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return .failure("\(host) replied \(http.statusCode).")
            }

            guard data.count <= NetworkInfoKit.maximumPublicIPResponseBytes,
                  let body = String(data: data, encoding: .utf8),
                  let address = NetworkInfoKit.publicIPAddress(fromResponseBody: body) else {
                return .failure("\(host) didn’t return an IP address.")
            }

            return .success(address)
        } catch {
            return .failure("Couldn’t reach \(host).")
        }
    }
}
