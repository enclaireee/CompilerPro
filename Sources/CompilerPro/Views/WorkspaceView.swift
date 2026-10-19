import AppKit
import CompilerProCore
import PDFKit
import SwiftUI

public struct WorkspaceView: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    @ObservedObject var appState: AppState
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @Environment(\.colorScheme) private var colorScheme

    @AppStorage(AppSettings.editorFontSize) private var fontSize: Double = 13
    @AppStorage(AppSettings.showLineNumbers) private var showLineNumbers: Bool = true
    @AppStorage(AppSettings.wrapLines) private var wrapLines: Bool = true
    @AppStorage(AppSettings.darkPDF) private var darkPDF: Bool = false
    @AppStorage(AppSettings.pdfZoomMode) private var pdfZoomModeRaw: String = "fitWidth"

    public init(viewModel: WorkspaceViewModel, appState: AppState) {
        self.viewModel = viewModel
        self.appState = appState
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 190, ideal: 240, max: 380)
        } detail: {
            VStack(spacing: 0) {
                detailContent
                StatusBar(viewModel: viewModel, appState: appState)
            }
            .inspector(isPresented: problemsBinding) {
                ProblemsInspector(viewModel: viewModel)
                    .inspectorColumnWidth(min: 260, ideal: 320, max: 520)
            }
        }
        .navigationTitle(viewModel.folderName)
        .navigationSubtitle(viewModel.currentRelativePath)
        .toolbar {
            WorkspaceToolbar(viewModel: viewModel, appState: appState)
        }
        .background(
            WindowStateBinder(
                isEdited: viewModel.isDirty,
                fileURL: viewModel.currentFile.map { URL(fileURLWithPath: $0) }
            )
        )
        .sheet(isPresented: $viewModel.isQuickOpenVisible) {
            QuickOpenView(viewModel: viewModel)
        }
        .alert(namePromptTitle, isPresented: namePromptBinding) {
            TextField("Name", text: $viewModel.promptText)
            Button(namePromptButton) { viewModel.commitNamePrompt() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(namePromptMessage)
        }
        .confirmationDialog(
            "Move “\(viewModel.trashTarget.map { ($0 as NSString).lastPathComponent } ?? "")” to the Trash?",
            isPresented: trashBinding,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { viewModel.performTrash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can restore it from the Trash.")
        }
        .confirmationDialog(
            "Remove build files?",
            isPresented: $viewModel.isCleanConfirmVisible,
            titleVisibility: .visible
        ) {
            Button("Clean Build Files", role: .destructive) { viewModel.performCleanBuild() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The compiled PDF and auxiliary files will be deleted. Your source files are not touched.")
        }
        .focusedSceneObject(viewModel)
    }

    // MARK: - Bindings

    private var problemsBinding: Binding<Bool> {
        Binding(
            get: { viewModel.mode == .latex && viewModel.isProblemsVisible },
            set: { viewModel.isProblemsVisible = $0 }
        )
    }

    private var namePromptBinding: Binding<Bool> {
        Binding(
            get: { viewModel.namePrompt != nil },
            set: { if !$0 { viewModel.namePrompt = nil } }
        )
    }

    private var trashBinding: Binding<Bool> {
        Binding(
            get: { viewModel.trashTarget != nil },
            set: { if !$0 { viewModel.trashTarget = nil } }
        )
    }

    private var namePromptTitle: String {
        if case .rename = viewModel.namePrompt?.kind { return "Rename File" }
        return "New File"
    }

    private var namePromptButton: String {
        if case .rename = viewModel.namePrompt?.kind { return "Rename" }
        return "Create"
    }

    private var namePromptMessage: String {
        let ext = viewModel.mode.extensions.first ?? ""
        return "Enter a name. “.\(ext)” is added if you leave the extension out."
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailContent: some View {
        if viewModel.currentFile == nil {
            ContentUnavailableView {
                Label("No File Selected", systemImage: "doc.text")
            } description: {
                Text("Choose a file in the sidebar or create a new one.")
            } actions: {
                Button("New File…") { viewModel.createNewFile() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        } else {
            HSplitView {
                if viewModel.layout != .preview {
                    editorPane
                        .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
                }
                if viewModel.layout != .editor {
                    previewPane
                        .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var editorPane: some View {
        VStack(spacing: 0) {
            if viewModel.mode == .latex && !appState.texFound {
                texMissingBanner
                Divider()
            }
            NativeCodeEditorView(
                mode: viewModel.mode,
                fileKey: viewModel.currentFile,
                text: viewModel.editorText,
                revealRequest: viewModel.revealRequest,
                formatRequest: viewModel.formatRequest,
                onTextChange: { viewModel.onTextEdited($0) },
                onCursorChange: { line, col in viewModel.onCursorChanged(line: line, col: col) },
                onTopLineChange: { top in
                    if viewModel.topVisibleLine != top {
                        viewModel.topVisibleLine = top
                    }
                },
                fontSize: CGFloat(fontSize),
                showLineNumbers: showLineNumbers,
                wrapLines: wrapLines
            )
        }
    }

    private var texMissingBanner: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            Text("LaTeX isn't installed. You can still write and preview math; install MacTeX to build PDFs.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Link("Get MacTeX", destination: URL(string: "https://www.tug.org/mactex/")!)
            Button("Check Again") { appState.recheckTex() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private var previewPane: some View {
        switch viewModel.mode {
        case .latex:
            if viewModel.isSnippetMode {
                LatexSnippetPreviewView(sourceText: viewModel.editorText)
            } else if viewModel.pdfDocument != nil {
                NativePDFPreviewView(
                    document: viewModel.pdfDocument,
                    invertColors: darkPDF && colorScheme == .dark,
                    syncTexSpots: viewModel.syncTexSpots,
                    syncTexTrigger: viewModel.syncTexTrigger,
                    zoomCommand: viewModel.pdfZoomCommand,
                    initialZoomMode: viewModel.pdfZoomMode ?? PDFZoomMode(rawValue: pdfZoomModeRaw) ?? .fitWidth,
                    initialScale: viewModel.pdfZoomMode == .custom ? viewModel.pdfScale : nil,
                    onZoomChange: { scale, mode in viewModel.pdfZoomChanged(scale, mode) },
                    onInverseSync: { page, x, y in
                        viewModel.syncInverseFromPdf(page: page, x: x, y: y)
                    }
                )
            } else {
                ContentUnavailableView {
                    Label("No Preview Yet", systemImage: "doc.richtext")
                } description: {
                    Text("Compile the document to see the PDF.")
                } actions: {
                    Button("Compile") { viewModel.compileOrStop() }
                        .disabled(!appState.texFound || viewModel.isCompiling)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
            }

        case .mermaid:
            MermaidPreviewView(viewModel: viewModel)

        case .markdown:
            MarkdownPreviewView(
                markdownText: viewModel.editorText,
                baseDirectory: viewModel.currentFile.map { ($0 as NSString).deletingLastPathComponent } ?? viewModel.folder,
                topLine: viewModel.topVisibleLine,
                workspaceRoot: viewModel.folder,
                onOpenRelativeMarkdown: { targetPath in
                    viewModel.openFile(targetPath)
                }
            )
        }
    }
}

/// Mirrors the unsaved state and current file onto the hosting NSWindow (edited dot + proxy icon).
private struct WindowStateBinder: NSViewRepresentable {
    let isEdited: Bool
    let fileURL: URL?

    final class Coordinator {
        weak var window: NSWindow?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        let edited = isEdited
        let url = fileURL
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            coordinator.window = window
            window.isDocumentEdited = edited
            if window.representedURL != url { window.representedURL = url }
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.window?.isDocumentEdited = false
        coordinator.window?.representedURL = nil
    }
}
