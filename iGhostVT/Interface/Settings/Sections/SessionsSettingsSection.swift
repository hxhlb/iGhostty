//
//  SessionsSettingsSection.swift
//  iGhostVT
//

import SwiftUI

/// What happens to sessions as the app opens and quits, right under the
/// shell those sessions run.
struct SessionsSettingsSection: View {
    /// Read by the scene delegate as a window opens; see `SessionLaunch`.
    @AppStorage(SessionLaunch.key) private var opensNewSession = true
    /// Read by AppDelegate when the app quits; see `SessionKeepAlive`.
    @AppStorage(SessionKeepAlive.key) private var keepAlive = true

    var body: some View {
        Section {
            Toggle("New Session at Launch", isOn: $opensNewSession)
            Toggle("Keep Sessions Running", isOn: $keepAlive)
        } header: {
            Text("Sessions")
                .font(DS.Font.caption)
        } footer: {
            VStack(alignment: .leading, spacing: DS.Padding.s) {
                Text(
                    """
                    New Session at Launch opens a session when the app starts \
                    with nothing to resume. With it off, the app opens with no tabs.
                    """,
                )
                Text(
                    """
                    Keep Sessions Running lets a session with a program running \
                    keep going after the app quits and come back on the next \
                    launch; a shell sitting at its prompt closes. With it off, \
                    every session closes when the app quits.
                    """,
                )
            }
            .font(DS.Font.detail)
        }
    }
}
