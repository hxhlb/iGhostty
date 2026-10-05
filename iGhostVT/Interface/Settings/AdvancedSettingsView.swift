//
//  AdvancedSettingsView.swift
//  iGhostVT
//

import GhosttyTerminal
import SwiftUI

/// What only troubleshooting needs, off the main sheet so it doesn't read
/// as something to fill in: the keystroke-level log and the way into the
/// logs. The Mac has its own pane for this (`MacSettingsPanes`), with the
/// background helper's status beside it.
struct AdvancedSettingsView: View {
    @AppStorage(DetailedTerminalLog.key) private var verboseTerminalLog = false

    var body: some View {
        Form {
            debugSection
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The keystroke log's switch and the way into the logs themselves —
    /// what the switch writes lands there, beside everything else the app
    /// and its helper record.
    private var debugSection: some View {
        Section {
            Toggle("Detailed Terminal Log", isOn: $verboseTerminalLog)
                .onChange(of: verboseTerminalLog, perform: DetailedTerminalLog.apply)
            NavigationLink {
                LogViewerView()
            } label: {
                Text("Logs")
            }
        } header: {
            Text("Debugging")
                .font(DS.Font.caption)
        } footer: {
            Text(
                """
                Writes detailed terminal activity to the log, \
                including every keystroke, while this is on.
                """,
            )
            .font(DS.Font.detail)
        }
    }
}

/// The keystroke-level log switch. Read by AppDelegate at launch; a flip
/// in Settings applies at once.
enum DetailedTerminalLog {
    static let key = "Debug.verboseTerminalLog"

    static func apply(_ enabled: Bool) {
        TerminalDebugLog.enable(enabled ? .standard : [.lifecycle, .metrics])
    }
}

extension MacLaunchAgent.Status {
    /// The helper's state as the Mac's settings window prints it.
    var settingsDescription: String {
        switch self {
        case .enabled:
            String(localized: "On")
        case .needsApproval:
            String(localized: "Waiting for Approval")
        case .rebinding:
            String(localized: "Updating")
        case .needsRelocation:
            String(localized: "Not in Applications")
        case .notRegistered:
            String(localized: "Off")
        case .brokenInstallation:
            String(localized: "Broken Installation")
        case let .failed(reason):
            reason
        case .notApplicable, .unsupported:
            String(localized: "Not Available")
        }
    }
}
