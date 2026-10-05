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
        var devices: [Device]
    }

    private(set) var hostID: String
    private(set) var devices: [Device]

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
            return RemoteStore(hostID: file.hostID, devices: file.devices)
        }
        let store = RemoteStore(hostID: UUID().uuidString, devices: [])
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

    mutating func markSeen(deviceID: String) {
        guard let index = devices.firstIndex(where: { $0.id == deviceID }) else { return }
        devices[index].lastSeen = Date()
        save()
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
        guard let data = try? JSONEncoder().encode(File(hostID: hostID, devices: devices)) else { return }
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
