import CryptoKit
import Foundation
import Network

/// The relay's control protocol (`Relay/PROTOCOL.md`), the part a host and
/// an app speak: `IGVR` and a version byte, then length-prefixed JSON
/// frames. The data a relay carries never goes through here — an app
/// reaches a host through it with plain remote-access TLS and an SNI.
enum RelayControl {
    static let magic = Array("IGVR".utf8)
    /// Equal on both ends or nothing: there is no negotiation.
    static let protocolVersion = 1
    static let maximumFrameByteCount = 64 * 1024

    enum Role: String {
        case host
        case accept
        case list
    }

    /// What a signature covers: the role, which relay, its challenge (empty
    /// for an accept, whose ticket is fresh on its own), and the role's one
    /// parameter — the host id, the ticket, or nothing.
    static func signedMessage(role: Role, relayID: String, nonce: String, parameter: String) -> Data {
        Data(["ighostvt-relay-v1", role.rawValue, relayID, nonce, parameter].joined(separator: "\n").utf8)
    }

    static func sign(_ message: Data, with key: P256.Signing.PrivateKey) -> String? {
        try? key.signature(for: message).derRepresentation.base64EncodedString()
    }

    /// Plain TCP, with the keepalive every remote-access link has: a relay
    /// leg that died is noticed in about 25 s.
    static func parameters() -> NWParameters {
        let parameters = NWParameters(tls: nil, tcp: RemoteTLS.tcpOptions())
        parameters.includePeerToPeer = false
        return parameters
    }
}

enum RelayError: Error, Equatable {
    /// The relay could not be reached, or the link died.
    case unreachable(String)
    /// The relay speaks another protocol version.
    case version(relay: Int)
    /// The relay said no: `auth`, `hostKey`, `full`, `ticket`, …
    case refused(String)
    /// Something that is not this protocol.
    case malformed(String)
}

/// A host the relay has registered.
struct RelayHostEntry: Equatable, Sendable {
    var id: String
    var name: String
    var appVersion: String
}

/// One control connection. Everything runs on `queue`; every callback is
/// delivered there, at most once per call, and nothing after `close`.
final class RelayControlConnection: @unchecked Sendable {
    let connection: NWConnection
    let queue: DispatchQueue
    private var isStarted = false
    private var isClosed = false
    private var onReady: (@Sendable (Result<Void, RelayError>) -> Void)?

    init(configuration: RelayConfiguration, queue: DispatchQueue) {
        connection = NWConnection(to: configuration.endpoint, using: RelayControl.parameters())
        self.queue = queue
    }

    /// Connects and writes the magic and version; `ready` once that is
    /// queued, or with why the relay could not be reached.
    func start(_ ready: @escaping @Sendable (Result<Void, RelayError>) -> Void) {
        guard !isStarted else { return }
        isStarted = true
        onReady = ready
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                var opening = RelayControl.magic
                opening.append(UInt8(RelayControl.protocolVersion))
                connection.send(content: Data(opening), completion: .idempotent)
                finishStart(.success(()))
            case let .waiting(error), let .failed(error):
                finishStart(.failure(.unreachable("\(error)")))
                close()
            case .cancelled:
                finishStart(.failure(.unreachable("cancelled")))
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func finishStart(_ result: Result<Void, RelayError>) {
        let ready = onReady
        onReady = nil
        ready?(result)
    }

    func send(_ object: [String: Any]) {
        guard !isClosed, let body = try? JSONSerialization.data(withJSONObject: object) else { return }
        var frame = Data(count: 4)
        frame.withUnsafeMutableBytes { $0.storeBytes(of: UInt32(body.count).bigEndian, as: UInt32.self) }
        frame.append(body)
        connection.send(content: frame, completion: .idempotent)
    }

    /// Exactly one frame: the four length bytes, then exactly that many —
    /// never a byte more, since what follows an accepted ticket is not a
    /// frame.
    func receiveFrame(_ completion: @escaping @Sendable (Result<[String: Any], RelayError>) -> Void) {
        receiveExactly(4) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .failure(error):
                completion(.failure(error))
            case let .success(header):
                let length = header.withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
                guard length > 0, length <= RelayControl.maximumFrameByteCount else {
                    return completion(.failure(.malformed("a \(length)-byte frame")))
                }
                receiveExactly(length) { result in
                    completion(result.flatMap { body in
                        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                            return .failure(.malformed("a frame that is not a JSON object"))
                        }
                        return .success(object)
                    })
                }
            }
        }
    }

    private func receiveExactly(_ count: Int, _ completion: @escaping @Sendable (Result<Data, RelayError>) -> Void) {
        guard !isClosed else { return }
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { [weak self] data, _, isComplete, error in
            guard let self, !isClosed else { return }
            if let data, data.count == count {
                completion(.success(data))
            } else if let error {
                completion(.failure(.unreachable("\(error)")))
            } else {
                completion(.failure(.unreachable(isComplete ? "closed by the relay" : "short read")))
            }
        }
    }

    /// The relay's hello: its version, which relay it is, and the nonce a
    /// signature covers. A relay of another version follows it with a
    /// refusal and closes; this says `.version` either way.
    func receiveHello(
        expecting relayID: String,
        _ completion: @escaping @Sendable (Result<String, RelayError>) -> Void,
    ) {
        receiveFrame { result in
            completion(result.flatMap { hello in
                guard hello["relay"] as? String == "ighostvt-relay", let version = hello["version"] as? Int else {
                    return .failure(.malformed("no relay hello"))
                }
                guard version == RelayControl.protocolVersion else {
                    return .failure(.version(relay: version))
                }
                guard hello["relayID"] as? String == relayID else {
                    return .failure(.refused("relayID"))
                }
                guard let nonce = hello["nonce"] as? String, Data(base64Encoded: nonce)?.count == 32 else {
                    return .failure(.malformed("no nonce"))
                }
                return .success(nonce)
            })
        }
    }

    /// `{"ok":true}`, or the reason given.
    func receiveAnswer(_ completion: @escaping @Sendable (Result<[String: Any], RelayError>) -> Void) {
        receiveFrame { result in
            completion(result.flatMap { answer in
                if answer["ok"] as? Bool == true {
                    return .success(answer)
                }
                if answer["reason"] as? String == "version" {
                    return .failure(.version(relay: answer["version"] as? Int ?? 0))
                }
                return .failure(.refused(answer["reason"] as? String ?? "refused"))
            })
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        finishStart(.failure(.unreachable("closed")))
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    /// Hands over the raw connection — an accepted ticket's stream. Nothing
    /// more is read, sent or closed through this object.
    func detach() -> NWConnection {
        isClosed = true
        connection.stateUpdateHandler = nil
        return connection
    }
}

extension RelayControl {
    /// The hosts registered at `configuration`'s relay: one connection,
    /// signed with the relay key, closed by the relay after it answers.
    /// Gives up after `timeout`.
    static func listHosts(
        configuration: RelayConfiguration,
        timeout: TimeInterval = 6,
        completion: @escaping @Sendable (Result<[RelayHostEntry], RelayError>) -> Void,
    ) {
        let request = ListRequest(configuration: configuration, completion: completion)
        request.start(timeout: timeout)
    }
}

/// One `list` exchange, finished once whichever way it ends. Everything
/// after `start` runs on its own queue.
private final class ListRequest: @unchecked Sendable {
    private let configuration: RelayConfiguration
    private let queue = DispatchQueue(label: "wiki.qaq.ighostvt.relay.list", qos: .userInitiated)
    private let control: RelayControlConnection
    private var completion: (@Sendable (Result<[RelayHostEntry], RelayError>) -> Void)?

    init(configuration: RelayConfiguration, completion: @escaping @Sendable (Result<[RelayHostEntry], RelayError>) -> Void) {
        self.configuration = configuration
        self.completion = completion
        control = RelayControlConnection(configuration: configuration, queue: queue)
    }

    func start(timeout: TimeInterval) {
        queue.async { [self] in
            control.start { [self] ready in
                if case let .failure(error) = ready {
                    return finish(.failure(error))
                }
                control.receiveHello(expecting: configuration.relayID) { [self] hello in
                    switch hello {
                    case let .failure(error):
                        finish(.failure(error))
                    case let .success(nonce):
                        request(nonce: nonce)
                    }
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) { [self] in
                finish(.failure(.unreachable("timed out")))
            }
        }
    }

    private func request(nonce: String) {
        let message = RelayControl.signedMessage(role: .list, relayID: configuration.relayID, nonce: nonce, parameter: "")
        guard let signature = RelayControl.sign(message, with: configuration.signingKey) else {
            return finish(.failure(.malformed("could not sign")))
        }
        control.send(["role": RelayControl.Role.list.rawValue, "sig": signature])
        control.receiveAnswer { [self] answer in
            finish(answer.map { answer in
                (answer["hosts"] as? [[String: Any]] ?? []).compactMap { row in
                    guard let id = row["id"] as? String else { return nil }
                    return RelayHostEntry(
                        id: id,
                        name: RemoteAccess.sanitizedName(row["name"] as? String ?? ""),
                        appVersion: row["appVersion"] as? String ?? "",
                    )
                }
            })
        }
    }

    private func finish(_ result: Result<[RelayHostEntry], RelayError>) {
        guard let completion else { return }
        self.completion = nil
        control.close()
        completion(result)
    }
}
