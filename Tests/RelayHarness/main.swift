import CryptoKit
import Darwin
import Dispatch
import Foundation
import Network

// The relay end to end: a real `ighostvt-relay` (the Go server under
// `Relay/`), the helper's own `RelayLink` registering a stand-in host, and
// clients reaching that host through the relay with remote-access TLS and an
// SNI — the same parameters the app uses. Loopback and ephemeral ports only.
//
//   relay-harness <ighostvt-relay binary> [--stress]
//       spawns the relay itself, so it can also kill and restart it
//   RELAY_CONFIG=<file.vtrpsc> relay-harness --external [--stress]
//       an already running relay (a container, a link with netem on it);
//       RELAY_RESTART_COMMAND, when set, is how to restart it
//
// --stress adds the long runs: bulk throughput, parallel streams, churn,
// a reader that falls behind, clients that vanish mid-transfer, and a relay
// that dies under load.

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)

var failures = 0

func check(_ condition: Bool, _ description: String) {
    if condition {
        print("  ok   \(description)")
    } else {
        failures += 1
        print("  FAIL \(description)")
    }
}

func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return condition()
}

let arguments = Array(CommandLine.arguments.dropFirst())
let isStress = arguments.contains("--stress")
let isExternal = arguments.contains("--external")
/// A slow link (netem) stretches every deadline, and shrinks the stress
/// runs' volumes by `RELAY_STRESS_SCALE`.
let slowFactor = Double(ProcessInfo.processInfo.environment["RELAY_SLOW_FACTOR"] ?? "") ?? 1
let stressScale = Double(ProcessInfo.processInfo.environment["RELAY_STRESS_SCALE"] ?? "") ?? 1

func scaled(_ byteCount: Int) -> Int {
    max(64 * 1024, Int(Double(byteCount) * stressScale))
}

func mebibytes(_ byteCount: Int) -> String {
    String(format: "%.1f MiB", Double(byteCount) / 1_048_576)
}

// MARK: - The relay

final class RelayProcess {
    let binary: String
    let dataDirectory: String
    let port: UInt16
    private(set) var process: Process?

    init(binary: String) {
        self.binary = binary
        dataDirectory = NSTemporaryDirectory() + "relay-harness-\(getpid())"
        try? FileManager.default.removeItem(atPath: dataDirectory)
        try? FileManager.default.createDirectory(atPath: dataDirectory, withIntermediateDirectories: true)
        port = Self.freePort()
    }

    var environment: [String: String] {
        [
            "RELAY_DATA": dataDirectory,
            "RELAY_LISTEN": "127.0.0.1:\(port)",
            "RELAY_PUBLIC_HOST": "127.0.0.1",
            "RELAY_PUBLIC_PORT": "\(port)",
            "RELAY_NAME": "Harness Relay",
            // Every client here comes from 127.0.0.1; the limit has unit
            // tests of its own.
            "RELAY_RATE_PER_IP": "0",
            "PATH": "/usr/bin:/bin",
        ]
    }

    func start() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["serve"]
        process.environment = environment
        let log = FileHandle(forWritingAtPath: logPath) ?? {
            FileManager.default.createFile(atPath: logPath, contents: nil)
            return FileHandle(forWritingAtPath: logPath)!
        }()
        log.seekToEndOfFile()
        process.standardOutput = log
        process.standardError = log
        try! process.run()
        self.process = process
    }

    var logPath: String {
        dataDirectory + "/relay.log"
    }

    func kill() {
        guard let process else { return }
        Darwin.kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        self.process = nil
    }

    func stop() {
        guard let process else { return }
        process.terminate()
        process.waitUntilExit()
        self.process = nil
    }

    var configuration: Data? {
        FileManager.default.contents(atPath: dataDirectory + "/ighostvt.vtrpsc")
    }

    /// Resident memory in KiB.
    var residentKiB: Int? {
        guard let pid = process?.processIdentifier else { return nil }
        return Int(run("/bin/ps", ["-o", "rss=", "-p", "\(pid)"]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func status() -> String {
        run(binary, ["status"], environment: environment)
    }

    private func run(_ path: String, _ arguments: [String], environment: [String: String]? = nil) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private static func freePort() -> UInt16 {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = bind(socket, $0, length)
                _ = getsockname(socket, $0, &length)
            }
        }
        return UInt16(bigEndian: address.sin_port)
    }
}

var relayProcess: RelayProcess?
let configuration: RelayConfiguration
if isExternal {
    guard let path = ProcessInfo.processInfo.environment["RELAY_CONFIG"],
          let data = FileManager.default.contents(atPath: path),
          let parsed = try? RelayConfiguration(data: data)
    else {
        print("RELAY_CONFIG must name a readable .vtrpsc")
        exit(2)
    }
    configuration = parsed
    print("relay (external) at \(configuration.endpointDescription)")
} else {
    guard let binary = arguments.first(where: { !$0.hasPrefix("--") }) else {
        print("usage: relay-harness <ighostvt-relay> [--stress]")
        exit(2)
    }
    let relay = RelayProcess(binary: binary)
    relay.start()
    relayProcess = relay
    print("relay (spawned) on 127.0.0.1:\(relay.port)")
    check(waitUntil(10) { relay.configuration != nil }, "the relay writes its configuration")
    guard let data = relay.configuration, let parsed = try? RelayConfiguration(data: data) else {
        print("no usable configuration; relay log:")
        print((try? String(contentsOfFile: relay.logPath, encoding: .utf8)) ?? "")
        exit(1)
    }
    configuration = parsed
    check(configuration.host == "127.0.0.1" && configuration.port == relay.port, "with the endpoint it was given")
    check(
        !((try? String(contentsOfFile: relay.logPath, encoding: .utf8)) ?? "").contains(configuration.key.base64EncodedString()),
        "and never logs the private key",
    )
}

// The host's ping to the relay, short enough for a run to see it work.
RelayLink.pingInterval = 3
RelayLink.pongTimeout = 3 * slowFactor

/// Registered as far as the relay is concerned, not only as the link
/// believes: a link held open by a proxy can believe it long after the
/// relay forgot it.
func isListed(_ hostID: String) -> Bool {
    if case let .success(hosts) = listHosts() {
        return hosts.contains { $0.id == hostID }
    }
    return false
}

func restartRelay() -> Bool {
    if let relayProcess {
        relayProcess.kill()
        relayProcess.start()
        return true
    }
    if let command = ProcessInfo.processInfo.environment["RELAY_RESTART_COMMAND"] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
    return false
}

// MARK: - A host behind the relay

let deviceKey = Data(SHA256.hash(data: Data("relay-harness-device".utf8)))
let deviceID = "HARNESS-DEVICE"

/// What `RemoteService` is to `RelayLink`: a TLS-PSK listener on loopback
/// (the relay listener), here echoing every byte back.
final class FakeHost: RelayLinkHost {
    let queue = DispatchQueue(label: "relay-harness.host")
    let relayHostID: String
    var hostName = "Harness Host"
    private(set) var relayListenerPort: UInt16?
    private(set) var arrivals: [String?] = []
    private(set) var accepted = 0
    private(set) var open = 0
    private(set) var exporters: [Data] = []
    /// Microseconds to wait before each read: a reader that falls behind.
    var readDelay: UInt32 = 0
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private(set) var states: [ObjectIdentifier: String] = [:]

    var openStates: [String] {
        connections.keys.map { states[$0] ?? "?" }
    }

    init(hostID: String = UUID().uuidString) {
        relayHostID = hostID
        let listener = try! NWListener(using: {
            let parameters = RemoteTLS.parameters(keys: [RemoteTLS.Key(identity: Data(deviceID.utf8), secret: deviceKey)])
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            return parameters
        }())
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            if case .ready = state {
                self?.relayListenerPort = listener?.port?.rawValue
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
        _ = waitUntil { self.queue.sync { self.relayListenerPort != nil } }
    }

    func noteRelayArrival(from address: String?) {
        arrivals.append(address)
    }

    private func serve(_ connection: NWConnection) {
        accepted += 1
        open += 1
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            states[id] = "\(state)"
            switch state {
            case .ready:
                if let secret = RemoteTLS.exporterSecret(of: connection) {
                    exporters.append(secret)
                }
                echo(connection)
            case .failed, .cancelled:
                if connections.removeValue(forKey: id) != nil {
                    open -= 1
                }
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func echo(_ connection: NWConnection) {
        let delay = readDelay
        states[ObjectIdentifier(connection)] = "reading"
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            let next = { [weak self] in
                if isComplete || error != nil {
                    connection.cancel()
                    return
                }
                if delay > 0 {
                    self?.queue.asyncAfter(deadline: .now() + .microseconds(Int(delay))) { self?.echo(connection) }
                } else {
                    self?.echo(connection)
                }
            }
            if let data, !data.isEmpty {
                states[ObjectIdentifier(connection)] = "writing \(data.count)"
                connection.send(content: data, completion: .contentProcessed { _ in next() })
            } else {
                next()
            }
        }
    }

    func stop() {
        listener?.cancel()
        for connection in connections.values {
            connection.cancel()
        }
    }
}

func makeLink(_ host: FakeHost, key: Data) -> RelayLink {
    host.queue.sync {
        let link = try! RelayLink(service: host, configuration: configuration, hostKey: key)
        link.start()
        return link
    }
}

func state(of link: RelayLink, on host: FakeHost) -> RelayState {
    host.queue.sync { link.state }
}

// MARK: - Clients

final class Client {
    let connection: NWConnection
    let queue = DispatchQueue(label: "relay-harness.client")
    private(set) var isReady = false
    private(set) var failure: String?

    init(hostID: String, key: Data = deviceKey) {
        let parameters = RemoteTLS.parameters(
            keys: [RemoteTLS.Key(identity: Data(deviceID.utf8), secret: key)],
            serverName: hostID,
        )
        connection = NWConnection(to: configuration.endpoint, using: parameters)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.isReady = true
            case let .failed(error): self?.failure = "\(error)"
            case let .waiting(error): self?.failure = "\(error)"
            case .cancelled: self?.failure = self?.failure ?? "cancelled"
            default: break
            }
        }
        connection.start(queue: queue)
    }

    /// Ready, or nil once it failed or `timeout` passed.
    func waitReady(_ timeout: TimeInterval = 15) -> Bool {
        _ = waitUntil(timeout * slowFactor) { queue.sync { isReady || failure != nil } }
        return queue.sync { isReady }
    }

    /// Sends `byteCount` pseudo-random bytes as fast as the link takes them
    /// while reading the echo; true when every byte came back, in order.
    func roundTrip(_ byteCount: Int, timeout: TimeInterval = 120) -> (ok: Bool, seconds: Double) {
        let start = Date()
        var generator = SystemRandomNumberGenerator()
        let chunk = Data((0 ..< 64 * 1024).map { _ in UInt8.random(in: 0 ... 255, using: &generator) })
        var sentHash = SHA256()
        var receivedHash = SHA256()
        var sent = 0
        var received = 0
        var broken = false
        let done = DispatchSemaphore(value: 0)
        func send() {
            guard sent < byteCount, !broken else { return }
            let piece = chunk.prefix(min(chunk.count, byteCount - sent))
            sent += piece.count
            sentHash.update(data: piece)
            connection.send(content: piece, completion: .contentProcessed { error in
                if error != nil {
                    broken = true
                    done.signal()
                } else {
                    send()
                }
            })
        }
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                if let data {
                    received += data.count
                    receivedHash.update(data: data)
                }
                if received >= byteCount || isComplete || error != nil {
                    if received < byteCount {
                        broken = true
                    }
                    done.signal()
                } else {
                    receive()
                }
            }
        }
        queue.async {
            send()
            receive()
        }
        let finished = done.wait(timeout: .now() + timeout * slowFactor) == .success
        return queue.sync {
            let ok = finished && !broken && received == byteCount && Data(sentHash.finalize()) == Data(receivedHash.finalize())
            return (ok, Date().timeIntervalSince(start))
        }
    }

    var exporter: Data? {
        queue.sync { RemoteTLS.exporterSecret(of: connection) }
    }

    func close() {
        connection.cancel()
    }
}

func listHosts(_ configuration: RelayConfiguration = configuration) -> Result<[RelayHostEntry], RelayError> {
    let semaphore = DispatchSemaphore(value: 0)
    let box = ResultBox()
    RelayControl.listHosts(configuration: configuration, timeout: 6 * slowFactor) { result in
        box.result = result
        semaphore.signal()
    }
    semaphore.wait()
    return box.result!
}

final class ResultBox: @unchecked Sendable {
    var result: Result<[RelayHostEntry], RelayError>?
}

/// A control connection by hand, for what the client library would never
/// send.
func rawControl(version: UInt8) -> [[String: Any]] {
    let queue = DispatchQueue(label: "relay-harness.raw")
    let connection = NWConnection(to: configuration.endpoint, using: .tcp)
    var frames: [[String: Any]] = []
    var buffer = Data()
    var finished = false
    connection.stateUpdateHandler = { state in
        if case .ready = state {
            connection.send(content: Data(RelayControl.magic + [version]), completion: .idempotent)
        }
    }
    func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if let data {
                buffer.append(data)
                while buffer.count >= 4 {
                    let length = Int(buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) })
                    guard buffer.count >= 4 + length else { break }
                    if let object = try? JSONSerialization.jsonObject(with: buffer.subdata(in: 4 ..< 4 + length)) as? [String: Any] {
                        frames.append(object)
                    }
                    buffer.removeSubrange(0 ..< 4 + length)
                }
            }
            if isComplete || error != nil {
                finished = true
            } else {
                read()
            }
        }
    }
    connection.start(queue: queue)
    queue.async { read() }
    _ = waitUntil(6 * slowFactor) { queue.sync { finished } }
    connection.cancel()
    return queue.sync { frames }
}

final class ResultsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool]
    init(count: Int) {
        values = Array(repeating: false, count: count)
    }

    func set(_ index: Int, _ value: Bool) {
        lock.withLock { values[index] = value }
    }

    var all: Bool {
        lock.withLock { values.allSatisfy { $0 } }
    }

    var any: Bool {
        lock.withLock { values.contains(true) }
    }
}

/// The relay's resident memory, sampled every 100 ms.
final class MemorySampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Int?
    private var isRunning = false

    func start() {
        guard let relayProcess else { return }
        isRunning = true
        DispatchQueue.global().async { [self] in
            while lock.withLock({ isRunning }) {
                if let value = relayProcess.residentKiB {
                    lock.withLock { peak = max(peak ?? 0, value) }
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }

    func stop() {
        lock.withLock { isRunning = false }
    }

    var peakKiB: Int? {
        lock.withLock { peak }
    }
}

// MARK: - Behaviour

print("configuration")
check(configuration.fingerprint == (try? RelayConfiguration(data: configuration.encoded()))?.fingerprint, "a configuration survives being written back")
check((try? RelayConfiguration(data: Data("{}".utf8))) == nil, "a file that is not one is refused")
var otherVersion = (try! JSONSerialization.jsonObject(with: configuration.encoded()) as! [String: Any])
otherVersion["version"] = 2
check(
    (try? RelayConfiguration(data: JSONSerialization.data(withJSONObject: otherVersion))) == nil,
    "a file format this build does not know is refused",
)

print("registration")
let hostKey = P256.Signing.PrivateKey().rawRepresentation
let host = FakeHost()
if case let .success(hosts) = listHosts() {
    check(!hosts.contains { $0.id == host.relayHostID }, "a host is not listed before it registers")
} else {
    check(false, "the relay answers a signed list")
}
var link = makeLink(host, key: hostKey)
check(waitUntil(10 * slowFactor) { state(of: link, on: host) == .registered }, "the host registers")
if case let .success(hosts) = listHosts() {
    let entry = hosts.first { $0.id == host.relayHostID }
    check(entry?.name == "Harness Host", "and is listed under its name")
    check(entry?.appVersion == RemoteAccess.appVersion, "with the version it runs")
} else {
    check(false, "the relay lists the host")
}
var wrongKey = configuration
wrongKey.key = P256.Signing.PrivateKey().rawRepresentation
if case let .failure(error) = listHosts(wrongKey) {
    check(error == .refused("auth"), "a list signed with another key is refused (\(error))")
} else {
    check(false, "a list signed with another key is refused")
}
let refusal = rawControl(version: UInt8(RelayControl.protocolVersion + 1))
check(
    refusal.first?["version"] as? Int == RelayControl.protocolVersion && refusal.last?["reason"] as? String == "version",
    "another protocol version gets the relay's hello and a version refusal",
)

print("data path")
let client = Client(hostID: host.relayHostID)
check(client.waitReady(), "a client reaches the host through the relay by SNI")
check(client.exporter != nil && host.queue.sync { host.exporters.contains(client.exporter!) }, "end-to-end TLS: both ends read the same exporter secret")
check(client.roundTrip(1 << 20).ok, "a mebibyte goes there and back intact")
check(host.queue.sync { host.arrivals.last.flatMap { $0 }?.isEmpty == false }, "the host learns where the connection came from")
client.close()

let upperCased = Client(hostID: host.relayHostID.uppercased())
check(upperCased.waitReady(), "the host id matches whatever its case")
upperCased.close()

let wrongDevice = Client(hostID: host.relayHostID, key: Data(count: 32))
check(!wrongDevice.waitReady(), "a key the host does not hold fails the handshake through the relay too")
let nobody = Client(hostID: UUID().uuidString)
let nobodyStart = Date()
check(!nobody.waitReady(), "an unregistered host id goes nowhere")
check(Date().timeIntervalSince(nobodyStart) < 5 * slowFactor, "and says so at once, not after a timeout")

print("bursts")
let burst = (0 ..< 12).map { _ in Client(hostID: host.relayHostID) }
check(burst.map { $0.waitReady(20) }.allSatisfy { $0 }, "twelve clients at once all get through (call backs wait their turn)")
burst.forEach { $0.close() }

print("identity")
let impostorHost = FakeHost(hostID: host.relayHostID)
let impostor = makeLink(impostorHost, key: P256.Signing.PrivateKey().rawRepresentation)
check(waitUntil(10 * slowFactor) { state(of: impostor, on: impostorHost) == .conflict }, "another key cannot register a host id that is taken")
check(state(of: link, on: host) == .registered, "and the real host stays registered")
impostorHost.queue.sync { impostor.stop() }
impostorHost.stop()

let copyHost = FakeHost(hostID: host.relayHostID)
let copy = makeLink(copyHost, key: hostKey)
check(waitUntil(10 * slowFactor) { state(of: copy, on: copyHost) == .registered }, "the same key registering again takes over")
check(waitUntil(10 * slowFactor) { state(of: link, on: host) == .conflict }, "the one it replaced is told and stops retrying")
Thread.sleep(forTimeInterval: 3)
check(state(of: copy, on: copyHost) == .registered, "and the two do not trade places")
copyHost.queue.sync { copy.stop() }
copyHost.stop()
host.queue.sync { link.stop() }
link = makeLink(host, key: hostKey)
check(waitUntil(10 * slowFactor) { state(of: link, on: host) == .registered }, "a fresh link registers again")

print("relay restart")
if restartRelay() {
    // Through a published container port the Mac side of the control
    // connection belongs to a proxy that may outlive the relay; only a
    // spawned relay's death is seen at once.
    if !isExternal {
        check(waitUntil(5) { state(of: link, on: host) != .registered }, "the host notices the relay went away")
    }
    check(waitUntil(20 * slowFactor) { isListed(host.relayHostID) }, "and registers again once it is back")
    let after = Client(hostID: host.relayHostID)
    check(after.waitReady(), "clients get through again")
    check(after.roundTrip(256 * 1024).ok, "and their data does")
    after.close()
} else {
    print("  skip (no way to restart this relay)")
}

// MARK: - Stress

func relayMemory() -> String {
    relayProcess?.residentKiB.map { "\($0 / 1024) MiB" } ?? "n/a"
}

/// RELAY_STRESS_ONLY=dies,churn runs only those parts.
func wants(_ part: String) -> Bool {
    guard let only = ProcessInfo.processInfo.environment["RELAY_STRESS_ONLY"] else { return true }
    return only.split(separator: ",").contains(Substring(part))
}

if isStress {
  if wants("bulk") {
    print("stress: bulk")
    let bulk = Client(hostID: host.relayHostID)
    if bulk.waitReady() {
        let size = scaled(256 << 20)
        let (ok, seconds) = bulk.roundTrip(size, timeout: 1200)
        check(ok, "\(mebibytes(size)) there and back intact, " + String(format: "%.1f MiB/s each way", Double(size) / 1_048_576 / seconds))
    } else {
        check(false, "a bulk client connects")
    }
    bulk.close()
    print("    relay resident memory: \(relayMemory())")

  }
  if wants("parallel") {
    print("stress: parallel")
    let parallel = (0 ..< 8).map { _ in Client(hostID: host.relayHostID) }
    check(parallel.map { $0.waitReady(20) }.allSatisfy { $0 }, "eight streams connect")
    let group = DispatchGroup()
    let results = ResultsBox(count: parallel.count)
    let parallelStart = Date()
    for (index, client) in parallel.enumerated() {
        DispatchQueue.global().async(group: group) {
            results.set(index, client.roundTrip(scaled(32 << 20), timeout: 1200).ok)
        }
    }
    group.wait()
    let elapsed = Date().timeIntervalSince(parallelStart)
    check(results.all, "8 × \(mebibytes(scaled(32 << 20))) in parallel intact, " + String(format: "%.1f MiB/s in all", Double(8 * scaled(32 << 20)) / 1_048_576 / elapsed))
    parallel.forEach { $0.close() }
    print("    relay resident memory: \(relayMemory())")

  }
  if wants("churn") {
    print("stress: churn")
    let churnStart = Date()
    var churned = 0
    let churnCount = stressScale < 1 ? max(30, Int(300 * stressScale)) : 300
    for _ in 0 ..< churnCount {
        let client = Client(hostID: host.relayHostID)
        if client.waitReady(), client.roundTrip(4096, timeout: 10).ok {
            churned += 1
        }
        client.close()
    }
    check(churned == churnCount, "\(churnCount) connections opened, used and closed one after another (\(churned) ok, \(Int(Date().timeIntervalSince(churnStart))) s)")
    check(waitUntil(30) { host.queue.sync { host.open } == 0 }, "every one of them is gone from the host afterwards (\(host.queue.sync { host.open }) open)")
    if let relayProcess {
        check(waitUntil(30) { relayProcess.status().contains("splices    0 active") }, "and from the relay")
    }
    print("    relay resident memory: \(relayMemory())")

  }
  if wants("backlog") {
    print("stress: a reader that falls behind")
    host.queue.sync { host.readDelay = 20000 }
    let flood = Client(hostID: host.relayHostID)
    if flood.waitReady() {
        let sampler = MemorySampler()
        sampler.start()
        let (ok, seconds) = flood.roundTrip(scaled(16 << 20), timeout: 1200)
        sampler.stop()
        check(ok, "\(mebibytes(scaled(16 << 20))) pushed at a host reading 64 KiB per 20 ms arrives intact " + String(format: "(%.0f s)", seconds))
        if let peak = sampler.peakKiB {
            check(peak < 96 * 1024, "the relay's memory stays bounded while the writer outruns the reader (peak \(peak / 1024) MiB)")
        }
    } else {
        check(false, "a flooding client connects")
    }
    flood.close()
    host.queue.sync { host.readDelay = 0 }

  }
  if wants("vanish") {
    print("stress: clients that vanish")
    let vanishing = (0 ..< 20).map { _ in Client(hostID: host.relayHostID) }
    check(vanishing.map { $0.waitReady(20) }.allSatisfy { $0 }, "twenty clients connect")
    for client in vanishing {
        client.queue.async {
            client.connection.send(content: Data(count: 1 << 20), completion: .idempotent)
        }
    }
    Thread.sleep(forTimeInterval: 0.2)
    vanishing.forEach { $0.close() }
    check(waitUntil(30) { host.queue.sync { host.open } == 0 }, "dropped mid-transfer, they leave nothing behind on the host")
    let afterVanish = Client(hostID: host.relayHostID)
    check(afterVanish.waitReady() && afterVanish.roundTrip(1 << 20).ok, "and the next client is served")
    afterVanish.close()

  }
  if wants("dies") {
    print("stress: the relay dies under load")
    let doomed = (0 ..< 4).map { _ in Client(hostID: host.relayHostID) }
    _ = doomed.map { $0.waitReady() }
    let doomedResults = ResultsBox(count: doomed.count)
    let doomedGroup = DispatchGroup()
    for (index, client) in doomed.enumerated() {
        DispatchQueue.global().async(group: doomedGroup) {
            doomedResults.set(index, client.roundTrip(512 << 20, timeout: 60).ok)
        }
    }
    Thread.sleep(forTimeInterval: 1)
    if restartRelay() {
        let ended = doomedGroup.wait(timeout: .now() + 40) == .success
        check(ended, "transfers cut by the relay dying end instead of hanging")
        check(!doomedResults.any, "and report the loss")
        // A proxy in the way keeps a dead relay's legs open; the splice's
        // idle limit is what lets go then.
        let letGo = waitUntil(isExternal ? RelaySplice.idleLimit + 30 : 30) { host.queue.sync { host.open } == 0 }
        if !letGo {
            for second in 0 ..< 90 {
                let open = host.queue.sync { host.open }
                guard open > 0 else {
                    print("    the host let go after \(30 + second) s")
                    break
                }
                if second % 10 == 0 {
                    print("    still open on the host after \(30 + second) s: \(open) \(host.queue.sync { host.openStates })")
                }
                Thread.sleep(forTimeInterval: 1)
            }
        }
        check(letGo, "the host lets go of their connections")
        check(waitUntil(20 * slowFactor) { isListed(host.relayHostID) }, "the host is registered again")
        let revived = Client(hostID: host.relayHostID)
        check(revived.waitReady() && revived.roundTrip(4 << 20).ok, "and serves the next client")
        revived.close()
    } else {
        print("  skip (no way to restart this relay)")
    }
    doomed.forEach { $0.close() }
  }
}

host.queue.sync { link.stop() }
host.stop()
relayProcess?.stop()
if let relayProcess, failures == 0 {
    try? FileManager.default.removeItem(atPath: relayProcess.dataDirectory)
} else if let relayProcess {
    print("relay log: \(relayProcess.logPath)")
}
print(failures == 0 ? "relay harness passed" : "relay harness: \(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
