//
//  AppearanceSettingsSection.swift
//  iGhostVT
//

import SwiftUI

/// The interface's accent, then the two theme slots, light and dark; each
/// slot opens the catalog list.
struct AppearanceSettingsSection: View {
    @ObservedObject private var theme = AppTheme.shared

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: DS.Padding.s) {
                Text("Accent Color")
                AccentColorPicker()
            }
            .padding(.vertical, DS.Padding.xs)
            NavigationLink {
                ThemeListView(slot: .light)
            } label: {
                SettingsValueRow(
                    title: "Light Theme",
                    value: ThemeSlot.light.label(in: theme.selection),
                )
            }
            .accessibilityLabel("Light Theme")
            .accessibilityValue(ThemeSlot.light.label(in: theme.selection))
            NavigationLink {
                ThemeListView(slot: .dark)
            } label: {
                SettingsValueRow(
                    title: "Dark Theme",
                    value: ThemeSlot.dark.label(in: theme.selection),
                )
            }
            .accessibilityLabel("Dark Theme")
            .accessibilityValue(ThemeSlot.dark.label(in: theme.selection))
        } header: {
            Text("Appearance")
                .font(DS.Font.caption)
        } footer: {
            Text("Themes come from the Ghostty theme catalog and apply to every tab in every window.")
                .font(DS.Font.detail)
        }
    }
}

extension ThemeSlot {
    /// What a settings row shows for the slot: the chosen theme's name, or
    /// the default's with a marker. Theme names are catalog data, so only
    /// the marker gets translated.
    @MainActor
    func label(in selection: AppTheme.Selection) -> String {
        let chosen = self == .light ? selection.lightName : selection.darkName
        if let chosen {
            return chosen
        }
        return String(
            format: NSLocalizedString("%@ (Default)", comment: "Theme name plus the default marker"),
            self == .light ? AppTheme.defaultLightName : AppTheme.defaultDarkName,
        )
    }
}
