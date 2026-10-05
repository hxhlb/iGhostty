import Darwin
import Dispatch
import XPC

/// Owns `ighostvtd-remote`, the remote-access helper, while the switch is on.
///
/// The switch is a file (`flagPath`): present means on. The proxy reads it at launch — `RunAtLoad` is what brings the
/// helper up after a boot or a login — and `setRemoteAccess` writes or
/// removes it and starts or stops the helper. The helper is spawned beside
/// this executable with a management socket on descriptor 3, the same
/// frames as the io link, and restarted when it dies, paced like io.
///
/// The management operations (`remoteStatus`, `beginPairing`, …) are
/// forwarded to it whole; nothing here reads more than the operation code,
/// except `setRemoteAccess`'s one flag. The helper's log lines arrive as
/// events on the same socket and are written to the daemon's log, which it
/// cannot open itself once it has dropped to mobile.
///
/// The helper is also a client of the daemon — it connects back over XPC
/// to relay each paired device — and `PeerAuthenticator` admits it by being
/// this child: its pid, which the kernel cannot reuse until it is reaped
/// here, and its path beside this executable.
final class RemoteSupervisor {
    static let executableName = "ighostvtd-remote"
    static let respawnDelay: DispatchTimeInterval = .seconds(2)
    private static let closeOnExecByDefault: Int16 = 0x4000

    private let queue: DispatchQueue
    let executablePath: String

    private var channel: IOChannel?
    private var childPID: pid_t = 0
    private var exitSource: DispatchSourceProcess?
    private var lastSpawn = DispatchTime(uptimeNanoseconds: 0)
    private var respawnScheduled = false
    private var pending: [UInt64: (xpc_object_t) -> Void] = [:]
    private var nextTag: UInt64 = 1

    init(queue: DispatchQueue, executablePath: String) {
        self.queue = queue
        self.executablePath = executablePath
    }

    /// The switch. On the device it is the bootstrap's, in a directory only
    /// root can write: it sat beside the daemon log once, in mobile's Logs,
    /// where any mobile process could turn a network listener on with a
    /// `touch`. On the Mac the daemon is the user's own agent, and the
    /// user's Logs is no less theirs than the switch.
    static let flagPath: String = {
        #if os(macOS)
            let log = iGhostVTProtocol.daemonLogPath
            return String(log[..<(log.lastIndex(of: "/") ?? log.startIndex)]) + "/ighostvtd.remote-access"
        #else
            return RuntimeEnvironment.resolve(RuntimeEnvironment.bootstrapPath("/var/lib/ighostvt/remote-access"))
        #endif
    }()

    var isEnabled: Bool {
        guard let directory = Self.openFlagDirectory() else { return false }
        defer { close(directory) }
        var info = stat()
        return fstatat(directory, Self.flagName, &info, AT_SYMLINK_NOFOLLOW) == 0
    }

    private static let flagName = ConfinedFile.split(flagPath)?.name ?? ""

    /// The switch's directory, made if missing, and only while nobody but
    /// this process's user can change it — a switch anyone else could have
    /// created is no switch.
    private static func openFlagDirectory() -> Int32? {
        guard let (path, _) = ConfinedFile.split(flagPath) else { return nil }
        let directory = ConfinedFile.openDirectory(path)
        guard directory >= 0 else { return nil }
        guard ConfinedFile.isPrivate(directory) else {
            close(directory)
            DaemonFileLog.log("remote access: \(path) is writable by others, so the switch reads off")
            return nil
        }
        return directory
    }

    /// The helper's pid until it is reaped — which is also how long the
    /// kernel keeps it from naming anyone else — and 0 otherwise.
    var helperProcessID: pid_t {
        childPID
    }

    /// At launch: the helper runs if the switch says so.
    func startIfEnabled() {
        guard isEnabled else { return }
        DaemonFileLog.log("remote access is on, starting the helper")
        spawnOrRetry()
    }

    // MARK: - Requests

    /// A management request from a local peer. `completion` gets the reply.
    func handle(_ message: xpc_object_t, completion: @escaping (xpc_object_t) -> Void) {
        let operation = iGhostVTOperation(rawValue: xpc_dictionary_get_uint64(message, iGhostVTWireKey.operation))
        if operation == .setRemoteAccess {
            let enabled = xpc_dictionary_get_bool(message, iGhostVTWireKey.enabled)
            setEnabled(enabled)
            // Off is answered here: the helper is on its way out, and it
            // would still say it is on.
            guard enabled else { return completion(Self.offlineStatus(enabled: false)) }
            // What the switch now says, from the helper when it is up.
            let status = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_uint64(status, iGhostVTWireKey.version, iGhostVTProtocol.version)
            xpc_dictionary_set_uint64(status, iGhostVTWireKey.operation, iGhostVTOperation.remoteStatus.rawValue)
            return forwardOrCompose(status, completion: completion)
        }
        forwardOrCompose(message, completion: completion)
    }

    private func forwardOrCompose(_ message: xpc_object_t, completion: @escaping (xpc_object_t) -> Void) {
        guard let channel else {
            completion(Self.offlineStatus(enabled: isEnabled))
            return
        }
        let tag = nextTag
        nextTag &+= 1
        pending[tag] = completion
        if !channel.send(.request, peer: 0, tag: tag, object: message) {
            pending.removeValue(forKey: tag)
            completion(Self.offlineStatus(enabled: isEnabled))
        }
    }

    /// The answer while no helper runs: the switch, and `starting` when it
    /// is on (the helper is on its way, or being restarted).
    private static func offlineStatus(enabled: Bool) -> xpc_object_t {
        let reply = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(reply, iGhostVTWireKey.version, iGhostVTProtocol.version)
        xpc_dictionary_set_int64(reply, iGhostVTWireKey.code, iGhostVTReplyCode.success.rawValue)
        xpc_dictionary_set_bool(reply, iGhostVTWireKey.enabled, enabled)
        xpc_dictionary_set_string(
            reply,
            iGhostVTWireKey.remoteState,
            (enabled ? RemoteAccessState.starting : RemoteAccessState.off).rawValue,
        )
        return reply
    }

    private func setEnabled(_ enabled: Bool) {
        let directory = Self.openFlagDirectory()
        defer { directory.map { _ = close($0) } }
        if enabled {
            if let directory {
                let descriptor = ConfinedFile.open(Self.flagName, in: directory, flags: O_WRONLY | O_CREAT)
                if descriptor >= 0 {
                    close(descriptor)
                }
            }
            DaemonFileLog.log("remote access turned on")
            if channel == nil {
                spawnOrRetry()
            }
        } else {
            if let directory {
                unlinkat(directory, Self.flagName, 0)
            }
            DaemonFileLog.log("remote access turned off")
            stop()
        }
    }

    private func stop() {
        guard childPID > 0, channel != nil else { return }
        kill(childPID, SIGTERM)
    }

    // MARK: - The child

    private func spawnOrRetry() {
        do {
            try spawn()
        } catch {
            scheduleRespawn()
        }
    }

    private func spawn() throws {
        lastSpawn = .now()
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            throw iGhostVTDaemonError.transportFailure
        }
        let parentEnd = pair[0]
        let childEnd = pair[1]

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for descriptor: Int32 in 0 ... 2 where fcntl(descriptor, F_GETFD) >= 0 {
            posix_spawn_file_actions_addinherit_np(&actions, descriptor)
        }
        posix_spawn_file_actions_adddup2(&actions, childEnd, IOWire.socketDescriptor)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Self.closeOnExecByDefault)

        let arguments = [executablePath, IOWire.socketArgument, String(IOWire.socketDescriptor)]
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        defer { argv.forEach { free($0) } }

        var pid: pid_t = 0
        let status = posix_spawn(&pid, executablePath, &actions, &attributes, argv, environ)
        close(childEnd)
        guard status == 0 else {
            close(parentEnd)
            DaemonFileLog.log("remote spawn of \(executablePath) failed: \(String(cString: strerror(status)))")
            throw iGhostVTDaemonError.transportFailure
        }
        childPID = pid
        let channel = IOChannel(descriptor: parentEnd, queue: queue)
        channel.onFrame = { [weak self] header, payload in
            self?.handleFrame(header, payload: payload)
        }
        channel.onClosed = { [weak self] in
            self?.handleLinkClosed()
        }
        self.channel = channel
        channel.activate()

        let exitSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        exitSource.setEventHandler { [weak self] in
            self?.reap()
        }
        self.exitSource = exitSource
        exitSource.activate()
        DaemonFileLog.log("remote helper spawned as pid \(pid)")
    }

    private func handleFrame(_ header: IOWire.Header, payload: UnsafeRawBufferPointer) {
        guard let object = IOCodec.decode(payload) else { return }
        switch header.kind {
        case .reply:
            pending.removeValue(forKey: header.tag)?(object)
        case .event:
            if let line = xpc_dictionary_get_string(object, iGhostVTWireKey.errorMessage) {
                DaemonFileLog.log("remote: \(String(cString: line))")
            }
        case .request, .peerGone:
            break
        }
    }

    private func handleLinkClosed() {
        channel = nil
        exitSource?.cancel()
        exitSource = nil
        let unanswered = pending
        pending.removeAll()
        for completion in unanswered.values {
            completion(Self.offlineStatus(enabled: isEnabled))
        }
        reap()
        if isEnabled {
            DaemonFileLog.log("remote helper gone, restarting")
            scheduleRespawn()
        } else {
            DaemonFileLog.log("remote helper stopped")
        }
    }

    /// Polled: a closed socket and an exit note can each come first.
    private func reap(attempt: Int = 0) {
        guard childPID > 0 else { return }
        var status: Int32 = 0
        var result: pid_t
        repeat {
            result = waitpid(childPID, &status, WNOHANG)
        } while result < 0 && errno == EINTR
        if result == 0 {
            channel?.close()
            // Asked until it is reaped, however long: the respawn waits on
            // it, and a helper that is never reaped never comes back.
            let delay: DispatchTimeInterval = attempt < 100 ? .milliseconds(20) : .seconds(1)
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.reap(attempt: attempt + 1)
            }
            return
        }
        childPID = 0
        channel?.close()
        // The link usually closes first, while the child is not yet
        // waitable (XNU posts the exit before the zombie), and the respawn
        // asked for then found a child still here and stood down. This is
        // the moment it can go ahead.
        if isEnabled, channel == nil {
            scheduleRespawn()
        }
    }

    private func scheduleRespawn() {
        guard !respawnScheduled else { return }
        respawnScheduled = true
        let elapsed = DispatchTime.now().uptimeNanoseconds &- lastSpawn.uptimeNanoseconds
        let delay: DispatchTimeInterval = elapsed < 2_000_000_000 ? Self.respawnDelay : .milliseconds(0)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            respawnScheduled = false
            guard isEnabled, channel == nil, childPID == 0 else { return }
            spawnOrRetry()
        }
    }
}
