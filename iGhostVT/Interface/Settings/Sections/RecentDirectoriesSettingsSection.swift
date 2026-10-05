//
//  RecentDirectoriesSettingsSection.swift
//  iGhostVT
//

import SwiftUI

/// The new-tab menu's third group: the directories this app's sessions
/// have been in. The switch is the one way to say "do not keep this list",
/// so it sits on the main page, beside the shell those tabs open.
struct RecentDirectoriesSettingsSection: View {
    @ObservedObject private var recents = RecentDirectoryStore.shared

    var body: some View {
        Section {
            Toggle("Remember Directories", isOn: $recents.isEnabled)

            if recents.isEnabled {
                HStack {
                    Text("Sort By")
                        .layoutPriority(1)
                    Spacer()
                    Menu {
                        RecentDirectorySortItems(recents: recents)
                    } label: {
                        HStack(spacing: DS.Padding.xs) {
                            Text(verbatim: recents.sortOrder.title)
                                .lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down")
                                .imageScale(.small)
                        }
                    }
                    .accessibilityLabel("Sort By")
                    .accessibilityValue(recents.sortOrder.title)
                }
            }

            if !recents.entries.isEmpty {
                Button(role: .destructive, action: { recents.clear() }) {
                    Text("Clear Recent Directories")
                }
            }
        } header: {
            Text("Recent Directories")
                .font(DS.Font.caption)
        } footer: {
            Text(
                """
                New Tab offers the directories your terminals are in, then \
                the ones they have been in before. Turn this off and that \
                second list is neither offered nor added to; what is already \
                remembered stays until you clear it.
                """,
            )
            .font(DS.Font.detail)
        }
    }
}

/// The sort menu's items, shared with the Mac's settings window; the
/// current order is checked. Buttons rather than a Picker, as with the
/// shell menu (`ShellMenuItems`).
struct RecentDirectorySortItems: View {
    @ObservedObject var recents: RecentDirectoryStore

    var body: some View {
        ForEach(RecentDirectoryStore.SortOrder.allCases) { order in
            Button {
                recents.sortOrder = order
            } label: {
                if recents.sortOrder == order {
                    Label(order.title, systemImage: "checkmark")
                } else {
                    Text(verbatim: order.title)
                }
            }
        }
    }
}
