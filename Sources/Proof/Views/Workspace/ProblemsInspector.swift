import AppKit
import ProofCore
import SwiftUI

struct ProblemsInspector: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    var onClose: (() -> Void)? = nil
    @State private var logFilter = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("View", selection: $viewModel.problemsTab) {
                    ForEach(WorkspaceViewModel.ProblemsTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Spacer(minLength: 0)

                Button {
                    viewModel.compileOrStop()
                } label: {
                    Label(viewModel.isCompiling ? "Stop" : "Build", systemImage: viewModel.isCompiling ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.borderless)
                .help(viewModel.isCompiling ? "Stop (⌘.)" : "Compile (⌘↩)")

                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Hide Problems (⇧⌘M)")
                    .accessibilityLabel("Hide Problems")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

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
        let lines = filteredLog
        return VStack(spacing: 0) {
            if viewModel.compileResult != nil {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Filter Log", text: $logFilter)
                        .textFieldStyle(.plain)
                    if !logFilter.isEmpty {
                        Button {
                            logFilter = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Clear Filter")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                .padding(8)
                Divider()
            }

            if lines.isEmpty {
                ContentUnavailableView(
                    viewModel.compileResult == nil ? "No Log Yet" : "No Matching Lines",
                    systemImage: viewModel.compileResult == nil ? "text.alignleft" : "line.3.horizontal.decrease.circle",
                    description: Text(viewModel.compileResult == nil ? "The build log appears after you compile." : "Try a different filter.")
                )
            } else {
                List(lines) { line in
                    logRow(line)
                }
                .listStyle(.plain)
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
    }

    private func logRow(_ line: BuildLogLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if line.isNavigable {
                Image(systemName: "arrow.up.forward.square")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(color(for: line.severity))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if line.isNavigable { viewModel.jumpToLogLine(line) }
        }
        .help(line.isNavigable ? "Jump to \(((line.file ?? "") as NSString).lastPathComponent):\(line.line ?? 0)" : "Build log line")
        .contextMenu {
            Button("Copy Line") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(line.text, forType: .string)
            }
            if line.isNavigable {
                Button("Jump to Source") { viewModel.jumpToLogLine(line) }
            }
        }
    }

    private func color(for severity: BuildLogLine.Severity) -> Color {
        switch severity {
        case .error: return .red
        case .warning: return .orange
        case .info: return .primary
        }
    }

    private var filteredLog: [BuildLogLine] {
        guard !logFilter.isEmpty else { return viewModel.buildLogLines }
        return viewModel.buildLogLines.filter { $0.text.localizedCaseInsensitiveContains(logFilter) }
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
