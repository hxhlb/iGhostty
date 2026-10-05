import Foundation
import Network
import Security

/// The TLS every remote-access connection runs: the system's, through
/// Network.framework, with pre-shared keys.
///
/// TLS 1.2 `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256` (RFC 7905, 0xCCAC):
/// an ephemeral ECDH for forward secrecy, the key for mutual
/// authentication, an AEAD for the records. Network.framework negotiates no
/// external PSK under TLS 1.3 (the handshake fails), and the plain PSK
/// suites have no forward secrecy, so this one suite is offered and nothing
/// else. iOS 15.0's libboringssl carries it.
enum RemoteTLS {
    static let cipherSuite: UInt16 = 0xCCAC

    struct Key: Sendable {
        var identity: Data
        var secret: Data
    }

    /// A client offers exactly one key; a server accepts any of `keys`.
    static func parameters(keys: [Key]) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
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
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = false
        return parameters
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
