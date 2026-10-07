import Foundation
import Network
import Security

/// The TLS every remote-access connection runs: the system's, through
/// Network.framework, with pre-shared keys.
///
/// TLS 1.2 `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256` (RFC 7905, 0xCCAC):
/// an ephemeral ECDH for forward secrecy, the key for mutual
/// authentication, an AEAD for the records. Network.framework negotiates no
/// external PSK under TLS 1.3 (the handshake fails). The suite is appended
/// to the system's PSK defaults rather than replacing them — a ClientHello
/// also lists the plain PSK suites (0x00A8, 0x00A9, 0x00AE, 0x00AF), which
/// have no forward secrecy — but both ends put this one first and the
/// server picks it; steering a handshake to another would take the key.
/// iOS 15.0's libboringssl carries it.
enum RemoteTLS {
    static let cipherSuite: UInt16 = 0xCCAC

    struct Key: Sendable {
        var identity: Data
        var secret: Data
    }

    /// A client offers exactly one key; a server accepts any of `keys`.
    ///
    /// `serverName` is the SNI a client sends: the host id, which is how a
    /// relay (`Relay/PROTOCOL.md`) knows which host a connection is for
    /// without seeing anything inside it. A listener ignores it, so a
    /// direct connection sends it too and both paths are the same TLS.
    static func parameters(keys: [Key], serverName: String? = nil) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        if let serverName {
            sec_protocol_options_set_tls_server_name(options, serverName.lowercased())
        }
        for key in keys {
            let secret = key.secret.withUnsafeBytes { DispatchData(bytes: $0) }
            let identity = key.identity.withUnsafeBytes { DispatchData(bytes: $0) }
            sec_protocol_options_add_pre_shared_key(options, secret as __DispatchData, identity as __DispatchData)
        }
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        if let suite = tls_ciphersuite_t(rawValue: cipherSuite) {
            sec_protocol_options_append_tls_ciphersuite(options, suite)
        }
        let parameters = NWParameters(tls: tls, tcp: tcpOptions())
        parameters.includePeerToPeer = false
        return parameters
    }

    /// The TCP every remote-access connection runs, relay legs included.
    static func tcpOptions() -> NWProtocolTCP.Options {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        // A link that died without a word (Wi-Fi gone, a device asleep) is
        // noticed in about 25 s whether it was idle — keepalive probes —
        // or had data in flight, which turns keepalive off and leaves it to
        // the drop time. The system's defaults take minutes either way.
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        tcp.connectionDropTime = 15
        tcp.connectionTimeout = 10
        return tcp
    }

    /// This TLS session's exporter secret, the same on both ends. Read once
    /// the connection is ready; `nil` before that.
    static func exporterSecret(of connection: NWConnection) -> Data? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata
        else { return nil }
        let label = Array(RemoteAccess.exporterLabel.utf8)
        let secret = label.withUnsafeBufferPointer { buffer -> DispatchData? in
            guard let base = buffer.baseAddress else { return nil }
            return base.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                sec_protocol_metadata_create_secret(
                    metadata.securityProtocolMetadata,
                    buffer.count,
                    $0,
                    RemoteAccess.exporterByteCount,
                ) as DispatchData?
            }
        }
        return secret.map { Data($0) }
    }
}
