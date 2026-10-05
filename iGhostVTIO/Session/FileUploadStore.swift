import Darwin
import Foundation

/// Files a client copies onto this device (`iGhostVTOperation.uploadFile`)
/// — a drop on a tab whose shell runs here while the file is on the device
/// the app runs on, where no path of the app's means anything to the shell.
///
/// An upload belongs to no peer: a link that drops mid-file on a weak
/// network comes back as another peer, asks how much of the file is here,
/// and carries on from there. One that hears nothing for `idleLifetime` is
/// given up and its partial file removed; a finished one is closed and
/// stays for the shell, until the sweep removes it a day later.
///
/// Uploads live under a root only this process can write (`rootPath`), each
/// in a directory of its own named for its id. The file and its directory
/// are handed to the session user — the shell moves or deletes what it was
/// given — so everything below the root is treated as that user's: it is
/// only ever reached by descriptor, never followed, and removed one
/// `unlinkat` at a time (`removeTree`).
///
/// Confined to the io side's one control queue, like the rest of it. A
/// chunk is one `pwrite` to local storage, which does not block the way a
/// PTY can.
final class FileUploadStore {
    struct Begun {
        var id: UInt64
        var path: String
    }

    private final class Upload {
        let descriptor: Int32
        let path: String
        let name: String
        let size: UInt64
        var received: UInt64 = 0
        /// The last part written: only a part counts, so a client that only
        /// asks cannot hold an upload, and its slot, forever.
        var lastProgress = Date()

        init(descriptor: Int32, path: String, name: String, size: UInt64) {
            self.descriptor = descriptor
            self.path = path
            self.name = name
            self.size = size
        }
    }

    private struct Finished {
        var size: UInt64
        var path: String
        var name: String
    }

    private var uploads: [UInt64: Upload] = [:]
    /// Finished uploads, so a client whose last reply was lost — or whose
    /// begin was answered after it gave up waiting — hears "all of it", not
    /// "unknown". Bounded: the oldest go first.
    private var finished: [UInt64: Finished] = [:]
    private var finishedOrder: [UInt64] = []
    private var expiry: DispatchSourceTimer?
    private let queue: DispatchQueue

    /// How long an upload waits for its client to send the next part.
    private static let idleLifetime: TimeInterval = 15 * 60
    /// How long a finished file stays for the shell it was dropped on.
    private static let fileLifetime: TimeInterval = 24 * 60 * 60
    /// Room left on the volume after a file, so a drop can never be what
    /// fills the device.
    private static let reservedByteCount: UInt64 = 1 << 30
    /// Deep enough for anything a shell is likely to leave in a drop's
    /// directory; anything deeper stays for the sweep after the next.
    private static let maximumRemovalDepth = 16

    /// Whether a file is still on its way: the idle exit waits for it, or
    /// a client coming back to finish would find the host had forgotten.
    var isEmpty: Bool {
        uploads.isEmpty
    }

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// Where uploads land: beside the remote-access switch on the device —
    /// a directory only root can write, unlike the bootstrap's `/var/tmp`,
    /// where any user could take the name first — and the user's own
    /// temporary directory on the Mac, where the agent is that user.
    private static var rootPath: String {
        #if os(macOS)
            (NSTemporaryDirectory() as NSString).appendingPathComponent("ighostvt-upload")
        #else
            RuntimeEnvironment.resolve(RuntimeEnvironment.bootstrapPath("/var/lib/ighostvt/upload"))
        #endif
    }

    /// The root, opened, or nil when it is not this process's alone.
    private static func openRoot() -> Int32? {
        let root = ConfinedFile.openDirectory(rootPath)
        guard root >= 0 else { return nil }
        var info = stat()
        guard fstat(root, &info) == 0, info.st_uid == geteuid(), ConfinedFile.isPrivate(root) else {
            DaemonFileLog.log("upload refused: \(rootPath) is not this process's own")
            close(root)
            return nil
        }
        // Readable on the way down: the session user has to reach its files.
        fchmod(root, 0o755)
        return root
    }

    /// Begins an upload, or answers again for one already begun under
    /// `requestedID` with the same name and size — a begin the client sent
    /// again because the first answer was lost must not make a second file.
    func begin(name rawName: String, size: UInt64, requestedID: UInt64?) -> Result<Begun, iGhostVTFailure> {
        let name = Self.safeName(rawName)
        if let requestedID {
            if let upload = uploads[requestedID] {
                guard upload.name == name, upload.size == size else {
                    return .failure(iGhostVTFailure(.invalidRequest, "That upload id is in use."))
                }
                return .success(Begun(id: requestedID, path: upload.path))
            }
            if let done = finished[requestedID] {
                guard done.name == name, done.size == size else {
                    return .failure(iGhostVTFailure(.invalidRequest, "That upload id is in use."))
                }
                return .success(Begun(id: requestedID, path: done.path))
            }
        }
        guard size <= iGhostVTProtocol.maximumUploadByteCount else {
            return .failure(iGhostVTFailure(.invalidRequest, "The file is larger than the host accepts."))
        }
        guard uploads.count < iGhostVTProtocol.maximumPendingUploadCount else {
            return .failure(iGhostVTFailure(.operationFailed, "Too many files are being copied to the host at once."))
        }
        guard let root = Self.openRoot() else {
            return .failure(iGhostVTFailure(.operationFailed, "The host has no safe folder to receive the file in."))
        }
        defer { close(root) }
        guard let rootKernelPath = Self.kernelPath(of: root) else {
            return .failure(iGhostVTFailure(.operationFailed, "The host could not name its upload folder."))
        }
        sweep(root)
        var volume = statfs()
        if fstatfs(root, &volume) == 0 {
            let free = UInt64(volume.f_bavail) * UInt64(volume.f_bsize)
            guard free > Self.reservedByteCount, size <= free - Self.reservedByteCount else {
                return .failure(iGhostVTFailure(.operationFailed, "The other device does not have enough free space."))
            }
        }

        var id = requestedID ?? 0
        var directoryName = ""
        while true {
            if requestedID == nil {
                id = UInt64.random(in: 1 ... .max)
            }
            directoryName = String(id, radix: 16)
            // Private while the file is made, handed over after.
            if mkdirat(root, directoryName, 0o700) == 0 {
                break
            }
            guard errno == EEXIST, requestedID == nil else {
                return .failure(iGhostVTFailure(.invalidRequest, "That upload id is in use."))
            }
        }
        let directory = openat(root, directoryName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else {
            unlinkat(root, directoryName, AT_REMOVEDIR)
            return .failure(iGhostVTFailure(.operationFailed, "The host could not make a folder for the file."))
        }
        defer { close(directory) }
        let descriptor = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            let reason = String(cString: strerror(errno))
            unlinkat(root, directoryName, AT_REMOVEDIR)
            return .failure(iGhostVTFailure(.operationFailed, "The host could not create the file: \(reason)."))
        }
        // The shell's to read, move and delete: the file, and the directory
        // that holds it.
        if let credentials = ShellLaunch.sessionCredentials {
            fchown(descriptor, credentials.uid, credentials.gid)
            fchown(directory, credentials.uid, credentials.gid)
        }
        fchmod(directory, 0o755)
        let path = rootKernelPath + "/" + directoryName + "/" + name
        uploads[id] = Upload(descriptor: descriptor, path: path, name: name, size: size)
        armExpiry()
        if size == 0 {
            finish(id)
        }
        DaemonFileLog.log("upload \(directoryName) began: \(size) byte(s) as \(name)")
        return .success(Begun(id: id, path: path))
    }

    /// How much of the file is here; nil for an upload this side does not
    /// know (given up, or from an io process that has since been replaced).
    /// A finished upload answers its size.
    func received(_ id: UInt64) -> UInt64? {
        uploads[id]?.received ?? finished[id]?.size
    }

    /// Writes `data` at `offset`. A part may repeat what is here already:
    /// after a link drops, parts the old link sent can still be on their
    /// way through the proxy when the new link asks how much is here and
    /// starts again from that answer, so the two streams overlap. What is
    /// already here is skipped and only what is new is written — the bytes
    /// are the same file's. A part that would leave a hole, or run past the
    /// size, is refused with nothing written, and the reply says where to
    /// carry on.
    func write(_ id: UInt64, offset: UInt64, data: Data) -> Result<UInt64, iGhostVTReplyCode> {
        let count = UInt64(data.count)
        guard let upload = uploads[id] else {
            // Compared without adding: the offset is the client's, and any
            // value at all must not trap.
            if let done = finished[id], offset <= done.size, count <= done.size - offset {
                return .success(done.size)
            }
            return .failure(.unknownSession)
        }
        guard offset <= upload.received, count <= upload.size - offset else {
            return .failure(.invalidRequest)
        }
        let end = offset + count
        guard end > upload.received else {
            return .success(upload.received)
        }
        let skip = Int(upload.received - offset)
        let written = data.withUnsafeBytes { buffer -> Bool in
            var done = skip
            while done < buffer.count {
                let result = pwrite(
                    upload.descriptor,
                    buffer.baseAddress! + done,
                    buffer.count - done,
                    off_t(offset) + off_t(done),
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                done += result
            }
            return true
        }
        guard written else {
            DaemonFileLog.log("upload \(String(id, radix: 16)) write failed: \(String(cString: strerror(errno)))")
            cancel(id)
            return .failure(.operationFailed)
        }
        upload.received = end
        upload.lastProgress = Date()
        if upload.received == upload.size {
            finish(id)
        }
        return .success(end)
    }

    func cancel(_ id: UInt64) {
        guard let upload = uploads.removeValue(forKey: id) else { return }
        close(upload.descriptor)
        if let root = Self.openRoot() {
            Self.removeTree(String(id, radix: 16), in: root, depth: 0)
            close(root)
        }
        DaemonFileLog.log("upload \(String(id, radix: 16)) cancelled at \(upload.received) of \(upload.size) byte(s)")
    }

    private func finish(_ id: UInt64) {
        guard let upload = uploads.removeValue(forKey: id) else { return }
        close(upload.descriptor)
        finished[id] = Finished(size: upload.size, path: upload.path, name: upload.name)
        finishedOrder.append(id)
        if finishedOrder.count > 64 {
            finished.removeValue(forKey: finishedOrder.removeFirst())
        }
        DaemonFileLog.log("upload \(String(id, radix: 16)) finished: \(upload.size) byte(s)")
    }

    // MARK: - Expiry

    private func armExpiry() {
        guard expiry == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in self?.expireIdle() }
        timer.resume()
        expiry = timer
    }

    private func expireIdle() {
        let cutoff = Date().addingTimeInterval(-Self.idleLifetime)
        for (id, upload) in uploads where upload.lastProgress < cutoff {
            DaemonFileLog.log("upload \(String(id, radix: 16)) given up: idle at \(upload.received) of \(upload.size) byte(s)")
            cancel(id)
        }
        if uploads.isEmpty {
            expiry?.cancel()
            expiry = nil
        }
    }

    /// Removes what earlier uploads left once it is a day old.
    private func sweep(_ root: Int32) {
        let active = Set(uploads.keys.map { String($0, radix: 16) })
        let cutoff = Date().addingTimeInterval(-Self.fileLifetime).timeIntervalSince1970
        var stale: [String] = []
        for name in Self.entries(of: root) where !active.contains(name) {
            var info = stat()
            guard fstatat(root, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  Double(info.st_mtimespec.tv_sec) < cutoff
            else { continue }
            stale.append(name)
        }
        for name in stale {
            Self.removeTree(name, in: root, depth: 0)
        }
    }

    /// Removes `name` from `directory`, and everything under it when it is
    /// a directory — reached by descriptor, `O_NOFOLLOW`, so a link the
    /// session user put there is removed as a link and never followed.
    private static func removeTree(_ name: String, in directory: Int32, depth: Int) {
        if unlinkat(directory, name, 0) == 0 {
            return
        }
        guard depth < maximumRemovalDepth else { return }
        let inner = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard inner >= 0 else { return }
        for entry in entries(of: inner) {
            removeTree(entry, in: inner, depth: depth + 1)
        }
        close(inner)
        unlinkat(directory, name, AT_REMOVEDIR)
    }

    private static func entries(of directory: Int32) -> [String] {
        let listing = dup(directory)
        guard listing >= 0 else { return [] }
        guard let stream = fdopendir(listing) else {
            close(listing)
            return []
        }
        defer { closedir(stream) }
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { buffer in
                String(cString: buffer.bindMemory(to: CChar.self).baseAddress!)
            }
            if name != ".", name != ".." {
                names.append(name)
            }
        }
        return names
    }

    // MARK: - Names

    /// The kernel's spelling of an open directory: the path the shell can
    /// use, whatever links the walk to it went through.
    private static func kernelPath(of descriptor: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// A single path component: separators and controls become `_`, a name
    /// that would be `.` or `..` or empty becomes `file`, and anything past
    /// 255 bytes is cut on a character boundary, keeping an extension that
    /// leaves room for a stem.
    static func safeName(_ raw: String) -> String {
        var name = String(raw.map { character -> Character in
            character == "/" || character.unicodeScalars.contains { $0.value < 0x20 || (0x7F ... 0x9F).contains($0.value) }
                ? "_" : character
        })
        if name.isEmpty || name == "." || name == ".." {
            name = "file"
        }
        guard name.utf8.count > 255 else { return name }
        let ext = (name as NSString).pathExtension
        var stem = ext.isEmpty || ext.utf8.count > 64 ? name : (name as NSString).deletingPathExtension
        let suffix = stem == name ? "" : "." + ext
        while stem.utf8.count + suffix.utf8.count > 255 {
            stem.removeLast()
        }
        return stem + suffix
    }
}
