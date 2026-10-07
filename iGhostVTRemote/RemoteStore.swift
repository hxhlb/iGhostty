import CryptoKit
import Darwin
import Foundation

/// The host's identity and the devices paired with it, in one file only the
/// helper's user can read (`RemoteAccess.stateDirectory`, 0700, the file
/// 0600). A device key is a secret: whoever holds it is that device.
struct RemoteStore {
    struct Device: Codable, Equatable {
        var id: String
        var name: String
        var key: Data
        var pairedAt: Date
        var lastSeen: Date?
    }

    private struct File: Codable {
        var hostID: String
        var hostName: String?
        var devices: [Device]
        var relay: Data?
        var relayHostKey: Data?
    }

    private(set) var hostID: String
    /// The name the owner chose for this host in the app; nil is the
    /// device's own.
    private(set) var hostName: String?
    private(set) var devices: [Device]
    /// The relay this host registers with: a `.vtrpsc` file's content, as
    /// the app sent it (`setRelayConfiguration`). Holds the relay's private
    /// key — a secret like a device key.
    private(set) var relay: Data?
    /// This host's own P-256 key at its relay (`Relay/PROTOCOL.md`): the
    /// relay binds the host id to it on first sight, so only this host can
    /// register under the id or take a connection for it. Made on first
    /// use; a copied state file copies it too, which the relay answers
    /// with `superseded` rather than letting two machines trade places.
    private(set) var relayHostKey: Data?

    private static var directory: String {
        RemoteAccess.stateDirectory
    }

    private static var path: String {
        directory + "/state.json"
    }

    /// Reads the file, or starts a fresh identity when there is none (or it
    /// cannot be read — a host that lost its file is a new host, and every
    /// device pairs again).
    static func load() -> RemoteStore {
        if let data = FileManager.default.contents(atPath: path),
           let file = try? JSONDecoder().decode(File.self, from: data)
        {
            return RemoteStore(
                hostID: file.hostID,
                hostName: file.hostName,
                devices: file.devices,
                relay: file.relay,
                relayHostKey: file.relayHostKey,
            )
        }
        let store = RemoteStore(hostID: UUID().uuidString, hostName: nil, devices: [], relay: nil, relayHostKey: nil)
        store.save()
        return store
    }

    mutating func add(_ device: Device) {
        devices.removeAll { $0.id == device.id }
        devices.append(device)
        save()
    }

    /// False when there was no such device.
    @discardableResult
    mutating func remove(deviceID: String) -> Bool {
        let before = devices.count
        devices.removeAll { $0.id == deviceID }
        guard devices.count != before else { return false }
        save()
        return true
    }

    /// A device connected: when, and under the name it goes by now.
    mutating func markSeen(deviceID: String, name: String?) {
        guard let index = devices.firstIndex(where: { $0.id == deviceID }) else { return }
        devices[index].lastSeen = Date()
        if let name, !name.isEmpty {
            devices[index].name = name
        }
        save()
    }

    mutating func setHostName(_ name: String?) {
        hostName = name
        save()
    }

    mutating func setRelay(_ relay: Data?) {
        self.relay = relay
        save()
    }

    /// The host key, made and kept the first time it is asked for.
    mutating func hostKey() -> Data {
        if let relayHostKey {
            return relayHostKey
        }
        let made = P256.Signing.PrivateKey().rawRepresentation
        relayHostKey = made
        save()
        return made
    }

    func device(id: String) -> Device? {
        devices.first { $0.id == id }
    }

    private func save() {
        let directory = Self.directory
        var current = ""
        for component in directory.split(separator: "/") {
            current += "/" + component
            mkdir(current, 0o700)
        }
        chmod(directory, 0o700)
        let file = File(hostID: hostID, hostName: hostName, devices: devices, relay: relay, relayHostKey: relayHostKey)
        guard let data = try? JSONEncoder().encode(file) else { return }
        let temporary = Self.path + ".tmp"
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            RemoteLog.log("could not write \(temporary): \(String(cString: strerror(errno)))")
            return
        }
        let written = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        fsync(descriptor)
        close(descriptor)
        guard written == data.count, rename(temporary, Self.path) == 0 else {
            unlink(temporary)
            RemoteLog.log("could not replace \(Self.path)")
            return
        }
    }
}
