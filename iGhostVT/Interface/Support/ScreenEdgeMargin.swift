//
//  ScreenEdgeMargin.swift
//  iGhostVT
//

import SwiftUI
import UIKit

extension View {
    /// Pads the bottom by `padding` and, where the screen has no safe area
    /// to lift the content off its edge, by enough more that the content
    /// sits `minimum` above it: max(safe area + `padding`, `minimum`). A
    /// bar that clears a home indicator by `padding` is laid out exactly as
    /// before; on a screen with nothing below the bar — an iPhone with a
    /// Home button — `padding` alone left the glass all but touching the
    /// screen's edge, nearer to it than to the sides.
    func bottomScreenMargin(_ padding: CGFloat, minimum: CGFloat) -> some View {
        modifier(BottomScreenMargin(padding: padding, minimum: minimum))
    }
}

private struct BottomScreenMargin: ViewModifier {
    let padding: CGFloat
    let minimum: CGFloat
    /// The window's bottom safe area — the home indicator's strip, or none.
    /// Read from UIKit's window rather than from this view's own geometry:
    /// the window's inset does not move when this padding does, so the
    /// read can never feed back into the layout it changes. (A geometry
    /// reader under the padded content did.)
    @State private var safeArea: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .padding(.bottom, max(padding, minimum - safeArea))
            .background(WindowSafeAreaReader { safeArea = $0 })
    }
}

/// Reports the bottom safe-area inset of the window it sits in, when it
/// joins the window and whenever UIKit changes it (rotation, a window
/// resized on iPad).
private struct WindowSafeAreaReader: UIViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeUIView(context _: Context) -> ReaderView {
        let view = ReaderView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: ReaderView, context _: Context) {
        view.onChange = onChange
    }

    final class ReaderView: UIView {
        var onChange: ((CGFloat) -> Void)?
        private var reported: CGFloat?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            report()
        }

        /// A turn later, outside the layout pass that told it, and only on
        /// a change.
        private func report() {
            guard let inset = window?.safeAreaInsets.bottom, inset != reported else { return }
            reported = inset
            DispatchQueue.main.async { [weak self] in
                self?.onChange?(inset)
            }
        }
    }
}
