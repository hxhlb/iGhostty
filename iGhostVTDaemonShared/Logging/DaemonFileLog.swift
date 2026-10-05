import Darwin
import Dispatch

/// On-disk mirror of the daemon's important events.
///
/// os_log from a jbroot daemon does not reliably reach `log`/idevicesyslog on
/// every bootstrap, and the daemon is exactly the process that needs a post-
/// mortem trail when the app can only say "connection lost". The file lives
/// in mobile's Logs so it is writable whether the daemon runs as root or as
/// mobile, and readable over ssh without elevation. That directory is
/// mobile's to change, so root opens the file through `ConfinedFile` and
/// never by its path.
///
/// Both `ighostvtd` and `ighostvtd-io` write here; each line names its
/// process. No Foundation on purpose: the proxy lives under a 6 MB jetsam
/// limit and a `DateFormatter` alone drags ICU in.
///
/// The location is the protocol's (`iGhostVTProtocol.daemonLogPath`): the
/// app's log viewer reads this file, so the two must agree on where it is.
/// The line format is likewise read back by the app — keep
/// `LogReader.parseDaemonLine` in step with `log(_:)`.
enum DaemonFileLog {
    /// Names another file in place of the protocol's. Only `make harness`
    /// sets it, so a test run on the host never writes into the log of the
    /// user's own running daemon.
    static let pathOverrideVariable = "IGHOSTVT_DAEMON_LOG"

    private static let path: String = {
        if let override = getenv(pathOverrideVariable), override.pointee != 0 {
            return String(cString: override)
        }
        return iGhostVTProtocol.daemonLogPath
    }()

    private static let location = ConfinedFile.split(path)
    private static let rotateAtBytes = 512 * 1024
    private static let queue = DispatchQueue(
        label: "wiki.qaq.ighostvt.daemon.filelog",
        qos: .utility,
    )
    private static let processName = String(cString: getprogname())

    static func log(_ message: String) {
        let line = "\(timestamp()) [\(getpid()) \(processName)] \(singleLine(message))\n"
        queue.async {
            let descriptor = openForAppend()
            guard descriptor >= 0 else { return }
            defer { close(descriptor) }
            let bytes = Array(line.utf8)
            _ = bytes.withUnsafeBytes { writeFully(descriptor, $0) }
        }
    }

    /// Waits for every line queued so far to reach the file. For the moment
    /// before an `exit`: libdispatch does not drain the queue for a dying
    /// process, and the line saying why it dies is the one worth having.
    static func flush() {
        queue.sync {}
    }

    private static func timestamp() -> String {
        var now = timeval()
        gettimeofday(&now, nil)
        var seconds = now.tv_sec
        var parts = tm()
        localtime_r(&seconds, &parts)
        var buffer = [CChar](repeating: 0, count: 32)
        let length = strftime(&buffer, buffer.count, "%m-%d %H:%M:%S", &parts)
        guard length > 0 else { return "?" }
        let millis = Int(now.tv_usec) / 1000
        let padding = millis < 10 ? "00" : millis < 100 ? "0" : ""
        return String(cString: buffer) + "." + padding + String(millis)
    }

    /// A message is one line whatever it quotes: a refused client's path
    /// is the caller's to choose, and a newline in it would forge a line of
    /// its own.
    private static func singleLine(_ message: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in message.unicodeScalars {
            scalars.append(scalar.value < 0x20 || scalar.value == 0x7F ? "?" : scalar)
        }
        return String(scalars)
    }

    /// The log, open for appending and rotated first when it is over size.
    ///
    /// Off the control queue, so a forkpty can land while this is open:
    /// close-on-exec from the start (AGENTS.md, descriptors). Both
    /// processes rotate, so the size check runs under the file's lock and
    /// only for the inode the lock was taken on — a racer that waited out
    /// another's rename finds the path naming a fresh file and reopens it
    /// rather than renaming that fresh file over the history.
    private static func openForAppend() -> Int32 {
        guard let (directoryPath, name) = location else { return -1 }
        let directory = ConfinedFile.openDirectory(directoryPath)
        guard directory >= 0 else { return -1 }
        defer { close(directory) }
        let flags = O_WRONLY | O_APPEND | O_CREAT
        var descriptor = ConfinedFile.open(name, in: directory, flags: flags)
        var attempts = 0
        while descriptor >= 0, attempts < 3 {
            attempts += 1
            _ = flock(descriptor, LOCK_EX)
            var held = stat()
            var named = stat()
            guard fstat(descriptor, &held) == 0, fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0 else {
                break
            }
            if held.st_ino == named.st_ino {
                guard held.st_size > rotateAtBytes else { break }
                _ = renameat(directory, name, directory, name + ".1")
            }
            close(descriptor)
            descriptor = ConfinedFile.open(name, in: directory, flags: flags)
        }
        return descriptor
    }
}
