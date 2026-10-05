import Foundation
import UIKit
@preconcurrency import XPC

/// This device as a host: keeps its windows in step with what paired
/// devices do to its terminals. A terminal a device opens here shows up as
/// a tab — never a shell running where nobody here can see it — and a tab
/// whose terminal a device took gets it back when the device lets go.
///
/// One connection to the daemon with `watchSessions`, held while remote
/// access is on and nowhere else: with it off, no device can open or take
/// anything. The switch is asked as the app starts and comes forward, and
/// every status the app reads anywhere is handed over (`update`).
///
/// An event can be missed — the link was down, or the switch went off as
/// the devices let go — so the windows are also squared with the daemon's
/// list (`reconcile`) whenever the link comes up, the app comes forward,
/// and shortly after the switch goes off.
@MainActor
final class HostSessionWatcher {
    static let shared = HostSessionWatcher()

    private var link: DaemonLink?
    private var isEnabled = false
    private var observer: NSObjectProtocol?
    private let queue = DispatchQueue(label: "wiki.qaq.ighostvt.client.watch", qos: .utility)

    private init() {}

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main,
        ) { _ in
            MainActor.assumeIsolated { HostSessionWatcher.shared.check() }
        }
        check()
    }

    /// A status read anywhere: the switch is what decides.
    func update(_ status: RemoteAccessStatus) {
        guard !status.isUnavailable else { return }
        RemoteHostDirectory.shared.noteOwnHostID(status.hostID)
        setEnabled(status.isEnabled)
    }

    private func check() {
        Task {
            update(await RemoteAccessControl.status())
            reconcile()
        }
    }

    private func setEnabled(_ enabled: Bool) {
        let wasEnabled = isEnabled
        isEnabled = enabled
        if enabled {
            connectIfNeeded()
        } else {
            link?.cancel()
            link = nil
            // The helper is stopping and its devices letting go, with no
            // link left to hear it: look once they have.
            if wasEnabled {
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    reconcile()
                }
            }
        }
    }

    private func connectIfNeeded() {
        guard link == nil, let link = XPCDaemonLink(queue: queue) else { return }
        self.link = link
        link.activate { event in
            switch event {
            case let .message(message):
                let box = EventBox(message)
                Task { @MainActor in HostSessionWatcher.shared.handle(box.message) }
            case .lost:
                Task { @MainActor in HostSessionWatcher.shared.lost(link) }
            }
        }
        let hello = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(hello, iGhostVTWireKey.version, iGhostVTProtocol.version)
        xpc_dictionary_set_uint64(hello, iGhostVTWireKey.operation, iGhostVTOperation.hello.rawValue)
        xpc_dictionary_set_bool(hello, iGhostVTWireKey.watchSessions, true)
        link.send(hello) { _ in
            Task { @MainActor in HostSessionWatcher.shared.reconcile() }
        }
    }

    /// Squares every window with the daemon's list: a tab held elsewhere
    /// whose session is free again takes it back, one whose session is
    /// gone closes, and a session a device holds that no window shows
    /// becomes a tab.
    func reconcile() {
        XPCDaemonTransport.listSessions { rows in
            Task { @MainActor in HostSessionWatcher.shared.apply(rows) }
        }
    }

    private func apply(_ rows: [XPCDaemonTransport.SessionSummary]?) {
        guard let rows else { return }
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let managers = ShortcutBridge.tabManagers()
        for manager in managers {
            for tab in manager.tabs where tab.store.isHeldElsewhere {
                guard let id = tab.daemonSessionID else { continue }
                if let row = byID[id] {
                    if !row.isAttached {
                        manager.reattachReleased(id)
                    }
                } else {
                    manager.closeEnded(id)
                }
            }
        }
        let shown = Set(managers.flatMap(\.tabs).compactMap(\.daemonSessionID))
        for row in rows where row.holder != nil && !shown.contains(row.id) {
            managers.first?.adoptHeldSession(row.id)
        }
    }

    /// The daemon went (an update, a crash): back once it is, while the
    /// switch is still on.
    private func lost(_ dead: DaemonLink) {
        guard link === dead else { return }
        dead.cancel()
        link = nil
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if isEnabled {
                connectIfNeeded()
            }
        }
    }

    private func handle(_ message: xpc_object_t) {
        guard xpc_get_type(message) == iGhostVTXPC.typeDictionary,
              let event = iGhostVTEvent(rawValue: xpc_dictionary_get_uint64(message, iGhostVTWireKey.event))
        else { return }
        let sessionID = xpc_dictionary_get_uint64(message, iGhostVTWireKey.sessionID)
        switch event {
        case .sessionOpened:
            let holder = xpc_dictionary_get_string(message, iGhostVTWireKey.holder).map { String(cString: $0) } ?? ""
            showOpened(sessionID, holder: holder)
        case .sessionReleased:
            for manager in ShortcutBridge.tabManagers() {
                manager.reattachReleased(sessionID)
            }
        case .sessionExit:
            for manager in ShortcutBridge.tabManagers() {
                manager.closeEnded(sessionID)
            }
        case .output, .processName, .sessionTaken:
            break
        }
    }

    /// A device holds a terminal here now — it opened it, or took it: a
    /// tab for it in the frontmost window, or the tab that shows it names
    /// the device. A launch with no window yet finds it among the sessions
    /// it claims.
    private func showOpened(_ sessionID: UInt64, holder: String) {
        let managers = ShortcutBridge.tabManagers()
        if let tab = managers.flatMap(\.tabs).first(where: { $0.daemonSessionID == sessionID }) {
            tab.store.noteHolder(holder)
            return
        }
        managers.first?.adoptHeldSession(sessionID)
    }
}

private struct EventBox: @unchecked Sendable {
    let message: xpc_object_t
    init(_ message: xpc_object_t) {
        self.message = message
    }
}
