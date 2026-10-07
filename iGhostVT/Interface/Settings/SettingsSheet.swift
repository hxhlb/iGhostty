//
//  SettingsSheet.swift
//  iGhostVT
//

import SwiftUI

/// The settings page on iPhone and iPad: one section per file under
/// `Sections/`, stacked in a Form. The sheet itself only owns navigation
/// and the Done control. The Mac has a settings window instead
/// (`SettingsWindow`).
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// Remote Access, pushed by itself for a relay file opened while the
    /// sheet is up or one that opened it (`RelayImport`): that page is
    /// where the file is asked about.
    @State private var isShowingRemoteAccess = false

    var body: some View {
        NavigationView {
            Form {
                AppearanceSettingsSection()
                TextSizeSettingsSection()
                ShellSettingsSection()
                SessionsSettingsSection()
                RemoteAccessSettingsSection()
                RecentDirectoriesSettingsSection()
                KeyboardSettingsSection()
                AboutSettingsSection()
            }
            // Out here, not on the section's row: a Form builds its rows
            // as they scroll into view, and a link in a row not built yet
            // cannot be followed.
            .background(
                NavigationLink(isActive: $isShowingRemoteAccess) {
                    RemoteAccessView()
                } label: {
                    EmptyView()
                },
            )
            .onReceive(RelayImport.pending) { request in
                if request != nil, RelayImport.remoteAccessOnScreen == 0 {
                    isShowingRemoteAccess = true
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .accessibilityLabel("Done")
                    .foregroundColor(.accentColor)
                }
            }
        }
        .navigationViewStyle(.stack)
        // On the sheet, not on Remote Access: one asker however deep the
        // navigation is, so a file opened from a page under Remote Access is
        // still asked about once.
        .relayImportPrompt()
    }
}
