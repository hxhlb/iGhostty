import Darwin
import Dispatch
import Foundation
import Network
import XPC

/// One network connection. Its first frame decides what it is (see
/// `RemoteAccess`): a paired device proving which one it is, or a pairing.
/// A device then gets a daemon connection of its own, so the daemon sees
/// each device as a separate peer — an attach is exclusive per peer, and a
/// device's tabs must not share one with another device's.
///
/// Only the session operations reach the daemon. Shutdown and remote-access
/// management are refused here, and the proxy refuses them from this
/// process as well.
final class RemoteClient {
    let address: String
    private unowned let service: RemoteService
    private let frames: RemoteFrameConnection

    private enum Mode {
        case handshaking
        case pairing(deviceID: String, deviceName: String, exchange: PairingExchange)
        case session(deviceID: String)
    }

    private var mode = Mode.handshaking
    private var daemon: xpc_connection_t?
    private var isDaemonSuspended = false
    private var isClosed = false

    /// The device output toward which may be held in the daemon instead of
    /// here: past this much not yet taken by the network, the daemon
    /// connection is suspended, which the proxy feels as a slow peer.
    private static let pauseAboveByteCount = 1 << 20
    private static let resumeBelowByteCount = 256 * 1024

    /// The operations a paired device may send, all of them the app's own.
    private static let sessionOperations: Set<iGhostVTOperation> = [
        .hello, .listSessions, .openSession, .attachSession, .detachSession, .write, .resize,
        .closeSession, .goodbye, .snapshotSession, .injectInput, .listShells, .setSessionAttributes,
    ]

    var isAuthenticated: Bool {
        if case .handshaking = mode { return false }
        return true
    }

    var isPairing: Bool {
        if case .pairing = mode { return true }
        return false
    }

    var deviceID: String? {
        if case let .session(deviceID) = mode { return deviceID }
        return nil
    }

    init(connection: NWConnection, address: String, service: RemoteService) {
        self.address = address
        self.service = service
        frames = RemoteFrameConnection(connection: connection, queue: service.queue)
    }

    func start() {
        frames.onFrame = { [weak self] header, object in
            self?.handle(header, object)
        }
        frames.onClosed = { [weak self] reason in
            self?.closed(reason: reason)
        }
        frames.onPendingChange = { [weak self] pending in
            self?.updateDaemonPause(pending: pending)
        }
        frames.start()
        service.queue.asyncAfter(deadline: .now() + RemoteAccess.handshakeTimeoutSeconds) { [weak self] in
            guard let self, !isClosed else { return }
            if case .handshaking = mode {
                close(reason: "no first frame in \(Int(RemoteAccess.handshakeTimeoutSeconds)) s")
            }
        }
    }

    func close(reason: String) {
        frames.close(reason: reason)
    }

    private func closed(reason: String) {
        guard !isClosed else { return }
        isClosed = true
        if let daemon {
            if isDaemonSuspended {
                xpc_connection_resume(daemon)
            }
            xpc_connection_cancel(daemon)
            self.daemon = nil
        }
        if case let .session(deviceID) = mode {
            RemoteLog.log("device \(deviceID) at \(address) disconnected: \(reason)")
        }
        service.clientClosed(self)
    }

    // MARK: - Frames

    private func handle(_ header: IOWire.Header, _ object: xpc_object_t) {
        guard header.kind == .request, xpc_get_type(object) == iGhostVTXPC.typeDictionary else {
            return close(reason: "a frame that is not a request")
        }
        let operation = iGhostVTOperation(rawValue: xpc_dictionary_get_uint64(object, iGhostVTWireKey.operation))
        switch mode {
        case .handshaking:
            switch operation {
            case .hello: authenticate(object, tag: header.tag)
            case .pairStart: startPairing(object, tag: header.tag)
            default: close(reason: "first frame was neither hello nor pairStart")
            }
        case let .pairing(deviceID, deviceName, exchange):
            guard operation == .pairFinish,
                  let confirmation = RemoteService.data(iGhostVTWireKey.confirmation, in: object)
            else { return close(reason: "unexpected frame while pairing") }
            let paired = service.finishPairing(
                client: self,
                exchange: exchange,
                deviceID: deviceID,
                deviceName: deviceName,
                confirmation: confirmation,
            )
            mode = .handshaking
            if paired {
                reply(.success, tag: header.tag)
            } else {
                reply(.invalidRequest, tag: header.tag, message: PairingRefusal.mismatch.message)
            }
            close(reason: paired ? "paired" : "pairing failed")
        case .session:
            guard let operation, Self.sessionOperations.contains(operation) else {
                reply(.invalidRequest, tag: header.tag)
                return
            }
            forward(object, tag: header.tag)
        }
    }

    // MARK: - A paired device

    /// `hello` with `deviceID` and its proof. The proof is checked against
    /// this TLS session's exporter secret, so it names the device whose key
    /// the handshake used and cannot have been lifted from another session.
    private func authenticate(_ hello: xpc_object_t, tag: UInt64) {
        guard let deviceID = xpc_dictionary_get_string(hello, iGhostVTWireKey.deviceID).map({ String(cString: $0) }),
              let proof = RemoteService.data(iGhostVTWireKey.confirmation, in: hello),
              let device = service.device(id: deviceID),
              let exporter = RemoteTLS.exporterSecret(of: frames.connection),
              RemoteDeviceProof.verify(proof, key: device.key, exporterSecret: exporter, deviceID: deviceID)
        else {
            RemoteLog.log("refused \(address): no valid device proof")
            reply(.invalidRequest, tag: tag, message: "This device is not paired with the host. Pair it again.")
            close(reason: "authentication failed")
            return
        }
        guard let daemon = service.makeDaemonConnection() else {
            reply(.operationFailed, tag: tag, message: "The terminal helper on the host is not running.")
            close(reason: "no daemon")
            return
        }
        mode = .session(deviceID: deviceID)
        self.daemon = daemon
        service.noteSeen(deviceID: deviceID)
        RemoteLog.log("device \(device.name) (\(deviceID)) connected from \(address)")
        xpc_connection_set_event_handler(daemon) { [weak self] event in
            self?.daemonEvent(event)
        }
        xpc_connection_activate(daemon)
        // The daemon's own hello, without the device's keys in it.
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(message, iGhostVTWireKey.version, xpc_dictionary_get_uint64(hello, iGhostVTWireKey.version))
        xpc_dictionary_set_uint64(message, iGhostVTWireKey.operation, iGhostVTOperation.hello.rawValue)
        forward(message, tag: tag)
    }

    private func forward(_ message: xpc_object_t, tag: UInt64) {
        guard let daemon else { return }
        guard tag != 0 else {
            xpc_connection_send_message(daemon, message)
            return
        }
        xpc_connection_send_message_with_reply(daemon, message, service.queue) { [weak self] reply in
            guard let self, !isClosed else { return }
            if xpc_get_type(reply) != iGhostVTXPC.typeDictionary || !frames.send(.reply, tag: tag, object: reply) {
                self.reply(.operationFailed, tag: tag, message: "The terminal helper on the host did not answer.")
            }
        }
    }

    private func daemonEvent(_ event: xpc_object_t) {
        guard !isClosed else { return }
        if xpc_get_type(event) == iGhostVTXPC.typeError {
            // The daemon cut this peer or restarted; the device reconnects
            // and reattaches, as the app does locally.
            close(reason: "daemon connection ended")
            return
        }
        frames.send(.event, tag: 0, object: event)
    }

    private func updateDaemonPause(pending: Int) {
        guard let daemon else { return }
        if !isDaemonSuspended, pending > Self.pauseAboveByteCount {
            isDaemonSuspended = true
            xpc_connection_suspend(daemon)
        } else if isDaemonSuspended, pending < Self.resumeBelowByteCount {
            isDaemonSuspended = false
            xpc_connection_resume(daemon)
        }
    }

    // MARK: - Pairing

    private func startPairing(_ message: xpc_object_t, tag: UInt64) {
        guard let deviceID = xpc_dictionary_get_string(message, iGhostVTWireKey.deviceID).map({ String(cString: $0) }),
              Self.isValidDeviceID(deviceID),
              let rawName = xpc_dictionary_get_string(message, iGhostVTWireKey.deviceName).map({ String(cString: $0) }),
              let share = RemoteService.data(iGhostVTWireKey.share, in: message)
        else {
            reply(.invalidRequest, tag: tag)
            return close(reason: "malformed pairStart")
        }
        switch service.beginPairing(client: self, deviceID: deviceID, share: share) {
        case let .success((exchange, answer)):
            mode = .pairing(
                deviceID: deviceID,
                deviceName: RemoteAccess.sanitizedName(rawName),
                exchange: exchange,
            )
            xpc_dictionary_set_uint64(answer, iGhostVTWireKey.version, iGhostVTProtocol.version)
            xpc_dictionary_set_int64(answer, iGhostVTWireKey.code, iGhostVTReplyCode.success.rawValue)
            frames.send(.reply, tag: tag, object: answer)
            // A pairing that is never finished is over in half a minute.
            service.queue.asyncAfter(deadline: .now() + 30) { [weak self] in
                guard let self, isPairing else { return }
                close(reason: "pairing not finished in time")
            }
        case let .failure(refusal):
            reply(.invalidRequest, tag: tag, message: refusal.message)
            close(reason: "pairing refused")
        }
    }

    private static func isValidDeviceID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 64 && id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-"
        }
    }

    private func reply(_ code: iGhostVTReplyCode, tag: UInt64, message: String? = nil) {
        guard tag != 0 else { return }
        let reply = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(reply, iGhostVTWireKey.version, iGhostVTProtocol.version)
        xpc_dictionary_set_int64(reply, iGhostVTWireKey.code, code.rawValue)
        if let message {
            xpc_dictionary_set_string(reply, iGhostVTWireKey.errorMessage, message)
        }
        frames.send(.reply, tag: tag, object: reply)
    }
}
