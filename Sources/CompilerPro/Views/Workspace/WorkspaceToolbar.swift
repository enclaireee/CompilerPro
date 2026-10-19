import SwiftUI

struct WorkspaceToolbar: ToolbarContent {
    @ObservedObject var viewModel: WorkspaceViewModel
    @ObservedObject var appState: AppState

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { appState.goHome() } label: {
                Label("Close Project", systemImage: "house")
            }
            .help("Close Project and return to the Welcome screen (⇧⌘W)")
        }

        ToolbarItem(placement: .principal) {
            Picker("Layout", selection: $viewModel.layout) {
                ForEach(EditorLayout.allCases, id: \.self) { layout in
                    Label(layout.title, systemImage: layout.symbolName)
                        .labelStyle(.iconOnly)
                        .help("\(layout.title) (⌥⌘\(index(of: layout)))")
                        .tag(layout)
                }
            }
            .pickerStyle(.segmented)
            .help("Editor, Split or Preview (⌥⌘1, ⌥⌘2, ⌥⌘3)")
            .accessibilityLabel("Layout")
        }

        if viewModel.mode == .latex {
            ToolbarItemGroup(placement: .primaryAction) {
                if viewModel.isCompiling {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Compiling")
                }
                Button {
                    viewModel.compileOrStop()
                } label: {
                    Label(viewModel.isCompiling ? "Stop" : "Compile",
                          systemImage: viewModel.isCompiling ? "stop.fill" : "play.fill")
                }
                .disabled(!viewModel.isCompiling && !appState.texFound)
                .help(viewModel.isCompiling ? "Stop (⌘.)" : appState.texFound ? "Compile (⌘↩)" : "Install MacTeX to compile documents")
            }

            ToolbarItem(placement: .primaryAction) {
                ZoomControl(scale: viewModel.zoomScale, onCommand: { viewModel.zoom($0) })
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    viewModel.syncForward()
                } label: {
                    Label("Show in PDF", systemImage: "text.viewfinder")
                }
                .help("Show Cursor Position in PDF (⌥⌘J)")

                Button {
                    viewModel.export()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Export PDF… (⇧⌘E)")

                Button {
                    viewModel.toggleProblems()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "exclamationmark.triangle")
                            .symbolVariant(viewModel.isProblemsVisible ? .fill : .none)
                        if viewModel.problemCount > 0 {
                            Text("\(viewModel.problemCount)")
                                .font(.caption.monospacedDigit().weight(.semibold))
                        }
                    }
                }
                .help("Show or Hide Problems (⇧⌘M)")
                .accessibilityLabel(viewModel.problemCount > 0 ? "Problems, \(viewModel.problemCount)" : "Problems")
            }

        } else if viewModel.mode == .mermaid {
            ToolbarItem(placement: .primaryAction) {
                ZoomControl(scale: viewModel.zoomScale, onCommand: { viewModel.zoom($0) }, showsFitModes: false)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("SVG") { viewModel.exportMermaid(format: "svg") }
                    // The PNG export is already rendered at 2x.
                    Button("PNG (2×)") { viewModel.exportMermaid(format: "png") }
                    Divider()
                    Toggle("White Background", isOn: $viewModel.mermaidWhiteExport)
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Export Diagram (⇧⌘E)")
            }
        }
    }

    private func index(of layout: EditorLayout) -> Int {
        (EditorLayout.allCases.firstIndex(of: layout) ?? 0) + 1
    }
}
