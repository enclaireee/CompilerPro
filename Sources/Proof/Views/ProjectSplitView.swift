import AppKit
import SwiftUI

/// A real `NSSplitView` that keeps both panes in the view hierarchy when a layout
/// switch hides one. SwiftUI's `HSplitView` with conditional children tore down the
/// `NSTextView` or `WKWebView`, which lost undo history, scroll position and the
/// PDF page whenever the user pressed ⌥⌘1/2/3.
struct ProjectSplitView<Leading: View, Trailing: View>: NSViewRepresentable {
    let showsLeading: Bool
    let showsTrailing: Bool
    let leading: Leading
    let trailing: Trailing

    init(
        showsLeading: Bool,
        showsTrailing: Bool,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.showsLeading = showsLeading
        self.showsTrailing = showsTrailing
        self.leading = leading()
        self.trailing = trailing()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SplitView {
        let split = SplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = context.coordinator

        let leadingHost = NSHostingView(rootView: AnyView(leading))
        let trailingHost = NSHostingView(rootView: AnyView(trailing))
        leadingHost.autoresizingMask = [.width, .height]
        trailingHost.autoresizingMask = [.width, .height]
        split.addArrangedSubview(leadingHost)
        split.addArrangedSubview(trailingHost)

        context.coordinator.leadingHost = leadingHost
        context.coordinator.trailingHost = trailingHost
        context.coordinator.applyVisibility(showsLeading, showsTrailing, to: split)
        return split
    }

    func updateNSView(_ split: SplitView, context: Context) {
        let coordinator = context.coordinator
        coordinator.leadingHost?.rootView = AnyView(leading)
        coordinator.trailingHost?.rootView = AnyView(trailing)
        coordinator.applyVisibility(showsLeading, showsTrailing, to: split)
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency NSSplitViewDelegate {
        weak var leadingHost: NSHostingView<AnyView>?
        weak var trailingHost: NSHostingView<AnyView>?
        private var savedFraction: CGFloat = 0.5
        private var lastShowsBoth = true

        func applyVisibility(_ showsLeading: Bool, _ showsTrailing: Bool, to split: NSSplitView) {
            guard let leadingHost, let trailingHost else { return }
            let showsBoth = showsLeading && showsTrailing
            if lastShowsBoth && !showsBoth {
                // Only remember a sane divider position; a collapsed pane has width 0.
                let width = split.bounds.width
                if width > 200 {
                    let x = split.subviews.first?.frame.maxX ?? split.bounds.width / 2
                    let fraction = x / width
                    if fraction > 0.12 && fraction < 0.88 { savedFraction = fraction }
                }
            }
            let changed = leadingHost.isHidden != !showsLeading || trailingHost.isHidden != !showsTrailing
            leadingHost.isHidden = !showsLeading
            trailingHost.isHidden = !showsTrailing
            if changed {
                split.adjustSubviews()
                if showsBoth {
                    let width = split.bounds.width
                    if width > 200 {
                        split.setPosition(width * savedFraction, ofDividerAt: 0)
                    }
                }
            }
            lastShowsBoth = showsBoth
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainMinCoordinate proposedMinimumPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            max(proposedMinimumPosition, minimumPaneWidth)
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainMaxCoordinate proposedMaximumPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            min(proposedMaximumPosition, splitView.bounds.width - minimumPaneWidth)
        }

        func splitView(
            _ splitView: NSSplitView,
            shouldCollapseSubview subview: NSView,
            forDoubleClickOnDividerAt dividerIndex: Int
        ) -> Bool {
            false
        }

    }
}

private let minimumPaneWidth: CGFloat = 220

/// NSSplitView subclass that gives the divider a sensible initial position once the
/// window has a real width. Doing this in `makeNSView` runs while bounds are zero.
final class SplitView: NSSplitView {
    private var didPlaceInitialDivider = false

    override func layout() {
        super.layout()
        guard !didPlaceInitialDivider, bounds.width > 200 else { return }
        didPlaceInitialDivider = true
        if !subviews.contains(where: \.isHidden) {
            setPosition(bounds.width * 0.5, ofDividerAt: 0)
        }
    }
}
