import CompilerProCore
import SwiftUI

struct StatusBar: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                if viewModel.currentFile != nil {
                    Text("Ln \(viewModel.cursorLine), Col \(viewModel.cursorCol)")
                        .monospacedDigit()
                    if viewModel.mode != .mermaid {
                        Text("\(viewModel.wordCount) word\(viewModel.wordCount == 1 ? "" : "s")")
                            .monospacedDigit()
                    }
                }

                Spacer(minLength: 8)

                if let message = appState.statusMessage {
                    Text(message)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                trailing
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(.bar)
        }
        .onChange(of: outcome) { _, new in
            if let new { AccessibilityNotification.Announcement(new).post() }
        }
    }

    private var outcome: String? {
        guard viewModel.mode == .latex, !viewModel.isCompiling, let res = viewModel.compileResult, !res.cancelled else { return nil }
        if res.ok { return "Compiled successfully" }
        let e = viewModel.errorCount
        return e > 0 ? "\(e) error\(e == 1 ? "" : "s")" : "Build failed"
    }

    @ViewBuilder
    private var trailing: some View {
        switch viewModel.mode {
        case .latex:
            if viewModel.isCompiling {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("Compiling…")
                }
                .accessibilityElement(children: .combine)
            } else if viewModel.isSnippetMode {
                Text("Snippet preview")
            } else if let res = viewModel.compileResult, !res.cancelled {
                if res.ok {
                    Text(String(format: "Built in %.1f s", Double(res.elapsedMs) / 1000.0))
                } else {
                    let errors = viewModel.errorCount
                    Button {
                        viewModel.isProblemsVisible = true
                    } label: {
                        Label {
                            Text(errors > 0 ? "\(errors) error\(errors == 1 ? "" : "s")" : "Build failed")
                                .foregroundStyle(.primary)
                        } icon: {
                            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Show Problems (⇧⌘M)")
                }
            }
        case .mermaid:
            if viewModel.mermaidError != nil {
                Label {
                    Text("Syntax error").foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                }
            }
        case .markdown:
            EmptyView()
        }
    }
}
