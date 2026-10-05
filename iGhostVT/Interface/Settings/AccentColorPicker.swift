//
//  AccentColorPicker.swift
//  iGhostVT
//

import SwiftUI

/// One round swatch per colour, the app's own accent first, the chosen one
/// ringed. Its name is the row's to show (`AccentColorPreference.current`),
/// beside the row's title. Shared by the iOS settings page and the Mac's
/// Appearance pane.
struct AccentColorPicker: View {
    @AppStorage(AccentColorPreference.key) private var rawValue = AccentColorPreference.appDefault.rawValue

    private static let side: CGFloat = 20
    private static let ring: CGFloat = 2
    private static let gap: CGFloat = 2
    /// The row's width at macOS's own 10pt spacing. A narrower row — an
    /// iPhone's settings form has well under this — closes the spacing up
    /// instead of clipping the last swatches.
    private static let preferredWidth: CGFloat = {
        let count = CGFloat(AccentColorPreference.allCases.count)
        return count * (side + 2 * (ring + gap)) + (count - 1) * 10
    }()

    private var selection: AccentColorPreference {
        AccentColorPreference(rawValue: rawValue) ?? .appDefault
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AccentColorPreference.allCases) { choice in
                swatch(choice)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: Self.preferredWidth)
    }

    private func swatch(_ choice: AccentColorPreference) -> some View {
        let isSelected = choice == selection
        return Button {
            rawValue = choice.rawValue
        } label: {
            fill(for: choice)
                .frame(width: Self.side, height: Self.side)
                .overlay {
                    Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
                }
                .padding(Self.ring + Self.gap)
                .overlay {
                    if isSelected {
                        Circle()
                            .strokeBorder(ringColor(for: choice), lineWidth: Self.ring)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: choice.title))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func fill(for choice: AccentColorPreference) -> some View {
        Circle().fill(choice.color)
    }

    private func ringColor(for choice: AccentColorPreference) -> Color {
        choice.color
    }
}
