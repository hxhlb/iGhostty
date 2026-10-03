//
//  TabWindowMove.swift
//  iGhostVT
//

import Foundation
import UIKit

/// Moving a tab into a window of its own. What moves is the daemon
/// session, never a shell: the new window is an ordinary scene that
/// attaches to the session by id, and the window the tab came from detaches
/// it — `disconnect`, not `closeSession` — and drops the tab. The replay
/// buffer repaints the earlier output and the attach reply's attributes
/// bring the lock back, exactly as for a tab reattached at launch.
///
/// The request is an `NSUserActivity` naming the session, the shape both
/// ways in arrive in: the context menu's Move to New Window asks for a
/// scene with it, and a tab dragged out of the sidebar or the iPad strip
/// carries it, which is what lets iPadOS turn a drop beside the window
/// into a new one. Either way the new scene finds it among its connection
/// options and does the whole hand-off itself (`SceneDelegate`), so the
/// source window learns of the move only when the move is real — a drag
/// that ends anywhere else leaves the tab where it was.
///
/// Attach is exclusive. The source's detach and the new window's attach
/// travel on two connections with nothing ordering them, so an attach
/// that lands first is answered `sessionBusy` and tried again for a
/// moment (`XPCDaemonTransport.openOrAttachSession`).
@MainActor
enum TabWindowMove {
    /// Declared in Info.plist (`NSUserActivityTypes`); the system hands a
    /// scene only the activity types its app lists.
    static let activityType = "wiki.qaq.ighostvt.move-tab"
    private static let sessionKey = "session"
    /// Where the new window's top-left corner goes, in AppKit screen
    /// coordinates: under the pointer that dragged the tab out. Absent for
    /// the menu's request, which leaves placement to the system.
    private static let originXKey = "originX"
    private static let originYKey = "originY"

    /// Whether this device opens windows at all. A phone runs one scene,
    /// and the request would do nothing there.
    static var isAvailable: Bool {
        UIApplication.shared.supportsMultipleScenes
    }

    /// Whether `tab` can move now: it has a session to hand over, and it is
    /// not the window's only tab — moving that one would trade the window
    /// for an identical one.
    static func canMove(_ tab: TerminalTab, in tabManager: TabManager) -> Bool {
        isAvailable && tab.daemonSessionID != nil && tabManager.tabs.count > 1
    }

    /// The activity that asks for `tab`'s session in a new window; `nil`
    /// when the tab cannot move.
    static func activity(for tab: TerminalTab, in tabManager: TabManager) -> NSUserActivity? {
        guard canMove(tab, in: tabManager), let sessionID = tab.daemonSessionID else { return nil }
        let activity = NSUserActivity(activityType: activityType)
        activity.title = tab.displayTitle
        activity.userInfo = [sessionKey: NSNumber(value: sessionID)]
        return activity
    }

    /// Opens the new window — from the context menu, or from a tab pulled
    /// out of the Mac strip, whose window then opens where it was dropped
    /// (`origin`). The hand-off happens in the new window.
    static func moveToNewWindow(_ tab: TerminalTab, from tabManager: TabManager, origin: CGPoint? = nil) {
        guard let activity = activity(for: tab, in: tabManager) else { return }
        if let origin {
            activity.userInfo?[originXKey] = NSNumber(value: Double(origin.x))
            activity.userInfo?[originYKey] = NSNumber(value: Double(origin.y))
        }
        let options = UIScene.ActivationRequestOptions()
        options.requestingScene = tabManager.windowScene
        AppLog.info(.tabs, "tab \(tab.id) asks for a new window, session \(tab.daemonSessionID.map(String.init) ?? "none")")
        UIApplication.shared.requestSceneSessionActivation(
            nil,
            userActivity: activity,
            options: options,
            errorHandler: { error in
                AppLog.error(.tabs, "new window for tab \(tab.id) refused: \(error.localizedDescription)")
            },
        )
    }

    /// The session a connecting scene was opened to hold, if it was opened
    /// for a move.
    static func sessionID(in activities: Set<NSUserActivity>) -> UInt64? {
        for activity in activities where activity.activityType == activityType {
            if let number = activity.userInfo?[sessionKey] as? NSNumber {
                return number.uint64Value
            }
        }
        return nil
    }

    /// Where the window opened for a move should put its top-left corner,
    /// if the request named a place.
    static func origin(in activities: Set<NSUserActivity>) -> CGPoint? {
        for activity in activities where activity.activityType == activityType {
            if let x = activity.userInfo?[originXKey] as? NSNumber,
               let y = activity.userInfo?[originYKey] as? NSNumber
            {
                return CGPoint(x: x.doubleValue, y: y.doubleValue)
            }
        }
        return nil
    }

    /// Whether `tab` can join another window: it has a session to hand
    /// over. Unlike a new window, a window's only tab may go — its window
    /// closes behind it.
    static func canMerge(_ tab: TerminalTab) -> Bool {
        isAvailable && tab.daemonSessionID != nil
    }

    /// Every window's tabs but `excluded`'s. A window closed at launch
    /// never took a scene (`SceneDelegate`) and is left out.
    static func otherWindows(than excluded: TabManager) -> [TabManager] {
        UIApplication.shared.connectedScenes
            .compactMap { ($0.delegate as? SceneDelegate)?.tabManager }
            .filter { $0 !== excluded && $0.windowScene != nil }
    }

    /// Moves `tab` into `destination`, a window already open: the same
    /// hand-off as a new window's, made here because no scene is being
    /// created to make it. The source detaches first; the destination's
    /// attach retries `sessionBusy` until that detach lands. A source left
    /// with no tab closes, and the destination comes forward.
    static func merge(_ tab: TerminalTab, from source: TabManager, into destination: TabManager) {
        guard canMerge(tab), let sessionID = tab.daemonSessionID else { return }
        AppLog.info(.tabs, "tab \(tab.id) joins another window, session \(sessionID)")
        source.handOff(tab)
        destination.openTab(attachingTo: sessionID)
        if let scene = destination.windowScene {
            UIApplication.shared.requestSceneSessionActivation(scene.session, userActivity: nil, options: nil)
        }
        if source.tabs.isEmpty, let scene = source.windowScene {
            UIApplication.shared.requestSceneSessionDestruction(scene.session, options: nil)
        }
    }

    /// Takes the session's tab out of whichever other window shows it —
    /// detached, so the shell is still there for `destination` to attach.
    static func releaseSource(of sessionID: UInt64, into destination: TabManager) {
        let managers = UIApplication.shared.connectedScenes
            .compactMap { ($0.delegate as? SceneDelegate)?.tabManager }
        for manager in managers where manager !== destination {
            if let tab = manager.tabs.first(where: { $0.daemonSessionID == sessionID }) {
                manager.handOff(tab)
                return
            }
        }
        AppLog.info(.tabs, "moved session \(sessionID) was in no open window")
    }
}
