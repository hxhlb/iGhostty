//
//  TabLabels.swift
//  iGhostVT
//

import SwiftUI

// The parts of a tab's presentation that change while its terminal runs,
// each a view of its own that observes what it shows. Every presentation
// of a tab — strip chip, title capsule, sidebar row, switcher card — also
// carries the tab's context menu, and a view that hosts a menu must not
// observe the tab: the tab republishes on every retitle, and SwiftUI then
// hands UIKit new menu content, which rebuilds the menu while it is open.
// So the host holds the tab as a plain reference and these do the
// observing (`TabContextMenu` explains the menu's side).

/// Title text that re-renders when the surface retitles (OSC updates).
struct ObservedTabTitle: View {
    @ObservedObject var tab: TerminalTab
    var font: DS.Font = .labelEmphasis

    var body: some View {
        Text(tab.displayTitle)
            .font(font)
            .lineLimit(1)
            .truncationMode(.middle)
            .retitleTransition()
            .animation(DS.Motion.smooth, value: tab.displayTitle)
    }
}

/// The dim line beside the title: what the session reports about itself
/// while the title itself stays the stable process name.
struct ObservedTabSubtitle: View {
    @ObservedObject var tab: TerminalTab

    var body: some View {
        Text(tab.secondaryTitle)
            .font(DS.Font.caption)
            .foregroundColor(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .retitleTransition()
            .animation(DS.Motion.smooth, value: tab.secondaryTitle)
    }
}

/// The padlock of a locked tab, and nothing for an unlocked one.
struct ObservedTabLockBadge: View {
    @ObservedObject var attributes: TabAttributes

    var body: some View {
        if let lock = attributes.lock {
            TabLockBadge(lock: lock)
        }
    }
}

private extension View {
    /// A retitle crossfades the text instead of swapping it. The shell
    /// retitles a fresh tab within a second of its prompt appearing, so
    /// "Terminal" turning into a host name is the first thing a new tab
    /// does — worth more than a hard cut.
    @ViewBuilder
    func retitleTransition() -> some View {
        if #available(iOS 16.0, *) {
            contentTransition(.opacity)
        } else {
            self
        }
    }
}
