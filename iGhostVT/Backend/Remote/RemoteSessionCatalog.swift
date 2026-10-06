import Combine
import UIKit

/// The terminals each paired device has open, for the new-tab menu: pick
/// one and it opens here (`TabManager.openRemoteTab`).
///
/// A SwiftUI menu is built from what is known when it opens, so the lists
/// are asked for ahead of time — as the app comes forward, and every half
/// minute while it stays there with a device to ask. Each ask is a fresh
/// connection to the device, so not more often than that. A device that does
/// not answer keeps its last list until it does.
@MainActor
final class RemoteSessionCatalog: ObservableObject {
    static let shared = RemoteSessionCatalog()

    @Published private(set) var sessions: [String: [XPCDaemonTransport.SessionSummary]] = [:]

    private var poll: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var subscriptions: Set<AnyCancellable> = []
    private static let interval: UInt64 = 30_000_000_000

    private init() {
        // A device the browser has just found is asked at once, rather
        // than at the next poll: the first one ran at launch, before
        // Bonjour had answered.
        RemoteHostDirectory.shared.$hosts
            .combineLatest(RemoteHostDirectory.shared.$paired)
            .map { _, _ in RemoteHostDirectory.shared.reachablePaired.map(\.id) }
            .removeDuplicates()
            .dropFirst()
            .sink { _ in
                Task { @MainActor in await RemoteSessionCatalog.shared.refresh() }
            }
            .store(in: &subscriptions)
        // The Mac's menu bar keeps a deferred menu's first answer; a
        // rebuild is what makes it ask again (`AppMenus.remoteTabMenu`).
        $sessions
            .map { _ in () }
            .merge(with: RemoteHostDirectory.shared.$hosts.map { _ in () })
            .merge(with: RemoteHostDirectory.shared.$paired.map { _ in () })
            .merge(with: RecentDirectoryStore.shared.$remoteEntries.map { _ in () })
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { _ in
                UIMenuSystem.main.setNeedsRebuild()
            }
            .store(in: &subscriptions)
    }

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main,
        ) { _ in
            MainActor.assumeIsolated { RemoteSessionCatalog.shared.resume() }
        })
        observers.append(center.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main,
        ) { _ in
            MainActor.assumeIsolated { RemoteSessionCatalog.shared.pause() }
        })
        resume()
    }

    private func resume() {
        guard poll == nil else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: Self.interval)
            }
        }
    }

    private func pause() {
        poll?.cancel()
        poll = nil
    }

    /// Asks every paired device worth offering, all at once.
    func refresh() async {
        let hosts = RemoteHostDirectory.shared.reachablePaired
        guard !hosts.isEmpty else {
            sessions = [:]
            return
        }
        await withTaskGroup(of: (String, [XPCDaemonTransport.SessionSummary]?).self) { group in
            for host in hosts {
                group.addTask {
                    await (host.id, Self.list(hostID: host.id))
                }
            }
            for await (hostID, rows) in group {
                if let rows, sessions[hostID] != rows {
                    sessions[hostID] = rows
                }
            }
        }
        // A device no longer offered takes its list with it.
        let offered = Set(hosts.map(\.id))
        for hostID in sessions.keys where !offered.contains(hostID) {
            sessions.removeValue(forKey: hostID)
        }
    }

    private nonisolated static func list(hostID: String) async -> [XPCDaemonTransport.SessionSummary]? {
        await withCheckedContinuation { continuation in
            XPCDaemonTransport.listSessions(at: .remote(hostID: hostID)) { rows in
                continuation.resume(returning: rows)
            }
        }
    }
}

extension XPCDaemonTransport.SessionSummary: Identifiable {}
