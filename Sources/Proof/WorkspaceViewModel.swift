import AppKit
import Combine
import ProofCore
import Foundation
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

public enum EditorLayout: String, CaseIterable {
    case editor, split, preview

    var title: String {
        switch self {
        case .editor: return "Editor"
        case .split: return "Split"
        case .preview: return "Preview"
        }
    }

    var symbolName: String {
        switch self {
        case .editor: return "rectangle.lefthalf.filled"
        case .split: return "rectangle.split.2x1"
        case .preview: return "rectangle.righthalf.filled"
        }
    }
}

@MainActor
public final class WorkspaceViewModel: ObservableObject {
    public let mode: WorkspaceMode
    public let folder: String
    public unowned let appState: AppState

    // Window feedback
    @Published public var statusMessage: String?
    @Published public var alert: AppAlert?
    private var statusTask: Task<Void, Never>?

    // Sidebar & Tree
    @Published public var treeEntries: [FileEntry] = []
    @Published public var flatFiles: [String] = []
    @Published public var outlineHeadings: [OutlineHeading] = []
    @Published public var activeOutlineLine: Int?

    // Editor State
    @Published public var currentFile: String?
    @Published public var editorText: String = ""
    @Published public var savedText: String = ""
    @Published public var cursorLine: Int = 1
    @Published public var cursorCol: Int = 1
    @Published public var topVisibleLine: Int = 1
    @Published public var revealRequest: (id: UUID, line: Int)?
    @Published public var formatRequest: (id: UUID, kind: FormatKind)?
    @Published public var layout: EditorLayout = .split

    public enum FormatKind {
        case bold
        case italic
        case toggleComment
    }

    // Quick Open (⌘P)
    @Published public var isQuickOpenVisible: Bool = false
    @Published public var quickOpenQuery: String = ""
    @Published public var quickOpenSelection: Int = 0

    // File-operation prompts (presented by WorkspaceView)
    public struct NamePrompt: Identifiable {
        public enum Kind { case newFile(directory: String), rename(path: String) }
        public let id = UUID()
        public let kind: Kind
    }
    @Published public var namePrompt: NamePrompt?
    @Published public var promptText: String = ""
    @Published public var trashTarget: String?
    @Published public var isCleanConfirmVisible: Bool = false

    // LaTeX Mode State
    @Published public var rootTexPath: String?
    @Published public var texEngine: String = "pdflatex"
    @Published public var isSnippetMode: Bool = false
    @Published public var isCompiling: Bool = false
    @Published public var compileResult: CompileResult?
    @Published public var activePdfPath: String?
    @Published public var pdfDocument: PDFDocument?
    @Published public var syncTexSpots: [SyncTexSpot] = []
    @Published public var syncTexTrigger: UUID = UUID()
    @Published public var pdfZoomCommand: (id: UUID, command: PDFZoomCommand)?
    @Published public var pdfScale: CGFloat = 1.0
    /// Last mode reported by the PDF view; nil until the first change (Settings default applies).
    public var pdfZoomMode: PDFZoomMode?

    // Problems inspector
    public enum ProblemsTab: String, CaseIterable {
        case problems = "Problems"
        case log = "Log"
    }
    @Published public var isProblemsVisible: Bool = false
    @Published public var problemsTab: ProblemsTab = .problems
    @Published public var showWarnings: Bool = true
    @Published public var showLayoutWarnings: Bool = false
    @Published public var selectedProblemID: String?

    // Mermaid Mode State
    @Published public var mermaidZoom: Double = 1.0
    @Published public var mermaidPan: CGSize = .zero
    @Published public var mermaidWhiteExport: Bool = false
    @Published public var mermaidError: String?
    @Published public var mermaidExportRequest: (id: UUID, format: String, destPath: String, whiteBg: Bool)?

    private let texRunner = TexProcessRunner()
    private var latestRunID = -1  // newest run reserved by this VM
    private var outlineTask: Task<Void, Never>?
    private var focusObserver: NSObjectProtocol?
    private var cursorCache: [String: (line: Int, col: Int)] = [:]

    public var isDirty: Bool {
        guard currentFile != nil else { return false }
        if editorText.utf8.count != savedText.utf8.count {
            return true
        }
        return editorText != savedText
    }

    public var wordCount: Int {
        let trimmed = editorText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return trimmed.split { $0.isWhitespace || $0.isNewline }.count
    }

    public var folderName: String {
        (folder as NSString).lastPathComponent
    }

    public var currentFileName: String {
        guard let currentFile else { return folderName }
        return (currentFile as NSString).lastPathComponent
    }

    /// Path of the current file relative to the project folder (window subtitle).
    public var currentRelativePath: String {
        guard let currentFile else { return "" }
        return relativePath(currentFile)
    }

    public func relativePath(_ path: String) -> String {
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : (path as NSString).lastPathComponent
    }

    // MARK: - Problems

    public var diagnostics: [TexDiagnostic] { compileResult?.diagnostics ?? [] }

    public var errorCount: Int { diagnostics.filter { !$0.isWarning }.count }

    private func isLayoutWarning(_ d: TexDiagnostic) -> Bool {
        d.isWarning && (d.message.hasPrefix("Overfull") || d.message.hasPrefix("Underfull"))
    }

    /// Errors first, then warnings, honoring the inspector filters.
    public var visibleDiagnostics: [TexDiagnostic] {
        let list = diagnostics.filter { d in
            if !d.isWarning { return true }
            guard showWarnings else { return false }
            return showLayoutWarnings || !isLayoutWarning(d)
        }
        return list.filter { !$0.isWarning } + list.filter { $0.isWarning }
    }

    public var problemCount: Int { visibleDiagnostics.count }

    public func toggleProblems() {
        guard mode == .latex else { return }
        isProblemsVisible.toggle()
    }

    public func nextProblem() { stepProblem(by: 1) }
    public func previousProblem() { stepProblem(by: -1) }

    private func stepProblem(by delta: Int) {
        let list = visibleDiagnostics
        guard !list.isEmpty else { return }
        let idx = list.firstIndex { $0.id == selectedProblemID }
        let next = idx.map { ($0 + delta + list.count) % list.count } ?? (delta > 0 ? 0 : list.count - 1)
        jumpToProblem(list[next])
    }

    public func jumpToProblem(_ diag: TexDiagnostic) {
        selectedProblemID = diag.id
        guard let target = diag.file.isEmpty ? rootTexPath : diag.file else { return }
        openFile(target, revealLine: max(1, diag.line))
    }

    // MARK: - Init / teardown

    public init(mode: WorkspaceMode, folder: String, initialFile: String?, appState: AppState) {
        self.mode = mode
        self.folder = folder
        self.appState = appState

        refreshTree()
        if let candidate = resolveInitialFile(requested: initialFile) {
            openFile(candidate)
        }
        // A project should open showing its page, not an empty pane. Build once when there is
        // nothing to show yet; an existing PDF is displayed as-is and left alone.
        if mode == .latex, !isSnippetMode, rootTexPath != nil, pdfDocument == nil, appState.texFound {
            startCompile(announceMissingRoot: false)
        }

        focusObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleWindowFocus()
            }
        }
    }

    public func teardown() {
        outlineTask?.cancel()
        statusTask?.cancel()
        latestRunID = -1
        texRunner.cancelCompile()
        if let focusObserver {
            NotificationCenter.default.removeObserver(focusObserver)
            self.focusObserver = nil
        }
    }

    /// Errors raise an alert in this window; everything else goes to the status bar and VoiceOver.
    public func showToast(_ text: String, isError: Bool = false) {
        if isError {
            alert = AppAlert(title: "Something went wrong", message: text)
            return
        }
        statusTask?.cancel()
        statusMessage = text
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
        statusTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            statusMessage = nil
        }
    }

    // MARK: - File Tree & Selection

    private func resolveInitialFile(requested: String?) -> String? {
        if let requested, flatFiles.contains(requested) {
            return requested
        }
        let primaryExts = Set(mode.primaryExtensions)
        let docs = flatFiles.filter { primaryExts.contains(($0 as NSString).pathExtension.lowercased()) }
        let sorted = docs.sorted { a, b in
            let depthA = a.components(separatedBy: "/").count
            let depthB = b.components(separatedBy: "/").count
            if depthA != depthB { return depthA < depthB }
            let isMainA = (a as NSString).lastPathComponent.hasPrefix("main.")
            let isMainB = (b as NSString).lastPathComponent.hasPrefix("main.")
            if isMainA != isMainB { return isMainA && !isMainB }
            return a < b
        }
        return sorted.first ?? flatFiles.first
    }

    public func refreshTree() {
        let entries = FileService.listTree(root: folder, extensions: mode.extensions)
        if entries != treeEntries {
            treeEntries = entries
            flatFiles = FileService.flattenFiles(entries)
        }
    }

    public func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private func samePath(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        if a == b { return true }
        return URL(fileURLWithPath: a).resolvingSymlinksInPath().path == URL(fileURLWithPath: b).resolvingSymlinksInPath().path
    }

    private func handleWindowFocus() {
        refreshTree()
        guard let file = currentFile, !isDirty else { return }
        // A missing/unreadable file here is not an error worth an alert; the tree refresh shows it.
        if let diskText = try? String(contentsOfFile: file, encoding: .utf8)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n"),
           diskText != savedText {
            savedText = diskText
            editorText = diskText
            updateOutlineImmediately()
            if mode == .latex {
                resolveLatexContext(for: file)
            }
        }
    }

    public func openFile(_ path: String, revealLine: Int? = nil) {
        if samePath(path, currentFile) {
            if let revealLine { revealLineInEditor(revealLine) }
            return
        }
        guard confirmCloseIfNeeded() else { return }
        if let prev = currentFile {
            cursorCache[prev] = (cursorLine, cursorCol)
        }

        do {
            let raw = try String(contentsOfFile: path, encoding: .utf8)
            let normalized = raw
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            currentFile = path
            savedText = normalized
            editorText = normalized

            if let revealLine {
                cursorLine = revealLine
                cursorCol = 1
                revealLineInEditor(revealLine)
            } else if let savedCursor = cursorCache[path] {
                cursorLine = savedCursor.line
                cursorCol = savedCursor.col
            } else {
                cursorLine = 1
                cursorCol = 1
            }

            updateOutlineImmediately()
            updateActiveOutlineHeading()
            appState.notifyFileChanged(mode: mode, folder: folder, file: path)

            if mode == .latex {
                resolveLatexContext(for: path)
            } else if mode == .mermaid {
                mermaidError = nil
                mermaidZoom = 1.0
                mermaidPan = .zero
            }
        } catch {
            showToast("Couldn't open \((path as NSString).lastPathComponent): \(error.localizedDescription)", isError: true)
        }
    }

    public func revealLineInEditor(_ line: Int) {
        revealRequest = (UUID(), max(1, line))
    }

    public func onTextEdited(_ newText: String) {
        if editorText != newText {
            editorText = newText
        }
        outlineTask?.cancel()
        outlineTask = Task {
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }
            updateOutlineImmediately()
        }
    }

    public func onCursorChanged(line: Int, col: Int) {
        if cursorLine != line { cursorLine = line }
        if cursorCol != col { cursorCol = col }
        updateActiveOutlineHeading()
    }

    private func updateOutlineImmediately() {
        guard mode != .mermaid, currentFile != nil else {
            outlineHeadings = []
            activeOutlineLine = nil
            return
        }
        outlineHeadings = FileService.outlineOf(mode: mode, text: editorText)
        updateActiveOutlineHeading()
    }

    private func updateActiveOutlineHeading() {
        let matched = outlineHeadings.last { $0.line <= cursorLine }?.line
        if activeOutlineLine != matched {
            activeOutlineLine = matched
        }
    }

    private func clearCurrentFile() {
        currentFile = nil
        editorText = ""
        savedText = ""
        outlineHeadings = []
        activeOutlineLine = nil
        rootTexPath = nil
        activePdfPath = nil
        pdfDocument = nil
        compileResult = nil
        isSnippetMode = false
        appState.notifyFileChanged(mode: mode, folder: folder, file: nil)
    }

    // MARK: - Saving & Unsaved Prompt

    private var compileOnSave: Bool {
        UserDefaults.standard.object(forKey: AppSettings.compileOnSave) as? Bool ?? true
    }

    /// Writes the buffer without triggering a build.
    private func writeToDisk() -> Bool {
        guard let path = currentFile else { return true }
        guard isDirty else { return true }
        do {
            try FileService.atomicWriteText(path: path, contents: editorText)
            savedText = editorText
            return true
        } catch {
            showToast("Couldn't save \((path as NSString).lastPathComponent): \(error.localizedDescription)", isError: true)
            return false
        }
    }

    @discardableResult
    public func save() -> Bool {
        let wasDirty = isDirty
        guard writeToDisk() else { return false }
        if wasDirty, mode == .latex, compileOnSave {
            startCompile(announceMissingRoot: false)
        }
        return true
    }

    /// Shows a native macOS `NSAlert` if the current buffer has unsaved changes. Returns `false` if cancelled or save failed.
    public func confirmCloseIfNeeded() -> Bool {
        guard isDirty, let path = currentFile else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Do you want to save the changes you made to \((path as NSString).lastPathComponent)?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return writeToDisk()
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    // MARK: - File operations

    /// Asks for a name (alert with text field), then creates the file in `directory` (default: project folder).
    public func createNewFile(in directory: String? = nil) {
        promptText = ""
        namePrompt = NamePrompt(kind: .newFile(directory: directory ?? folder))
    }

    public func requestRename(_ path: String) {
        promptText = (path as NSString).lastPathComponent
        namePrompt = NamePrompt(kind: .rename(path: path))
    }

    public func requestTrash(_ path: String) {
        trashTarget = path
    }

    public func commitNamePrompt() {
        guard let prompt = namePrompt else { return }
        namePrompt = nil
        guard let name = validatedName(promptText) else { return }
        switch prompt.kind {
        case .newFile(let directory): performCreate(name: name, in: directory)
        case .rename(let path): performRename(path, to: name)
        }
    }

    /// Trims, rejects empty/path-like names, and appends the mode's default extension when missing.
    private func validatedName(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        guard !name.contains("/"), !name.contains(":"), name != ".", name != ".." else {
            showToast("File names can't contain “/” or “:”.", isError: true)
            return nil
        }
        let ext = (name as NSString).pathExtension.lowercased()
        if ext.isEmpty {
            name += "." + (mode.extensions.first ?? "txt")
        } else if !mode.extensions.contains(ext) {
            showToast("A \(mode.displayName) project can only contain \(mode.extensions.map { ".\($0)" }.joined(separator: ", ")) files.", isError: true)
            return nil
        }
        return name
    }

    private func performCreate(name: String, in directory: String) {
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            showToast("“\(name)” already exists.", isError: true)
            return
        }
        // The first file in an empty project gets the starter template.
        let starter = mode.starterFile
        let isFirst = flatFiles.isEmpty
        do {
            try FileService.atomicWriteText(path: url.path, contents: isFirst ? starter.contents : "")
            refreshTree()
            openFile(url.path, revealLine: isFirst ? starter.initialLine : nil)
        } catch {
            showToast("Couldn't create “\(name)”: \(error.localizedDescription)", isError: true)
        }
    }

    private func performRename(_ path: String, to name: String) {
        let src = URL(fileURLWithPath: path)
        guard src.lastPathComponent != name else { return }
        let dest = src.deletingLastPathComponent().appendingPathComponent(name)
        let fm = FileManager.default
        // Case-only rename on a case-insensitive volume: dest "exists" but is the same file.
        let caseOnly = src.lastPathComponent.lowercased() == name.lowercased()
            && (try? fm.attributesOfItem(atPath: src.path)[.systemFileNumber] as? Int)
                == (try? fm.attributesOfItem(atPath: dest.path)[.systemFileNumber] as? Int)
        guard caseOnly || !fm.fileExists(atPath: dest.path) else {
            showToast("“\(name)” already exists.", isError: true)
            return
        }
        do {
            if caseOnly {
                let tmp = src.deletingLastPathComponent().appendingPathComponent(".rename-\(UUID().uuidString)")
                try fm.moveItem(at: src, to: tmp)
                do { try fm.moveItem(at: tmp, to: dest) } catch {
                    try? fm.moveItem(at: tmp, to: src)
                    throw error
                }
            } else {
                try fm.moveItem(at: src, to: dest)
            }
        } catch {
            showToast("Couldn't rename: \(error.localizedDescription)", isError: true)
            return
        }
        if samePath(path, currentFile) {
            cursorCache[dest.path] = (cursorLine, cursorCol)
            currentFile = dest.path  // buffer (and dirty state) stay as they are
            if mode == .latex {
                rootTexPath = nil
                resolveLatexContext(for: dest.path)
            }
            appState.notifyFileChanged(mode: mode, folder: folder, file: dest.path)
        }
        refreshTree()
    }

    public func duplicateFile(_ path: String) {
        let src = URL(fileURLWithPath: path)
        let dir = src.deletingLastPathComponent()
        let stem = src.deletingPathExtension().lastPathComponent
        let ext = src.pathExtension
        var n = 1
        var dest: URL
        repeat {
            let suffix = n == 1 ? " copy" : " copy \(n)"
            dest = dir.appendingPathComponent(stem + suffix).appendingPathExtension(ext)
            n += 1
        } while FileManager.default.fileExists(atPath: dest.path)
        do {
            try FileManager.default.copyItem(at: src, to: dest)
            refreshTree()
            openFile(dest.path)
        } catch {
            showToast("Couldn't duplicate: \(error.localizedDescription)", isError: true)
        }
    }

    public func performTrash() {
        guard let path = trashTarget else { return }
        trashTarget = nil
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        } catch {
            showToast("Couldn't move to Trash: \(error.localizedDescription)", isError: true)
            return
        }
        if samePath(path, currentFile) {
            clearCurrentFile()
        }
        refreshTree()
    }

    public func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: - Quick Open (⌘P)

    public var quickOpenHits: [String] {
        FileService.fuzzyFilter(query: quickOpenQuery, files: flatFiles, rootFolder: folder)
    }

    public func toggleQuickOpen() {
        quickOpenQuery = ""
        quickOpenSelection = 0
        isQuickOpenVisible.toggle()
    }

    // MARK: - Layout & zoom

    public func setLayout(_ newLayout: EditorLayout) {
        layout = newLayout
    }

    public func zoom(_ command: PDFZoomCommand) {
        switch mode {
        case .latex:
            pdfZoomCommand = (UUID(), command)
        case .mermaid:
            switch command {
            case .zoomIn: mermaidZoom = min(6.0, mermaidZoom * 1.25)
            case .zoomOut: mermaidZoom = max(0.2, mermaidZoom * 0.8)
            case .set(let s): mermaidZoom = min(6.0, max(0.2, Double(s)))
            case .fitWidth, .fitPage, .actualSize:
                mermaidZoom = 1.0
                mermaidPan = .zero
            }
        case .markdown:
            break
        }
    }

    /// Called by the PDF view whenever its scale changes (possibly during a view update, so deferred).
    public func pdfZoomChanged(_ scale: CGFloat, _ mode: PDFZoomMode) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.pdfZoomMode = mode
            if self.pdfScale != scale { self.pdfScale = scale }
        }
    }

    public var zoomScale: CGFloat {
        mode == .mermaid ? CGFloat(mermaidZoom) : pdfScale
    }

    // MARK: - LaTeX Compilation & SyncTeX

    private var texPathOverride: String? {
        let p = (UserDefaults.standard.string(forKey: AppSettings.texPath) ?? "").trimmingCharacters(in: .whitespaces)
        return p.isEmpty ? nil : p
    }

    private var engineOverride: String? {
        let e = UserDefaults.standard.string(forKey: AppSettings.texEngine) ?? "auto"
        return e == "auto" || e.isEmpty ? nil : e
    }

    private func resolveLatexContext(for path: String) {
        let info = TexService.resolveRootAndEngine(file: path, workspaceRoot: folder)
        if let root = info.root {
            isSnippetMode = false
            texEngine = info.engine
            if rootTexPath != root {
                rootTexPath = root
                compileResult = nil
                let existingPdf = TexService.pdfPath(forRoot: root)
                if FileManager.default.fileExists(atPath: existingPdf),
                   let doc = PDFDocument(url: URL(fileURLWithPath: existingPdf)) {
                    activePdfPath = existingPdf
                    pdfDocument = doc
                } else {
                    activePdfPath = nil
                    pdfDocument = nil
                }
            }
        } else {
            let ext = (path as NSString).pathExtension.lowercased()
            if ext == "tex" || ext == "ltx" {
                isSnippetMode = true
                rootTexPath = nil
                activePdfPath = nil
                pdfDocument = nil
                compileResult = nil
            }
        }
    }

    public func compileOrStop() {
        guard mode == .latex else { return }
        if isCompiling {
            stopCompile()
            return
        }
        guard currentFile != nil else {
            showToast("Open a .tex file first")
            return
        }
        guard appState.texFound || texPathOverride != nil else {
            offerTeXSetup()
            return
        }
        guard writeToDisk() else { return }
        startCompile(announceMissingRoot: true)
    }

    /// A disabled Compile button is a dead end; say what is missing and offer the fix.
    private func offerTeXSetup() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "LaTeX isn't installed"
        alert.informativeText = "Proof needs MacTeX to build PDFs. You can keep writing, and the math preview still works without it."
        alert.addButton(withTitle: "Get MacTeX")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "https://www.tug.org/mactex/") {
            NSWorkspace.shared.open(url)
        }
    }

    public func stopCompile() {
        guard isCompiling else { return }
        texRunner.cancelCompile()
        isCompiling = false  // the cancelled run's result won't re-set it
    }

    /// Starts a build of the current file's root; a running build is restarted.
    private func startCompile(announceMissingRoot: Bool) {
        guard mode == .latex, let file = currentFile else { return }
        let info = TexService.resolveRootAndEngine(file: file, workspaceRoot: folder)
        guard let root = info.root else {
            isSnippetMode = true
            if announceMissingRoot {
                showToast("No \\documentclass: previewing math snippets live. Add \\documentclass to compile.")
            }
            return
        }
        guard appState.texFound || texPathOverride != nil else {
            if announceMissingRoot {
                showToast("LaTeX isn't installed. Install MacTeX to build PDFs.", isError: true)
            }
            return
        }

        isSnippetMode = false
        rootTexPath = root
        texEngine = info.engine

        let runID = texRunner.reserveRunID()
        latestRunID = runID  // reserving cancels any older run; its result is ignored via `runID`
        isCompiling = true
        let manual = announceMissingRoot  // true only for toolbar/menu/⌘↩ builds

        let runner = texRunner
        let engine = engineOverride
        let texbin = texPathOverride
        let vm = self
        Task.detached(priority: .userInitiated) {
            let outcome = Result { try runner.compile(root: root, engine: engine, texbinOverride: texbin, runID: runID) }
            await MainActor.run {
                vm.finishCompile(outcome, root: root, runID: runID, manual: manual)
            }
        }
    }

    private func finishCompile(_ outcome: Result<CompileResult, Error>, root: String, runID: Int, manual: Bool) {
        guard runID == latestRunID else { return }  // a newer run owns the spinner
        isCompiling = false
        guard rootTexPath == root else { return }  // root changed while compiling
        switch outcome {
        case .failure(let err):
            showToast("Compile failed: \(err.localizedDescription)", isError: true)
        case .success(let res):
            if res.cancelled || res.superseded || !texRunner.isCurrentRun(res.runID) { return }
            compileResult = res
            texEngine = res.engine
            if let pdfPath = res.pdfPath,
               let doc = PDFDocument(url: URL(fileURLWithPath: pdfPath)) {
                activePdfPath = pdfPath
                pdfDocument = doc
            }  // else keep the previous PDF on screen
            if res.timedOut {
                showToast("Compilation took longer than 5 minutes and was stopped. See the Log.")
            } else if res.ok {
                showToast(String(format: "Compiled in %.1f s", Double(res.elapsedMs) / 1000.0))
            }
            if !res.ok {
                selectedProblemID = nil
                problemsTab = diagnostics.isEmpty ? .log : .problems
                isProblemsVisible = true
                if let first = visibleDiagnostics.first(where: { !$0.isWarning }) {
                    if manual { jumpToProblem(first) } else { selectedProblemID = first.id }
                }
            }
        }
    }

    public func syncForward() {
        guard mode == .latex else { return }
        guard let file = currentFile, let pdf = activePdfPath, pdfDocument != nil else {
            showToast("Compile first to generate a PDF")
            return
        }
        let line = cursorLine
        let col = cursorCol
        let texbin = texPathOverride
        let vm = self
        Task.detached(priority: .userInitiated) {
            let spots = TexProcessRunner.synctexView(file: file, line: line, col: col, pdf: pdf, texbinOverride: texbin)
            await MainActor.run {
                if spots.isEmpty {
                    vm.showToast("No matching SyncTeX position in PDF")
                } else {
                    vm.syncTexSpots = spots
                    vm.syncTexTrigger = UUID()
                }
            }
        }
    }

    public func syncInverseFromPdf(page: Int, x: Double, y: Double) {
        guard let pdf = activePdfPath else { return }
        let texbin = texPathOverride
        let vm = self
        Task.detached(priority: .userInitiated) {
            let loc = TexProcessRunner.synctexEdit(pdf: pdf, page: page, x: x, y: y, texbinOverride: texbin)
            await MainActor.run {
                if let loc {
                    vm.openFile(loc.file, revealLine: loc.line)  // same file: just reveals the line
                } else {
                    vm.showToast("No source line found for that PDF location")
                }
            }
        }
    }

    /// Asks for confirmation (see WorkspaceView), then `performCleanBuild()`.
    public func cleanBuild() {
        guard mode == .latex else { return }
        isCleanConfirmVisible = true
    }

    public func performCleanBuild() {
        guard let root = rootTexPath else {
            showToast("Nothing to clean: no root document")
            return
        }
        do {
            try TexProcessRunner.cleanBuild(root: root)
            activePdfPath = nil
            pdfDocument = nil
            compileResult = nil
            showToast("Build files removed")
        } catch {
            showToast("Couldn't remove build files: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Export

    public func export() {
        switch mode {
        case .latex: exportPdf()
        case .mermaid: exportMermaid(format: "svg")
        case .markdown: break
        }
    }

    public func exportPdf() {
        guard let pdf = activePdfPath, FileManager.default.fileExists(atPath: pdf) else {
            showToast("Compile first to generate a PDF")
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export PDF"
        panel.nameFieldStringValue = (pdf as NSString).lastPathComponent
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: URL(fileURLWithPath: pdf), to: dest)
            showToast("Exported \(dest.lastPathComponent)")
        } catch {
            showToast("Export failed: \(error.localizedDescription)", isError: true)
        }
    }

    public func exportMermaid(format: String) {
        let stem: String
        if let f = currentFile {
            stem = ((f as NSString).lastPathComponent as NSString).deletingPathExtension
        } else {
            stem = "diagram"
        }
        let panel = NSSavePanel()
        panel.title = "Export Mermaid \(format.uppercased())"
        panel.nameFieldStringValue = "\(stem).\(format)"
        panel.allowedContentTypes = [format].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        mermaidExportRequest = (UUID(), format, dest.path, mermaidWhiteExport)
    }
}
