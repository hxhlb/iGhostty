import CryptoKit
import Foundation

/// The constants remote access is built on, shared by the app and
/// `ighostvtd-remote`.
///
/// One TCP port, TLS 1.2 with pre-shared keys (`RemoteTLS`), and the same
/// frames the proxy and `ighostvtd-io` exchange (`IOWire`, `peer` always 0)
/// carrying the same XPC dictionaries the app sends the local daemon. A
/// connection is one of two kinds, and its first frame says which:
///
/// - **A paired device.** The client handshakes with its own device key, so
///   only the host that holds that key completes TLS, and its first frame
///   is `hello` carrying `deviceID` and a proof (`RemoteDeviceProof`) — an
///   HMAC under that same key over this TLS session's exporter secret. The
///   server cannot learn from TLS which of its keys the client used; the
///   proof is how it knows, and it cannot be replayed on another session.
/// - **Pairing.** The client knows no key yet and handshakes with
///   `pairingKey`, which is public: TLS then only frames and hides the
///   exchange, and the security is SPAKE2+ inside it (`PairingExchange`).
///   Only `pairStart` and `pairFinish` are answered on such a connection.
enum RemoteAccess {
    /// IANA lists 46337–46997 as unassigned, and it is below the 49152+
    /// ephemeral range macOS and iOS hand out for outgoing connections.
    static let port: UInt16 = 46404
    /// The Bonjour service type. Listed in the app's `NSBonjourServices`.
    static let serviceType = "_ighostvt._tcp"

    /// The TXT record of the advertisement.
    enum TXTKey {
        static let hostID = "id"
        static let hostName = "name"
        static let version = "v"
        /// The host's address on the local network, for a list to show.
        static let address = "ip"
        /// The iGhostVT version the host runs (`appVersion`), so a list can
        /// say a device needs updating before anyone connects.
        static let appVersion = "av"
    }

    static let protocolVersion = "1"

    /// The iGhostVT version this side runs, `CFBundleShortVersionString`.
    /// Two devices connect, and pair, only when theirs are equal: the
    /// operations a device may send grow from one version to the next, and
    /// a mismatch is said plainly instead of surfacing as some later
    /// request failing. The build number is left out — every local build
    /// bumps it.
    ///
    /// The app reads its own bundle, and so does `ighostvtd-remote` on the
    /// Mac, where it sits in `Contents/MacOS`. On the device the helper is
    /// in `<bootstrap>/usr/libexec` and the app it was installed with in
    /// `<bootstrap>/Applications`, two levels up from it whatever the
    /// bootstrap's root is. A build with neither — the harness, a helper
    /// run from a build folder — is `unknownVersion`, and the check is
    /// skipped for it rather than refusing everyone.
    static let appVersion: String = {
        if let version = shortVersion(Bundle.main.infoDictionary) {
            return version
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments.first ?? "").resolvingSymlinksInPath()
        let plist = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Applications/iGhostVT.app/Info.plist")
        if let data = try? Data(contentsOf: plist),
           let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let version = shortVersion(object)
        {
            return version
        }
        return unknownVersion
    }()

    static let unknownVersion = "0"

    /// Whether two versions may talk: equal, or one side does not know its
    /// own.
    static func isCompatible(_ theirs: String?, with ours: String = appVersion) -> Bool {
        guard ours != unknownVersion else { return true }
        guard let theirs else { return false }
        return theirs == ours || theirs == unknownVersion
    }

    private static func shortVersion(_ info: [String: Any]?) -> String? {
        (info?["CFBundleShortVersionString"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The identity and key a pairing connection handshakes with. Public
    /// by design — see the type's notes.
    static let pairingIdentity = Data("ighostvt-pairing".utf8)
    static let pairingKey = Data(SHA256.hash(data: Data("wiki.qaq.ighostvt remote pairing v1".utf8)))

    /// Six digits, from the system's random source.
    static let pairingCodeLength = 6
    /// How long a pairing window stays open.
    static let pairingWindowSeconds: TimeInterval = 120
    /// Attempts per window. Each `pairStart` spends one, wrong code or not:
    /// a client that starts and walks away has still tested a guess against
    /// the host's confirmation. The window closes when they are gone.
    static let pairingAttemptLimit = 3

    /// A client that has not finished its first frame by then is dropped.
    static let handshakeTimeoutSeconds: TimeInterval = 10
    /// Connections not yet past their first frame, at once.
    static let maximumUnauthenticatedConnections = 4
    /// The largest frame a connection may send before it has proved a
    /// device key. `hello`, `pairStart` and `pairFinish` are a few hundred
    /// bytes; the pairing key is public, so anyone on the network gets this
    /// far, and a full-size frame of empty containers decodes to hundreds
    /// of thousands of XPC objects before anything looks at it.
    static let maximumUnauthenticatedPayloadByteCount = 16 * 1024
    /// How long a device connection that ended without letting go of its
    /// terminals keeps holding them — long enough for a phone that locked
    /// or lost Wi-Fi for a moment to reconnect and pick them up again
    /// without the host noticing, short enough that a device that left
    /// hands them back soon.
    static let reconnectGraceSeconds: TimeInterval = 30
    /// A link through a relay is pinged after this much quiet
    /// (`iGhostVTOperation.ping`), and given up by the app after
    /// `relayedReplyLimit` without a byte from the host.
    static let relayedPingInterval: TimeInterval = 15
    static let relayedReplyLimit: TimeInterval = 45
    /// The host drops a relayed device it has heard nothing from for this
    /// long — a phone that went to sleep is one, and reattaches when it
    /// wakes.
    static let relayedSilenceLimit: TimeInterval = 60
    static let maximumDeviceCount = 32
    static let maximumNameByteCount = 64

    /// The label of the TLS exporter secret a device proof is computed over.
    static let exporterLabel = "EXPORTER-ighostvt-device-proof"
    static let exporterByteCount = 32

    /// Where `ighostvtd-remote` keeps its identity and the paired devices,
    /// readable by nobody but the user it runs as.
    static var stateDirectory: String {
        #if os(macOS) || targetEnvironment(macCatalyst)
            let home = getenv("HOME").map { String(cString: $0) } ?? "/tmp"
            return home + "/Library/Application Support/iGhostVT/Remote"
        #else
            return "/var/mobile/Library/iGhostVT/Remote"
        #endif
    }

    /// A six-digit code, uniformly drawn.
    static func makePairingCode() -> String {
        var generator = SystemRandomNumberGenerator()
        let value = UInt32.random(in: 0 ..< 1_000_000, using: &generator)
        let digits = String(value)
        return String(repeating: "0", count: pairingCodeLength - digits.count) + digits
    }

    /// A name trimmed to something a row can show and a file can hold.
    static func sanitizedName(_ name: String) -> String {
        var trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { !$0.isNewline && $0 != "\0" }
        while trimmed.utf8.count > maximumNameByteCount {
            trimmed.removeLast()
        }
        return trimmed.isEmpty ? "Unnamed" : trimmed
    }
}

/// What a paired device sends in its first frame to say which device it is:
/// an HMAC, under its own key, over this TLS session's exporter secret and
/// its id. Only the holder of the key can make it, and only for this
/// session.
enum RemoteDeviceProof {
    static func make(key: Data, exporterSecret: Data, deviceID: String) -> Data {
        var message = exporterSecret
        message.append(Data(deviceID.utf8))
        let code = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key))
        return Data(code)
    }

    static func verify(_ proof: Data, key: Data, exporterSecret: Data, deviceID: String) -> Bool {
        var message = exporterSecret
        message.append(Data(deviceID.utf8))
        return HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: message, using: SymmetricKey(data: key))
    }
}
