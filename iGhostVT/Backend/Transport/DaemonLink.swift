import Dispatch
import Foundation
import Network
@preconcurrency import XPC

@_silgen_name("xpc_connection_create_mach_service")
private func ighostvtCreateMachServiceConnection(
    _ name: UnsafePointer<CChar>,
    _ queue: DispatchQueue?,
    _ flags: UInt64,
) -> xpc_connection_t?

/// What carries the daemon protocol for a transport: the local daemon's
/// XPC connection, or a TLS link to another device's `ighostvtd-remote`.
/// Both carry the same dictionaries, so `XPCDaemonTransport` — opening,
/// attaching, replay, input, resizing — is the same for a remote tab.
///
/// Everything is delivered on the queue the link was made with: replies,
/// events, and the one `lost`. A link that dies answers every reply still
/// outstanding with an empty dictionary, which reads as `operationFailed`.
protocol DaemonLink: AnyObject, Sendable {
    func activate(_ handler: @escaping @Sendable (DaemonLinkEvent) -> Void)
    func send(_ message: xpc_object_t)
    func send(_ message: xpc_object_t, reply: @escaping @Sendable (xpc_object_t) -> Void)
    func cancel()
}

enum DaemonLinkEvent: @unchecked Sendable {
    case message(xpc_object_t)
    /// The link died out from under its owner. Not delivered for `cancel`.
    case lost
}

/// Where a transport's daemon is.
enum DaemonEndpoint: Sendable, Equatable {
    case local
    case remote(hostID: String)

    var isRemote: Bool {
        if case .remote = self { return true }
        return false
    }

    /// A fresh link to the endpoint, `nil` when there is no way to reach it
    /// at all (no daemon service, a host that is not paired).
    func makeLink(queue: DispatchQueue) -> DaemonLink? {
        switch self {
        case .local:
            XPCDaemonLink(queue: queue)
        case let .remote(hostID):
            RemoteDaemonLink(hostID: hostID, queue: queue)
        }
    }
}

// MARK: - Local

final class XPCDaemonLink: DaemonLink, @unchecked Sendable {
    private let connection: xpc_connection_t
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var isCancelled = false

    init?(queue: DispatchQueue) {
        guard let connection = iGhostVTProtocol.serviceName.withCString({
            ighostvtCreateMachServiceConnection($0, queue, 0)
        }) else { return nil }
        self.connection = connection
        self.queue = queue
    }

    func activate(_ handler: @escaping @Sendable (DaemonLinkEvent) -> Void) {
        xpc_connection_set_event_handler(connection) { [weak self] event in
            autoreleasepool {
                if xpc_get_type(event) == iGhostVTXPC.typeError {
                    guard let self, !self.lock.withLock({ self.isCancelled }) else { return }
                    handler(.lost)
                } else {
                    handler(.message(event))
                }
            }
        }
        xpc_connection_activate(connection)
    }

    func send(_ message: xpc_object_t) {
        xpc_connection_send_message(connection, message)
    }

    func send(_ message: xpc_object_t, reply: @escaping @Sendable (xpc_object_t) -> Void) {
        xpc_connection_send_message_with_reply(connection, message, queue, reply)
    }

    func cancel() {
        lock.withLock { isCancelled = true }
        xpc_connection_cancel(connection)
    }
}

// MARK: - Remote

/// The daemon of a paired device, through its `ighostvtd-remote`.
///
/// TLS with this device's key for that host — so only the host that holds
/// the key completes the handshake — and the first `hello` gains the
/// device's id and its proof over the session's exporter secret, which is
/// how the host knows which device this is (`RemoteAccess`). Everything
/// else is the local protocol, framed (`RemoteFrameConnection`).
final class RemoteDaemonLink: DaemonLink, @unchecked Sendable {
    private let hostID: String
    private let host: PairedRemoteHost
    private let queue: DispatchQueue
    private var frames: RemoteFrameConnection?
    private var handler: (@Sendable (DaemonLinkEvent) -> Void)?
    private var pendingReplies: [UInt64: @Sendable (xpc_object_t) -> Void] = [:]
    private var nextTag: UInt64 = 1
    /// Sent before TLS was up; they leave, in order, once it is.
    private var queuedBeforeReady: [(tag: UInt64, message: xpc_object_t)] = []
    private var isReady = false
    private var isFinished = false

    init?(hostID: String, queue: DispatchQueue) {
        guard let host = PairedRemoteHostStore.host(id: hostID) else { return nil }
        self.hostID = hostID
        self.host = host
        self.queue = queue
    }

    func activate(_ handler: @escaping @Sendable (DaemonLinkEvent) -> Void) {
        queue.async { [self] in
            self.handler = handler
            let endpoint = RemoteHostDirectory.endpoint(forHostID: hostID) ?? host.lastEndpoint
            guard let endpoint else {
                AppLog.warning(.transport, "remote host \(hostID) has no known address")
                finish(lost: true)
                return
            }
            let parameters = RemoteTLS.parameters(keys: [
                RemoteTLS.Key(identity: Data(host.deviceID.utf8), secret: host.deviceKey),
            ])
            let frames = RemoteFrameConnection(connection: NWConnection(to: endpoint, using: parameters), queue: queue)
            frames.onReady = { [weak self] in self?.ready() }
            frames.onFrame = { [weak self] header, object in self?.received(header, object) }
            frames.onClosed = { [weak self] reason in
                AppLog.info(.transport, "remote link to \(self?.host.name ?? "?") closed: \(reason)")
                self?.finish(lost: true)
            }
            self.frames = frames
            frames.start()
        }
    }

    func send(_ message: xpc_object_t) {
        queue.async { [self] in
            enqueue(message, tag: 0)
        }
    }

    func send(_ message: xpc_object_t, reply: @escaping @Sendable (xpc_object_t) -> Void) {
        queue.async { [self] in
            guard !isFinished else {
                reply(xpc_dictionary_create(nil, nil, 0))
                return
            }
            let tag = nextTag
            nextTag &+= 1
            pendingReplies[tag] = reply
            enqueue(message, tag: tag)
        }
    }

    func cancel() {
        queue.async { [self] in
            finish(lost: false)
        }
    }

    private func enqueue(_ message: xpc_object_t, tag: UInt64) {
        guard !isFinished else { return }
        guard isReady, let frames else {
            queuedBeforeReady.append((tag, message))
            return
        }
        transmit(message, tag: tag, over: frames)
    }

    private func ready() {
        guard let frames else { return }
        isReady = true
        PairedRemoteHostStore.noteReached(frames.connection, forHostID: hostID)
        let queued = queuedBeforeReady
        queuedBeforeReady.removeAll()
        for item in queued {
            transmit(item.message, tag: item.tag, over: frames)
        }
    }

    private func transmit(_ message: xpc_object_t, tag: UInt64, over frames: RemoteFrameConnection) {
        if xpc_dictionary_get_uint64(message, iGhostVTWireKey.operation) == iGhostVTOperation.hello.rawValue {
            guard let exporter = RemoteTLS.exporterSecret(of: frames.connection) else {
                frames.close(reason: "no exporter secret")
                return
            }
            let proof = RemoteDeviceProof.make(key: host.deviceKey, exporterSecret: exporter, deviceID: host.deviceID)
            xpc_dictionary_set_string(message, iGhostVTWireKey.deviceID, host.deviceID)
            // The name it goes by now, so the host's list follows a rename.
            xpc_dictionary_set_string(message, iGhostVTWireKey.deviceName, RemoteDeviceIdentity.deviceName)
            proof.withUnsafeBytes { buffer in
                if let base = buffer.baseAddress {
                    xpc_dictionary_set_data(message, iGhostVTWireKey.confirmation, base, buffer.count)
                }
            }
        }
        if !frames.send(.request, tag: tag, object: message), tag != 0 {
            pendingReplies.removeValue(forKey: tag)?(xpc_dictionary_create(nil, nil, 0))
        }
    }

    private func received(_ header: IOWire.Header, _ object: xpc_object_t) {
        switch header.kind {
        case .reply:
            pendingReplies.removeValue(forKey: header.tag)?(object)
        case .event:
            handler?(.message(object))
        case .request, .peerGone:
            break
        }
    }

    private func finish(lost: Bool) {
        guard !isFinished else { return }
        isFinished = true
        // A cancel lets the last frames leave first: the owner's close or
        // detach was sent just before it.
        if lost {
            frames?.close(reason: "lost")
        } else {
            frames?.onClosed = nil
            frames?.closeWhenFlushed()
        }
        frames = nil
        queuedBeforeReady.removeAll()
        let unanswered = pendingReplies
        pendingReplies.removeAll()
        for reply in unanswered.values {
            reply(xpc_dictionary_create(nil, nil, 0))
        }
        let handler = handler
        self.handler = nil
        if lost {
            handler?(.lost)
        }
    }
}
