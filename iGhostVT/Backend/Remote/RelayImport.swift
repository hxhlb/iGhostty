import UIKit

/// Taking a relay configuration (`.vtrpsc`) in: from a double-click or a
/// share (`SceneDelegate`), or from Settings' file picker. The file is read
/// and checked first, then the person is asked — use it, or replace the one
/// in use — and only a yes saves it.
@MainActor
enum RelayImport {
    static func isConfiguration(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == RelayConfiguration.fileExtension
    }

    static func open(_ url: URL, in window: UIWindow?) {
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
        guard let window = window ?? keyWindow else { return }
        let configuration: RelayConfiguration
        do {
            guard let data else { throw RelayConfiguration.ParseError.notConfiguration }
            configuration = try RelayConfiguration(data: data)
        } catch {
            AlertViewController(
                title: "Unable to Use This Relay",
                message: "\(error.localizedDescription)",
                actions: [AlertAction("Done", kind: .highlighted)],
            ).present(in: window)
            return
        }
        confirm(configuration, in: window)
    }

    private static func confirm(_ configuration: RelayConfiguration, in window: UIWindow) {
        let current = RelayConfigurationStore.current
        if current == configuration {
            AlertViewController(
                title: "Relay Already in Use",
                message: "This device already uses “\(configuration.name)”.",
                actions: [AlertAction("Done", kind: .highlighted)],
            ).present(in: window)
            return
        }
        let save = AlertAction("Use Relay", kind: .highlighted) {
            do {
                try RelayConfigurationStore.save(configuration)
            } catch {
                AppLog.error(.transport, "could not save the relay configuration: \(error)")
            }
        }
        let alert: AlertViewController
        // Same relay and key: only the address moved. A rotated key is a
        // new configuration even under the same relay id.
        if let current, current.relayID == configuration.relayID, current.key == configuration.key {
            alert = AlertViewController(
                title: "Update the Relay “\(configuration.name)”?",
                message: "Its address becomes \(configuration.endpointDescription).",
                actions: [AlertAction("Cancel"), save],
            )
        } else if let current {
            alert = AlertViewController(
                title: "Replace the Relay “\(current.name)”?",
                message: "This device will use “\(configuration.name)” at \(configuration.endpointDescription) instead. Devices reach each other through it when they are not on the same network.",
                actions: [AlertAction("Cancel"), save],
            )
        } else {
            alert = AlertViewController(
                title: "Use the Relay “\(configuration.name)”?",
                message: "Devices with remote access reach each other through \(configuration.endpointDescription) when they are not on the same network. Paired devices still need their pairing.",
                actions: [AlertAction("Cancel"), save],
            )
        }
        alert.present(in: window)
    }

    private static var keyWindow: UIWindow? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first
    }
}
