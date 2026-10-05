//
//  AccentColorPreference.swift
//  iGhostVT
//

import SwiftUI
import UIKit

/// The accent the interface is tinted with — selections, switches, links,
/// the settings window's controls, and on the Mac what AppKit draws in the
/// accent itself. Multicolor is no override at all: the
/// app's own accent from the asset catalog, as macOS's Multicolor leaves
/// each app its own. The other choices are the colours macOS offers in
/// System Settings ▸ Appearance, as UIKit's system colours so each one
/// adapts to light and dark the way the system's do.
enum AccentColorPreference: String, CaseIterable, Identifiable {
    case multicolor
    case blue
    case purple
    case pink
    case red
    case orange
    case yellow
    case green
    case graphite

    static let key = "Interface.accentColor"

    var id: String {
        rawValue
    }

    static var current: AccentColorPreference {
        UserDefaults.standard.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .multicolor
    }

    /// The override, or nil for Multicolor — UIKit and SwiftUI then fall
    /// back to the asset catalog's accent on their own.
    var uiColor: UIColor? {
        switch self {
        case .multicolor: nil
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .pink: .systemPink
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .graphite: .systemGray
        }
    }

    var color: Color? {
        uiColor.map(Color.init(uiColor:))
    }

    var title: String {
        switch self {
        case .multicolor: String(localized: "Multicolor")
        case .blue: String(localized: "Blue")
        case .purple: String(localized: "Purple")
        case .pink: String(localized: "Pink")
        case .red: String(localized: "Red")
        case .orange: String(localized: "Orange")
        case .yellow: String(localized: "Yellow")
        case .green: String(localized: "Green")
        case .graphite: String(localized: "Graphite")
        }
    }

    /// UIKit's half: every window's `tintColor`, which every UIKit control
    /// and the text system inherit. Windows made later pick it up from the
    /// root modifier's first appearance. On the Mac, AppKit's own accent
    /// follows too (`CatalystAccentColor`).
    @MainActor
    static func applyToWindows() {
        #if targetEnvironment(macCatalyst)
            CatalystAccentColor.update(current)
        #endif
        let tint = current.uiColor
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.tintColor = tint
            }
        }
    }
}

/// SwiftUI's half: the tint and the accent colour every view under a
/// hosting controller's root reads (`Color.accentColor` included), and the
/// windows' UIKit tint kept in step as the preference changes.
private struct InterfaceAccentModifier: ViewModifier {
    @AppStorage(AccentColorPreference.key) private var rawValue = AccentColorPreference.multicolor.rawValue

    private var preference: AccentColorPreference {
        AccentColorPreference(rawValue: rawValue) ?? .multicolor
    }

    func body(content: Content) -> some View {
        content
            .accentColor(preference.color)
            .tint(preference.color)
            .onAppear(perform: AccentColorPreference.applyToWindows)
            .onChange(of: rawValue) { _ in
                AccentColorPreference.applyToWindows()
            }
    }
}

extension View {
    /// Tints everything under this view with the accent preference; goes at
    /// the root of every hosting controller, beside `interfaceTextSize()`.
    func interfaceAccent() -> some View {
        modifier(InterfaceAccentModifier())
    }
}
