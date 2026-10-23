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
    public private(set) var savedText: String = ""
    @Published public private(set) var isDirty = false
    @Published public private(set) var wordCount = 0
    @Published public private(set) var textFormat: TextFormat = .default
    @Published public var cursorLine: Int = 1
    @Published public var cursorCol: Int = 1
    @Published public var topVisibleLine: Int = 1
    @Published public var revealRequest: (id: UUID, line: Int)?
    @Published public var formatRequest: (id: UUID, kind: FormatKind)?
    @Published public var editRequest: (id: UUID, range: NSRange, replacement: String)?
    @Published public var layout: EditorLayout = .split

    /// A file that changed on disk while the buffer had unsaved edits.
    public struct ExternalChange: Identifiable {
        public let id = UUID()
        public let path: String
        public let text: String
        public let format: TextFormat
        /// Identifies this version of the disk contents, so "Keep My Changes" is not re-asked.
        let signature: String
    }
    @Published public var externalChange: ExternalChange?
    private var dismissedExternalSignature: String?

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
        public enum Kind { case newFile(directory: String), newFolder(directory: String), rename(path: String) }
        public let id = UUID()
        public let kind: Kind
    }
    @Published public var namePrompt: NamePrompt?
    @Published public var promptText: String = ""
    @Published public var isGoToLineVisible: Bool = false
    @Published public var goToLineText: String = ""
    @Published public var trashTarget: String?
    @Published public var isCleanConfirmVisible: Bool = false

    // LaTeX Mode State
    @Published public var rootTexPath: String?
    @Published public var texEngine: String = "pdflatex"
    @Published public var isSnippetMode: Bool = false
    @Published public var isCompiling: Bool = false
    @Published public var compileResult: CompileResult?
    @Published public private(set) var buildLogLines: [BuildLogLine] = []
    @Published public var activePdfPath: String?
    @Published public var pdfDocument: PDFDocument?
    @Published public var syncTexSpots: [SyncTexSpot] = []
    @Published public var syncTexTrigger: UUID = UUID()
    @Published public var pdfZoomCommand: (id: UUID, command: PDFZoomCommand)?
    @Published public var pdfActionRequest: (id: UUID, action: PDFAction)?
    @Published public var pdfScale: CGFloat = 1.0
    @Published public var pdfPage: Int = 1
    @Published public var pdfPageCount: Int = 0
    @Published public var isPDFSearchVisible: Bool = false
    @Published public var pdfSearchQuery: String = ""
    @Published public private(set) var pdfFindCurrent = 0
    @Published public private(set) var pdfFindTotal: Int?
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
    @Published public var markdownExportRequest: (id: UUID, destPath: String)?

    private let texRunner = TexProcessRunner()
    private var latestRunID = -1  // newest run reserved by this VM
    private var outlineTask: Task<Void, Never>?
    private var textFlushTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var pendingText: String?
    private var offeredRecoveryPaths = Set<String>()
    private var focusObserver: NSObjectProtocol?
    private var cursorCache: [String: (line: Int, col: Int)] = [:]
    private var treeTask: Task<Void, Never>?
    private var treeGeneration = 0

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

    public func jumpToLogLine(_ line: BuildLogLine) {
        guard let file = line.file, let number = line.line else { return }
        let target: String
        if FileManager.default.fileExists(atPath: file) {
            target = file
        } else {
            // Some tools print paths that differ from the workspace spelling (or use a
            // symlinked build directory). Fall back to the deepest matching suffix.
            let suffix = file.split(separator: "/").suffix(2).joined(separator: "/")
            target = flatFiles.first { $0.hasSuffix("/" + suffix) } ?? file
        }
        openFile(target, revealLine: max(1, number))
    }

    // MARK: - Init / teardown

    public init(mode: WorkspaceMode, folder: String, initialFile: String?, appState: AppState) {
        self.mode = mode
        self.folder = folder
        self.appState = appState

        refreshTreeSynchronously()
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
        textFlushTask?.cancel()
        recoveryTask?.cancel()
        statusTask?.cancel()
        latestRunID = -1
        texRunner.cancelCompile()
        if let focusObserver {
            NotificationCenter.default.removeObserver(focusObserver)
            self.focusObserver = nil
        }
    }

    /// After the window closed: SwiftUI's menu commands can keep the last focused view model alive
    /// (via @FocusedObject), so drop what is heavy. Text and the current file stay untouched.
    public func releaseMemory() {
        treeGeneration += 1
        treeTask?.cancel()
        pdfDocument = nil
        compileResult = nil
        buildLogLines = []
        syncTexSpots = []
        treeEntries = []
        flatFiles = []
        outlineHeadings = []
        cursorCache = [:]
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
        return sorted.first ?? flatFiles.first {
            mode.extensions.contains(($0 as NSString).pathExtension.lowercased())
        }
    }

    private func refreshTreeSynchronously() {
        treeGeneration += 1
        let entries = FileService.listTree(root: folder, extensions: mode.browsableExtensions)
        treeEntries = entries
        flatFiles = FileService.flattenFiles(entries)
    }

    /// Rescans off the main actor: a project with thousands of files must not stall typing.
    public func refreshTree() {
        treeGeneration += 1
        let generation = treeGeneration
        let root = folder
        let extensions = mode.browsableExtensions
        treeTask?.cancel()
        treeTask = Task.detached(priority: .userInitiated) {
            let entries = FileService.listTree(root: root, extensions: extensions)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.treeGeneration == generation else { return }
                if entries != self.treeEntries {
                    self.treeEntries = entries
                    self.flatFiles = FileService.flattenFiles(entries)
                }
            }
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
        flushText()
        guard let file = currentFile else { return }
        // A missing/unreadable file here is not an error worth an alert; the tree refresh shows it.
        guard let disk = try? TextFile.read(path: file) else { return }
        guard disk.text != savedText else { return }

        if isDirty, disk.text != editorText {
            // Someone else wrote the file while we had unsaved edits. Ask instead of
            // silently overwriting their work on the next save.
            let signature = "\(file)|\(disk.text.hashValue)"
            if signature != dismissedExternalSignature {
                externalChange = ExternalChange(
                    path: file,
                    text: disk.text,
                    format: disk.format,
                    signature: signature
                )
            }
            return
        }

        guard !isDirty else { return }
        textFormat = disk.format
        savedText = disk.text
        editorText = disk.text
        isDirty = false
        wordCount = Self.countWords(disk.text)
        updateOutlineImmediately()
        if mode == .latex {
            resolveLatexContext(for: file)
        }
    }

    public func reloadExternalChange() {
        guard let change = externalChange else { return }
        externalChange = nil
        dismissedExternalSignature = change.signature
        guard samePath(change.path, currentFile) else { return }
        textFormat = change.format
        savedText = change.text
        editorText = change.text
        pendingText = nil
        isDirty = false
        wordCount = Self.countWords(change.text)
        updateOutlineImmediately()
        RecoveryStore.remove(folder: folder, path: change.path)
        if mode == .latex {
            resolveLatexContext(for: change.path)
        }
    }

    public func keepExternalChange() {
        dismissedExternalSignature = externalChange?.signature
        externalChange = nil
    }

    public func openFile(_ path: String, revealLine: Int? = nil) {
        if samePath(path, currentFile) {
            if let revealLine { revealLineInEditor(revealLine) }
            return
        }
        // Assets (images, PDFs) are visible in the tree but are not text buffers. Hand them
        // to the system instead of decoding them into the editor and corrupting them on save.
        guard FileService.isTextPath(path) else {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }
        guard confirmCloseIfNeeded() else { return }
        if let prev = currentFile {
            cursorCache[prev] = (cursorLine, cursorCol)
        }

        do {
            let contents = try TextFile.read(path: path)
            currentFile = path
            textFormat = contents.format
            savedText = contents.text
            editorText = contents.text
            pendingText = nil
            isDirty = false
            wordCount = Self.countWords(contents.text)

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
            // Let the window appear first: this runs during view-model construction on launch,
            // and an app-modal alert before any window exists looks stranded.
            let openingPath = path
            let diskText = contents.text
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled else { return }
                self?.offerRecoveryIfNeeded(for: openingPath, diskText: diskText)
            }

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

    /// The text the plain editor should show. It includes keystrokes that have not been
    /// published yet (the debounce exists to avoid re-rendering every view on each key),
    /// so SwiftUI's periodic updates never push a stale buffer back into the text view.
    public var liveEditorText: String { pendingText ?? editorText }

    public func onTextEdited(_ newText: String) {
        // Do not publish the whole document on every keystroke: seven views observe this
        // object, and each publish re-runs their bodies. Coalesce to one update per pause.
        pendingText = newText
        textFlushTask?.cancel()
        textFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled else { return }
            self?.flushText()
        }
    }

    /// Applies any pending edit immediately. Saves, window closes and compile must call
    /// this first so they never write the pre-debounce buffer.
    public func flushText() {
        textFlushTask?.cancel()
        textFlushTask = nil
        guard let text = pendingText else { return }
        pendingText = nil
        if editorText != text { editorText = text }
        isDirty = currentFile != nil && text != savedText
        wordCount = Self.countWords(text)
        updateOutlineImmediately()
        scheduleRecoveryCopy()
    }

    private static func countWords(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace {
                inWord = false
            } else if !inWord {
                inWord = true
                count += 1
            }
        }
        return count
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
        pendingText = nil
        isDirty = false
        wordCount = 0
        textFormat = .default
        externalChange = nil
        dismissedExternalSignature = nil
        outlineHeadings = []
        activeOutlineLine = nil
        rootTexPath = nil
        activePdfPath = nil
        pdfDocument = nil
        pdfPage = 1
        pdfPageCount = 0
        compileResult = nil
        buildLogLines = []
        isSnippetMode = false
        appState.notifyFileChanged(mode: mode, folder: folder, file: nil)
    }

    // MARK: - Crash recovery

    private func scheduleRecoveryCopy() {
        guard isDirty, currentFile != nil else { return }
        recoveryTask?.cancel()
        recoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.saveRecoveryCopy()
        }
    }

    private func saveRecoveryCopy() {
        guard let file = currentFile else { return }
        // Use the live buffer: teardown can run before the 90 ms debounce publishes it.
        let text = pendingText ?? editorText
        guard text != savedText else { return }
        RecoveryStore.write(path: file, folder: folder, text: text, format: textFormat)
    }

    /// Offers a backup only when it differs from what is on disk. A stale snapshot that
    /// matches the file is simply deleted.
    private func offerRecoveryIfNeeded(for path: String, diskText: String) {
        guard samePath(path, currentFile) else { return }
        let key = URL(fileURLWithPath: path).standardizedFileURL.path
        guard !offeredRecoveryPaths.contains(key) else { return }
        offeredRecoveryPaths.insert(key)
        guard let snapshot = RecoveryStore.load(folder: folder, path: path) else { return }
        guard snapshot.text != diskText else {
            RecoveryStore.remove(folder: folder, path: path)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Recover unsaved changes to \((path as NSString).lastPathComponent)?"
        alert.informativeText = "Proof found a backup from \(Self.recoveryDateFormatter.string(from: snapshot.savedAtDate))."
        alert.addButton(withTitle: "Recover")
        alert.addButton(withTitle: "Discard")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            textFormat = snapshot.format
            editorText = snapshot.text
            isDirty = snapshot.text != savedText
            wordCount = Self.countWords(snapshot.text)
            updateOutlineImmediately()
            showToast("Recovered unsaved changes")
        } else {
            RecoveryStore.remove(folder: folder, path: path)
        }
    }

    private static let recoveryDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    // MARK: - Saving & Unsaved Prompt

    private var compileOnSave: Bool {
        UserDefaults.standard.object(forKey: AppSettings.compileOnSave) as? Bool ?? true
    }

    /// Writes the buffer without triggering a build.
    private func writeToDisk() -> Bool {
        flushText()
        guard let path = currentFile else { return true }
        guard isDirty else { return true }
        do {
            try FileService.atomicWriteText(path: path, contents: editorText, format: textFormat)
            savedText = editorText
            isDirty = false
            RecoveryStore.remove(folder: folder, path: path)
            return true
        } catch {
            showToast("Couldn't save \((path as NSString).lastPathComponent): \(error.localizedDescription)", isError: true)
            return false
        }
    }

    @discardableResult
    public func save() -> Bool {
        flushText()
        let wasDirty = isDirty
        guard writeToDisk() else { return false }
        if wasDirty, mode == .latex, compileOnSave {
            startCompile(announceMissingRoot: false)
        }
        return true
    }

    /// Shows a native macOS `NSAlert` if the current buffer has unsaved changes. Returns `false` if cancelled or save failed.
    public func confirmCloseIfNeeded() -> Bool {
        flushText()
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
            // An explicit discard must not be offered back at the next launch.
            RecoveryStore.remove(folder: folder, path: path)
            return true
        default:
            return false
        }
    }

    // MARK: - File operations

    public func presentGoToLine() {
        guard currentFile != nil else { return }
        goToLineText = "\(cursorLine)"
        isGoToLineVisible = true
    }

    public func commitGoToLine() {
        isGoToLineVisible = false
        guard let line = Int(goToLineText.trimmingCharacters(in: .whitespaces)), line > 0 else {
            showToast("Enter a line number", isError: true)
            return
        }
        if layout == .preview { layout = .split }
        revealLineInEditor(line)
    }

    /// A task checkbox in the Markdown preview toggles the source token in place. The
    /// edit goes through the editor so it is undoable with ⌘Z and updates dirty state.
    public func toggleTask(atLine line: Int, checked: Bool) {
        guard mode == .markdown, currentFile != nil, line > 0 else { return }
        flushText()
        let ns = editorText as NSString
        var location = 0
        var current = 1
        while current < line, location < ns.length {
            let range = ns.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
            current += 1
        }
        guard location <= ns.length else { return }
        let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
        let lineText = ns.substring(with: lineRange) as NSString
        guard let match = Self.taskRegex.firstMatch(
            in: lineText as String,
            range: NSRange(location: 0, length: lineText.length)
        ) else { return }
        let replacement = checked ? "[x]" : "[ ]"
        editRequest = (
            UUID(),
            NSRange(location: lineRange.location + match.range.location, length: match.range.length),
            replacement
        )
    }

    private static let taskRegex = try! NSRegularExpression(pattern: #"\[( |x|X)\]"#)

    /// Asks for a name (alert with text field), then creates the file in `directory` (default: project folder).
    public func createNewFile(in directory: String? = nil) {
        promptText = ""
        namePrompt = NamePrompt(kind: .newFile(directory: directory ?? folder))
    }

    public func createNewFolder(in directory: String? = nil) {
        promptText = ""
        namePrompt = NamePrompt(kind: .newFolder(directory: directory ?? folder))
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
        switch prompt.kind {
        case .newFile(let directory):
            guard let name = validatedName(promptText) else { return }
            performCreate(name: name, in: directory)
        case .newFolder(let directory):
            guard let name = validatedFolderName(promptText) else { return }
            performCreateFolder(name: name, in: directory)
        case .rename(let path):
            guard let name = validatedName(promptText) else { return }
            performRename(path, to: name)
        }
    }

    private func validatedFolderName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        guard !name.contains("/"), !name.contains(":"), name != ".", name != ".." else {
            showToast("Folder names can't contain “/” or “:”.", isError: true)
            return nil
        }
        return name
    }

    private func performCreateFolder(name: String, in directory: String) {
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            showToast("“\(name)” already exists.", isError: true)
            return
        }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            refreshTree()
        } catch {
            showToast("Couldn't create “\(name)”: \(error.localizedDescription)", isError: true)
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
        let isFirst = !flatFiles.contains { mode.primaryExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
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
        updatePreferredMainFile(from: path, to: dest.path)
        if samePath(path, currentFile) {
            cursorCache[dest.path] = (cursorLine, cursorCol)
            currentFile = dest.path  // buffer (and dirty state) stay as they are
            RecoveryStore.remove(folder: folder, path: path)
            scheduleRecoveryCopy()
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
        RecoveryStore.remove(folder: folder, path: path)
        removePreferredMainFile(path)
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

    // MARK: - PDF find, page navigation and printing

    public var canPrintPDF: Bool { mode == .latex && !isSnippetMode && pdfDocument != nil }

    public func printPDF() {
        guard canPrintPDF else { return }
        pdfActionRequest = (UUID(), .print)
    }

    public func togglePDFSearch() {
        isPDFSearchVisible.toggle()
        if isPDFSearchVisible {
            // Re-opening Find keeps the last query, like the system Find panel.
            let query = pdfSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            if !query.isEmpty {
                pdfActionRequest = (UUID(), .find(query, forward: true))
            }
        } else {
            pdfFindCurrent = 0
            pdfFindTotal = nil
            pdfActionRequest = (UUID(), .clearFind)
        }
    }

    public func findInPDF(forward: Bool = true) {
        let query = pdfSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            // First use of Find Next: open the bar so the field has focus.
            if !isPDFSearchVisible { isPDFSearchVisible = true }
            return
        }
        if !isPDFSearchVisible { isPDFSearchVisible = true }
        pdfActionRequest = (UUID(), .find(query, forward: forward))
    }

    /// A fresh query has no results yet; the find bar shows nothing until Enter.
    public func resetPDFFindProgress() {
        if pdfFindCurrent != 0 { pdfFindCurrent = 0 }
        if pdfFindTotal != nil { pdfFindTotal = nil }
    }

    public func goToPDFPage(_ page: Int) {
        guard pdfPageCount > 0 else { return }
        pdfActionRequest = (UUID(), .goToPage(min(max(1, page), pdfPageCount)))
    }

    /// Reported by the PDF view. Deferred because it can fire while SwiftUI is updating it.
    public func pdfPageChanged(_ page: Int, count: Int) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.pdfPageCount != count { self.pdfPageCount = count }
            if self.pdfPage != page { self.pdfPage = page }
        }
    }

    /// 0 of 0 means the query has no matches; nil means no search is running.
    public func pdfFindProgressChanged(current: Int?, total: Int?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let currentValue = current ?? 0
            if self.pdfFindCurrent != currentValue { self.pdfFindCurrent = currentValue }
            if self.pdfFindTotal != total { self.pdfFindTotal = total }
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

    private var standardizedFolder: String {
        URL(fileURLWithPath: folder).standardizedFileURL.path
    }

    /// The user's explicit main document for this project, if it still exists.
    public var preferredMainFile: String? {
        let map = UserDefaults.standard.dictionary(forKey: AppSettings.mainFiles) as? [String: String] ?? [:]
        guard let path = map[standardizedFolder], FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }

    /// Chooses the document that Compile builds, independent of which chapter is open.
    public func setAsMainFile(_ path: String) {
        guard mode == .latex else { return }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: standardized) else { return }
        let info = TexService.resolveRootAndEngine(file: standardized, workspaceRoot: folder)
        guard info.root == standardized else {
            showToast("\((standardized as NSString).lastPathComponent) has no \\documentclass, so it can't be the main file.", isError: true)
            return
        }
        var map = UserDefaults.standard.dictionary(forKey: AppSettings.mainFiles) as? [String: String] ?? [:]
        map[standardizedFolder] = standardized
        UserDefaults.standard.set(map, forKey: AppSettings.mainFiles)
        rootTexPath = nil
        resolveLatexContext(for: currentFile ?? standardized)
        showToast("Main file: \((standardized as NSString).lastPathComponent)")
    }

    public func revealMainFile() {
        guard let root = rootTexPath else { return }
        openFile(root)
    }

    private func updatePreferredMainFile(from oldPath: String, to newPath: String) {
        var map = UserDefaults.standard.dictionary(forKey: AppSettings.mainFiles) as? [String: String] ?? [:]
        let standardizedOld = URL(fileURLWithPath: oldPath).standardizedFileURL.path
        guard map[standardizedFolder] == standardizedOld else { return }
        map[standardizedFolder] = URL(fileURLWithPath: newPath).standardizedFileURL.path
        UserDefaults.standard.set(map, forKey: AppSettings.mainFiles)
    }

    private func removePreferredMainFile(_ path: String) {
        var map = UserDefaults.standard.dictionary(forKey: AppSettings.mainFiles) as? [String: String] ?? [:]
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard map[standardizedFolder] == standardized else { return }
        map.removeValue(forKey: standardizedFolder)
        UserDefaults.standard.set(map, forKey: AppSettings.mainFiles)
    }

    private func resolveLatexContext(for path: String) {
        var info = TexService.resolveRootAndEngine(file: path, workspaceRoot: folder)
        // A project may contain several \documentclass files (article + beamer, a
        // standalone figure, a letter). The user's explicit choice wins, as long as
        // the file still exists and is still a root document.
        if let preferred = preferredMainFile {
            let preferredInfo = TexService.resolveRootAndEngine(file: preferred, workspaceRoot: folder)
            if preferredInfo.root == preferred {
                info = preferredInfo
            }
        }
        if let root = info.root {
            isSnippetMode = false
            texEngine = info.engine
            if rootTexPath != root {
                rootTexPath = root
                compileResult = nil
                buildLogLines = []
                let existingPdf = TexService.pdfPath(forRoot: root)
                if FileManager.default.fileExists(atPath: existingPdf),
                   let doc = PDFDocument(url: URL(fileURLWithPath: existingPdf)) {
                    activePdfPath = existingPdf
                    pdfDocument = doc
                    pdfPage = 1
                    pdfPageCount = doc.pageCount
                } else {
                    activePdfPath = nil
                    pdfDocument = nil
                    pdfPage = 1
                    pdfPageCount = 0
                }
            }
        } else {
            let ext = (path as NSString).pathExtension.lowercased()
            if ext == "tex" || ext == "ltx" {
                isSnippetMode = true
                rootTexPath = nil
                activePdfPath = nil
                pdfDocument = nil
                pdfPage = 1
                pdfPageCount = 0
                compileResult = nil
                buildLogLines = []
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
            compileResult = nil
            buildLogLines = [BuildLogLine(id: 0, text: err.localizedDescription, severity: .error)]
            showToast("Compile failed: \(err.localizedDescription)", isError: true)
        case .success(let res):
            if res.cancelled || res.superseded || !texRunner.isCurrentRun(res.runID) { return }
            compileResult = res
            buildLogLines = BuildLog.parse(res.log, root: folder)
            texEngine = res.engine
            if let pdfPath = res.pdfPath,
               let doc = PDFDocument(url: URL(fileURLWithPath: pdfPath)) {
                activePdfPath = pdfPath
                pdfDocument = doc
                pdfPage = 1
                pdfPageCount = doc.pageCount
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
            pdfPage = 1
            pdfPageCount = 0
            compileResult = nil
            buildLogLines = []
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
        case .markdown: exportMarkdownPDF()
        }
    }

    /// Exports the rendered preview, not the Markdown source: math, diagrams, tables
    /// and code highlighting are part of the document the user is looking at.
    public func exportMarkdownPDF() {
        guard currentFile != nil else {
            showToast("Open a Markdown file first")
            return
        }
        flushText()
        let stem = currentFile.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? "document"
        let panel = NSSavePanel()
        panel.title = "Export PDF"
        panel.nameFieldStringValue = "\(stem).pdf"
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        markdownExportRequest = (UUID(), dest.path)
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
