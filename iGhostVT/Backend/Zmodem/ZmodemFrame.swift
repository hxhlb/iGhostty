//
//  ZmodemFrame.swift
//  iGhostVT
//

import Foundation

enum Zmodem {
    static let ZPAD: UInt8 = 0x2A
    static let ZDLE: UInt8 = 0x18
    static let ZBIN: UInt8 = 0x41
    static let ZHEX: UInt8 = 0x42
    static let ZBIN32: UInt8 = 0x43
    static let XON: UInt8 = 0x11

    static let ZCRCE: UInt8 = 0x68
    static let ZCRCG: UInt8 = 0x69
    static let ZCRCQ: UInt8 = 0x6A
    static let ZCRCW: UInt8 = 0x6B
    static let ZRUB0: UInt8 = 0x6C
    static let ZRUB1: UInt8 = 0x6D

    static let CANFDX: UInt8 = 0x01
    static let CANOVIO: UInt8 = 0x02
    static let CANFC32: UInt8 = 0x20
}

enum ZFrameType: UInt8 {
    case rqinit = 0
    case rinit = 1
    case sinit = 2
    case ack = 3
    case file = 4
    case skip = 5
    case nak = 6
    case abort = 7
    case fin = 8
    case rpos = 9
    case data = 10
    case eof = 11
    case ferr = 12
    case crc = 13
    case challenge = 14
    case compl = 15
    case can = 16
    case freecnt = 17
    case command = 18
    case stderr = 19
}

enum ZSubpacketEnd: UInt8 {
    case end = 0x68
    case go = 0x69
    case query = 0x6A
    case wait = 0x6B

    var continues: Bool { self == .go || self == .query }
    var wantsAck: Bool { self == .query || self == .wait }
}

struct ZHeader {
    var type: ZFrameType
    var p0: UInt8
    var p1: UInt8
    var p2: UInt8
    var p3: UInt8

    var position: UInt32 {
        UInt32(p0) | (UInt32(p1) << 8) | (UInt32(p2) << 16) | (UInt32(p3) << 24)
    }

    static func position(_ offset: UInt32) -> (UInt8, UInt8, UInt8, UInt8) {
        (
            UInt8(offset & 0xFF),
            UInt8((offset >> 8) & 0xFF),
            UInt8((offset >> 16) & 0xFF),
            UInt8((offset >> 24) & 0xFF),
        )
    }
}

struct ZmodemEncoder {
    private var out: [UInt8] = []

    private mutating func raw(_ byte: UInt8) {
        out.append(byte)
    }

    // Escape every control byte, not just the required set: a raw one gets
    // mangled by the PTY's line discipline and corrupts a binary block.
    private mutating func escaped(_ byte: UInt8) {
        if (byte & 0x60) == 0 {
            raw(Zmodem.ZDLE)
            raw(byte ^ 0x40)
        } else {
            raw(byte)
        }
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    private mutating func hex(_ byte: UInt8) {
        raw(Self.hexDigits[Int(byte >> 4)])
        raw(Self.hexDigits[Int(byte & 0x0F)])
    }

    static func hexHeader(_ type: ZFrameType, _ p0: UInt8 = 0, _ p1: UInt8 = 0, _ p2: UInt8 = 0, _ p3: UInt8 = 0) -> [UInt8] {
        var enc = ZmodemEncoder()
        enc.raw(Zmodem.ZPAD)
        enc.raw(Zmodem.ZPAD)
        enc.raw(Zmodem.ZDLE)
        enc.raw(Zmodem.ZHEX)
        let body: [UInt8] = [type.rawValue, p0, p1, p2, p3]
        let crc = ZmodemCRC.crc16(body)
        for byte in body { enc.hex(byte) }
        enc.hex(UInt8(crc >> 8))
        enc.hex(UInt8(crc & 0xFF))
        enc.raw(0x0D)
        enc.raw(0x0A)
        if type != .ack, type != .fin {
            enc.raw(Zmodem.XON)
        }
        return enc.out
    }

    static func bin32Header(_ type: ZFrameType, _ p0: UInt8 = 0, _ p1: UInt8 = 0, _ p2: UInt8 = 0, _ p3: UInt8 = 0) -> [UInt8] {
        var enc = ZmodemEncoder()
        enc.raw(Zmodem.ZPAD)
        enc.raw(Zmodem.ZDLE)
        enc.raw(Zmodem.ZBIN32)
        let body: [UInt8] = [type.rawValue, p0, p1, p2, p3]
        for byte in body { enc.escaped(byte) }
        var crc = ZmodemCRC.crc32(body)
        for _ in 0 ..< 4 {
            enc.escaped(UInt8(crc & 0xFF))
            crc >>= 8
        }
        return enc.out
    }

    static func dataSubpacket32(_ data: [UInt8], end: ZSubpacketEnd) -> [UInt8] {
        var enc = ZmodemEncoder()
        for byte in data { enc.escaped(byte) }
        enc.raw(Zmodem.ZDLE)
        enc.raw(end.rawValue)
        var crc = ZmodemCRC.crc32(data + [end.rawValue])
        for _ in 0 ..< 4 {
            enc.escaped(UInt8(crc & 0xFF))
            crc >>= 8
        }
        if end == .wait {
            enc.raw(Zmodem.XON)
        }
        return enc.out
    }

    static func cancelSequence() -> [UInt8] {
        [UInt8](repeating: Zmodem.ZDLE, count: 8) + [UInt8](repeating: 0x08, count: 8)
    }
}

// MARK: - Parser

enum ZParserEvent {
    case header(ZHeader)
    case data(bytes: [UInt8], end: ZSubpacketEnd)
    case badCRC
    case abort
    case noise(UInt8)
}

final class ZmodemParser {
    var onEvent: (ZParserEvent) -> Void = { _ in }

    private enum State {
        case idle
        case gotPad
        case gotZDLE
        case hexBody
        case binBody
        case bin32Body
        case subpacket
        case subpacketCRC
    }

    private var state: State = .idle
    private var canRun = 0

    private var hexNibbles: [UInt8] = []
    private var headerBytes: [UInt8] = []
    private var headerNeeded = 0
    private var headerCRC32 = false

    private var escaped = false

    private var subpacketData: [UInt8] = []
    private var subpacketCRC32 = false
    private var subpacketEnd: ZSubpacketEnd = .end
    private var crcBytes: [UInt8] = []
    private var crcNeeded = 0

    func feed(_ data: [UInt8]) {
        for byte in data { consume(byte) }
    }

    func feed(_ data: Data) {
        for byte in data { consume(byte) }
    }

    func reset() {
        state = .idle
        canRun = 0
        escaped = false
        hexNibbles.removeAll(keepingCapacity: true)
        headerBytes.removeAll(keepingCapacity: true)
        subpacketData.removeAll(keepingCapacity: true)
        crcBytes.removeAll(keepingCapacity: true)
    }

    private func consume(_ byte: UInt8) {
        // Drop XON/XOFF a flow-controlled link inserts; only inside a frame,
        // where a real one would have been escaped.
        if !escaped, byte == 0x11 || byte == 0x13 || byte == 0x91 || byte == 0x93 {
            switch state {
            case .binBody, .bin32Body, .subpacket, .subpacketCRC:
                return
            default:
                break
            }
        }
        switch state {
        case .idle:
            consumeIdle(byte)
        case .gotPad:
            consumeGotPad(byte)
        case .gotZDLE:
            consumeGotZDLE(byte)
        case .hexBody:
            consumeHex(byte)
        case .binBody, .bin32Body:
            consumeHeaderBody(byte)
        case .subpacket:
            consumeSubpacket(byte)
        case .subpacketCRC:
            consumeSubpacketCRC(byte)
        }
    }

    private func consumeIdle(_ byte: UInt8) {
        switch byte {
        case Zmodem.ZPAD:
            state = .gotPad
            canRun = 0
        case Zmodem.ZDLE:
            state = .gotZDLE
            canRun = 1
        default:
            canRun = 0
            onEvent(.noise(byte))
        }
    }

    private func consumeGotPad(_ byte: UInt8) {
        switch byte {
        case Zmodem.ZPAD:
            break // extra padding; stay
        case Zmodem.ZDLE:
            state = .gotZDLE
            canRun = 0
        default:
            onEvent(.noise(Zmodem.ZPAD))
            state = .idle
            consumeIdle(byte)
        }
    }

    private func consumeGotZDLE(_ byte: UInt8) {
        switch byte {
        case Zmodem.ZDLE:
            canRun += 1
            if canRun >= 5 {
                onEvent(.abort)
                reset()
            }
        case Zmodem.ZBIN:
            beginHeader(crc32: false)
        case Zmodem.ZBIN32:
            beginHeader(crc32: true)
        case Zmodem.ZHEX:
            state = .hexBody
            hexNibbles.removeAll(keepingCapacity: true)
        default:
            state = .idle
            consumeIdle(byte)
        }
    }

    private func beginHeader(crc32: Bool) {
        headerCRC32 = crc32
        headerBytes.removeAll(keepingCapacity: true)
        headerNeeded = 5 + (crc32 ? 4 : 2)
        escaped = false
        state = crc32 ? .bin32Body : .binBody
    }

    private func consumeHex(_ byte: UInt8) {
        if let value = Self.hexValue(byte) {
            hexNibbles.append(value)
            if hexNibbles.count == 14 {
                finishHexHeader()
            }
        } else {
            if hexNibbles.count != 0, hexNibbles.count < 14 {
                onEvent(.badCRC)
            }
            state = .idle
            if byte != 0x0D, byte != 0x0A, byte != Zmodem.XON {
                consumeIdle(byte)
            }
        }
    }

    private func finishHexHeader() {
        var bytes: [UInt8] = []
        var index = 0
        while index < 14 {
            bytes.append((hexNibbles[index] << 4) | hexNibbles[index + 1])
            index += 2
        }
        let crc = (UInt16(bytes[5]) << 8) | UInt16(bytes[6])
        guard ZmodemCRC.crc16(bytes[0 ..< 5]) == crc else {
            onEvent(.badCRC)
            state = .idle
            return
        }
        emitHeader(Array(bytes[0 ..< 5]), crc32: false)
    }

    private func consumeHeaderBody(_ byte: UInt8) {
        guard let decoded = unescape(byte) else { return }
        if decoded.isAbort {
            onEvent(.abort)
            reset()
            return
        }
        headerBytes.append(decoded.value)
        if headerBytes.count == headerNeeded {
            finishBinaryHeader()
        }
    }

    private func finishBinaryHeader() {
        let body = Array(headerBytes[0 ..< 5])
        if headerCRC32 {
            var received: UInt32 = 0
            for index in 0 ..< 4 {
                received |= UInt32(headerBytes[5 + index]) << (8 * index)
            }
            guard ZmodemCRC.crc32(body) == received else {
                onEvent(.badCRC)
                state = .idle
                return
            }
        } else {
            let received = (UInt16(headerBytes[5]) << 8) | UInt16(headerBytes[6])
            guard ZmodemCRC.crc16(body) == received else {
                onEvent(.badCRC)
                state = .idle
                return
            }
        }
        emitHeader(body, crc32: headerCRC32)
    }

    private func emitHeader(_ body: [UInt8], crc32: Bool) {
        guard let type = ZFrameType(rawValue: body[0]) else {
            state = .idle
            return
        }
        let header = ZHeader(type: type, p0: body[1], p1: body[2], p2: body[3], p3: body[4])
        if type == .abort || type == .can {
            onEvent(.abort)
            reset()
            return
        }
        onEvent(.header(header))
        switch type {
        case .file, .data, .sinit, .command, .stderr:
            subpacketCRC32 = crc32
            beginSubpacket()
        default:
            state = .idle
        }
    }

    private func beginSubpacket() {
        subpacketData.removeAll(keepingCapacity: true)
        escaped = false
        state = .subpacket
    }

    private func consumeSubpacket(_ byte: UInt8) {
        guard let decoded = unescape(byte) else { return }
        if decoded.isAbort {
            onEvent(.abort)
            reset()
            return
        }
        if let end = decoded.terminator {
            subpacketEnd = end
            crcBytes.removeAll(keepingCapacity: true)
            crcNeeded = subpacketCRC32 ? 4 : 2
            escaped = false
            state = .subpacketCRC
            return
        }
        subpacketData.append(decoded.value)
    }

    private func consumeSubpacketCRC(_ byte: UInt8) {
        guard let decoded = unescape(byte) else { return }
        if decoded.isAbort {
            onEvent(.abort)
            reset()
            return
        }
        crcBytes.append(decoded.value)
        guard crcBytes.count == crcNeeded else { return }
        let payload = subpacketData + [subpacketEnd.rawValue]
        let ok: Bool
        if subpacketCRC32 {
            var received: UInt32 = 0
            for index in 0 ..< 4 { received |= UInt32(crcBytes[index]) << (8 * index) }
            ok = ZmodemCRC.crc32(payload) == received
        } else {
            let received = (UInt16(crcBytes[0]) << 8) | UInt16(crcBytes[1])
            ok = ZmodemCRC.crc16(payload) == received
        }
        if ok {
            onEvent(.data(bytes: subpacketData, end: subpacketEnd))
        } else {
            onEvent(.badCRC)
        }
        if subpacketEnd.continues, ok {
            beginSubpacket()
        } else {
            state = .idle
        }
    }

    private struct Decoded {
        var value: UInt8 = 0
        var terminator: ZSubpacketEnd?
        var isAbort = false
    }

    private func unescape(_ byte: UInt8) -> Decoded? {
        if escaped {
            escaped = false
            switch byte {
            case Zmodem.ZCRCE, Zmodem.ZCRCG, Zmodem.ZCRCQ, Zmodem.ZCRCW:
                return Decoded(terminator: ZSubpacketEnd(rawValue: byte))
            case Zmodem.ZRUB0:
                return Decoded(value: 0x7F)
            case Zmodem.ZRUB1:
                return Decoded(value: 0xFF)
            case Zmodem.ZDLE:
                return Decoded(isAbort: true)
            default:
                return Decoded(value: byte ^ 0x40)
            }
        }
        if byte == Zmodem.ZDLE {
            escaped = true
            return nil
        }
        return Decoded(value: byte)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30 ... 0x39: byte - 0x30
        case 0x61 ... 0x66: byte - 0x61 + 10
        case 0x41 ... 0x46: byte - 0x41 + 10
        default: nil
        }
    }
}

// MARK: - Trigger detection

struct ZmodemDetector {
    enum Trigger {
        case download
        case upload
    }

    struct Result {
        var passthrough: [UInt8] = []
        var trigger: Trigger?
        var parserBytes: [UInt8] = []
    }

    private static let download: [UInt8] = [0x2A, 0x2A, 0x18, 0x42, 0x30, 0x30]
    private static let upload: [UInt8] = [0x2A, 0x2A, 0x18, 0x42, 0x30, 0x31]

    private var pending: [UInt8] = []

    mutating func feed(_ data: [UInt8]) -> Result {
        var result = Result()
        var index = 0
        while index < data.count {
            pending.append(data[index])
            index += 1
            while !pending.isEmpty {
                if let trigger = Self.fullMatch(pending) {
                    result.trigger = trigger
                    result.parserBytes = pending + Array(data[index...])
                    pending.removeAll(keepingCapacity: true)
                    return result
                }
                if Self.isPrefix(pending) {
                    break
                }
                result.passthrough.append(pending.removeFirst())
            }
        }
        return result
    }

    private static func fullMatch(_ bytes: [UInt8]) -> Trigger? {
        if bytes == download { return .download }
        if bytes == upload { return .upload }
        return nil
    }

    private static func isPrefix(_ bytes: [UInt8]) -> Bool {
        isPrefix(bytes, of: download) || isPrefix(bytes, of: upload)
    }

    private static func isPrefix(_ bytes: [UInt8], of pattern: [UInt8]) -> Bool {
        guard bytes.count <= pattern.count else { return false }
        return Array(pattern[0 ..< bytes.count]) == bytes
    }
}
