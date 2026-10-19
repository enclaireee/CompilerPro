import AppKit
import CompilerProCore
import SwiftUI

struct ProblemsInspector: View {
    @ObservedObject var viewModel: WorkspaceViewModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $viewModel.problemsTab) {
                ForEach(WorkspaceViewModel.ProblemsTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)

            Divider()

            Group {
                if viewModel.problemsTab == .problems {
                    problemsList
                } else {
                    logView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
        }
    }

    // MARK: Problems

    @ViewBuilder
    private var problemsList: some View {
        let items = viewModel.visibleDiagnostics
        if items.isEmpty {
            ContentUnavailableView(
                "No Problems",
                systemImage: "checkmark.circle",
                description: Text(viewModel.compileResult == nil ? "Compile the document to check for problems." : "The last build had nothing to report.")
            )
        } else {
            List {
                ForEach(items) { diag in
                    row(diag)
                }
            }
            .listStyle(.inset)
        }
    }

    private func row(_ diag: TexDiagnostic) -> some View {
        let file = ((diag.file.isEmpty ? (viewModel.rootTexPath ?? "") : diag.file) as NSString).lastPathComponent
        let isSelected = viewModel.selectedProblemID == diag.id
        return Button {
            viewModel.jumpToProblem(diag)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: diag.isWarning ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(diag.isWarning ? Color.yellow : Color.red)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(diag.message)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    if let explanation = diag.explanation, !explanation.isEmpty {
                        Text(explanation)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("\(file):\(diag.line)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.15) : nil)
        .contextMenu {
            Button("Copy Message") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(diag.message, forType: .string)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(diag.isWarning ? "Warning" : "Error"), \(file) line \(diag.line): \(diag.message)\(diag.explanation.map { $0.isEmpty ? "" : ". \($0)" } ?? "")")
        .accessibilityHint("Jumps to the line")
    }

    // MARK: Log

    private var logView: some View {
        let log = viewModel.compileResult?.log ?? ""
        return Group {
            if log.isEmpty {
                ContentUnavailableView("No Log Yet", systemImage: "text.alignleft", description: Text("The build log appears after you compile."))
            } else {
                ScrollView {
                    Text(log)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Menu {
                Toggle("Show Warnings", isOn: $viewModel.showWarnings)
                Toggle("Show Layout Warnings", isOn: $viewModel.showLayoutWarnings)
                    .disabled(!viewModel.showWarnings)
                Divider()
                Button("Clean Build Files…") { viewModel.cleanBuild() }
            } label: {
                Label("Options", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Filter problems or clean build files")

            Spacer()

            if viewModel.problemsTab == .log {
                Button("Copy Log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(viewModel.compileResult?.log ?? "", forType: .string)
                }
                .disabled((viewModel.compileResult?.log ?? "").isEmpty)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
