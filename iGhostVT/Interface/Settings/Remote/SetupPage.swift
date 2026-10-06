import SwiftUI

/// A page laid out the way iOS's own setup is: a symbol, one large title,
/// a centred line of explanation, what the step needs in the middle, and
/// its buttons held at the bottom edge. The pairing sheets are built from
/// it, so each of their states — the code, the outcome — reads as one step.
///
/// In a popover (the Mac's settings pane) the same step is drawn small:
/// `setupPageIsCompact` in the environment.
struct SetupPage<Content: View, Footer: View>: View {
    @Environment(\.setupPageIsCompact) private var isCompact
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
        if isCompact {
            compact
        } else {
            regular
        }
    }

    /// A popover's worth: the same parts at the sizes a Mac popover uses.
    private var compact: some View {
        VStack(spacing: DS.Padding.m) {
            Image(systemName: symbol)
                .font(.system(size: 32, weight: .regular))
                .foregroundColor(tint)
                .accessibilityHidden(true)
            Text(title)
                .font(DS.Font.title)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(DS.Font.detail)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            content()
            footer()
        }
        .padding(DS.Padding.xl)
        .frame(width: 320)
    }

    private var regular: some View {
        VStack(spacing: 0) {
            // Centred in the height above the buttons, the way the
            // system's setup steps sit; a step taller than that scrolls.
            GeometryReader { proxy in
                ScrollView {
                    centredColumn(minHeight: proxy.size.height)
                }
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

    private func centredColumn(minHeight: CGFloat) -> some View {
        VStack(spacing: DS.Padding.l) {
            Image(systemName: symbol)
                .font(.system(size: 64, weight: .regular))
                .foregroundColor(tint)
                .frame(height: 76)
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
        .padding(.vertical, DS.Padding.xl)
        .frame(maxWidth: Self.columnWidth)
        .frame(maxWidth: .infinity, minHeight: minHeight)
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

/// The step's main button, full width at the bottom of a `SetupPage`; in
/// a popover, a regular default button.
struct SetupPrimaryButton: View {
    @Environment(\.setupPageIsCompact) private var isCompact
    let title: String
    let action: () -> Void

    var body: some View {
        if isCompact {
            Button(title, action: action)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        } else {
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
}

private struct SetupPageIsCompactKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Draws a `SetupPage` at popover size.
    var setupPageIsCompact: Bool {
        get { self[SetupPageIsCompactKey.self] }
        set { self[SetupPageIsCompactKey.self] = newValue }
    }
}
