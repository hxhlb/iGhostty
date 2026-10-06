//
//  NewTabMenuElements.swift
//  iGhostVT
//

import SwiftUI
import UIKit

/// The new-tab menu in UIKit, built at the moment it opens.
///
/// A SwiftUI `Menu` is built from what its view knew at its last render: a
/// paired device's terminals as the last half-minute poll found them, and
/// rows marked open here for tabs closed since. A deferred element asks
/// first — the paired devices answer, or a short wait runs out — and then
/// lists what is true now. The standalone `+` controls (`NewTabMenu`) and
/// the Mac's File ▸ New Tab on Device are built from it; only the ⋯ menu's
/// submenu, a SwiftUI menu inside a SwiftUI menu, still renders from the
/// catalog's last answer.
@MainActor
enum NewTabMenuElements {
    /// How long an opening menu waits for the devices' lists before it
    /// shows what it has; a device that answers later is in the next one.
    private static let refreshWait: UInt64 = 1_500_000_000

    /// The whole menu for one window, asked fresh on every opening.
    static func deferred(tabManager: TabManager, onOpen: @escaping () -> Void) -> UIMenuElement {
        UIDeferredMenuElement.uncached { [weak tabManager] completion in
            Task { @MainActor in
                await refreshRemoteSessions()
                guard let tabManager else {
                    completion([])
                    return
                }
                completion(elements(tabManager: tabManager, onOpen: onOpen))
            }
        }
    }

    /// Starts every paired device's list and returns when they have all
    /// answered or `refreshWait` has passed, whichever is first. The asking
    /// carries on past the wait and lands in the catalog.
    static func refreshRemoteSessions() async {
        RemoteHostDirectory.shared.start()
        guard !RemoteHostDirectory.shared.reachablePaired.isEmpty else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let gate = ResumeOnce(continuation)
            Task { @MainActor in
                await RemoteSessionCatalog.shared.refresh()
                gate.resume()
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: refreshWait)
                gate.resume()
            }
        }
    }

    /// The rows `NewTabMenuContent` lists, in the same order and groups.
    static func elements(tabManager: TabManager, onOpen: @escaping () -> Void) -> [UIMenuElement] {
        let choices = NewTabDirectoryChoices(
            tabManager: tabManager,
            recents: RecentDirectoryStore.shared,
            remoteHosts: RemoteHostDirectory.shared,
            remoteSessions: RemoteSessionCatalog.shared,
        )
        func row(_ title: String, _ systemImage: String, _ origin: TabManager.Origin) -> UIAction {
            UIAction(title: title, image: UIImage(systemName: systemImage)) { [weak tabManager] _ in
                tabManager?.newTab(origin)
                onOpen()
            }
        }
        var elements: [UIMenuElement] = [
            UIMenu(title: "", options: .displayInline, children: [
                row(
                    String(
                        localized: "Home (directory)",
                        comment: "Menu item: opens a terminal in the home directory; the English text is “Home”",
                    ),
                    "house",
                    .home,
                ),
            ]),
        ]
        if !choices.openTabs.isEmpty {
            elements.append(UIMenu(
                title: String(localized: "Open Tabs"),
                options: .displayInline,
                children: choices.openTabs.map { row($0.directory.label, "macwindow", .session($0.sessionID)) },
            ))
        }
        if !choices.recents.isEmpty {
            elements.append(UIMenu(
                title: String(localized: "Recent"),
                options: .displayInline,
                children: choices.recents.map { row($0.label, "clock", .directory($0)) },
            ))
        }
        let hosts = remoteHostElements(
            hosts: choices.remoteHosts,
            sessions: choices.remoteSessions,
            isOpenHere: { host, session in
                tabManager.tabs.contains { $0.remoteHostID == host.id && $0.remoteSessionID == session.id }
            },
            openFresh: { [weak tabManager] hostID, directory in
                tabManager?.newTab(.remote(hostID: hostID, directory: directory))
                onOpen()
            },
            attach: { [weak tabManager] hostID, sessionID in
                tabManager?.openRemoteTab(attachingTo: sessionID, hostID: hostID)
                onOpen()
            },
        )
        if !hosts.isEmpty {
            elements.append(UIMenu(title: String(localized: "Other Devices"), options: .displayInline, children: hosts))
        }
        return elements
    }

    /// One submenu per paired device. Shared with the Mac's File ▸ New Tab
    /// on Device.
    static func remoteHostElements(
        hosts: [PairedRemoteHost],
        sessions: [String: [XPCDaemonTransport.SessionSummary]],
        isOpenHere: @escaping (PairedRemoteHost, XPCDaemonTransport.SessionSummary) -> Bool,
        openFresh: @escaping (String, TerminalDirectory?) -> Void,
        attach: @escaping (String, UInt64) -> Void,
    ) -> [UIMenuElement] {
        hosts.map { host in
            let fresh = UIAction(
                title: String(localized: "New Terminal", comment: "Menu item: a fresh shell on another device"),
                image: UIImage(systemName: "plus"),
            ) { _ in openFresh(host.id, nil) }
            let recents = RecentDirectoryStore.shared.menuDirectories(onHost: host.id).map { directory in
                UIAction(title: directory.label, image: UIImage(systemName: "clock")) { _ in
                    openFresh(host.id, directory)
                }
            }
            let open = (sessions[host.id] ?? []).map { session in
                let action = UIAction(
                    title: session.menuTitle,
                    image: UIImage(systemName: isOpenHere(host, session) ? "checkmark" : "terminal"),
                ) { _ in attach(host.id, session.id) }
                if #available(iOS 16.0, *) {
                    action.subtitle = session.menuSubtitle
                }
                return action
            }
            var children: [UIMenuElement] = [fresh]
            if !recents.isEmpty {
                children.append(UIMenu(title: String(localized: "Recent"), options: .displayInline, children: recents))
            }
            if !open.isEmpty {
                children.append(UIMenu(title: String(localized: "Open Terminals"), options: .displayInline, children: open))
            }
            return UIMenu(title: host.displayName, image: UIImage(systemName: "network"), children: children)
        }
    }
}

/// Resumes its continuation the first time it is asked, and never again.
@MainActor
private final class ResumeOnce {
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

/// A transparent button over a SwiftUI label that opens the deferred menu
/// on a tap — what lets `NewTabMenu` keep its label views while the menu
/// itself is UIKit's.
struct NewTabMenuAnchor: UIViewRepresentable {
    let tabManager: TabManager
    let onOpen: () -> Void

    func makeUIView(context _: Context) -> UIButton {
        let button = UIButton(type: .custom)
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = String(localized: "New Tab")
        return button
    }

    func updateUIView(_ button: UIButton, context _: Context) {
        button.menu = UIMenu(children: [NewTabMenuElements.deferred(tabManager: tabManager, onOpen: onOpen)])
    }
}

extension XPCDaemonTransport.SessionSummary {
    /// The first line a menu gives the terminal: the title its tab shows
    /// on the device holding it, word for word — else what is running.
    var menuTitle: String {
        if let title {
            return title
        }
        if let processName, !processName.isEmpty {
            return processName
        }
        return directory?.label ?? String(localized: "Terminal")
    }

    /// The second line, as that tab's own second line reads: the process
    /// in front, or, where the process is already the title, where it is.
    var menuSubtitle: String? {
        if title != nil, let processName, !processName.isEmpty {
            return processName
        }
        return directory?.label
    }
}
