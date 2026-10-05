//
//  Spacing.swift
//  iGhostVTWidgets
//

import CoreGraphics

/// The three gaps this widget is allowed to use — a 4pt geometric scale, so
/// spacing reads as deliberate instead of per-view guesswork.
enum Spacing {
    /// Between one session row and the next.
    static let row: CGFloat = 4
    /// Between lines, and between a row's dot, name, and directory.
    static let line: CGFloat = 8
    /// The card's outer padding.
    static let card: CGFloat = 16
}
