import AppKit
import SwiftUI

/// Bottom build panel, the way Xcode and TeX editors put problems and logs: under
/// the document, attached to the status bar, resizable from its top edge.
struct BuildPanel: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    @State private var height: CGFloat = 210
    @State private var dragStartHeight: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            dragHandle
            ProblemsInspector(viewModel: viewModel, onClose: {
                viewModel.isProblemsVisible = false
            })
        }
        .frame(height: height)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
    }

    private var dragHandle: some View {
        ZStack {
            Color.clear
                .frame(height: 9)
                .contentShape(Rectangle())
            Capsule()
                .fill(.tertiary)
                .frame(width: 34, height: 3)
                .allowsHitTesting(false)
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let start = dragStartHeight ?? height
                    if dragStartHeight == nil { dragStartHeight = start }
                    height = min(560, max(120, start - value.translation.height))
                }
                .onEnded { _ in dragStartHeight = nil }
        )
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.set() } else { NSCursor.arrow.set() }
        }
        .accessibilityLabel("Resize build panel")
        .help("Drag to resize")
    }
}
