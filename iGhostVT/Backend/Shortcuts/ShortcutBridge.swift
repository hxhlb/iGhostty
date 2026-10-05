//
//  ShortcutBridge.swift
//  iGhostVT
//

import Foundation
import UIKit

/// Where a foreground intent (or an `ighostvt://` link) meets the windows.
/// The app has one `TabManager` per scene, so every request here starts by
/// picking a scene: the one showing the session if a tab already has it,
/// the frontmost one otherwise. Nothing here talks to the daemon except
/// through the tabs — a headless intent uses `ShortcutDaemonClient`.
@MainActor
enum ShortcutBridge {
    /// How long a request launched into a cold app waits for the first
    /// window to connect. `openAppWhenRun` brings the app up before the
    /// intent performs, but the scene can still be a beat behind.
    private static let sceneWait: UInt64 = 3_000_000_000

    /// Every connected window's tabs, frontmost first.
    static func tabManagers() -> [TabManager] {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .sorted { rank($0) < rank($1) }
        return scenes.compactMap { ($0.delegate as? SceneDelegate)?.tabManager }
    }

    private static func rank(_ scene: UIWindowScene) -> Int {
        if isFrontmost(scene) {
            return 0
        }
        switch scene.activationState {
        case .foregroundActive: return 1
        case .foregroundInactive: return 2
        case .background: return 3
        case .unattached: return 4
        @unknown default: return 5
        }
    }

    /// Whether `scene` is the window in front. Every window on a Mac screen
    /// is `foregroundActive` at once; the one in front is the key window.
    private static func isFrontmost(_ scene: UIWindowScene) -> Bool {
        #if targetEnvironment(macCatalyst)
            scene.keyWindow?.isKeyWindow == true
        #else
            scene.activationState == .foregroundActive
        #endif
    }

    /// The frontmost window, waiting briefly for one to exist.
    private static func frontTabManager() async throws -> TabManager {
        let deadline = DispatchTime.now().uptimeNanoseconds + sceneWait
        while true {
            if let manager = tabManagers().first {
                return manager
            }
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                throw ShortcutError.noWindow
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// The tab attached to `sessionID`, in whichever window has it.
    private static func tab(for sessionID: UInt64) -> (TabManager, TerminalTab)? {
        for manager in tabManagers() {
            if let tab = manager.tabs.first(where: { $0.daemonSessionID == sessionID }) {
                return (manager, tab)
            }
        }
        return nil
    }

    /// Brings the session's tab to the front, attaching it to a new tab in
    /// the frontmost window when no tab has it. A session another window
    /// is showing brings that window forward.
    @discardableResult
    static func showSession(_ sessionID: UInt64) async throws -> TerminalTab {
        if let (manager, tab) = tab(for: sessionID) {
            manager.activate(tab)
            if let scene = manager.windowScene, !isFrontmost(scene) {
                UIApplication.shared.requestSceneSessionActivation(
                    scene.session,
                    userActivity: nil,
                    options: nil,
                    errorHandler: nil,
                )
            }
            return tab
        }
        let manager = try await frontTabManager()
        return manager.openTab(attachingTo: sessionID)
    }

    /// The frontmost window's active tab's session — what a new tab opened
    /// from a Shortcut inherits its directory from, as ⌘T would.
    static func activeSessionID() -> UInt64? {
        tabManagers().first?.activeTab?.daemonSessionID
    }

    /// Opens a plain new tab in the frontmost window, the way ⌘T does.
    static func openNewTab() async throws -> TerminalTab {
        let manager = try await frontTabManager()
        return manager.newTab()
    }

    /// Opens a tab on a paired device in the frontmost window (remote
    /// access): a fresh shell there.
    @discardableResult
    static func openRemoteTab(hostID: String) async throws -> TerminalTab {
        let manager = try await frontTabManager()
        return manager.newTab(.remote(hostID: hostID))
    }

    /// The same, for a terminal the device already has open.
    @discardableResult
    static func openRemoteTab(hostID: String, attachingTo sessionID: UInt64) async throws -> TerminalTab {
        let manager = try await frontTabManager()
        return manager.openRemoteTab(attachingTo: sessionID, hostID: hostID)
    }

    // MARK: - URLs

    /// `ighostvt://session/<id>` shows a session; `ighostvt://new` opens a
    /// tab. Anything else is ignored — the scheme exists so a Shortcut's
    /// Open URL, a widget, or another app can reach a session, and nothing
    /// typed into a URL ever reaches a shell.
    static func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "ighostvt" else { return }
        let host = url.host?.lowercased()
        let path = url.pathComponents.filter { $0 != "/" }
        Task { @MainActor in
            switch host {
            case "session":
                guard let first = path.first, let id = UInt64(first) else { return }
                _ = try? await showSession(id)
            case "new":
                _ = try? await openNewTab()
            default:
                return
            }
        }
    }
}
