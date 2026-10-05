import Network

/// Who a remote-access connection comes from.
enum RemoteNetwork {
    static func addressDescription(_ endpoint: NWEndpoint) -> String {
        guard case let .hostPort(host, _) = endpoint else { return "\(endpoint)" }
        switch host {
        case let .ipv4(address): return "\(address)"
        case let .ipv6(address): return "\(address)"
        case let .name(name, _): return name
        @unknown default: return "\(host)"
        }
    }

    /// Until remote access goes beyond the local network, only a peer on it
    /// is served: private IPv4, link-local, loopback, and IPv6 unique-local.
    static func isLocal(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case let .ipv4(address):
            return isLocal(ipv4: [UInt8](address.rawValue))
        case let .ipv6(address):
            let bytes = [UInt8](address.rawValue)
            guard bytes.count == 16 else { return false }
            if bytes[0 ..< 10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
                return isLocal(ipv4: Array(bytes[12 ..< 16]))
            }
            if bytes[0 ..< 15].allSatisfy({ $0 == 0 }), bytes[15] == 1 {
                return true
            }
            return bytes[0] & 0xFE == 0xFC || (bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80)
        default:
            return false
        }
    }

    private static func isLocal(ipv4 bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        switch (bytes[0], bytes[1]) {
        case (10, _), (127, _), (192, 168), (169, 254): return true
        case (172, 16 ... 31): return true
        default: return false
        }
    }
}
