import ProofCore
import SwiftUI

/// Floating controls over the PDF: find, and a Preview-style page field. They sit
/// above the page instead of in the toolbar so the toolbar stays about the document,
/// and they disappear when the cursor leaves the preview.
struct PDFPreviewControls: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    @FocusState private var findFocused: Bool
    @State private var pageInput = ""

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Spacer(minLength: 0)
                if viewModel.isPDFSearchVisible {
                    findBar
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            Spacer(minLength: 0)
            HStack {
                Spacer(minLength: 0)
                if viewModel.pdfPageCount > 1 {
                    pageBar
                }
            }
        }
        .padding(10)
        .onChange(of: viewModel.isPDFSearchVisible) { _, visible in
            if visible {
                findFocused = true
                pageInput = "\(viewModel.pdfPage)"
            }
        }
        .onChange(of: viewModel.pdfPage) { _, page in
            pageInput = "\(page)"
        }
        .onAppear { pageInput = "\(viewModel.pdfPage)" }
        .animation(.easeInOut(duration: 0.15), value: viewModel.isPDFSearchVisible)
    }

    private var findBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find in PDF", text: $viewModel.pdfSearchQuery)
                .textFieldStyle(.plain)
                .focused($findFocused)
                .frame(width: 170)
                .onSubmit { viewModel.findInPDF(forward: true) }
                .onChange(of: viewModel.pdfSearchQuery) { _, _ in
                    viewModel.resetPDFFindProgress()
                }
            if let total = viewModel.pdfFindTotal {
                if total == 0 {
                    Text("No matches")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(viewModel.pdfFindCurrent)/\(total)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                viewModel.findInPDF(forward: false)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .help("Previous Match (⌥⇧⌘G)")
            .disabled(viewModel.pdfSearchQuery.isEmpty)

            Button {
                viewModel.findInPDF(forward: true)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .help("Next Match (⌥⌘G)")
            .disabled(viewModel.pdfSearchQuery.isEmpty)

            Divider().frame(height: 14)

            Button {
                viewModel.togglePDFSearch()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Close Find (esc)")
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator.opacity(0.6)))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .frame(maxWidth: 420)
        .onAppear { findFocused = true }
    }

    private var pageBar: some View {
        HStack(spacing: 4) {
            Button {
                viewModel.goToPDFPage(viewModel.pdfPage - 1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.pdfPage <= 1)
            .help("Previous Page")

            TextField("", text: $pageInput)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .frame(width: 34)
                .onSubmit {
                    if let page = Int(pageInput) {
                        let clamped = min(max(1, page), max(1, viewModel.pdfPageCount))
                        pageInput = "\(clamped)"
                        viewModel.goToPDFPage(clamped)
                    } else {
                        pageInput = "\(viewModel.pdfPage)"
                    }
                }

            Text("of \(viewModel.pdfPageCount)")
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Button {
                viewModel.goToPDFPage(viewModel.pdfPage + 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.pdfPage >= viewModel.pdfPageCount)
            .help("Next Page")
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator.opacity(0.6)))
        .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
    }
}
