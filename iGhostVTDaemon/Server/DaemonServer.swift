import Darwin
import Dispatch
import os
import XPC

/// Mach service listener.
///
/// Accepts several peers at once (an iPad can have more than one app
/// window). The daemon is demand-launched on both platforms: launchd starts
/// it at load and whenever a client looks the service up, and it leaves on
/// its own once nothing needs it — no peer for a while and no session held,
/// which `IOSupervisor` decides and carries out through the child's
/// `shutdown`. `KeepAlive = {SuccessfulExit = false}` restarts a crash and
/// lets that exit stand.
///
/// The exit cannot be made atomic against launchd routing a new connection,
/// so a client can arrive just as the child goes. The supervisor takes the
/// exit back when that happens — a fresh child, the proxy stays — and the
/// client, cut from the child that left, reconnects and replays the way it
/// does after any interruption. While remote access is on,
/// `ighostvtd-remote` holds a connection for as long as it runs, and the
/// daemon never sees itself idle.
///
/// This process holds no session: it is the jetsam-limited launchd job, and
/// everything with a buffer lives in the child (`IOSupervisor`).
final class DaemonServer {
    private let controlQueue = DispatchQueue(
        label: "wiki.qaq.ighostvt.daemon.control",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem,
    )
    private let authenticator = PeerAuthenticator()
    private lazy var supervisor = IOSupervisor(
        queue: controlQueue,
        executablePath: Self.ioExecutablePath(),
    )

    private var listener: xpc_connection_t?
    private var peers: [UInt64: PeerRelay] = [:]
    private var nextPeerID: UInt64 = 1

    /// `ighostvtd-io` beside this executable: `/usr/libexec` on the device,
    /// `Contents/MacOS` in the Mac bundle, the same DerivedData products
    /// directory for the harness.
    private static func ioExecutablePath() -> String {
        guard let own = RuntimeEnvironment.currentExecutablePath(),
              let slash = own.lastIndex(of: "/")
        else { return IOWire.executableName }
        return String(own[...slash]) + IOWire.executableName
    }

    func start() throws {
        guard listener == nil else { return }
        if !supervisor.isRunning {
            try supervisor.start()
        }
        guard let listener = iGhostVTProtocol.serviceName.withCString({
            ighostvtCreateMachServiceListener(
                $0,
                controlQueue,
                PrivateSystemConstant.machServiceListener,
            )
        }) else {
            throw iGhostVTDaemonError.transportFailure
        }
        self.listener = listener

        xpc_connection_set_event_handler(listener) { [weak self] event in
            autoreleasepool {
                self?.accept(event)
            }
        }
        xpc_connection_activate(listener)
        DaemonLog.server.info(
            "listening on \(iGhostVTProtocol.serviceName, privacy: .public), pid \(getpid())",
        )
        DaemonFileLog.log(
            "listening on \(iGhostVTProtocol.serviceName), uid \(getuid()) euid \(geteuid())",
        )
    }

    private func accept(_ event: xpc_object_t) {
        guard xpc_get_type(event) == iGhostVTXPC.typeConnection else { return }
        guard let clientPID = authenticator.authenticate(event) else {
            DaemonFileLog.log("peer rejected, connection canceled")
            xpc_connection_cancel(event)
            return
        }

        let peerID = nextPeerID
        nextPeerID &+= 1
        let peer = PeerRelay(
            peerID: peerID,
            connection: event,
            clientPID: clientPID,
            queue: controlQueue,
            supervisor: supervisor,
        ) { [weak self] peer in
            self?.peerInvalidated(peer)
        }
        peers[peerID] = peer
        peer.activate()
        DaemonLog.server.info("peer \(clientPID) connected as \(peerID), \(self.peers.count) peer(s)")
        DaemonFileLog.log("peer \(clientPID) connected as peer \(peerID), \(peers.count) peer(s)")
    }

    /// The peer went away. Its sessions stay: detaching is not closing, and
    /// the next launch reattaches to them.
    private func peerInvalidated(_ peer: PeerRelay) {
        peers.removeValue(forKey: peer.peerID)
        DaemonLog.server.info("peer gone, \(self.peers.count) peer(s) remain")
        DaemonFileLog.log("peer \(peer.peerID) gone, \(peers.count) peer(s) remain")
    }
}
