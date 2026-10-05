import Combine
import Foundation
import Network

/// A host on the local network that offers remote access, as its Bonjour
/// advertisement describes it.
struct DiscoveredRemoteHost: Identifiable, Equatable, Sendable {
    /// The TXT record's host id: what a pairing is keyed by, so a renamed
    /// service (Bonjour adds " (2)" to a name it sees twice) is still the
    /// same host.
    var id: String
    var name: String
    var endpoint: NWEndpoint
    /// The address it advertises, for a list to tell same-named devices
    /// apart; nil from a host that does not say.
    var address: String? = nil
}

/// The hosts nearby, from an `NWBrowser` on `_ighostvt._tcp`.
///
/// Browsing is what asks for the local-network permission, so it starts
/// only when something wants the answer: the remote-access settings, or a
/// launch with paired hosts to offer in the new-tab menu. This device's own
/// helper advertises too, and is left out by its host id.
@MainActor
final class RemoteHostDirectory: ObservableObject {
    static let shared = RemoteHostDirectory()

    @Published private(set) var hosts: [DiscoveredRemoteHost] = []
    @Published private(set) var paired: [PairedRemoteHost] = PairedRemoteHostStore.hosts

    /// This device's own host id: its advertisement is never a device to
    /// pair or connect with. Kept once the helper has said it — the id
    /// never changes — so a status that could not be read does not bring
    /// this device back into its own list.
    private(set) var ownHostID: String? = UserDefaults.standard.string(forKey: ownHostIDKey) {
        didSet { publish() }
    }

    nonisolated private static let ownHostIDKey = "Remote.ownHostID"

    func noteOwnHostID(_ id: String?) {
        guard let id, id != ownHostID else { return }
        UserDefaults.standard.set(id, forKey: Self.ownHostIDKey)
        ownHostID = id
    }

    /// The same, readable from the pairing path.
    nonisolated static var storedOwnHostID: String? {
        UserDefaults.standard.string(forKey: ownHostIDKey)
    }

    private var browser: NWBrowser?
    private var results: [DiscoveredRemoteHost] = []
    private var observer: NSObjectProtocol?

    private nonisolated static let lock = NSLock()
    private nonisolated(unsafe) static var endpoints: [String: NWEndpoint] = [:]

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: PairedRemoteHostStore.didChange,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.paired = PairedRemoteHostStore.hosts
            }
        }
    }

    /// The host's current address, for a transport's queue.
    nonisolated static func endpoint(forHostID id: String) -> NWEndpoint? {
        lock.withLock { endpoints[id] }
    }

    /// Paired hosts worth offering: the ones the browser sees, and the ones
    /// with a remembered address — on a network that drops multicast the
    /// browser sees nothing, and the address is the only way in.
    var reachablePaired: [PairedRemoteHost] {
        paired.filter(isReachable)
    }

    func isReachable(_ host: PairedRemoteHost) -> Bool {
        isDiscovered(host.id) || host.lastAddress != nil
    }

    func isDiscovered(_ hostID: String) -> Bool {
        hosts.contains { $0.id == hostID }
    }

    /// Where a paired host is now: what it advertises, else where it was
    /// last reached.
    func address(of host: PairedRemoteHost) -> String? {
        hosts.first { $0.id == host.id }?.address ?? host.lastAddress
    }

    /// Starts browsing if it has not; idempotent.
    func start() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: RemoteAccess.serviceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap(Self.host(from:))
            Task { @MainActor in
                self?.results = found
                self?.publish()
            }
        }
        browser.stateUpdateHandler = { state in
            if case let .failed(error) = state {
                AppLog.warning(.transport, "remote host browser failed: \(error)")
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    /// At launch: browse only if there is a paired host to look for.
    func startIfPaired() {
        if !paired.isEmpty {
            start()
        }
    }

    private func publish() {
        var seen: Set<String> = []
        let visible = results.filter { $0.id != ownHostID && seen.insert($0.id).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        Self.lock.withLock {
            Self.endpoints = Dictionary(visible.map { ($0.id, $0.endpoint) }, uniquingKeysWith: { first, _ in first })
        }
        if visible != hosts {
            hosts = visible
        }
        // A paired host renamed on its own side: follow it.
        for host in visible {
            if let pairedHost = paired.first(where: { $0.id == host.id }), pairedHost.name != host.name {
                PairedRemoteHostStore.syncName(host.name, forHostID: host.id)
            }
        }
    }

    private nonisolated static func host(from result: NWBrowser.Result) -> DiscoveredRemoteHost? {
        guard case let .bonjour(record) = result.metadata,
              let id = record[RemoteAccess.TXTKey.hostID], !id.isEmpty
        else { return nil }
        var name = record[RemoteAccess.TXTKey.hostName] ?? ""
        if name.isEmpty, case let .service(serviceName, _, _, _) = result.endpoint {
            name = serviceName
        }
        let address = record[RemoteAccess.TXTKey.address].flatMap { $0.isEmpty ? nil : $0 }
        return DiscoveredRemoteHost(id: id, name: name, endpoint: result.endpoint, address: address)
    }
}
