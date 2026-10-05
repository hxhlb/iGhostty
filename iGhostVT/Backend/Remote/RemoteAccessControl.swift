import Foundation
@preconcurrency import XPC

/// What this device's remote access looks like, from `remoteStatus`.
struct RemoteAccessStatus: Equatable, Sendable {
    struct Device: Identifiable, Equatable, Sendable {
        var id: String
        var name: String
        var pairedAt: Date
        var lastSeen: Date?
    }

    struct FailedAttempt: Equatable, Sendable {
        var address: String
        var time: Date
    }

    var isEnabled = false
    var state = RemoteAccessState.off
    var failureMessage: String?
    var hostID: String?
    var hostName: String?
    var connectedCount = 0
    var devices: [Device] = []
    var pairingCode: String?
    var pairingExpiresAt: Date?
    var failedAttempts: [FailedAttempt] = []

    /// The daemon could not be asked at all.
    var isUnavailable = false
}

/// The management operations (`remoteStatus`, `setRemoteAccess`, …) to this
/// device's daemon, each over a one-shot connection. Local only: nothing
/// here is reachable from another device.
enum RemoteAccessControl {
    static func status() async -> RemoteAccessStatus {
        await request(.remoteStatus)
    }

    static func setEnabled(_ enabled: Bool) async -> RemoteAccessStatus {
        await request(.setRemoteAccess) { xpc_dictionary_set_bool($0, iGhostVTWireKey.enabled, enabled) }
    }

    static func beginPairing() async -> RemoteAccessStatus {
        await request(.beginPairing)
    }

    static func endPairing() async -> RemoteAccessStatus {
        await request(.endPairing)
    }

    static func setHostName(_ name: String?) async -> RemoteAccessStatus {
        await request(.setHostName) { xpc_dictionary_set_string($0, iGhostVTWireKey.hostName, name ?? "") }
    }

    static func revoke(deviceID: String) async -> RemoteAccessStatus {
        await request(.revokeRemoteDevice) { xpc_dictionary_set_string($0, iGhostVTWireKey.deviceID, deviceID) }
    }

    private static func request(
        _ operation: iGhostVTOperation,
        _ fill: (xpc_object_t) -> Void = { _ in },
    ) async -> RemoteAccessStatus {
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(message, iGhostVTWireKey.version, iGhostVTProtocol.version)
        xpc_dictionary_set_uint64(message, iGhostVTWireKey.operation, operation.rawValue)
        fill(message)
        let box = Box(message)
        return await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "wiki.qaq.ighostvt.client.remote-access")
            let finished = Finished(continuation)
            guard let link = XPCDaemonLink(queue: queue) else {
                finished.resume(RemoteAccessStatus(isUnavailable: true))
                return
            }
            link.activate { event in
                if case .lost = event {
                    finished.resume(RemoteAccessStatus(isUnavailable: true))
                }
            }
            queue.asyncAfter(deadline: .now() + 6) {
                finished.resume(RemoteAccessStatus(isUnavailable: true))
                link.cancel()
            }
            let hello = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_uint64(hello, iGhostVTWireKey.version, iGhostVTProtocol.version)
            xpc_dictionary_set_uint64(hello, iGhostVTWireKey.operation, iGhostVTOperation.hello.rawValue)
            link.send(hello) { _ in
                link.send(box.message) { reply in
                    finished.resume(parse(reply))
                    link.cancel()
                }
            }
        }
    }

    private static func parse(_ reply: xpc_object_t) -> RemoteAccessStatus {
        guard xpc_get_type(reply) == iGhostVTXPC.typeDictionary,
              xpc_dictionary_get_value(reply, iGhostVTWireKey.remoteState) != nil
        else { return RemoteAccessStatus(isUnavailable: true) }
        var status = RemoteAccessStatus()
        status.isEnabled = xpc_dictionary_get_bool(reply, iGhostVTWireKey.enabled)
        status.state = string(iGhostVTWireKey.remoteState, in: reply).flatMap(RemoteAccessState.init(rawValue:)) ?? .off
        status.failureMessage = string(iGhostVTWireKey.errorMessage, in: reply)
        status.hostID = string(iGhostVTWireKey.hostID, in: reply)
        status.hostName = string(iGhostVTWireKey.hostName, in: reply)
        status.connectedCount = Int(xpc_dictionary_get_uint64(reply, iGhostVTWireKey.connectedCount))
        status.pairingCode = string(iGhostVTWireKey.pairingCode, in: reply)
        if xpc_dictionary_get_value(reply, iGhostVTWireKey.pairingExpiresAt) != nil {
            status.pairingExpiresAt = Date(
                timeIntervalSince1970: TimeInterval(xpc_dictionary_get_int64(reply, iGhostVTWireKey.pairingExpiresAt)),
            )
        }
        status.devices = entries(iGhostVTWireKey.devices, in: reply).compactMap { entry in
            guard let id = string(iGhostVTWireKey.deviceID, in: entry) else { return nil }
            return RemoteAccessStatus.Device(
                id: id,
                name: string(iGhostVTWireKey.deviceName, in: entry) ?? id,
                pairedAt: date(iGhostVTWireKey.time, in: entry) ?? Date(),
                lastSeen: date(iGhostVTWireKey.lastSeen, in: entry),
            )
        }
        status.failedAttempts = entries(iGhostVTWireKey.pairingFailures, in: reply).compactMap { entry in
            guard let address = string(iGhostVTWireKey.address, in: entry),
                  let time = date(iGhostVTWireKey.time, in: entry)
            else { return nil }
            return RemoteAccessStatus.FailedAttempt(address: address, time: time)
        }
        return status
    }

    private static func string(_ key: String, in dictionary: xpc_object_t) -> String? {
        xpc_dictionary_get_string(dictionary, key).map { String(cString: $0) }
    }

    private static func date(_ key: String, in dictionary: xpc_object_t) -> Date? {
        guard xpc_dictionary_get_value(dictionary, key) != nil else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(xpc_dictionary_get_int64(dictionary, key)))
    }

    private static func entries(_ key: String, in dictionary: xpc_object_t) -> [xpc_object_t] {
        guard let array = xpc_dictionary_get_value(dictionary, key),
              xpc_get_type(array) == iGhostVTXPC.typeArray
        else { return [] }
        return (0 ..< xpc_array_get_count(array)).map { xpc_array_get_value(array, $0) }
            .filter { xpc_get_type($0) == iGhostVTXPC.typeDictionary }
    }
}

private struct Box: @unchecked Sendable {
    let message: xpc_object_t
    init(_ message: xpc_object_t) {
        self.message = message
    }
}

/// Resumes a continuation once, whichever of reply, loss or timeout comes
/// first.
private final class Finished: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<RemoteAccessStatus, Never>?

    init(_ continuation: CheckedContinuation<RemoteAccessStatus, Never>) {
        self.continuation = continuation
    }

    func resume(_ status: RemoteAccessStatus) {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: status)
    }
}
