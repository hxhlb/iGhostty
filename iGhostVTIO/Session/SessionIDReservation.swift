import Darwin

/// Hands out session ids that no earlier `ighostvtd-io` has used.
///
/// A client keeps the id it was given across a link drop and attaches to it
/// again — the app's tabs do after every reconnect, and its ledger does after
/// a cold launch. When io itself died, that id names nothing any more, and
/// the attach must fail so the tab opens a fresh shell. A counter that began
/// at 1 in every io made the old id name *someone else's* session instead: a
/// tab reconnecting after an io crash attached to whatever the replacement
/// had opened under that number first, a CLI `new` included. So the counter
/// outlives the process: ids are reserved in blocks, and the end of the last
/// block reserved is kept on disk beside the daemon's log, where a
/// replacement io starts.
///
/// The file only ever grows. A reservation takes an exclusive lock, reads
/// what is there, and writes back the larger of that and its own end, so two
/// io processes sharing it (the harness's beside a running daemon) cannot
/// pull it below an id either has handed out. A file that cannot be read or
/// written costs only that guarantee: ids still never repeat within one io.
struct SessionIDReservation {
    static let blockSize: UInt64 = 64

    static var defaultPath: String {
        let log = iGhostVTProtocol.daemonLogPath
        let directory = log[..<(log.lastIndex(of: "/") ?? log.startIndex)]
        return directory + "/ighostvtd.session-ids"
    }

    private let path: String
    private var next: UInt64
    private var reservedEnd: UInt64

    init(path: String = Self.defaultPath) {
        self.path = path
        let start = max(Self.update(path: path, atLeast: 0) ?? 1, 1)
        next = start
        reservedEnd = start
    }

    /// The next id, reserving another block first when this one is spent.
    mutating func take() -> UInt64 {
        if next >= reservedEnd {
            let wanted = next &+ Self.blockSize
            reservedEnd = Self.update(path: path, atLeast: wanted).map { max($0, wanted) } ?? wanted
        }
        let id = next
        next &+= 1
        return id
    }

    /// Raises the stored value to at least `value` and returns what is stored
    /// afterwards; nil when the file is out of reach.
    private static func update(path: String, atLeast value: UInt64) -> UInt64? {
        var descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        if descriptor < 0, errno == ENOENT {
            // mobile's Logs does not exist until someone makes it; the log
            // makes it the same way, and either may come first.
            let directory = String(path[..<(path.lastIndex(of: "/") ?? path.startIndex)])
            mkdir(directory, 0o755)
            descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        }
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { return nil }
        defer { flock(descriptor, LOCK_UN) }

        var buffer = [UInt8](repeating: 0, count: 32)
        let count = pread(descriptor, &buffer, buffer.count - 1, 0)
        let digits = count > 0 ? buffer[..<count].prefix { (48 ... 57).contains($0) } : []
        let stored = UInt64(String(decoding: digits, as: UTF8.self))
        let result = max(stored ?? 0, value)
        guard result != stored else { return result }
        let text = Array("\(result)\n".utf8)
        let written = text.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
        guard written == text.count else { return stored }
        ftruncate(descriptor, off_t(text.count))
        return result
    }
}
