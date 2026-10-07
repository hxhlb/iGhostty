import Foundation
import Network
import UIKit

/// A device this one has paired with: what to call it, and the key that
/// opens a link to it. The key is the whole of the pairing — whoever holds
/// it is this device to that host.
struct PairedRemoteHost: Codable, Equatable, Identifiable, Sendable {
    /// The host's own id, from its Bonjour TXT record and the pairing reply.
    var id: String
    /// What the host calls itself — its device name, kept in step with its
    /// advertisement (`PairedRemoteHostStore.syncName`).
    var name: String
    /// What the user calls it here, when they named it; nil follows `name`.
    var nickname: String? = nil
    /// This device's id as that host knows it.
    var deviceID: String
    var deviceKey: Data
    var pairedAt: Date
    /// The address it was last reached at directly, as the connection
    /// resolved it — never the relay's. The way back in on a launch where
    /// the browser has not seen the host yet.
    var lastAddress: String?
    /// When a link last reached it — pairing, then every connection.
    var lastSeen: Date? = nil

    /// The name to show: the nickname, or the device's own.
    var displayName: String {
        nickname ?? name
    }

    /// Where to try when the browser has not found the host: the address
    /// it last answered at.
    var lastEndpoint: NWEndpoint? {
        guard let lastAddress, let port = NWEndpoint.Port(rawValue: RemoteAccess.port) else { return nil }
        return .hostPort(host: NWEndpoint.Host(lastAddress), port: port)
    }
}

/// This device as a remote-access client: one id for every host it pairs
/// with, made once, and the name it introduces itself by.
enum RemoteDeviceIdentity {
    private static let key = "Remote.deviceID"

    static var deviceID: String {
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let made = UUID().uuidString
        UserDefaults.standard.set(made, forKey: key)
        return made
    }

    private static let chosenNameKey = "Remote.deviceName"
    private static let systemNameKey = "Remote.systemDeviceName"

    /// Kept where a transport's queue can read it: UIDevice answers on the
    /// main thread only. Called as the app launches.
    @MainActor
    static func noteSystemName() {
        UserDefaults.standard.set(
            RemoteAccess.sanitizedName(DeviceNaming.meaningful(UIDevice.current.name)),
            forKey: systemNameKey,
        )
    }

    /// The name the owner gave the device in Settings.
    static var systemName: String {
        UserDefaults.standard.string(forKey: systemNameKey) ?? RemoteAccess.sanitizedName("")
    }

    /// The name chosen in Remote Access, nil for the device's own.
    static var chosenName: String? {
        get { UserDefaults.standard.string(forKey: chosenNameKey) }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed.isEmpty {
                UserDefaults.standard.removeObject(forKey: chosenNameKey)
            } else {
                UserDefaults.standard.set(RemoteAccess.sanitizedName(trimmed), forKey: chosenNameKey)
            }
        }
    }

    /// What the other devices call this one: as a host it is advertised
    /// under it, as a client it pairs and connects under it.
    static var deviceName: String {
        chosenName ?? systemName
    }
}

/// The paired hosts, in one file in the app's own container: 0600, and on
/// the device under data protection until the first unlock — a tab that
/// reconnects in the background after a reboot-and-unlock still reads it. Read from the transport's queue as well as the main
/// actor, so every access goes through the lock; `didChange` tells the
/// interface.
enum PairedRemoteHostStore {
    static let didChange = Notification.Name("wiki.qaq.ighostvt.pairedRemoteHostsDidChange")

    private static let lock = NSLock()
    private nonisolated(unsafe) static var cache: [PairedRemoteHost]?

    static var hosts: [PairedRemoteHost] {
        lock.withLock { loadedLocked() }
    }

    static func host(id: String) -> PairedRemoteHost? {
        hosts.first { $0.id == id }
    }

    static func save(_ host: PairedRemoteHost) {
        lock.withLock {
            var hosts = loadedLocked()
            hosts.removeAll { $0.id == host.id }
            hosts.append(host)
            hosts.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            writeLocked(hosts)
        }
        notify()
    }

    /// The user named the host; nil or blank goes back to its own name.
    static func setNickname(_ nickname: String?, forHostID id: String) {
        let trimmed = nickname.map { RemoteAccess.sanitizedName($0) }
        let value = (nickname?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) ? nil : trimmed
        update(id) { $0.nickname = value }
    }

    /// The host advertised itself under a new device name.
    static func syncName(_ name: String, forHostID id: String) {
        guard !name.isEmpty else { return }
        update(id) { $0.name = RemoteAccess.sanitizedName(name) }
    }

    private static func update(_ id: String, _ change: (inout PairedRemoteHost) -> Void) {
        let changed = lock.withLock { () -> Bool in
            var hosts = loadedLocked()
            guard let index = hosts.firstIndex(where: { $0.id == id }) else { return false }
            var host = hosts[index]
            change(&host)
            guard host != hosts[index] else { return false }
            hosts[index] = host
            writeLocked(hosts)
            return true
        }
        if changed {
            notify()
        }
    }

    static func remove(id: String) {
        lock.withLock {
            var hosts = loadedLocked()
            hosts.removeAll { $0.id == id }
            writeLocked(hosts)
        }
        notify()
    }

    /// The link reached the host: the address that answered, and when — kept up to date on every connection for a
    /// launch on which the browser has not found it. Through the relay
    /// only the time: the address that answered is the relay's, and kept
    /// as the host's it would send every later direct attempt there.
    static func noteReached(_ connection: NWConnection, forHostID id: String, viaRelay: Bool) {
        let address = viaRelay ? nil : rememberedAddress(of: connection, hostID: id)
        lock.withLock {
            var hosts = loadedLocked()
            guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
            var host = hosts[index]
            host.lastAddress = address ?? host.lastAddress
            host.lastSeen = Date()
            guard host != hosts[index] else { return }
            hosts[index] = host
            writeLocked(hosts)
        }
    }

    /// The IPv4 address to remember for a host a connection reached. Bonjour
    /// often resolves to IPv6, which is no address to show or to dial back:
    /// a link-local one routes nowhere without its interface, and a
    /// unique-local or temporary one changes under the host. The host's own
    /// advertised IPv4 stands in for it; with neither, nil keeps the last.
    static func rememberedAddress(of connection: NWConnection, hostID: String) -> String? {
        if case let .hostPort(host, _) = connection.currentPath?.remoteEndpoint,
           let address = RemoteNetwork.ipv4Description(host)
        {
            return address
        }
        return RemoteHostDirectory.advertisedAddress(forHostID: hostID)
    }

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #if targetEnvironment(macCatalyst)
            // Unsandboxed on the Mac: Application Support is the user's own.
            return base.appendingPathComponent("iGhostVT/RemoteHosts.json")
        #else
            return base.appendingPathComponent("RemoteHosts.json")
        #endif
    }

    private static func loadedLocked() -> [PairedRemoteHost] {
        if let cache {
            return cache
        }
        var loaded = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode([PairedRemoteHost].self, from: $0) } ?? []
        // Earlier builds kept whatever the connection resolved, IPv6
        // included; only an IPv4 address is kept. The next connection
        // records the right one.
        for index in loaded.indices {
            if let address = loaded[index].lastAddress, IPv4Address(address) == nil {
                loaded[index].lastAddress = nil
            }
        }
        cache = loaded
        return loaded
    }

    private static func writeLocked(_ hosts: [PairedRemoteHost]) {
        cache = hosts
        let url = fileURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(hosts)
            #if targetEnvironment(macCatalyst)
                try data.write(to: url, options: .atomic)
            #else
                try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #endif
            chmod(url.path, 0o600)
        } catch {
            AppLog.error(.transport, "could not save paired hosts: \(error)")
        }
    }

    private static func notify() {
        Task { @MainActor in
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }
}
