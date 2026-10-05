//
//  RemoteAccessSettingsSection.swift
//  iGhostVT
//

import SwiftUI

/// The way into Settings ▸ Remote Access from the settings sheet.
struct RemoteAccessSettingsSection: View {
    var body: some View {
        Section {
            NavigationLink {
                RemoteAccessView()
            } label: {
                Text("Remote Access")
            }
        } header: {
            Text("Remote Access")
                .font(DS.Font.caption)
        } footer: {
            Text("Open terminals on another device of yours, or let your other devices open them here.")
                .font(DS.Font.detail)
        }
    }
}
