//
//  CopiedIndicator.swift
//  iGhostVT
//

import SPIndicator
import UIKit

/// The one confirmation a copy gets: a pasteboard write changes nothing on
/// screen, so without it Copy Text and Copy as Image read as dead menu
/// items even though they worked.
///
/// Presented on the window the command came from — the key window is
/// whichever one the system last focused, which on an iPad with two
/// windows side by side need not be it.
@MainActor
enum CopiedIndicator {
    static func present(in window: UIWindow?) {
        let indicator = SPIndicatorView(
            title: String(localized: "Copied"),
            preset: .done,
        )
        indicator.presentWindow = window
        indicator.present(haptic: .success)
    }
}
