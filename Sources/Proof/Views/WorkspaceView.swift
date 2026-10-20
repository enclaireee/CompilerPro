import AppKit
import ProofCore
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
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if viewModel.isProblemsVisible, viewModel.mode == .latex {
                            BuildPanel(viewModel: viewModel)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                StatusBar(viewModel: viewModel)
            }
            .animation(.easeInOut(duration: 0.18), value: viewModel.isProblemsVisible)
        }
        .navigationTitle(viewModel.folderName)
        .navigationSubtitle(viewModel.currentRelativePath)
        .toolbar {
            WorkspaceToolbar(viewModel: viewModel, appState: appState)
        }
        .background(
            WindowStateBinder(
                isEdited: viewModel.isDirty,
                fileURL: viewModel.currentFile.map { URL(fileURLWithPath: $0) },
                shouldClose: { [weak viewModel] in viewModel?.confirmCloseIfNeeded() ?? true },
                didClose: { [weak viewModel, appState] in
                    guard let viewModel else { return }
                    viewModel.teardown()
                    appState.unregister(viewModel)
                }
            )
        )
        .alert(item: $viewModel.alert) { a in
            Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text("OK")))
        }
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
        .alert("Go to Line", isPresented: $viewModel.isGoToLineVisible) {
            TextField("Line number", text: $viewModel.goToLineText)
            Button("Go") { viewModel.commitGoToLine() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a line number between 1 and the end of the file.")
        }
        .alert("File Changed on Disk", isPresented: externalChangeBinding) {
            Button("Reload from Disk", role: .destructive) { viewModel.reloadExternalChange() }
            Button("Keep My Changes", role: .cancel) { viewModel.keepExternalChange() }
        } message: {
            Text("“\(externalChangeName)” was changed by another program. Reloading replaces your unsaved edits.")
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

    private var externalChangeBinding: Binding<Bool> {
        Binding(
            get: { viewModel.externalChange != nil },
            set: { if !$0 { viewModel.keepExternalChange() } }
        )
    }

    private var externalChangeName: String {
        guard let path = viewModel.externalChange?.path else { return "The file" }
        return (path as NSString).lastPathComponent
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
        guard let kind = viewModel.namePrompt?.kind else { return "New File" }
        switch kind {
        case .rename: return "Rename File"
        case .newFolder: return "New Folder"
        case .newFile: return "New File"
        }
    }

    private var namePromptButton: String {
        guard let kind = viewModel.namePrompt?.kind else { return "Create" }
        switch kind {
        case .rename: return "Rename"
        case .newFolder, .newFile: return "Create"
        }
    }

    private var namePromptMessage: String {
        if case .newFolder = viewModel.namePrompt?.kind {
            return "Enter a name for the new folder."
        }
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
            ProjectSplitView(
                showsLeading: viewModel.layout != .preview,
                showsTrailing: viewModel.layout != .editor,
                leading: { editorPane },
                trailing: { previewPane }
            )
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
                text: viewModel.liveEditorText,
                revealRequest: viewModel.revealRequest,
                formatRequest: viewModel.formatRequest,
                editRequest: viewModel.editRequest,
                diagnostics: viewModel.diagnostics,
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
                ZStack(alignment: .topTrailing) {
                    NativePDFPreviewView(
                        document: viewModel.pdfDocument,
                        invertColors: darkPDF && colorScheme == .dark,
                        syncTexSpots: viewModel.syncTexSpots,
                        syncTexTrigger: viewModel.syncTexTrigger,
                        zoomCommand: viewModel.pdfZoomCommand,
                        actionRequest: viewModel.pdfActionRequest,
                        initialZoomMode: viewModel.pdfZoomMode ?? PDFZoomMode(rawValue: pdfZoomModeRaw) ?? .fitWidth,
                        initialScale: viewModel.pdfZoomMode == .custom ? viewModel.pdfScale : nil,
                        onZoomChange: { scale, mode in viewModel.pdfZoomChanged(scale, mode) },
                        onInverseSync: { page, x, y in
                            viewModel.syncInverseFromPdf(page: page, x: x, y: y)
                        },
                        onPageChange: { page, count in
                            viewModel.pdfPageChanged(page, count: count)
                        },
                        onFindProgress: { current, total in
                            viewModel.pdfFindProgressChanged(current: current, total: total)
                        }
                    )
                    PDFPreviewControls(viewModel: viewModel)
                }
            } else {
                ContentUnavailableView {
                    Label("No Preview Yet", systemImage: "doc.richtext")
                } description: {
                    Text("Compile the document to see the PDF.")
                } actions: {
                    Button("Compile") { viewModel.compileOrStop() }
                        .disabled(viewModel.isCompiling)
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
                exportRequest: viewModel.markdownExportRequest,
                onExportCompleted: { message, isError in
                    viewModel.showToast(message, isError: isError)
                },
                onToggleTask: { line, checked in
                    viewModel.toggleTask(atLine: line, checked: checked)
                },
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
    let shouldClose: () -> Bool
    let didClose: () -> Void

    final class Coordinator {
        weak var window: NSWindow?
        let closeGuard = CloseGuard()
        var didClose: () -> Void = {}
        private var closeObserver: NSObjectProtocol?

        /// A real close, unlike onDisappear, which also fires when tabs merge or hide.
        func observeClose(of window: NSWindow) {
            guard closeObserver == nil else { return }
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in self?.didClose() }
        }

        deinit {
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.closeGuard.shouldClose = shouldClose
        coordinator.didClose = didClose
        let edited = isEdited
        let url = fileURL
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            coordinator.window = window
            coordinator.closeGuard.install(on: window)
            coordinator.observeClose(of: window)
            window.isDocumentEdited = edited
            if window.representedURL != url { window.representedURL = url }
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.window?.isDocumentEdited = false
        coordinator.window?.representedURL = nil
    }
}

/// Asks to save before any close path (close button, tab ✕, ⌘W) by wrapping SwiftUI's window delegate.
/// ponytail: forwards everything else to SwiftUI's delegate; if SwiftUI swaps the delegate, the next update re-wraps it.
final class CloseGuard: NSObject, NSWindowDelegate {
    var shouldClose: () -> Bool = { true }
    private weak var original: NSWindowDelegate?

    func install(on window: NSWindow) {
        guard window.delegate !== self else { return }
        original = window.delegate
        window.delegate = self
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard shouldClose() else { return false }
        return original?.windowShouldClose?(sender) ?? true
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        original
    }
}
