//
//  SettingsValueRow.swift
//  iGhostVT
//

import SwiftUI

/// A labelled row with its current value trailing in secondary colour —
/// the shape shared by the theme slots and the text-size steppers.
struct SettingsValueRow: View {
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }
}
