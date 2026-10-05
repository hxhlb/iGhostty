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
    }

    static let protocolVersion = "1"

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
    /// How long a device connection that ended without letting go of its
    /// terminals keeps holding them — long enough for a phone that locked
    /// or lost Wi-Fi for a moment to reconnect and pick them up again
    /// without the host noticing, short enough that a device that left
    /// hands them back soon.
    static let reconnectGraceSeconds: TimeInterval = 30
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
