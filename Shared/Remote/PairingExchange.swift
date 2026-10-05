import CiGhostVTCoreCrypto
import CryptoKit
import Foundation

/// One side of a pairing: SPAKE2+ on P-256 from the system's corecrypto
/// (`CiGhostVTCoreCrypto`), the pre-RFC 9383 variant iOS 15 already has.
///
/// The client that typed the code is the prover, the host that showed it
/// the verifier. Each guess costs the guesser a round with the host: a
/// share commits to one code, and neither the shares nor the confirmations
/// let anyone test a second code offline. The exchange, in the order
/// corecrypto requires it:
///
///     client → host   share X            (pairStart)
///     host → client   share Y, confirm V
///     client          verifies V, gets the session key
///     client → host   confirm P          (pairFinish)
///     host            verifies P, gets the same session key
///
/// Both ends then derive the device key from the session key
/// (`deviceKey(sessionKey:hostID:deviceID:)`), which is all that outlives
/// the exchange.
final class PairingExchange {
    enum Role {
        case prover
        case verifier
    }

    enum Failure: Error {
        case setup(Int32)
        case badShare
        /// The other side's confirmation did not verify: a different code,
        /// or someone else's exchange.
        case mismatch
    }

    /// The additional data both sides bind into the transcript (≤ 20 bytes).
    private static let context = Array("ighostvt-pair-v1".utf8)
    /// HMAC-SHA256's digest, and half of it: corecrypto's session key.
    private static let confirmationByteCount = 32
    private static let sessionKeyByteCount = 16

    private let curve = ccspake_cp_256()
    private let mac = ccspake_mac_hkdf_hmac_sha256()
    private let context: UnsafeMutableRawPointer
    private let contextByteCount: Int

    init(role: Role, code: String) throws {
        contextByteCount = ccspake_sizeof_ctx(curve)
        context = UnsafeMutableRawPointer.allocate(byteCount: contextByteCount, alignment: 16)
        context.initializeMemory(as: UInt8.self, repeating: 0, count: contextByteCount)
        let wordByteCount = ccspake_sizeof_w(curve)
        let (w0, w1) = Self.scalars(code: code, wordByteCount: wordByteCount)
        guard let rng = ccrng(nil) else { throw Failure.setup(-1) }
        let status: Int32 = switch role {
        case .prover:
            w0.scalar.withUnsafeBytes { w0Bytes in
                w1.scalar.withUnsafeBytes { w1Bytes in
                    ccspake_prover_init(
                        OpaquePointer(context), curve, mac, rng,
                        Self.context.count, Self.context,
                        wordByteCount,
                        w0Bytes.bindMemory(to: UInt8.self).baseAddress,
                        w1Bytes.bindMemory(to: UInt8.self).baseAddress,
                    )
                }
            }
        case .verifier:
            w0.scalar.withUnsafeBytes { w0Bytes in
                w1.point.withUnsafeBytes { pointBytes in
                    ccspake_verifier_init(
                        OpaquePointer(context), curve, mac, rng,
                        Self.context.count, Self.context,
                        wordByteCount,
                        w0Bytes.bindMemory(to: UInt8.self).baseAddress,
                        pointBytes.count,
                        pointBytes.bindMemory(to: UInt8.self).baseAddress,
                    )
                }
            }
        }
        guard status == 0 else {
            Self.release(context, contextByteCount)
            throw Failure.setup(status)
        }
    }

    deinit {
        Self.release(context, contextByteCount)
    }

    private static func release(_ pointer: UnsafeMutableRawPointer, _ count: Int) {
        // The context holds the scalars; it does not outlive the exchange.
        memset_s(pointer, count, 0, count)
        pointer.deallocate()
    }

    /// This side's public share.
    func makeShare() throws -> Data {
        var share = [UInt8](repeating: 0, count: ccspake_sizeof_point(curve))
        let status = ccspake_kex_generate(OpaquePointer(context), share.count, &share)
        guard status == 0 else { throw Failure.setup(status) }
        return Data(share)
    }

    func receiveShare(_ share: Data) throws {
        guard share.count == ccspake_sizeof_point(curve) else { throw Failure.badShare }
        let status = share.withUnsafeBytes {
            ccspake_kex_process(OpaquePointer(context), $0.count, $0.bindMemory(to: UInt8.self).baseAddress)
        }
        guard status == 0 else { throw Failure.badShare }
    }

    func makeConfirmation() throws -> Data {
        var confirmation = [UInt8](repeating: 0, count: Self.confirmationByteCount)
        let status = ccspake_mac_compute(OpaquePointer(context), confirmation.count, &confirmation)
        guard status == 0 else { throw Failure.setup(status) }
        return Data(confirmation)
    }

    /// The session key, once the other side's confirmation verifies.
    func verifyConfirmation(_ confirmation: Data) throws -> SymmetricKey {
        guard confirmation.count == Self.confirmationByteCount else { throw Failure.mismatch }
        var sessionKey = [UInt8](repeating: 0, count: Self.sessionKeyByteCount)
        let status = confirmation.withUnsafeBytes {
            ccspake_mac_verify_and_get_session_key(
                OpaquePointer(context),
                $0.count,
                $0.bindMemory(to: UInt8.self).baseAddress,
                sessionKey.count,
                &sessionKey,
            )
        }
        guard status == 0 else { throw Failure.mismatch }
        return SymmetricKey(data: sessionKey)
    }

    /// The device key a pairing leaves behind: 32 bytes, bound to both ids.
    static func deviceKey(sessionKey: SymmetricKey, hostID: String, deviceID: String) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: sessionKey,
            salt: Data("ighostvt-device-key-v1".utf8),
            info: Data((hostID + "\n" + deviceID).utf8),
            outputByteCount: 32,
        )
        return key.withUnsafeBytes { Data($0) }
    }

    // MARK: - Scalars

    /// w0 and w1 from the code. corecrypto reads a `wordByteCount` (40)
    /// byte big-endian w and uses (w mod (n − 1)) + 1, so a scalar t that
    /// CryptoKit accepts (1 ≤ t < n) is handed over as t − 1, zero-padded,
    /// and the verifier's L is t₁·G computed by CryptoKit — which is
    /// exactly the point corecrypto derives from the same w1.
    private static func scalars(
        code: String,
        wordByteCount: Int,
    ) -> (w0: (scalar: Data, point: Data), w1: (scalar: Data, point: Data)) {
        func derive(_ label: String) -> (scalar: Data, point: Data) {
            for counter in 0 ..< 256 {
                let candidate = HKDF<SHA256>.deriveKey(
                    inputKeyMaterial: SymmetricKey(data: Data(code.utf8)),
                    salt: Data("ighostvt-pairing-v1".utf8),
                    info: Data("\(label)-\(counter)".utf8),
                    outputByteCount: 32,
                )
                let raw = candidate.withUnsafeBytes { Data($0) }
                guard let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: raw) else { continue }
                let padding = Data(count: max(0, wordByteCount - 32))
                return (padding + minusOne(raw), key.publicKey.x963Representation)
            }
            // 256 rejections in a row is a 2^-8000 event.
            fatalError("no P-256 scalar for the pairing code")
        }
        return (derive("w0"), derive("w1"))
    }

    /// Big-endian t − 1 for t ≥ 1.
    private static func minusOne(_ value: Data) -> Data {
        var bytes = [UInt8](value)
        var index = bytes.count - 1
        while index > 0, bytes[index] == 0 {
            bytes[index] = 0xFF
            index -= 1
        }
        bytes[index] &-= 1
        return Data(bytes)
    }
}
