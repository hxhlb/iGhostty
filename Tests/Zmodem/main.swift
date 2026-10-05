import Foundation

// Tests for the clean-room ZMODEM core (iGhostVT/Backend/Zmodem). No daemon
// and no UIKit in the loop: the CRCs, the frame codec, the detector, and the
// two state machines driven against each other over in-memory pipes. The
// loopback is the strong one — `ZmodemSender` plays `sz`, `ZmodemReceiver`
// plays `rz`, and a file that comes out the other end byte-for-byte exercises
// both halves at once.

var failures: [String] = []

func check(_ condition: Bool, _ description: String) {
    if condition {
        print("  ok   \(description)")
    } else {
        print("  FAIL \(description)")
        failures.append(description)
    }
}

// MARK: CRC vectors

print("zmodem: CRC")
// CRC-16/CCITT over "123456789" with no augmentation is 0x29B1; ZMODEM augments
// with two zero bytes, which advances it to a different, well-defined value —
// assert it is stable and that a single bit-flip changes it.
let crc16a = ZmodemCRC.crc16(Array("123456789".utf8))
let crc16b = ZmodemCRC.crc16(Array("123456780".utf8))
check(crc16a != crc16b, "CRC-16 distinguishes a one-byte change")
check(ZmodemCRC.crc16([]) == ZmodemCRC.crc16([]), "CRC-16 is deterministic")
// Captured from real lrzsz over a PTY: these exact CRCs are what rz/sz put on
// the wire for a ZRPOS(0) and a ZRINIT(caps 0x23) hex header. Guards against
// re-introducing the augmentation bug that made every real header fail.
check(ZmodemCRC.crc16([0x09, 0, 0, 0, 0]) == 0xA87C, "CRC-16 matches real lrzsz ZRPOS header (0xA87C)")
check(ZmodemCRC.crc16([0x01, 0, 0, 0, 0x23]) == 0xBE50, "CRC-16 matches real lrzsz ZRINIT header (0xBE50)")
// CRC-32 of "123456789" is the standard 0xCBF43926.
check(ZmodemCRC.crc32(Array("123456789".utf8)) == 0xCBF4_3926, "CRC-32 matches the known vector")

// MARK: Header round-trip

print("zmodem: header codec")
func parseOne(_ bytes: [UInt8]) -> [ZParserEvent] {
    let parser = ZmodemParser()
    var events: [ZParserEvent] = []
    parser.onEvent = { events.append($0) }
    parser.feed(bytes)
    return events
}

do {
    let events = parseOne(ZmodemEncoder.hexHeader(.rinit, 0, 0, 0, 0x23))
    if case let .header(header)? = events.first, header.type == .rinit, header.p3 == 0x23 {
        check(true, "hex ZRINIT header round-trips with its capability byte")
    } else {
        check(false, "hex ZRINIT header round-trips with its capability byte")
    }
}
do {
    let events = parseOne(ZmodemEncoder.hexHeader(.rpos, 0x34, 0x12, 0, 0))
    if case let .header(header)? = events.first, header.type == .rpos, header.position == 0x1234 {
        check(true, "hex ZRPOS carries a little-endian position")
    } else {
        check(false, "hex ZRPOS carries a little-endian position")
    }
}
do {
    // A ZDATA bin32 header whose position bytes include control values that
    // must be ZDLE-escaped on the wire (0x18, 0x11).
    let events = parseOne(ZmodemEncoder.bin32Header(.data, 0x18, 0x11, 0x13, 0x10))
    if case let .header(header)? = events.first, header.type == .data,
       header.p0 == 0x18, header.p1 == 0x11, header.p2 == 0x13, header.p3 == 0x10 {
        check(true, "bin32 ZDATA header survives ZDLE escaping of its bytes")
    } else {
        check(false, "bin32 ZDATA header survives ZDLE escaping of its bytes")
    }
}

// MARK: Subpacket / ZDLE round-trip over every byte value

print("zmodem: subpacket ZDLE escaping")
do {
    // A bin32 ZDATA header to set the parser's subpacket CRC width, then a
    // subpacket containing all 256 byte values.
    var stream = ZmodemEncoder.bin32Header(.data, 0, 0, 0, 0)
    let payload = (0 ... 255).map { UInt8($0) }
    stream += ZmodemEncoder.dataSubpacket32(payload, end: .end)
    let events = parseOne(stream)
    var recovered: [UInt8]?
    for event in events {
        if case let .data(bytes, end) = event, end == .end { recovered = bytes }
    }
    check(recovered == payload, "every byte value survives a subpacket round-trip")
}
do {
    // Bare XON/XOFF that a flow-controlled link might inject mid-frame must be
    // ignored by the parser, not taken as data (which would fail the CRC).
    var stream = ZmodemEncoder.bin32Header(.data, 0, 0, 0, 0)
    let payload: [UInt8] = Array("hello world".utf8)
    var sub = ZmodemEncoder.dataSubpacket32(payload, end: .end)
    // Splice XON (0x11) and XOFF (0x13) into the middle of the encoded subpacket.
    sub.insert(0x13, at: sub.count / 2)
    sub.insert(0x11, at: sub.count / 3)
    stream += sub
    let events = parseOne(stream)
    var recovered: [UInt8]?
    for event in events { if case let .data(bytes, _) = event { recovered = bytes } }
    check(recovered == payload, "bare XON/XOFF injected mid-subpacket are ignored")
}

// MARK: Detector

print("zmodem: trigger detection")
do {
    var detector = ZmodemDetector()
    let input = Array("hello\r\n".utf8) + [0x2A, 0x2A, 0x18, 0x42, 0x30, 0x30, 0x41]
    let result = detector.feed(input)
    check(result.trigger == .download, "ZRQINIT prefix is detected as a download")
    check(result.passthrough == input, "the whole detecting chunk is passed to the terminal in real time")
    check(result.parserBytes == [0x2A, 0x2A, 0x18, 0x42, 0x30, 0x30, 0x41],
          "the trigger and trailing bytes are handed to the parser")
}
do {
    var detector = ZmodemDetector()
    let first = detector.feed([0x2A, 0x2A, 0x18])
    check(first.trigger == nil, "a split trigger is not yet detected on the first half")
    check(first.passthrough == [0x2A, 0x2A, 0x18], "partial-prefix bytes are rendered immediately, never withheld")
    let second = detector.feed([0x42, 0x30, 0x31])
    check(second.trigger == .upload, "the rest of a split trigger completes an upload detection")
    check(second.parserBytes == [0x2A, 0x2A, 0x18, 0x42, 0x30, 0x31],
          "a split trigger is reassembled across chunks for the parser")
}
do {
    var detector = ZmodemDetector()
    let input = Array("a ** b ***".utf8)
    let result = detector.feed(input)
    check(result.trigger == nil, "stray asterisks do not false-trigger")
    check(result.passthrough == input, "non-trigger text is rendered verbatim, including a trailing prefix")
}

// MARK: Loopback — sender ↔ receiver

print("zmodem: end-to-end loopback")

final class MemoryWriter: ZmodemFileWriter, @unchecked Sendable {
    var files: [(name: String, data: [UInt8])] = []
    var completed: Bool?
    private var current: (name: String, data: [UInt8])?

    func beginFile(name: String, size _: UInt64?) -> Bool {
        current = (name, [])
        return true
    }

    func write(_ bytes: [UInt8]) {
        current?.data.append(contentsOf: bytes)
    }

    func finishFile() {
        if let current { files.append(current) }
        current = nil
    }

    func finish(completed: Bool) {
        self.completed = completed
    }
}

final class MemorySource: ZmodemFileSource, @unchecked Sendable {
    private var queue: [(name: String, data: [UInt8])]
    var completed: Bool?

    init(_ files: [(name: String, data: [UInt8])]) { queue = files }

    func nextFile() -> ZmodemOutgoingFile? {
        guard !queue.isEmpty else { return nil }
        let file = queue.removeFirst()
        return ZmodemOutgoingFile(name: file.name, size: UInt64(file.data.count)) { offset, maxLength in
            let start = Int(offset)
            guard start < file.data.count else { return [] }
            let end = min(start + maxLength, file.data.count)
            return Array(file.data[start ..< end])
        }
    }

    func finish(completed: Bool) {
        self.completed = completed
    }
}

/// Runs `ZmodemSender` (as `sz`) against `ZmodemReceiver` (as `rz`) over two
/// byte queues and returns what the receiver wrote.
func loopback(_ files: [(name: String, data: [UInt8])]) -> (MemoryWriter, MemorySource) {
    var usToPeer: [UInt8] = []
    var peerToUs: [UInt8] = []

    let source = MemorySource(files)
    let writer = MemoryWriter()

    let sender = ZmodemSender(send: { usToPeer.append(contentsOf: $0) }, source: source)
    let receiver = ZmodemReceiver(send: { peerToUs.append(contentsOf: $0) }, writer: writer)

    let senderParser = ZmodemParser()
    senderParser.onEvent = { sender.handle($0) }
    let receiverParser = ZmodemParser()
    receiverParser.onEvent = { receiver.handle($0) }

    receiver.begin() // rz announces ZRINIT
    sender.begin() // sz sends ZFILE

    var guardCount = 0
    while !usToPeer.isEmpty || !peerToUs.isEmpty {
        guardCount += 1
        if guardCount > 1_000_000 { break }
        if !usToPeer.isEmpty {
            let bytes = usToPeer
            usToPeer.removeAll(keepingCapacity: true)
            receiverParser.feed(bytes)
        }
        if !peerToUs.isEmpty {
            let bytes = peerToUs
            peerToUs.removeAll(keepingCapacity: true)
            senderParser.feed(bytes)
        }
    }
    return (writer, source)
}

func randomBytes(_ count: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    for index in 0 ..< count { bytes[index] = UInt8.random(in: 0 ... 255) }
    return bytes
}

do {
    let payload = Array("The quick brown fox\r\njumps over the lazy dog.\n".utf8)
    let (writer, source) = loopback([("fox.txt", payload)])
    check(writer.files.count == 1 && writer.files.first?.name == "fox.txt", "loopback transfers the file name")
    check(writer.files.first?.data == payload, "loopback transfers a small text file intact")
    check(writer.completed == true, "receiver reports completion")
    check(source.completed == true, "sender reports completion")
}
do {
    // Binary data with control bytes, spanning several 8192-byte blocks and
    // not a clean multiple of the block size.
    let payload = randomBytes(8192 * 3 + 123)
    let (writer, _) = loopback([("blob.bin", payload)])
    check(writer.files.first?.data == payload, "loopback transfers a multi-block binary file intact")
}
do {
    let payload = randomBytes(8192) // exactly one block
    let (writer, _) = loopback([("exact.bin", payload)])
    check(writer.files.first?.data == payload, "loopback handles an exact-block-size file")
}
do {
    let (writer, _) = loopback([("empty.bin", [])])
    check(writer.files.first?.name == "empty.bin" && writer.files.first?.data.isEmpty == true,
          "loopback handles an empty file")
}
do {
    let a = randomBytes(5000)
    let b = Array("second file\n".utf8)
    let (writer, _) = loopback([("a.bin", a), ("b.txt", b)])
    check(writer.files.count == 2, "loopback transfers a batch of two files")
    check(writer.files.first?.data == a && writer.files.last?.data == b, "both files in the batch arrive intact")
}

// MARK: Result

if failures.isEmpty {
    print("\nzmodem: all checks passed")
    exit(0)
} else {
    print("\nzmodem: \(failures.count) FAILURE(S)")
    for failure in failures { print("  - \(failure)") }
    exit(1)
}
