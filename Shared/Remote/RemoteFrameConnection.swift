import Foundation
import Network
import XPC

/// `IOWire` frames over an `NWConnection`: what the app and
/// `ighostvtd-remote` exchange once TLS is up.
///
/// Everything happens on `queue`, the connection's own. Frames are handed
/// out whole; a header that is not one of ours, or a payload that does not
/// decode, ends the connection. Output not yet taken by the network is
/// counted (`pendingByteCount`) so a caller can stop producing while a slow
/// link catches up.
final class RemoteFrameConnection: @unchecked Sendable {
    let connection: NWConnection
    let queue: DispatchQueue

    /// A decoded frame. `nil` objects never reach it.
    var onFrame: ((IOWire.Header, xpc_object_t) -> Void)?
    /// The connection is ready (TLS done), once.
    var onReady: (() -> Void)?
    /// The connection is over, once, whatever ended it.
    var onClosed: ((String) -> Void)?
    /// `pendingByteCount` changed.
    var onPendingChange: ((Int) -> Void)?

    private(set) var pendingByteCount = 0
    private var buffer: [UInt8] = []
    private var isClosed = false
    private var isReady = false
    /// `closeWhenFlushed` is waiting for the last sends to leave.
    private var isDraining = false
    /// Held while draining: the owner has usually let go by then, and the
    /// send completions only hold this weakly.
    private var retainedWhileDraining: RemoteFrameConnection?

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            self?.handle(state)
        }
        connection.start(queue: queue)
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            guard !isReady else { return }
            isReady = true
            onReady?()
            receive()
        case let .waiting(error):
            close(reason: "waiting: \(error)")
        case let .failed(error):
            close(reason: "failed: \(error)")
        case .cancelled:
            close(reason: "cancelled")
        default:
            break
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !isClosed else { return }
            if let data, !data.isEmpty {
                buffer.append(contentsOf: data)
                guard drainFrames() else { return }
            }
            if let error {
                close(reason: "receive: \(error)")
            } else if isComplete {
                close(reason: "closed by the other end")
            } else {
                receive()
            }
        }
    }

    /// Hands out every whole frame in the buffer. False when the link
    /// carried something that is not a frame, which closes it.
    private func drainFrames() -> Bool {
        var offset = 0
        defer {
            if offset > 0 {
                buffer.removeFirst(offset)
            }
        }
        while buffer.count - offset >= IOWire.headerByteCount {
            let header = buffer.withUnsafeBytes { bytes in
                IOWire.decodeHeader(UnsafeRawBufferPointer(rebasing: bytes[offset...]))
            }
            guard let header else {
                close(reason: "unreadable frame header")
                return false
            }
            let end = offset + IOWire.headerByteCount + header.payloadByteCount
            guard buffer.count >= end else { break }
            let object = buffer.withUnsafeBytes { bytes in
                IOCodec.decode(UnsafeRawBufferPointer(rebasing: bytes[(offset + IOWire.headerByteCount) ..< end]))
            }
            offset = end
            guard let object else {
                close(reason: "undecodable frame payload")
                return false
            }
            onFrame?(header, object)
            if isClosed {
                return false
            }
        }
        return true
    }

    /// False when the object could not be encoded or the link is gone.
    @discardableResult
    func send(_ kind: IOWire.Kind, tag: UInt64, object: xpc_object_t) -> Bool {
        guard !isClosed, !isDraining else { return false }
        var payload: [UInt8] = []
        guard IOCodec.encode(object, into: &payload), payload.count <= IOWire.maximumPayloadByteCount else {
            return false
        }
        var frame: [UInt8] = []
        frame.reserveCapacity(IOWire.headerByteCount + payload.count)
        IOWire.appendHeader(
            IOWire.Header(kind: kind, peer: 0, tag: tag, payloadByteCount: payload.count),
            to: &frame,
        )
        frame.append(contentsOf: payload)
        let count = frame.count
        pendingByteCount += count
        onPendingChange?(pendingByteCount)
        connection.send(content: Data(frame), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            pendingByteCount -= count
            onPendingChange?(pendingByteCount)
            if let error {
                close(reason: "send: \(error)")
            } else if isDraining, pendingByteCount == 0 {
                close(reason: "flushed")
            }
        })
        return true
    }

    /// Closes once everything sent so far has left — a cancel would drop
    /// it, and the last frame is often the one that matters (a close, a
    /// detach) — or after `timeout`, whichever is first. Nothing more may
    /// be sent meanwhile, and nothing more is delivered.
    func closeWhenFlushed(timeout: TimeInterval = 2) {
        guard !isClosed, !isDraining else { return }
        guard isReady, pendingByteCount > 0 else {
            close(reason: "closed")
            return
        }
        isDraining = true
        retainedWhileDraining = self
        onFrame = nil
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.close(reason: "flush timed out")
        }
    }

    func close(reason: String) {
        guard !isClosed else { return }
        isClosed = true
        retainedWhileDraining = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        let onClosed = onClosed
        self.onClosed = nil
        onFrame = nil
        onReady = nil
        onClosed?(reason)
    }
}
