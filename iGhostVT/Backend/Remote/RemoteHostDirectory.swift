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
    var address: String?
    /// The iGhostVT version it runs; nil from a host older than the
    /// version rule, which no longer matches anything.
    var appVersion: String?
    /// Found at the relay rather than on this network: `endpoint` is the
    /// relay's, and a connection has to name the host by SNI.
    var viaRelay = false
}

/// A host registered at this device's relay, as the relay's list says.
struct RelayHost: Equatable, Sendable {
    var id: String
    var name: String
    var appVersion: String
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
    /// The hosts at the relay, by id, this device's own left out. Kept
    /// apart from `hosts`: those are on this network and are dialled at
    /// the address Bonjour gives, these only through the relay.
    @Published private(set) var relayHosts: [String: RelayHost] = [:]
    /// Why the relay could not be asked, nil when it answered (or there is
    /// none).
    @Published private(set) var relayProblem: RelayError?
    /// The relay this device uses (`RelayConfigurationStore`), for the
    /// settings to show.
    @Published private(set) var relay: RelayConfiguration? = RelayConfigurationStore.current
    private var relayObserver: NSObjectProtocol?
    private var relayAskedAt: Date?
    private var relayRequest: Task<Void, Never>?

    /// This device's own host id: its advertisement is never a device to
    /// pair or connect with. Kept once the helper has said it — the id
    /// never changes — so a status that could not be read does not bring
    /// this device back into its own list.
    private(set) var ownHostID: String? = UserDefaults.standard.string(forKey: ownHostIDKey) {
        didSet { publish() }
    }

    private nonisolated static let ownHostIDKey = "Remote.ownHostID"

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
    private nonisolated(unsafe) static var addresses: [String: String] = [:]
    /// Each host's version, from its advertisement or the relay's list.
    private nonisolated(unsafe) static var versions: [String: String] = [:]
    private nonisolated(unsafe) static var relayHostIDs: Set<String> = []

    private init() {
        relayObserver = NotificationCenter.default.addObserver(
            forName: RelayConfigurationStore.didChange,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.relay = RelayConfigurationStore.current
            }
        }
        observer = NotificationCenter.default.addObserver(
            forName: PairedRemoteHostStore.didChange,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                let paired = PairedRemoteHostStore.hosts
                self?.paired = paired
                // An unpaired device takes its recent directories with it.
                let kept = Set(paired.map(\.id))
                for hostID in RecentDirectoryStore.shared.remoteEntries.keys where !kept.contains(hostID) {
                    RecentDirectoryStore.shared.forget(host: hostID)
                }
            }
        }
    }

    /// The host's current address, for a transport's queue.
    nonisolated static func endpoint(forHostID id: String) -> NWEndpoint? {
        lock.withLock { endpoints[id] }
    }

    /// The IPv4 address the host advertises, for a transport's queue.
    nonisolated static func advertisedAddress(forHostID id: String) -> String? {
        lock.withLock { addresses[id] }
    }

    /// Whether the relay listed the host last time it was asked, for a
    /// transport's queue.
    nonisolated static func isAtRelay(_ id: String) -> Bool {
        lock.withLock { relayHostIDs.contains(id) }
    }

    /// The version the host says it runs, when it said, for a transport's
    /// queue.
    nonisolated static func knownVersion(ofHostID id: String) -> String? {
        lock.withLock { versions[id] }
    }

    /// The other device's version when it is known not to match this
    /// one's: a device that cannot connect, and why.
    nonisolated static func mismatchedVersion(ofHostID id: String) -> String? {
        guard let theirs = knownVersion(ofHostID: id), !RemoteAccess.isCompatible(theirs) else { return nil }
        return theirs
    }

    func mismatchedVersion(of hostID: String) -> String? {
        Self.mismatchedVersion(ofHostID: hostID)
    }

    /// Paired hosts worth offering: the ones the browser sees, and the ones
    /// with a remembered address — on a network that drops multicast the
    /// browser sees nothing, and the address is the only way in.
    var reachablePaired: [PairedRemoteHost] {
        paired.filter(isReachable)
    }

    func isReachable(_ host: PairedRemoteHost) -> Bool {
        isDiscovered(host.id) || relayHosts[host.id] != nil || host.lastAddress != nil
    }

    func isAtRelay(_ hostID: String) -> Bool {
        relayHosts[hostID] != nil
    }

    /// The hosts at the relay this device is not paired with, to pair with
    /// through it — never shown as nearby.
    var unpairedAtRelay: [DiscoveredRemoteHost] {
        guard let relay = RelayConfigurationStore.current else { return [] }
        let known = Set(paired.map(\.id)).union(hosts.map(\.id))
        return relayHosts.values.filter { !known.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { DiscoveredRemoteHost(id: $0.id, name: $0.name, endpoint: relay.endpoint, appVersion: $0.appVersion, viaRelay: true) }
    }

    /// Asks the relay which hosts it has. At most every few seconds unless
    /// `force` (the configuration changed); a call while one is out waits
    /// for that one.
    func refreshRelay(force: Bool = false) async {
        if let relayRequest {
            return await relayRequest.value
        }
        guard let configuration = RelayConfigurationStore.current else {
            relayAskedAt = nil
            relayProblem = nil
            if !relayHosts.isEmpty {
                relayHosts = [:]
                publish()
            }
            return
        }
        if !force, let relayAskedAt, Date().timeIntervalSince(relayAskedAt) < 5 {
            return
        }
        relayAskedAt = Date()
        let request = Task { @MainActor in
            let result = await withCheckedContinuation { continuation in
                RelayControl.listHosts(configuration: configuration) { continuation.resume(returning: $0) }
            }
            // The relay was removed or replaced while it answered: its list
            // describes a relay this device no longer uses.
            guard RelayConfigurationStore.current?.fingerprint == configuration.fingerprint else {
                relayProblem = nil
                if !relayHosts.isEmpty {
                    relayHosts = [:]
                }
                publish()
                return
            }
            switch result {
            case let .success(entries):
                relayProblem = nil
                let found = Dictionary(
                    entries.filter { $0.id != ownHostID }
                        .map { ($0.id, RelayHost(id: $0.id, name: $0.name, appVersion: $0.appVersion)) },
                    uniquingKeysWith: { first, _ in first },
                )
                if found != relayHosts {
                    relayHosts = found
                }
            case let .failure(error):
                AppLog.info(.transport, "relay list failed: \(error)")
                relayProblem = error
                if !relayHosts.isEmpty {
                    relayHosts = [:]
                }
            }
            publish()
        }
        relayRequest = request
        await request.value
        relayRequest = nil
    }

    func isDiscovered(_ hostID: String) -> Bool {
        hosts.contains { $0.id == hostID }
    }

    /// Where a paired host is now: what it advertises, else where it was
    /// last reached.
    func address(of host: PairedRemoteHost) -> String? {
        hosts.first { $0.id == host.id }?.address ?? host.lastAddress
    }

    /// The devices found here that this one is not paired with yet.
    var unpairedNearby: [DiscoveredRemoteHost] {
        let pairedIDs = Set(paired.map(\.id))
        return hosts.filter { !pairedIDs.contains($0.id) }
    }

    /// Starts browsing if it has not; idempotent. Asks the relay too.
    func start() {
        Task { await refreshRelay() }
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
        let relayHosts = relayHosts
        Self.lock.withLock {
            Self.endpoints = Dictionary(visible.map { ($0.id, $0.endpoint) }, uniquingKeysWith: { first, _ in first })
            Self.addresses = Dictionary(
                visible.compactMap { host in host.address.map { (host.id, $0) } },
                uniquingKeysWith: { first, _ in first },
            )
            var versions = relayHosts.mapValues(\.appVersion).filter { !$0.value.isEmpty }
            for host in visible {
                // An advertisement without a version is a host older than
                // the rule: it cannot match.
                versions[host.id] = host.appVersion ?? ""
            }
            Self.versions = versions
            Self.relayHostIDs = Set(relayHosts.keys)
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
        let version = record[RemoteAccess.TXTKey.appVersion].flatMap { $0.isEmpty ? nil : $0 }
        return DiscoveredRemoteHost(id: id, name: name, endpoint: result.endpoint, address: address, appVersion: version)
    }
}
