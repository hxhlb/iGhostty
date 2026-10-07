import Combine
import SwiftUI
import UIKit

/// Taking a relay configuration (`.vtrpsc`) in, from a double-click or a
/// share (`SceneDelegate`). The file is read and checked here, then
/// Settings ▸ Remote Access opens — where the relay lives — and asks there:
/// use it, or replace the one in use. Only a yes saves it.
///
/// Never asked over a terminal: alerts do not stack, so a question raised
/// there took down whatever a tab was already asking (a program's clipboard
/// request, a close confirmation) as if it had been refused, and the answer
/// left nothing on screen to show the relay had been taken.
@MainActor
enum RelayImport {
    /// What an opened file has to ask.
    enum Request {
        case review(RelayConfiguration)
        /// The file is no relay configuration; the reason, to show.
        case unusable(String)
    }

    /// The file opened last and not yet answered, which Settings asks
    /// about (`relayImportPrompt`); nil once answered. A second file opened
    /// before the first is answered replaces it.
    static let pending = CurrentValueSubject<Request?, Never>(nil)

    /// How many Remote Access pages are on screen (`RemoteAccessView`
    /// counts itself), so the settings sheet pushes one only when none is.
    static var remoteAccessOnScreen = 0

    static func isConfiguration(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == RelayConfiguration.fileExtension
    }

    /// Reads `url` and brings up Settings ▸ Remote Access to ask about it:
    /// in `window` on iPhone and iPad, in the settings window on the Mac.
    static func open(_ url: URL, in window: UIWindow?) {
        let request = read(url)
        #if targetEnvironment(macCatalyst)
            pending.send(request)
            SettingsWindow.open(showing: .remote)
        #else
            guard let window = (window ?? keyWindow) as? TerminalWindow else { return }
            waiting = request
            waitingWindow = window
            deliver()
        #endif
    }

    private static func read(_ url: URL) -> Request {
        let isScoped = url.startAccessingSecurityScopedResource()
        let data = try? Data(contentsOf: url)
        if isScoped {
            url.stopAccessingSecurityScopedResource()
        }
        // A copy shared into the app lands in Documents/Inbox; it holds a
        // private key and has no business staying there. A file opened in
        // place is the person's own and stays where it is.
        if url.path.contains("/Documents/Inbox/") {
            try? FileManager.default.removeItem(at: url)
        }
        do {
            guard let data else { throw RelayConfiguration.ParseError.notConfiguration }
            let configuration = try RelayConfiguration(data: data)
            AppLog.info(.transport, "opened a relay configuration for \(configuration.name) at \(configuration.endpointDescription)")
            return .review(configuration)
        } catch {
            AppLog.info(.transport, "opened a file that is not a usable relay configuration: \(error)")
            return .unusable(error.localizedDescription)
        }
    }

    #if !targetEnvironment(macCatalyst)
        /// A request whose window is busy asking something else, and that
        /// window; a window closed meanwhile takes the request with it.
        private static var waiting: Request?
        private static weak var waitingWindow: TerminalWindow?
        private static var alertObserver: NSObjectProtocol?

        /// Hands the request to Settings once the window is free. An alert
        /// already up is waited for, never taken down: the question a tab
        /// asked is answered first, and the relay is asked about after it.
        private static func deliver() {
            guard let request = waiting else { return }
            guard let window = waitingWindow else {
                waiting = nil
                return
            }
            guard !AlertViewController.isShowing(in: window) else {
                if alertObserver == nil {
                    alertObserver = NotificationCenter.default.addObserver(
                        forName: AlertViewController.didDisappear,
                        object: nil,
                        queue: .main,
                    ) { _ in
                        // A turn later: the alert's presenter lets go of it
                        // after this, not before.
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated { deliver() }
                        }
                    }
                }
                return
            }
            waiting = nil
            pending.send(request)
            showSettings(in: window, attempt: 0)
        }

        /// Opens the settings sheet; one already up takes the request where
        /// it is (`SettingsSheet` pushes Remote Access and asks). The sheet
        /// hangs off the window's root, which presents one thing at a time,
        /// so the switcher's cover is closed first, and whatever else is in
        /// the way — the cover on its way out, a share sheet — is waited
        /// out for a few seconds. Past that the request stays, and Settings
        /// asks about it the next time it opens.
        private static func showSettings(in window: TerminalWindow, attempt: Int) {
            guard pending.value != nil else { return }
            let interface = window.interface
            guard !interface.showsSettingsSheet else { return }
            if interface.showsSwitcher {
                interface.showsSwitcher = false
            }
            guard window.rootViewController?.presentedViewController == nil else {
                guard attempt < 20 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    MainActor.assumeIsolated { showSettings(in: window, attempt: attempt + 1) }
                }
                return
            }
            interface.showsSettingsSheet = true
        }

        private static var keyWindow: UIWindow? {
            let windows = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
            return windows.first(where: \.isKeyWindow) ?? windows.first
        }
    #endif

    /// The question for `request`. Every answer calls `finish`.
    fileprivate static func alert(for request: Request, finish: @escaping () -> Void) -> AlertViewController {
        let configuration: RelayConfiguration
        switch request {
        case let .unusable(message):
            let alert = AlertViewController(
                title: "Unable to Use This Relay",
                message: "\(message)",
                actions: [AlertAction("Done", kind: .highlighted, handler: finish)],
            )
            alert.onDismissUnanswered = finish
            return alert
        case let .review(reviewed):
            configuration = reviewed
        }

        let current = RelayConfigurationStore.current
        if current == configuration {
            let alert = AlertViewController(
                title: "Relay Already in Use",
                message: "This device already uses “\(configuration.name)”.",
                actions: [AlertAction("Done", kind: .highlighted, handler: finish)],
            )
            alert.onDismissUnanswered = finish
            return alert
        }
        let cancel = AlertAction("Cancel", handler: finish)
        let save = AlertAction("Use Relay", kind: .highlighted) {
            finish()
            do {
                try RelayConfigurationStore.save(configuration)
            } catch {
                AppLog.error(.transport, "could not save the relay configuration: \(error)")
            }
        }
        // Same relay and key: only the address moved. A rotated key is a
        // new configuration even under the same relay id.
        if let current, current.relayID == configuration.relayID, current.key == configuration.key {
            return AlertViewController(
                title: "Update the Relay “\(configuration.name)”?",
                message: "Its address becomes \(configuration.endpointDescription).",
                actions: [cancel, save],
            )
        } else if let current {
            return AlertViewController(
                title: "Replace the Relay “\(current.name)”?",
                message: "This device will use “\(configuration.name)” at \(configuration.endpointDescription) instead. Devices reach each other through it when they are not on the same network.",
                actions: [cancel, save],
            )
        } else {
            return AlertViewController(
                title: "Use the Relay “\(configuration.name)”?",
                message: "Devices with remote access reach each other through \(configuration.endpointDescription) when they are not on the same network. Paired devices still need their pairing.",
                actions: [cancel, save],
            )
        }
    }
}

extension View {
    /// Asks about the relay file opened last (`RelayImport.pending`), in
    /// this view's window. One per settings presentation — the iPhone and
    /// iPad sheet, the Mac's Remote pane — so a file is asked about once
    /// however deep the sheet's navigation is.
    func relayImportPrompt() -> some View {
        modifier(WindowAlertPresenter(
            requests: RelayImport.pending,
            onFinish: { RelayImport.pending.send(nil) },
            makeAlert: { request, finish in RelayImport.alert(for: request, finish: finish) },
        ))
    }
}
