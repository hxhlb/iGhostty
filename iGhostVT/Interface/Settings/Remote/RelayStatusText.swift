import SwiftUI
import UniformTypeIdentifiers

/// The relay configuration's file type, for the pickers.
enum RelayImportType {
    static let type = UTType(exportedAs: RelayConfiguration.typeIdentifier, conformingTo: .json)
}

/// One line on how the relay is doing, for the settings on both platforms:
/// this device's registration while remote access is on, and whether the
/// relay answered the last time this device asked it for its hosts.
@MainActor
enum RelayStatusText {
    static func describe(_ status: RemoteAccessStatus, directory: RemoteHostDirectory) -> (text: String, isProblem: Bool)? {
        if let problem = directory.relayProblem {
            switch problem {
            case let .version(relay):
                return (String.localizedStringWithFormat(
                    NSLocalizedString(
                        "The relay runs protocol %1$lld, this device needs %2$lld. Update the relay or iGhostVT.",
                        comment: "Relay status; two protocol version numbers",
                    ),
                    relay,
                    RelayControl.protocolVersion,
                ), true)
            case .refused:
                return (String(localized: "The relay did not accept this configuration. Import the current one."), true)
            case .unreachable, .malformed:
                return (String(localized: "Unable to reach the relay"), true)
            }
        }
        guard status.isEnabled, status.relayFingerprint == RelayConfigurationStore.fingerprint else {
            return (String(localized: "Connected"), false)
        }
        switch status.relayState {
        case .registered:
            return (String(localized: "Connected, this device is reachable"), false)
        case .connecting, .off:
            return (String(localized: "Connecting…"), false)
        case .failed:
            return (String(localized: "Unable to reach the relay"), true)
        case .conflict:
            return (String(localized: "Another device is registered as this one"), true)
        case .versionMismatch:
            return (String(localized: "The relay runs another version. Update the relay or iGhostVT."), true)
        }
    }
}
