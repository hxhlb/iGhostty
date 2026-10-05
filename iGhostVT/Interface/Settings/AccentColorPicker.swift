//
//  AccentColorPicker.swift
//  iGhostVT
//

import SwiftUI

/// The accent row as macOS draws it in System Settings ▸ Appearance: one
/// round swatch per colour, Multicolor first as the conic rainbow, the
/// chosen one ringed and named underneath. Shared by the iOS settings page
/// and the Mac's Appearance pane.
struct AccentColorPicker: View {
    @AppStorage(AccentColorPreference.key) private var rawValue = AccentColorPreference.multicolor.rawValue

    private static let side: CGFloat = 20
    private static let ring: CGFloat = 2
    private static let gap: CGFloat = 2

    private var selection: AccentColorPreference {
        AccentColorPreference(rawValue: rawValue) ?? .multicolor
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(AccentColorPreference.allCases) { choice in
                swatch(choice)
            }
        }
        // Room for the name under the chosen swatch, which is an overlay so
        // a long name never pushes the swatches apart.
        .padding(.bottom, 18)
        // A row that centres its label on this control (the Mac's settings
        // rows) centres it on the swatches, not on swatches plus name.
        .alignmentGuide(VerticalAlignment.center) { _ in
            (Self.side + 2 * (Self.ring + Self.gap)) / 2
        }
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
        .overlay(alignment: .bottom) {
            if isSelected {
                Text(verbatim: choice.title)
                    .font(DS.Font.detail)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .offset(y: 18)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel(Text(verbatim: choice.title))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    @ViewBuilder
    private func fill(for choice: AccentColorPreference) -> some View {
        if let color = choice.color {
            Circle().fill(color)
        } else {
            Circle().fill(AngularGradient(
                colors: [.red, .orange, .yellow, .green, .blue, .purple, .pink, .red],
                center: .center,
            ))
        }
    }

    private func ringColor(for choice: AccentColorPreference) -> Color {
        choice.color ?? Color.secondary
    }
}
