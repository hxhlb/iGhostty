//
//  TabAttributes.swift
//  iGhostVT
//

import Combine
import Foundation

/// Which of a tab's two locks is on (`TabAttributes.lock`). They are
/// exclusive: a tab has one lock or none.
enum TabLock: Equatable {
    /// The surface refuses every interaction — touches and keyboard focus.
    case interaction
    /// Only the software keyboard is refused.
    case keyboard

    /// The lock as the daemon keeps it on the session
    /// (`iGhostVTSessionAttribute.lock`), which is how it outlives the app.
    var sessionAttribute: String {
        switch self {
        case .interaction: iGhostVTSessionAttribute.interactionLock
        case .keyboard: iGhostVTSessionAttribute.keyboardLock
        }
    }

    /// The lock a session's attribute names; `nil` for none, or for a
    /// value this build does not know.
    init?(sessionAttribute: String?) {
        switch sessionAttribute {
        case iGhostVTSessionAttribute.interactionLock: self = .interaction
        case iGhostVTSessionAttribute.keyboardLock: self = .keyboard
        default: return nil
        }
    }

    /// The word every presentation labels this lock with — the badge's
    /// accessibility text, and the overlay capsule's caption.
    var badgeTitle: String {
        switch self {
        case .interaction: String(localized: "Locked")
        case .keyboard: String(localized: "Keyboard Locked")
        }
    }
}

/// What the user has set on a tab, as opposed to what its session reports
/// about itself — the one place a per-tab user choice lives.
///
/// Its own observable object, apart from `TerminalTab`, on purpose: the tab
/// republishes on every retitle, and a program that retitles as it prints
/// (or a page that keeps changing) would otherwise re-evaluate every view
/// that only wants these — above all the tab's context menu, which UIKit
/// rebuilds whenever SwiftUI hands it new content, so an open menu flickered
/// grey and dropped taps for as long as the terminal printed. These change
/// only when the user changes them.
@MainActor
final class TabAttributes: ObservableObject {
    /// The tab's lock, if any — one of the two, never both. Either freezes
    /// the *user*, never the program: the session keeps running, output
    /// keeps flowing, and the surface keeps rendering. `interaction` makes
    /// the surface's view refuse touches and keyboard focus
    /// (`LockableTerminalView.isInteractionLocked`); `keyboard` only keeps
    /// the software keyboard down (`isSoftwareKeyboardLocked`) while
    /// touches, scrolling, selection, and hardware keys still work.
    /// The tab's context menu and the main menu are the ways in and out:
    /// choosing the lock that is on removes it, choosing the other one
    /// switches to it.
    @Published var lock: TabLock?

    /// The interaction lock as a flag — what the presentations badge and
    /// what the menus toggle. Setting it on replaces a keyboard lock;
    /// setting it off clears nothing but itself.
    var isLocked: Bool {
        get { lock == .interaction }
        set { setLock(.interaction, on: newValue) }
    }

    /// The keyboard lock as a flag, with the same exclusive semantics as
    /// `isLocked`.
    var isKeyboardLocked: Bool {
        get { lock == .keyboard }
        set { setLock(.keyboard, on: newValue) }
    }

    private func setLock(_ kind: TabLock, on: Bool) {
        if on {
            lock = kind
        } else if lock == kind {
            lock = nil
        }
    }
}
