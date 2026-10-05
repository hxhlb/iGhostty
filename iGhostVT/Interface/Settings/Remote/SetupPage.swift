import SwiftUI

/// A page laid out the way iOS's own setup is: a symbol, one large title,
/// a centred line of explanation, what the step needs in the middle, and
/// its buttons held at the bottom edge. The pairing sheets are built from
/// it, so each of their states — the code, the outcome — reads as one step.
struct SetupPage<Content: View, Footer: View>: View {
    let symbol: String
    var tint: Color = .accentColor
    let title: String
    let message: String
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    /// A setup page stays a column on a wide sheet, as the system's does.
    private static var columnWidth: CGFloat {
        480
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: DS.Padding.l) {
                    Image(systemName: symbol)
                        .font(.system(size: 64, weight: .regular))
                        .foregroundColor(tint)
                        .frame(height: 76)
                        .padding(.top, DS.Padding.xl)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(DS.Font.heroTitle)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(message)
                        .font(DS.Font.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    content()
                        .padding(.top, DS.Padding.l)
                }
                .padding(.horizontal, DS.Padding.xl)
                .frame(maxWidth: Self.columnWidth)
                .frame(maxWidth: .infinity)
            }
            VStack(spacing: DS.Padding.m) {
                footer()
            }
            .padding(.horizontal, DS.Padding.xl)
            .padding(.top, DS.Padding.s)
            .padding(.bottom, DS.Padding.l)
            .frame(maxWidth: Self.columnWidth)
        }
    }
}

extension SetupPage where Footer == EmptyView {
    init(
        symbol: String,
        tint: Color = .accentColor,
        title: String,
        message: String,
        @ViewBuilder content: @escaping () -> Content,
    ) {
        self.init(symbol: symbol, tint: tint, title: title, message: message, content: content, footer: { EmptyView() })
    }
}

/// The step's main button, full width at the bottom of a `SetupPage`.
struct SetupPrimaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(DS.Font.controlEmphasis)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.Padding.xs)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
    }
}
