//
//  TabStripBar.swift
//  iGhostVT
//

import SwiftUI

/// Safari-for-iPad-style top bar for regular width. With the sidebar closed
/// it shows scrollable tab chips; with the sidebar open the tabs live there
/// and this bar shows the active tab's title instead.
struct TabStripBar: View {
    /// The bar's height: its controls plus the padding above and below.
    /// The Mac's traffic lights are centred on it (`CatalystWindowChrome`).
    static let height: CGFloat = DS.Padding.s + controlSize + DS.Padding.s
    static let controlSize: CGFloat = 40

    @ObservedObject var tabManager: TabManager
    @Binding var showsSidebar: Bool
    @State private var window: UIWindow?
    #if !targetEnvironment(macCatalyst)
        @StateObject private var reorderPacing = TabReorderPacing()
    #endif
    /// The chip strip's width, for `reveal` to tell whether it scrolls.
    @State private var stripWidth: CGFloat = 0
    #if targetEnvironment(macCatalyst)
        /// The chip being dragged along the Mac strip, if any.
        @State private var chipDrag: ChipDrag?
    #endif

    var body: some View {
        GlassBarContainer(spacing: DS.Padding.s) {
            HStack(spacing: DS.Padding.s) {
                // With the sidebar open the toggle sits in the sidebar's own
                // top strip, beside the separator (`SidebarView`).
                if !showsSidebar {
                    SidebarToggleButton(showsSidebar: $showsSidebar)
                        .barGlass(in: Circle())
                }

                if tabManager.tabs.isEmpty {
                    // With no tabs there is nothing to title or strip: an
                    // empty capsule collapses to its padding — an 8pt line
                    // squashed across the bar — so the empty state yields the
                    // space instead.
                    Spacer()
                } else {
                    centerCapsule
                }

                // The bar's only trailing control: the active tab's menu,
                // with New Tab at its head. The sidebar owns settings and
                // doubles as the tab overview at this width, so the strip
                // carries neither entry.
                Menu {
                    TabOverflowMenuContent(tabManager: tabManager, window: window)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(DS.Font.control)
                        .frame(width: Self.controlSize, height: Self.controlSize)
                        .contentShape(Circle())
                }
                .barGlass(in: Circle())
                .accessibilityLabel("Tab Menu")
            }
            // One inset all round: the controls sit as far from the window's
            // side as from its top edge.
            .padding(.horizontal, DS.Padding.s)
            .padding(.leading, windowControlsInset)
            .padding(.top, DS.Padding.s)
            .padding(.bottom, DS.Padding.s)
            .background(WindowDragRegion())
        }
        .buttonStyle(.plain)
        // For the context menu's share sheet, which presents via UIKit.
        .background(WindowReader(window: $window))
    }

    /// With the sidebar hidden, the Mac's traffic lights float over this
    /// bar's leading end; the sidebar toggle moves out from under them, and
    /// the bar's horizontal padding is then the gap to the lights — the
    /// same 8pt the toggle keeps from the capsule on its other side. With
    /// the sidebar open it clears them itself and the bar starts flush.
    private var windowControlsInset: CGFloat {
        #if targetEnvironment(macCatalyst)
            showsSidebar ? 0 : CatalystWindowChrome.windowControlsEnd
        #else
            0
        #endif
    }

    /// One capsule for both modes. The bar is a glass-effect container, and
    /// replacing a glass capsule with another one makes Liquid Glass morph
    /// between them — a blob that shrinks to a pill and regrows while the
    /// sidebar slides. The shape stays mounted; only its content crossfades.
    private var centerCapsule: some View {
        // Leading, like the chips: a program that retitles on every prompt
        // (a status line, an agent reporting progress) would otherwise
        // re-centre the text at each change.
        ZStack(alignment: .leading) {
            if showsSidebar {
                if let tab = tabManager.activeTab {
                    HStack(spacing: DS.Padding.s) {
                        ObservedTabTitle(tab: tab)
                        ObservedTabSubtitle(tab: tab)
                    }
                    // Title and subtitle name one tab: VoiceOver reads them
                    // as one stop rather than stopping twice on the capsule.
                    .accessibilityElement(children: .combine)
                    .padding(.horizontal, DS.Padding.l)
                    .contextMenu {
                        TabContextMenu(tab: tab, tabManager: tabManager, window: window)
                    }
                    // Keyed on the tab: switching tabs (a new one included)
                    // crossfades one title for another. Without the key
                    // SwiftUI reads it as the same text changing and morphs
                    // the two — strings overlapping mid-slide.
                    .id(tab.id)
                    .transition(.opacity)
                }
            } else {
                chipStrip
                    .clipShape(Capsule())
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Self.controlSize, alignment: .leading)
        // On the Mac the capsule is most of the title bar: a drag on the
        // title, or between chips, moves the window as a title bar would.
        .background(WindowDragRegion())
        .barGlass(in: Capsule(), interactive: false)
    }

    /// Chips share the bar Safari-style: equal widths, the bar divided by
    /// the tab count (``TabChip/width(sharing:among:)``), so a title that
    /// keeps changing never resizes its chip or shoves its neighbours, and
    /// the strip scrolls only once the minimums no longer fit.
    private var chipStrip: some View {
        GeometryReader { proxy in
            let width = chipLayout(in: proxy.size.width).width
            ScrollViewReader { scroller in
                ChipScroller {
                    HStack(spacing: DS.Padding.xs) {
                        ForEach(tabManager.tabs) { tab in
                            TabChip(
                                tab: tab,
                                isActive: tab.id == tabManager.activeTabID,
                                showsSelection: tabManager.tabs.count > 1,
                                onSelect: { tabManager.activeTabID = tab.id },
                                onClose: { tabManager.requestClose(tab) },
                            )
                            .frame(width: width)
                            .contextMenu {
                                TabContextMenu(tab: tab, tabManager: tabManager, window: window)
                            }
                        #if targetEnvironment(macCatalyst)
                            .offset(x: chipDragOffset(for: tab, pitch: width + DS.Padding.xs))
                            .zIndex(chipDrag?.id == tab.id ? 1 : 0)
                            // The dragged chip rides the pointer; only its
                            // neighbours slide into their new slots.
                            .transaction { if chipDrag?.id == tab.id { $0.animation = nil } }
                            .highPriorityGesture(chipDragGesture(for: tab, pitch: width + DS.Padding.xs, scroller: scroller))
                        #else
                            .tabReorderable(tab, in: tabManager, pacing: reorderPacing, preview: .chip, width: width)
                        #endif
                            .id(tab.id)
                        }
                    }
                    .padding(DS.Padding.xs)
                    // The gaps between chips are bare chrome too.
                    .background(WindowDragRegion())
                #if !targetEnvironment(macCatalyst)
                    .tabReorderContainer()
                #endif
                }
                .onAppear {
                    stripWidth = proxy.size.width
                    reveal(with: scroller, animated: false)
                }
                .onChange(of: proxy.size.width) { stripWidth = $0 }
                .onChange(of: tabManager.activeTabID) { _ in reveal(with: scroller, animated: true) }
                // A resize or a tab opened or closed changes every chip's
                // width, and the active one can slide out of view with it.
                .onChange(of: width) { _ in reveal(with: scroller, animated: false) }
            }
        }
        // A GeometryReader fills whatever it is given, in both axes; the
        // bar's height is the capsule's, not the window's.
        .frame(maxWidth: .infinity, maxHeight: Self.controlSize, alignment: .leading)
    }

    #if targetEnvironment(macCatalyst)
        /// Where the dragged chip is drawn relative to the slot it now
        /// holds: the pointer's travel, less the slots it has already moved.
        private func chipDragOffset(for tab: TerminalTab, pitch: CGFloat) -> CGFloat {
            guard let chipDrag, chipDrag.id == tab.id,
                  let index = tabManager.tabs.firstIndex(where: { $0.id == tab.id })
            else { return 0 }
            return chipDrag.travel - CGFloat(index - chipDrag.startIndex) * pitch
        }

        /// The Mac strip's reorder. Not the system drag the sidebar uses:
        /// the strip lives in the band AppKit keeps for a title bar, and a
        /// system drag over that band never reaches the content as a drop
        /// target — the lift happened and no slot was ever entered. A plain
        /// gesture stays inside the app: the chip follows the pointer and
        /// trades places with a neighbour once it is past that neighbour's
        /// middle; carried past the strip's end it keeps trading as the
        /// pointer moves, and the strip scrolls to keep the chip in view.
        private func chipDragGesture(for tab: TerminalTab, pitch: CGFloat, scroller: ScrollViewProxy) -> some Gesture {
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { value in
                    guard let index = tabManager.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
                    if chipDrag?.id != tab.id {
                        chipDrag = ChipDrag(id: tab.id, startIndex: index, travel: 0)
                    }
                    chipDrag?.travel = value.translation.width
                    let offset = chipDragOffset(for: tab, pitch: pitch)
                    let tabs = tabManager.tabs
                    if offset > pitch / 2, index + 1 < tabs.count {
                        tabManager.moveTab(tab, toSlotOf: tabs[index + 1])
                    } else if offset < -pitch / 2, index > 0 {
                        tabManager.moveTab(tab, toSlotOf: tabs[index - 1])
                    } else {
                        return
                    }
                    scroller.scrollTo(tab.id)
                }
                .onEnded { _ in
                    withAnimation(DS.Motion.smooth) {
                        chipDrag = nil
                        scroller.scrollTo(tab.id)
                    }
                }
        }
    #endif

    /// Scrolls the active chip into view — a tab picked from the sidebar,
    /// the menu or a shortcut may sit past the strip's visible end. The
    /// nearest edge, not the centre: a chip already showing stays put. A
    /// strip that fits is put back at its start instead, since every chip
    /// shows there.
    ///
    /// Asked twice: now, and again once a tab's arrival or departure has
    /// finished animating. The scroll view's content size follows that
    /// animation, so a scroll asked for mid-flight is clamped to a size
    /// that is about to change — at the point where a new tab makes the
    /// strip start scrolling, the new chip stayed half hidden, and where a
    /// strip stopped scrolling it kept an offset its content no longer had.
    ///
    /// Whether the strip fits is read when each scroll runs, from the live
    /// tab count and `stripWidth`: an `onChange` action runs with the values
    /// of the body that installed it, and a captured answer was the one from
    /// before the tab that tipped the strip into scrolling.
    private func reveal(with scroller: ScrollViewProxy, animated: Bool) {
        let scroll = {
            if chipLayout(in: stripWidth).fits, let first = tabManager.tabs.first {
                scroller.scrollTo(first.id, anchor: .leading)
            } else if let id = tabManager.activeTabID {
                scroller.scrollTo(id)
            }
        }
        if animated {
            withAnimation(DS.Motion.smooth, scroll)
        } else {
            scroll()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.tabTransitionSettle) {
            withAnimation(DS.Motion.smooth, scroll)
        }
    }

    /// The chips' shared width in a strip `stripWidth` wide, and whether
    /// they fit it without scrolling.
    private func chipLayout(in stripWidth: CGFloat) -> (width: CGFloat, fits: Bool) {
        let count = CGFloat(max(tabManager.tabs.count, 1))
        let available = stripWidth - DS.Padding.xs * 2 - DS.Padding.xs * (count - 1)
        let width = TabChip.width(sharing: available, among: count)
        return (width, width * count <= available)
    }

    /// Long enough for `TabManager.tabTransition` to come to rest.
    private static let tabTransitionSettle: TimeInterval = 0.6
}

#if targetEnvironment(macCatalyst)
    /// A chip drag in progress: which tab, the slot it was lifted from,
    /// and how far the pointer has travelled since.
    private struct ChipDrag {
        let id: UUID
        let startIndex: Int
        var travel: CGFloat
    }
#endif

/// Not an observer of the tab: the strip hangs the tab's context menu on
/// this view, and a menu host re-evaluated on every retitle rebuilds the
/// menu while it is open. The title and the padlock observe for themselves.
private struct TabChip: View {
    let tab: TerminalTab
    let isActive: Bool
    /// Whether the active chip draws its capsule. A lone tab has nothing to
    /// be picked out from, and a filled chip alone in the strip reads as a
    /// stray button; it is still the selected one to VoiceOver.
    let showsSelection: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    /// The floor keeps room for a title beside the close button — a tap on
    /// the chip's leading half must select, not close; the ceiling keeps
    /// one long title from owning the bar.
    static let widthRange: ClosedRange<CGFloat> = 120 ... 240

    /// The Mac's chip: wide enough for a window-title's worth of text.
    /// Below it the strip scrolls; above it the chips split the capsule.
    static let macWidth: CGFloat = 200

    /// Each chip's width when `count` chips share `available` points. On
    /// the Mac the chips fill the capsule whatever the count — one tab is
    /// one full-width chip, as in Safari — until a share falls under
    /// ``macWidth``, where they stop shrinking and the strip scrolls. The
    /// share is rounded *down* to a 64th of a point: the row then never
    /// comes out a hair wider than its scroller, which would make a strip
    /// that fits scroll by a fraction of a pixel. Elsewhere the share is
    /// clamped to ``widthRange``.
    static func width(sharing available: CGFloat, among count: CGFloat) -> CGFloat {
        let share = available / count
        #if targetEnvironment(macCatalyst)
            guard share >= macWidth else { return macWidth }
            return (share * 64).rounded(.down) / 64
        #else
            return min(widthRange.upperBound, max(widthRange.lowerBound, share))
        #endif
    }

    var body: some View {
        #if DEBUG
            let _ = BodyTrace.note("TabChip")
        #endif
        Button(action: onSelect) {
            HStack(spacing: DS.Padding.xs) {
                ObservedTabTitle(tab: tab, font: .label)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ObservedTabLockBadge(attributes: tab.attributes)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(DS.Font.captionEmphasis)
                        .foregroundColor(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Circle())
                }
                .accessibilityLabel("Close Tab")
            }
            .padding(.horizontal, DS.Padding.m)
            .frame(height: 32)
            .background(
                Capsule().fill(
                    isActive && showsSelection ? Color.primary.opacity(0.12) : Color.clear,
                ),
            )
            .contentShape(Capsule())
        }
        // Without it a chip gives VoiceOver no way to tell which tab the
        // strip is on. The close button inside stays its own element.
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }
}

/// The chips' horizontal scroller. On the Mac the strip sits in the band
/// AppKit keeps for a title bar, and macOS 26+ draws a scroll view's edge
/// effect over whatever scrolls under that band — the chips came up as a
/// frosted blank capsule, which read as the glass covering them and once
/// had the Mac strip laid out as a clipped row that could not scroll. With
/// the edge effect hidden it scrolls like everywhere else, a mouse wheel
/// included (`WheelScrollsHorizontally`).
private struct ChipScroller<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        #if targetEnvironment(macCatalyst)
            if #available(iOS 26.0, *) {
                ScrollView(.horizontal, showsIndicators: false, content: wheelScrolledContent)
                    .scrollEdgeEffectHidden()
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            } else {
                ScrollView(.horizontal, showsIndicators: false, content: wheelScrolledContent)
            }
        #else
            ScrollView(.horizontal, showsIndicators: false, content: content)
        #endif
    }

    #if targetEnvironment(macCatalyst)
        private func wheelScrolledContent() -> some View {
            content().background(WheelScrollsHorizontally())
        }
    #endif
}

#if targetEnvironment(macCatalyst)
    /// A mouse wheel only scrolls vertically, and a horizontal scroll view
    /// ignores it — with a plain mouse the strip's hidden chips were out of
    /// reach. Placed inside the scroller's content, this finds the
    /// `UIScrollView` SwiftUI built around it and turns a wheel's vertical
    /// steps into horizontal travel, as an AppKit tab bar does. Trackpads
    /// scroll continuously, in both axes, and are left to the scroll view.
    private struct WheelScrollsHorizontally: UIViewRepresentable {
        func makeUIView(context _: Context) -> WheelView {
            WheelView()
        }

        func updateUIView(_: WheelView, context _: Context) {}

        final class WheelView: UIView, UIGestureRecognizerDelegate {
            private weak var scrollView: UIScrollView?
            private lazy var wheel: UIPanGestureRecognizer = {
                let wheel = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
                wheel.allowedScrollTypesMask = .discrete
                // Scroll events only: a press-and-drag stays the chips'.
                wheel.allowedTouchTypes = []
                wheel.delegate = self
                return wheel
            }()

            override func didMoveToWindow() {
                super.didMoveToWindow()
                scrollView?.removeGestureRecognizer(wheel)
                scrollView = nil
                guard window != nil else { return }
                var ancestor = superview
                while let view = ancestor, !(view is UIScrollView) {
                    ancestor = view.superview
                }
                scrollView = ancestor as? UIScrollView
                scrollView?.addGestureRecognizer(wheel)
            }

            @objc private func scrolled(_ wheel: UIPanGestureRecognizer) {
                guard let scrollView else { return }
                let step = wheel.translation(in: scrollView)
                wheel.setTranslation(.zero, in: scrollView)
                // A wheel turned down reads as travel towards the end.
                let travel = abs(step.y) > abs(step.x) ? -step.y : -step.x
                let limit = max(0, scrollView.contentSize.width - scrollView.bounds.width)
                let x = min(limit, max(0, scrollView.contentOffset.x + travel))
                scrollView.setContentOffset(CGPoint(x: x, y: scrollView.contentOffset.y), animated: false)
            }

            func gestureRecognizer(
                _: UIGestureRecognizer,
                shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer,
            ) -> Bool {
                true
            }
        }
    }
#endif
