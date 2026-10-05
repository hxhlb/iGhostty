//
//  MacThemeMenu.swift
//  iGhostVT
//

import GhosttyTheme
import SwiftUI
import UIKit

#if targetEnvironment(macCatalyst)

    /// The theme slot's popup button: a real menu, the way a Mac settings
    /// pane picks from a list, with each theme drawn as its item's image —
    /// its background and foreground, and its eight base colours. A popover
    /// holding the iOS theme list read as a sheet over the window; a menu
    /// closes on the pick and finds a name as it is typed, as every AppKit
    /// menu does.
    ///
    /// UIKit rather than a SwiftUI `Menu`: an item's checkmark has to be its
    /// state, not a second image beside the theme's, and the hundreds of
    /// items are built when the menu opens (`UIDeferredMenuElement`), not on
    /// every evaluation of the pane.
    struct MacThemeMenuButton: View {
        let slot: ThemeSlot
        @ObservedObject private var theme = AppTheme.shared

        var body: some View {
            MacPopupLabel(title: slot.label(in: theme.selection))
                .accessibilityHidden(true)
                .overlay {
                    MenuTrigger(slot: slot, title: slot.label(in: theme.selection))
                }
        }
    }

    /// A clear button over the popup label whose primary action is the menu.
    private struct MenuTrigger: UIViewRepresentable {
        let slot: ThemeSlot
        let title: String

        func makeUIView(context _: Context) -> UIButton {
            let button = UIButton(type: .custom)
            button.showsMenuAsPrimaryAction = true
            button.menu = Self.menu(for: slot)
            return button
        }

        func updateUIView(_ button: UIButton, context _: Context) {
            button.accessibilityLabel = slot == .light
                ? String(localized: "Light Theme")
                : String(localized: "Dark Theme")
            button.accessibilityValue = title
        }

        private static func menu(for slot: ThemeSlot) -> UIMenu {
            UIMenu(children: [
                UIDeferredMenuElement.uncached { completion in
                    completion(items(for: slot))
                },
            ])
        }

        private static func items(for slot: ThemeSlot) -> [UIMenuElement] {
            let theme = AppTheme.shared
            let selected = slot == .light ? theme.selection.lightName : theme.selection.darkName
            return GhosttyThemeCatalog.allThemes
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map { definition in
                    UIAction(
                        title: definition.name,
                        image: ThemeMenuImage.image(for: definition),
                        state: definition.name == selected ? .on : .off,
                    ) { _ in
                        switch slot {
                        case .light:
                            theme.selection.lightName = definition.name
                        case .dark:
                            theme.selection.darkName = definition.name
                        }
                    }
                }
        }
    }

    /// A theme as one small picture: the `$_` swatch on its background, in
    /// its foreground, beside the strip of its eight base ANSI colours — the
    /// two things the iOS list shows for a row, in the space a menu item
    /// gives its image. Drawn once per theme and kept.
    @MainActor
    private enum ThemeMenuImage {
        private static var cache: [String: UIImage] = [:]

        private static let swatch = CGSize(width: 22, height: 15)
        private static let segment: CGFloat = 4
        private static let stripHeight: CGFloat = 9
        private static let gap: CGFloat = 5

        static func image(for definition: GhosttyThemeDefinition) -> UIImage {
            if let image = cache[definition.name] {
                return image
            }
            let image = draw(definition)
            cache[definition.name] = image
            return image
        }

        private static func draw(_ definition: GhosttyThemeDefinition) -> UIImage {
            let stripWidth = segment * 8
            let size = CGSize(width: swatch.width + gap + stripWidth, height: swatch.height)
            let edge = UIColor.gray.withAlphaComponent(0.45)
            let image = UIGraphicsImageRenderer(size: size).image { _ in
                let swatchRect = CGRect(origin: .zero, size: swatch).insetBy(dx: 0.5, dy: 0.5)
                let swatchPath = UIBezierPath(roundedRect: swatchRect, cornerRadius: 3)
                color(definition.background).setFill()
                swatchPath.fill()
                edge.setStroke()
                swatchPath.lineWidth = 0.5
                swatchPath.stroke()

                let prompt = NSAttributedString(string: "$_", attributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: 8, weight: .bold),
                    .foregroundColor: color(definition.foreground),
                ])
                let promptSize = prompt.size()
                prompt.draw(at: CGPoint(
                    x: (swatch.width - promptSize.width) / 2,
                    y: (swatch.height - promptSize.height) / 2,
                ))

                let stripRect = CGRect(
                    x: swatch.width + gap,
                    y: (swatch.height - stripHeight) / 2,
                    width: stripWidth,
                    height: stripHeight,
                )
                let stripPath = UIBezierPath(roundedRect: stripRect, cornerRadius: 2)
                stripPath.addClip()
                for index in 0 ..< 8 {
                    color(definition.palette[index] ?? definition.foreground).setFill()
                    UIRectFill(CGRect(
                        x: stripRect.minX + CGFloat(index) * segment,
                        y: stripRect.minY,
                        width: segment,
                        height: stripHeight,
                    ))
                }
                edge.setStroke()
                stripPath.lineWidth = 0.5
                stripPath.stroke()
            }
            // The theme's own colours, never tinted to the menu's text.
            return image.withRenderingMode(.alwaysOriginal)
        }

        private static func color(_ hex: String) -> UIColor {
            UIColor(Color(hex: hex))
        }
    }

#endif
