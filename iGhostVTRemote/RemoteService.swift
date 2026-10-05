import Darwin
import Dispatch
import Foundation
import Network
import XPC

/// Everything the helper does, on one serial queue: the listener and its
/// Bonjour advertisement, the clients, the pairing window, the management
/// socket to the proxy, and the anchor connection that keeps the daemon
/// resident while this process runs.
final class RemoteService {
    let queue = DispatchQueue(
        label: "wiki.qaq.ighostvt.remote",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem,
    )
    private let management: IOChannel
    private(set) var store = RemoteStore.load()
    let hostName = RemoteHostName.current()

    private var listener: NWListener?
    private var listenerGeneration = 0
    private var state: RemoteAccessState = .starting
    private var failureMessage: String?
    private var clients: [ObjectIdentifier: RemoteClient] = [:]
    private var anchor: xpc_connection_t?

    /// An open pairing window: one code, a few attempts, and the failed
    /// ones, each with where it came from.
    private struct PairingWindow {
        var code: String
        var expiresAt: Date
        var attemptsUsed = 0
        var failures: [(address: String, time: Date)] = []
        /// The client mid-exchange; one at a time.
        var activeClient: ObjectIdentifier?
    }

    private var pairing: PairingWindow?

    init(managementDescriptor: Int32) {
        management = IOChannel(descriptor: managementDescriptor, queue: queue)
    }

    func start() {
        queue.async { [self] in
            management.onFrame = { [weak self] header, payload in
                self?.handleManagement(header, payload: payload)
            }
            management.onClosed = {
                // The proxy is gone; it spawns a new helper when it comes
                // back, and the clients reconnect to that one.
                exit(EXIT_SUCCESS)
            }
            management.activate()
            RemoteLog.sink = { [weak self] line in
                self?.queue.async {
                    self?.forwardLog(line)
                }
            }
            RemoteLog.log("starting as uid \(getuid()), host \(store.hostID), \(store.devices.count) paired device(s)")
            connectAnchor()
            startListener()
        }
    }

    // MARK: - The daemon

    /// One connection to the daemon held for as long as this process runs:
    /// with it the daemon never sees itself idle, which is what makes remote
    /// access keep it resident. A daemon restart drops it; it comes back.
    private func connectAnchor() {
        guard anchor == nil else { return }
        guard let connection = makeDaemonConnection() else {
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.connectAnchor() }
            return
        }
        anchor = connection
        xpc_connection_set_event_handler(connection) { [weak self] event in
            guard let self, xpc_get_type(event) == iGhostVTXPC.typeError else { return }
            anchor = nil
            xpc_connection_cancel(connection)
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.connectAnchor() }
        }
        xpc_connection_activate(connection)
        let hello = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(hello, iGhostVTWireKey.version, iGhostVTProtocol.version)
        xpc_dictionary_set_uint64(hello, iGhostVTWireKey.operation, iGhostVTOperation.hello.rawValue)
        xpc_connection_send_message_with_reply(connection, hello, queue) { _ in }
    }

    func makeDaemonConnection() -> xpc_connection_t? {
        iGhostVTProtocol.serviceName.withCString {
            ighostvtCreateMachServiceListener($0, queue, 0)
        }
    }

    // MARK: - Listener

    private func startListener() {
        listener?.cancel()
        listener = nil
        listenerGeneration += 1
        let generation = listenerGeneration
        var keys = [RemoteTLS.Key(identity: RemoteAccess.pairingIdentity, secret: RemoteAccess.pairingKey)]
        for device in store.devices {
            keys.append(RemoteTLS.Key(identity: Data(device.id.utf8), secret: device.key))
        }
        let parameters = RemoteTLS.parameters(keys: keys)
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            guard let port = NWEndpoint.Port(rawValue: RemoteAccess.port) else { return }
            listener = try NWListener(using: parameters, on: port)
        } catch {
            fail("could not create the listener: \(error)", message: Self.describe(error))
            return
        }
        listener.service = NWListener.Service(
            name: hostName,
            type: RemoteAccess.serviceType,
            domain: nil,
            txtRecord: Self.txtRecord([
                (RemoteAccess.TXTKey.hostID, store.hostID),
                (RemoteAccess.TXTKey.hostName, hostName),
                (RemoteAccess.TXTKey.version, RemoteAccess.protocolVersion),
            ]),
        )
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, generation == listenerGeneration else { return }
            switch state {
            case .ready:
                self.state = .listening
                failureMessage = nil
                RemoteLog.log("listening on port \(RemoteAccess.port) as \(hostName)")
            case let .failed(error), let .waiting(error):
                fail("listener: \(error)", message: Self.describe(error))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    /// The listener cannot run — the port is taken, most often. Reported
    /// through `remoteStatus`, and tried again every half minute in case
    /// whatever holds the port lets go.
    private func fail(_ logLine: String, message: String) {
        listener?.cancel()
        listener = nil
        state = .failed
        failureMessage = message
        RemoteLog.log(logLine)
        let generation = listenerGeneration
        queue.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, generation == listenerGeneration, state == .failed else { return }
            startListener()
        }
    }

    private static func describe(_ error: Error) -> String {
        if case let NWError.posix(code) = error, code == .EADDRINUSE {
            return "Port \(RemoteAccess.port) is in use by another program."
        }
        return "Remote access could not listen on port \(RemoteAccess.port) (\(error))."
    }

    private func accept(_ connection: NWConnection) {
        let address = RemoteNetwork.addressDescription(connection.endpoint)
        guard RemoteNetwork.isLocal(connection.endpoint) else {
            RemoteLog.log("refused \(address): not a local network address")
            connection.cancel()
            return
        }
        let unauthenticated = clients.values.filter { !$0.isAuthenticated }.count
        guard unauthenticated < RemoteAccess.maximumUnauthenticatedConnections else {
            RemoteLog.log("refused \(address): too many connections still handshaking")
            connection.cancel()
            return
        }
        let client = RemoteClient(connection: connection, address: address, service: self)
        clients[ObjectIdentifier(client)] = client
        client.start()
    }

    func clientClosed(_ client: RemoteClient) {
        clients.removeValue(forKey: ObjectIdentifier(client))
        if pairing?.activeClient == ObjectIdentifier(client) {
            // Started and never finished: a guess was spent all the same.
            recordPairingFailure(address: client.address, reason: "abandoned")
        }
    }

    // MARK: - Devices

    func device(id: String) -> RemoteStore.Device? {
        store.device(id: id)
    }

    func noteSeen(deviceID: String) {
        store.markSeen(deviceID: deviceID)
    }

    // MARK: - Pairing

    /// `pairStart` from `client`: spends an attempt and answers with the
    /// host's share and confirmation, or with why not.
    func beginPairing(
        client: RemoteClient,
        deviceID: String,
        share: Data,
    ) -> Result<(exchange: PairingExchange, reply: xpc_object_t), PairingRefusal> {
        expirePairingIfNeeded()
        guard var window = pairing else {
            return .failure(.notOpen)
        }
        guard window.activeClient == nil else {
            return .failure(.busy)
        }
        guard store.devices.count < RemoteAccess.maximumDeviceCount || store.device(id: deviceID) != nil else {
            return .failure(.full)
        }
        window.attemptsUsed += 1
        window.activeClient = ObjectIdentifier(client)
        pairing = window
        do {
            let exchange = try PairingExchange(role: .verifier, code: window.code)
            try exchange.receiveShare(share)
            let reply = xpc_dictionary_create(nil, nil, 0)
            Self.setData(try exchange.makeShare(), for: iGhostVTWireKey.share, in: reply)
            Self.setData(try exchange.makeConfirmation(), for: iGhostVTWireKey.confirmation, in: reply)
            xpc_dictionary_set_string(reply, iGhostVTWireKey.hostID, store.hostID)
            xpc_dictionary_set_string(reply, iGhostVTWireKey.hostName, hostName)
            RemoteLog.log("pairing attempt \(window.attemptsUsed) from \(client.address)")
            return .success((exchange, reply))
        } catch {
            recordPairingFailure(address: client.address, reason: "bad share")
            return .failure(.mismatch)
        }
    }

    /// `pairFinish` from `client`: the device is paired, or the attempt is
    /// recorded as failed.
    func finishPairing(
        client: RemoteClient,
        exchange: PairingExchange,
        deviceID: String,
        deviceName: String,
        confirmation: Data,
    ) -> Bool {
        guard pairing?.activeClient == ObjectIdentifier(client) else { return false }
        guard let sessionKey = try? exchange.verifyConfirmation(confirmation) else {
            recordPairingFailure(address: client.address, reason: "wrong code")
            return false
        }
        let key = PairingExchange.deviceKey(sessionKey: sessionKey, hostID: store.hostID, deviceID: deviceID)
        store.add(RemoteStore.Device(id: deviceID, name: deviceName, key: key, pairedAt: Date(), lastSeen: nil))
        pairing = nil
        RemoteLog.log("paired \(deviceName) (\(deviceID)) from \(client.address)")
        // The listener takes its keys when it is made; the new one has to be
        // among them before the device's first real connection.
        startListener()
        return true
    }

    private func recordPairingFailure(address: String, reason: String) {
        guard var window = pairing else { return }
        window.activeClient = nil
        window.failures.append((address, Date()))
        RemoteLog.log("pairing attempt from \(address) failed: \(reason)")
        if window.attemptsUsed >= RemoteAccess.pairingAttemptLimit {
            RemoteLog.log("pairing closed after \(window.attemptsUsed) attempts")
            pairing = nil
            for client in clients.values where client.isPairing {
                client.close(reason: "pairing closed")
            }
            return
        }
        pairing = window
    }

    private func expirePairingIfNeeded() {
        if let window = pairing, window.expiresAt <= Date() {
            pairing = nil
        }
    }

    // MARK: - Management

    private func handleManagement(_ header: IOWire.Header, payload: UnsafeRawBufferPointer) {
        guard header.kind == .request, let message = IOCodec.decode(payload) else { return }
        let operation = iGhostVTOperation(rawValue: xpc_dictionary_get_uint64(message, iGhostVTWireKey.operation))
        var code = iGhostVTReplyCode.success
        switch operation {
        case .remoteStatus:
            break
        case .beginPairing:
            pairing = PairingWindow(
                code: RemoteAccess.makePairingCode(),
                expiresAt: Date().addingTimeInterval(RemoteAccess.pairingWindowSeconds),
            )
            for client in clients.values where client.isPairing {
                client.close(reason: "a new pairing window opened")
            }
            RemoteLog.log("pairing window opened")
        case .endPairing:
            pairing = nil
            for client in clients.values where client.isPairing {
                client.close(reason: "pairing closed")
            }
        case .revokeRemoteDevice:
            let deviceID = xpc_dictionary_get_string(message, iGhostVTWireKey.deviceID).map { String(cString: $0) }
            if let deviceID, store.remove(deviceID: deviceID) {
                RemoteLog.log("revoked device \(deviceID)")
                for client in clients.values where client.deviceID == deviceID {
                    client.close(reason: "device revoked")
                }
                startListener()
            } else {
                code = .invalidRequest
            }
        default:
            code = .invalidRequest
        }
        guard header.tag != 0 else { return }
        let reply = statusReply()
        xpc_dictionary_set_int64(reply, iGhostVTWireKey.code, code.rawValue)
        _ = management.send(.reply, peer: header.peer, tag: header.tag, object: reply)
    }

    private func statusReply() -> xpc_object_t {
        expirePairingIfNeeded()
        let reply = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(reply, iGhostVTWireKey.version, iGhostVTProtocol.version)
        xpc_dictionary_set_bool(reply, iGhostVTWireKey.enabled, true)
        xpc_dictionary_set_string(reply, iGhostVTWireKey.remoteState, state.rawValue)
        if let failureMessage {
            xpc_dictionary_set_string(reply, iGhostVTWireKey.errorMessage, failureMessage)
        }
        xpc_dictionary_set_string(reply, iGhostVTWireKey.hostID, store.hostID)
        xpc_dictionary_set_string(reply, iGhostVTWireKey.hostName, hostName)
        xpc_dictionary_set_uint64(reply, iGhostVTWireKey.port, UInt64(RemoteAccess.port))
        let devices = xpc_array_create(nil, 0)
        for device in store.devices {
            let entry = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_string(entry, iGhostVTWireKey.deviceID, device.id)
            xpc_dictionary_set_string(entry, iGhostVTWireKey.deviceName, device.name)
            xpc_dictionary_set_int64(entry, iGhostVTWireKey.time, Int64(device.pairedAt.timeIntervalSince1970))
            if let lastSeen = device.lastSeen {
                xpc_dictionary_set_int64(entry, iGhostVTWireKey.lastSeen, Int64(lastSeen.timeIntervalSince1970))
            }
            xpc_array_append_value(devices, entry)
        }
        xpc_dictionary_set_value(reply, iGhostVTWireKey.devices, devices)
        if let pairing {
            xpc_dictionary_set_string(reply, iGhostVTWireKey.pairingCode, pairing.code)
            xpc_dictionary_set_int64(
                reply,
                iGhostVTWireKey.pairingExpiresAt,
                Int64(pairing.expiresAt.timeIntervalSince1970),
            )
            let failures = xpc_array_create(nil, 0)
            for failure in pairing.failures {
                let entry = xpc_dictionary_create(nil, nil, 0)
                xpc_dictionary_set_string(entry, iGhostVTWireKey.address, failure.address)
                xpc_dictionary_set_int64(entry, iGhostVTWireKey.time, Int64(failure.time.timeIntervalSince1970))
                xpc_array_append_value(failures, entry)
            }
            xpc_dictionary_set_value(reply, iGhostVTWireKey.pairingFailures, failures)
        }
        return reply
    }

    private func forwardLog(_ line: String) {
        let event = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(event, iGhostVTWireKey.errorMessage, line)
        _ = management.send(.event, peer: 0, tag: 0, object: event)
    }

    // MARK: - Helpers

    /// RFC 6763's TXT encoding — one length byte, then `key=value` — by
    /// hand, since `NWTXTRecord.data` is iOS 16.
    private static func txtRecord(_ entries: [(String, String)]) -> Data {
        var data = Data()
        for (key, value) in entries {
            var entry = Array("\(key)=\(value)".utf8)
            if entry.count > 255 {
                entry.removeLast(entry.count - 255)
            }
            data.append(UInt8(entry.count))
            data.append(contentsOf: entry)
        }
        return data
    }

    static func setData(_ data: Data, for key: String, in dictionary: xpc_object_t) {
        data.withUnsafeBytes { buffer in
            xpc_dictionary_set_data(dictionary, key, buffer.baseAddress ?? UnsafeRawPointer(bitPattern: 1)!, buffer.count)
        }
    }

    static func data(_ key: String, in dictionary: xpc_object_t) -> Data? {
        var count = 0
        guard let bytes = xpc_dictionary_get_data(dictionary, key, &count) else { return nil }
        return Data(bytes: bytes, count: count)
    }
}

enum PairingRefusal: Error {
    case notOpen
    case busy
    case full
    case mismatch

    var message: String {
        switch self {
        case .notOpen: "Pairing is not open on this device. Choose Pair a Device on it first."
        case .busy: "Another device is pairing with this one. Try again in a moment."
        case .full: "This device has as many paired devices as it can hold. Remove one first."
        case .mismatch: "The code is incorrect."
        }
    }
}
