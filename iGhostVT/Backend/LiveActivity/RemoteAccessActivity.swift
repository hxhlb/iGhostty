//
//  RemoteAccessActivity.swift
//  iGhostVT
//

import UIKit

/// Keeps the Live Activity's remote-access line true: asks the daemon as
/// the app comes forward, and every quarter minute while it stays there
/// and remote access is on (the connected count moves). The settings page
/// hands over every answer it gets as well. With remote access off the
/// answer is nil and the activity goes back to sessions only.
@MainActor
enum RemoteAccessActivity {
    private static var poll: Task<Void, Never>?
    private static var observers: [NSObjectProtocol] = []

    static func start() {
        #if !targetEnvironment(macCatalyst)
            guard observers.isEmpty else { return }
            let center = NotificationCenter.default
            observers.append(center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main,
            ) { _ in
                MainActor.assumeIsolated { resume() }
            })
            observers.append(center.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main,
            ) { _ in
                MainActor.assumeIsolated {
                    poll?.cancel()
                    poll = nil
                }
            })
        #endif
    }

    /// An answer from anywhere — the settings page has fresher ones than
    /// the poll.
    static func note(_ status: RemoteAccessStatus) {
        SessionActivityController.shared.remoteAccess = status.isEnabled && !status.isUnavailable ? status : nil
        HostSessionWatcher.shared.update(status)
    }

    private static func resume() {
        poll?.cancel()
        poll = Task {
            while !Task.isCancelled {
                let status = await RemoteAccessControl.status()
                note(status)
                guard status.isEnabled else { return }
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }
}
