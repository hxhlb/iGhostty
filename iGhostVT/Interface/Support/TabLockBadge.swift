import SwiftUI

/// The glyph a locked tab wears — the strip chip, the phone's title
/// capsule, the switcher card, and the sidebar row's close slot.
///
/// Both lock kinds use the filled padlock. The caption the surface shows
/// for a moment as the lock changes names which freeze is on
/// (`TabLock.badgeTitle`); the glyph does not.
struct TabLockBadge: View {
    let lock: TabLock
    var font: DS.Font = .captionEmphasis

    var body: some View {
        Image(systemName: "lock.fill")
            .font(font)
            .foregroundColor(.secondary)
            .accessibilityLabel(lock.badgeTitle)
    }
}
