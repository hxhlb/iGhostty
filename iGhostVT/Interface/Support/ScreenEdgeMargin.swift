//
//  ScreenEdgeMargin.swift
//  iGhostVT
//

import SwiftUI

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
    /// The bottom safe area under this view. Read from the content's own
    /// geometry: a bar in a `safeAreaInset` sits on the safe area's edge
    /// and still reports the inset beyond it.
    @State private var safeArea: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .padding(.bottom, max(padding, minimum - safeArea))
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: BottomSafeAreaKey.self,
                        value: proxy.safeAreaInsets.bottom,
                    )
                },
            )
            .onPreferenceChange(BottomSafeAreaKey.self) { safeArea = $0 }
    }
}

private struct BottomSafeAreaKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
