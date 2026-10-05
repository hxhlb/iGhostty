//
//  TerminalSessionAttributes.swift
//  iGhostVT
//
//  Compiled into both the app and the widget extension; the Live Activity's
//  payload contract between the two.
//

#if canImport(ActivityKit)
    import ActivityKit
#endif
import Foundation

/// The ActivityKit conformance is added below, off Catalyst only: the
/// framework imports there but `ActivityAttributes` itself is unavailable,
/// and the payload still has to compile into the Mac development build.
@available(iOS 16.2, *)
struct TerminalSessionAttributes {
    /// One open tab, as the Live Activity lists it.
    ///
    /// Everything here is presentation-ready: the app resolves paths and
    /// connection states before encoding, because the widget process cannot
    /// reach the app's model and an ActivityKit payload is small.
    struct Session: Codable, Hashable, Identifiable {
        enum Status: Int, Codable, Hashable {
            /// Opening or reattaching — no shell on the other end yet.
            case starting
            /// A live shell.
            case live
            /// The transport gave up; the tab is showing an error.
            case failed
        }

        /// The tab's identity, stable across updates so rows keep their place.
        var id: String
        /// What the shell called itself via OSC 0/2, empty when it never did.
        /// Deliberately not the transport's endpoint string — "ighostvtd
        /// session 3" is plumbing, not a title.
        var title: String
        /// OSC 7, already collapsed against the shell's home. Empty when the
        /// shell doesn't report it.
        var directory: String
        /// Basename of the configured shell, when the app picked one. Empty
        /// when the daemon chose, because then the app doesn't know.
        var shell: String
        /// The foreground program's name as the daemon reports it (event
        /// 102) — "zsh", "vim" — short and stable however the program
        /// retitles. Optional so a payload from a build without it decodes.
        var process: String?
        /// The daemon's session number, the last resort for naming a row.
        var number: UInt64?
        var status: Status
        /// The frontmost tab of its window.
        var isActive: Bool
    }

    /// This device's remote access while it is on — the reason the
    /// activity stays up with no session at all: a device that others can
    /// reach says so where its owner looks.
    struct RemoteAccess: Codable, Hashable {
        /// What other devices see this one as.
        var hostName: String
        /// Paired devices connected right now.
        var connectedCount: Int
        /// A pairing window is open.
        var isPairing: Bool
    }

    struct ContentState: Codable, Hashable {
        /// The listed sessions, capped so the payload stays small.
        var sessions: [Session]
        /// Open tabs past the cap.
        var overflowCount: Int
        /// Daemon sessions no window is showing — detached, still running.
        var detachedCount: Int
        /// Remote access, when it is on. Optional so a payload from a build
        /// without it decodes.
        var remoteAccess: RemoteAccess? = nil

        var totalCount: Int {
            sessions.count + overflowCount + detachedCount
        }
    }
}

#if !targetEnvironment(macCatalyst) && canImport(ActivityKit)
    @available(iOS 16.2, *)
    extension TerminalSessionAttributes: ActivityAttributes {}
#endif
