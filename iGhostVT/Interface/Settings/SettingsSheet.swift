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
    }
}
