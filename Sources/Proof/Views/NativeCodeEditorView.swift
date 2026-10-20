import AppKit
import ProofCore
import SwiftUI

public struct NativeCodeEditorView: NSViewRepresentable {
    public let mode: WorkspaceMode
    public let fileKey: String?
    public let text: String
    public let revealRequest: (id: UUID, line: Int)?
    public let formatRequest: (id: UUID, kind: WorkspaceViewModel.FormatKind)?
    public let editRequest: (id: UUID, range: NSRange, replacement: String)?
    public let onTextChange: (String) -> Void
    public let onCursorChange: (Int, Int) -> Void
    public let onTopLineChange: (Int) -> Void
    public let fontSize: CGFloat
    public let showLineNumbers: Bool
    public let wrapLines: Bool
    public let diagnostics: [TexDiagnostic]

    public init(
        mode: WorkspaceMode,
        fileKey: String?,
        text: String,
        revealRequest: (id: UUID, line: Int)?,
        formatRequest: (id: UUID, kind: WorkspaceViewModel.FormatKind)?,
        editRequest: (id: UUID, range: NSRange, replacement: String)? = nil,
        diagnostics: [TexDiagnostic] = [],
        onTextChange: @escaping (String) -> Void,
        onCursorChange: @escaping (Int, Int) -> Void,
        onTopLineChange: @escaping (Int) -> Void,
        fontSize: CGFloat = 13,
        showLineNumbers: Bool = true,
        wrapLines: Bool = true
    ) {
        self.fontSize = fontSize
        self.showLineNumbers = showLineNumbers
        self.wrapLines = wrapLines
        self.mode = mode
        self.fileKey = fileKey
        self.text = text
        self.revealRequest = revealRequest
        self.formatRequest = formatRequest
        self.editRequest = editRequest
        self.diagnostics = diagnostics
        self.onTextChange = onTextChange
        self.onCursorChange = onCursorChange
        self.onTopLineChange = onTopLineChange
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    static func applyWrap(_ wrap: Bool, scrollView: NSScrollView, textView: ProofTextView) {
        guard let tc = textView.textContainer else { return }
        scrollView.hasHorizontalScroller = !wrap
        textView.isHorizontallyResizable = !wrap
        tc.widthTracksTextView = wrap
        textView.autoresizingMask = wrap ? [.width] : []
        if wrap {
            let w = scrollView.contentSize.width
            tc.containerSize = NSSize(width: w, height: CGFloat.greatestFiniteMagnitude)
            textView.setFrameSize(NSSize(width: w, height: textView.frame.height))
        } else {
            tc.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
    }

    static func typingAttributes(fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: SyntaxHighlighter.paragraphStyle()
        ]
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        // Trackpad gestures may move both axes at once. AppKit otherwise snaps a
        // gesture to its predominant axis, which makes diagonal scrolling impossible.
        scrollView.usesPredominantAxisScrolling = false

        let contentSize = scrollView.contentSize
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        // Only lay out what is visible. Without this, opening a long chapter lays out
        // the entire document before the first frame, and typing re-lays-out it all.
        layoutManager.allowsNonContiguousLayout = true
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer(containerSize: NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(textContainer)

        let textView = ProofTextView(frame: NSRect(origin: .zero, size: contentSize), textContainer: textContainer)
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        // Code editor: no typographic or spelling substitutions.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.insertionPointColor = .controlAccentColor
        textView.textContainerInset = NSSize(width: 10, height: 14)
        textView.delegate = context.coordinator
        textView.mode = mode
        textStorage.delegate = textView
        textView.defaultParagraphStyle = SyntaxHighlighter.paragraphStyle()
        textView.typingAttributes = Self.typingAttributes(fontSize: fontSize)
        textView.setAccessibilityLabel("Source editor")

        scrollView.documentView = textView
        Self.applyWrap(wrapLines, scrollView: scrollView, textView: textView)

        let ruler = LineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = showLineNumbers

        let c = context.coordinator
        c.textView = textView
        c.rulerView = ruler
        c.appliedFontSize = fontSize
        c.appliedWrap = wrapLines
        c.appliedMode = mode
        c.setupNotifications(scrollView: scrollView, textView: textView)
        textView.onAppearanceChange = { [weak c] in c?.fullHighlight() }

        textView.string = text
        textView.invalidateLineIndex()
        c.loadedFileKey = fileKey
        c.fullHighlight()
        c.applyDiagnostics(diagnostics)
        ruler.needsDisplay = true

        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let textView = c.textView else { return }

        var needsFullHighlight = false
        textView.mode = mode
        if c.appliedMode != mode {
            c.appliedMode = mode
            needsFullHighlight = true
        }
        if c.appliedFontSize != fontSize {
            c.appliedFontSize = fontSize
            textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            textView.typingAttributes = Self.typingAttributes(fontSize: fontSize)
            needsFullHighlight = true
        }
        if c.appliedWrap != wrapLines {
            c.appliedWrap = wrapLines
            Self.applyWrap(wrapLines, scrollView: scrollView, textView: textView)
        }
        if scrollView.rulersVisible != showLineNumbers {
            scrollView.rulersVisible = showLineNumbers
        }

        if c.loadedFileKey != fileKey || (!c.isEditing && textView.string != text) {
            c.isProgrammaticChange = true
            let sameFile = c.loadedFileKey == fileKey
            let oldRanges = textView.selectedRanges
            textView.string = text
            textView.invalidateLineIndex()
            needsFullHighlight = true
            let length = (text as NSString).length
            if sameFile {
                // Selections may be past the end after an external replacement.
                let clamped = oldRanges.map { v -> NSValue in
                    let r = v.rangeValue
                    let loc = min(r.location == NSNotFound ? 0 : r.location, length)
                    return NSValue(range: NSRange(location: loc, length: min(r.length, length - loc)))
                }
                textView.selectedRanges = clamped.isEmpty ? [NSValue(range: NSRange(location: 0, length: 0))] : clamped
            } else {
                textView.undoManager?.removeAllActions()
                textView.setSelectedRange(NSRange(location: 0, length: 0))
            }
            c.loadedFileKey = fileKey
            c.isProgrammaticChange = false
        }

        if needsFullHighlight { c.fullHighlight() }
        if c.appliedDiagnostics != diagnostics {
            c.applyDiagnostics(diagnostics)
        }
        c.rulerView?.needsDisplay = true

        if let req = revealRequest, req.id != c.lastRevealID {
            c.lastRevealID = req.id
            c.revealLine(req.line)
        }

        if let req = editRequest, req.id != c.lastEditID {
            c.lastEditID = req.id
            let length = (textView.string as NSString).length
            if req.range.location != NSNotFound, NSMaxRange(req.range) <= length,
               textView.shouldChangeText(in: req.range, replacementString: req.replacement) {
                let selection = textView.selectedRanges
                textView.insertText(req.replacement, replacementRange: req.range)
                textView.selectedRanges = selection
            }
        }

        if let fmt = formatRequest, fmt.id != c.lastFormatID {
            c.lastFormatID = fmt.id
            textView.applyFormatting(fmt.kind)
        }
    }

    // MARK: - Coordinator

    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeCodeEditorView
        weak var textView: ProofTextView?
        weak var rulerView: LineNumberRulerView?
        var loadedFileKey: String?
        var isEditing = false
        var isProgrammaticChange = false
        var lastRevealID: UUID?
        var lastFormatID: UUID?
        var lastEditID: UUID?
        var appliedFontSize: CGFloat = 13
        var appliedWrap = true
        var appliedMode: WorkspaceMode?
        var appliedDiagnostics: [TexDiagnostic] = []
        private var blocks: [NSRange] = []
        private var lastTextLength = 0
        private var observers: [NSObjectProtocol] = []

        init(parent: NativeCodeEditorView) {
            self.parent = parent
        }

        deinit {
            for obs in observers {
                NotificationCenter.default.removeObserver(obs)
            }
        }

        func setupNotifications(scrollView: NSScrollView, textView: ProofTextView) {
            scrollView.contentView.postsBoundsChangedNotifications = true
            let boundsObs = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.rulerView?.needsDisplay = true
                    self?.reportTopLine()
                }
            }
            observers = [boundsObs]
        }

        func fullHighlight() {
            guard let ts = textView?.textStorage else { return }
            let mode = parent.mode
            blocks = SyntaxHighlighter.blocks(in: ts.string as NSString, mode: mode)
            lastTextLength = ts.length
            SyntaxHighlighter.highlight(textStorage: ts, mode: mode, fontSize: parent.fontSize, range: nil, blocks: blocks)
            applyDiagnosticAttributes(limitedTo: nil)
        }

        /// Re-highlights only the edited paragraph (plus any enclosing code block);
        /// falls back to a full pass when a fence/verbatim delimiter is involved.
        private func highlightEdited(_ edited: NSRange, delta: Int) {
            guard let ts = textView?.textStorage else { return }
            let len = ts.length
            guard len > 0 else { return }
            guard edited.location != NSNotFound, edited.location <= len else { return fullHighlight() }
            let mode = parent.mode
            let ns = ts.string as NSString
            var range = ns.paragraphRange(for: NSRange(location: edited.location, length: min(edited.length, len - edited.location)))
            if mode != .mermaid {
                if SyntaxHighlighter.containsDelimiter(ns.substring(with: range), mode: mode) {
                    return fullHighlight()
                }
                // Shift cached block ranges instead of rescanning the whole document.
                let oldEnd = edited.location + edited.length - delta
                let oldRange = NSRange(location: edited.location, length: max(0, oldEnd - edited.location))
                if blocks.contains(where: { NSIntersectionRange($0, oldRange).length > 0 }) {
                    return fullHighlight()
                }
                if delta != 0 {
                    blocks = blocks.map { block in
                        block.location >= oldEnd
                            ? NSRange(location: block.location + delta, length: block.length)
                            : block
                    }
                }
                for b in blocks where b.location <= NSMaxRange(range) && NSMaxRange(b) >= range.location {
                    range = NSUnionRange(range, b)
                }
            }
            SyntaxHighlighter.highlight(textStorage: ts, mode: mode, fontSize: parent.fontSize, range: range, blocks: blocks)
            applyDiagnosticAttributes(limitedTo: range)
        }

        public func textDidChange(_ notification: Notification) {
            guard !isProgrammaticChange, let textView else { return }
            isEditing = true
            parent.onTextChange(textView.string)
            isEditing = false

            let length = textView.textStorage?.length ?? 0
            let delta = length - lastTextLength
            lastTextLength = length
            highlightEdited(textView.textStorage?.editedRange ?? NSRange(location: NSNotFound, length: 0), delta: delta)
            rulerView?.needsDisplay = true
            textView.needsDisplay = true
        }

        // MARK: Diagnostics

        /// Errors get a red wash and an underline; warnings get amber. Both also
        /// appear as dots in the gutter, so a problem is visible without opening the panel.
        func applyDiagnostics(_ diagnostics: [TexDiagnostic]) {
            appliedDiagnostics = diagnostics
            removeDiagnosticAttributes()
            diagnosticRanges = []
            guard let textView, let file = parent.fileKey else {
                rulerView?.diagnosticLines = [:]
                return
            }
            let target = URL(fileURLWithPath: file).standardizedFileURL.path
            var marks: [Int: Bool] = [:]
            var ranges: [(NSRange, Bool)] = []
            for diag in diagnostics {
                let diagPath = diag.file.isEmpty ? target : URL(fileURLWithPath: diag.file).standardizedFileURL.path
                guard diagPath == target else { continue }
                let line = max(1, diag.line)
                marks[line] = marks[line] == true || !diag.isWarning
                ranges.append((textView.contentRange(forLine: line), diag.isWarning))
            }
            rulerView?.diagnosticLines = marks
            diagnosticRanges = ranges
            applyDiagnosticAttributes(limitedTo: nil)
        }

        private var diagnosticRanges: [(NSRange, Bool)] = []

        /// Clears the previous build's marks, including when the new build is clean.
        private func removeDiagnosticAttributes() {
            guard let storage = textView?.textStorage, !diagnosticRanges.isEmpty else { return }
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            for (range, _) in diagnosticRanges {
                let target = NSIntersectionRange(range, full)
                guard target.length > 0 else { continue }
                storage.removeAttribute(.backgroundColor, range: target)
                storage.removeAttribute(.underlineStyle, range: target)
                storage.removeAttribute(.underlineColor, range: target)
            }
            storage.endEditing()
        }

        private func applyDiagnosticAttributes(limitedTo limit: NSRange?) {
            guard let storage = textView?.textStorage, !diagnosticRanges.isEmpty else { return }
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            for (range, isWarning) in diagnosticRanges {
                let target = NSIntersectionRange(range, limit ?? full)
                guard target.length > 0 else { continue }
                let color = isWarning ? NSColor.systemYellow : NSColor.systemRed
                storage.addAttributes([
                    .backgroundColor: color.withAlphaComponent(isWarning ? 0.07 : 0.09),
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: color.withAlphaComponent(0.85)
                ], range: target)
            }
            storage.endEditing()
        }

        public func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            textView.needsDisplay = true
            rulerView?.needsDisplay = true
            let (line, col) = textView.currentLineAndColumn()
            parent.onCursorChange(line, col)
        }

        func reportTopLine() {
            guard let textView,
                  let scrollView = textView.enclosingScrollView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer,
                  layoutManager.numberOfGlyphs > 0 else { return }
            let visibleRect = scrollView.documentVisibleRect
            let topPoint = NSPoint(
                x: textView.textContainerInset.width,
                y: max(0, visibleRect.minY - textView.textContainerInset.height)
            )
            let glyphIndex = layoutManager.glyphIndex(for: topPoint, in: textContainer)
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            parent.onTopLineChange(textView.lineNumber(forCharacterIndex: charIndex))
        }

        func revealLine(_ targetLine: Int) {
            guard let textView else { return }
            let range = textView.contentRange(forLine: targetLine)
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: range.location, length: 0))
            textView.scrollRangeToVisible(range)
            if range.length > 0 {
                textView.showFindIndicator(for: range)
            }
        }
    }
}

// MARK: - Custom NSTextView Subclass

public final class ProofTextView: NSTextView, NSTextStorageDelegate {
    public var mode: WorkspaceMode = .latex
    var onAppearanceChange: (() -> Void)?

    private static let pairs: [Character: Character] = [
        "{": "}",
        "[": "]",
        "(": ")",
        "\"": "\""
    ]

    // MARK: Line index (UTF-16 offsets of each line start, '\n' separated)

    private var lineStarts: [Int] = [0]
    private var lineIndexDirty = true
    private var lineIndexLength = -1

    func invalidateLineIndex() { lineIndexDirty = true }

    /// Keeps the line index in sync with edits without rescanning the document.
    /// A full rescan is used only when the index was never built or the length
    /// bookkeeping does not match (e.g. after a programmatic bulk replace).
    public func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        guard !lineIndexDirty, lineIndexLength >= 0,
              lineIndexLength + delta == textStorage.length else {
            lineIndexDirty = true
            return
        }
        applyIncrementalLineIndex(editedRange: editedRange, delta: delta, storage: textStorage)
        lineIndexLength = textStorage.length
    }

    private func applyIncrementalLineIndex(editedRange: NSRange, delta: Int, storage: NSTextStorage) {
        let newLocation = editedRange.location
        let newEnd = editedRange.location + editedRange.length
        let oldEnd = newEnd - delta
        guard newLocation <= lineIndexLength, oldEnd >= 0, oldEnd <= lineIndexLength else {
            lineIndexDirty = true
            return
        }
        let starts = lineStarts
        let lineIdx = Self.lineIndex(of: newLocation, in: starts)
        let lineStart = starts[lineIdx]

        // Drop cached starts that lived inside the replaced range.
        var endIdx = lineIdx + 1
        while endIdx < starts.count && starts[endIdx] <= oldEnd { endIdx += 1 }

        // Rebuild only the starts inside the edited line(s), from the new text.
        var rebuilt: [Int] = []
        if newEnd > lineStart, newEnd <= storage.length {
            let ns = storage.string as NSString
            let limit = min(newEnd, ns.length)
            var i = lineStart
            while i < limit {
                if ns.character(at: i) == 10 { rebuilt.append(i + 1) }
                i += 1
            }
        }

        var tail = Array(starts[endIdx...])
        if delta != 0 {
            for i in tail.indices { tail[i] += delta }
        }
        lineStarts = Array(starts[0...lineIdx]) + rebuilt + tail
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
        needsDisplay = true
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    /// Cached line starts; rebuilt lazily after edits (one O(n) scan per edit, O(log n) lookups).
    func lineStartOffsets() -> [Int] {
        let length = textStorage?.length ?? 0
        if lineIndexDirty || lineIndexLength != length {
            var starts = [0]
            var i = 0
            for u in string.utf16 {
                i += 1
                if u == 10 { starts.append(i) }
            }
            lineStarts = starts
            lineIndexLength = length
            lineIndexDirty = false
        }
        return lineStarts
    }

    static func lineIndex(of offset: Int, in starts: [Int]) -> Int {
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Range of a 1-based line's content (excluding newline), clamped to the document.
    func contentRange(forLine line: Int) -> NSRange {
        let starts = lineStartOffsets()
        let length = textStorage?.length ?? 0
        let idx = max(0, min(line - 1, starts.count - 1))
        let start = min(starts[idx], length)
        let end = idx + 1 < starts.count ? max(start, starts[idx + 1] - 1) : length
        return NSRange(location: start, length: max(0, min(end, length) - start))
    }

    func currentLineAndColumn() -> (Int, Int) {
        let starts = lineStartOffsets()
        let loc = max(0, min(selectedRange().location, textStorage?.length ?? 0))
        let idx = Self.lineIndex(of: loc, in: starts)
        return (idx + 1, loc - starts[idx] + 1)
    }

    func lineNumber(forCharacterIndex charIndex: Int) -> Int {
        Self.lineIndex(of: max(0, charIndex), in: lineStartOffsets()) + 1
    }

    public override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager = self.layoutManager,
              let textContainer = self.textContainer else { return }

        let nsStr = self.string as NSString
        let loc = selectedRange().location
        guard loc != NSNotFound, loc <= nsStr.length else { return }

        var lineRect: NSRect
        if loc >= nsStr.length, !layoutManager.extraLineFragmentRect.isEmpty {
            lineRect = layoutManager.extraLineFragmentRect
        } else {
            let lineCharRange = nsStr.lineRange(for: NSRange(location: loc, length: 0))
            let glyphRange = layoutManager.glyphRange(forCharacterRange: lineCharRange, actualCharacterRange: nil)
            lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        }
        if lineRect.height == 0 {
            lineRect.size.height = (self.font?.pointSize ?? 13) * 1.45
        }
        lineRect.origin.y += self.textContainerInset.height
        lineRect.origin.x = 0
        lineRect.size.width = self.bounds.width

        NSColor.labelColor.withAlphaComponent(0.038).setFill()
        lineRect.fill()
    }

    private func validSelection() -> NSRange? {
        let sel = selectedRange()
        let len = (string as NSString).length
        guard sel.location != NSNotFound, sel.location + sel.length <= len else { return nil }
        return sel
    }

    public override func insertText(_ string: Any, replacementRange: NSRange) {
        if let str = string as? String, str.count == 1, let ch = str.first,
           let closing = Self.pairs[ch],
           let sel = validSelection(), sel.length > 0, let ts = textStorage {
            let wrapped = "\(ch)\((self.string as NSString).substring(with: sel))\(closing)"
            if shouldChangeText(in: sel, replacementString: wrapped) {
                ts.replaceCharacters(in: sel, with: wrapped)
                didChangeText()
                setSelectedRange(NSRange(location: sel.location + 1, length: sel.length))
                return
            }
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == [.command], let chars = event.charactersIgnoringModifiers?.lowercased() {
            switch chars {
            case "b":
                applyFormatting(.bold)
                return true
            case "i":
                applyFormatting(.italic)
                return true
            case "/":
                applyFormatting(.toggleComment)
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    public func applyFormatting(_ kind: WorkspaceViewModel.FormatKind) {
        switch kind {
        case .bold:
            if mode == .latex { wrapSelection(prefix: "\\textbf{", suffix: "}") }
            else if mode == .markdown { wrapSelection(prefix: "**", suffix: "**") }
        case .italic:
            if mode == .latex { wrapSelection(prefix: "\\textit{", suffix: "}") }
            else if mode == .markdown { wrapSelection(prefix: "*", suffix: "*") }
        case .toggleComment:
            toggleLineComment()
        }
    }

    private func wrapSelection(prefix: String, suffix: String) {
        guard let sel = validSelection() else { return }
        let inner = (string as NSString).substring(with: sel)
        let replacement = "\(prefix)\(inner)\(suffix)"
        if shouldChangeText(in: sel, replacementString: replacement) {
            textStorage?.replaceCharacters(in: sel, with: replacement)
            didChangeText()
            setSelectedRange(NSRange(location: sel.location + (prefix as NSString).length, length: sel.length))
        }
    }

    private func toggleLineComment() {
        guard let sel = validSelection() else { return }
        let (prefix, suffix) = mode.commentSyntax
        let nsStr = string as NSString
        let lineRange = nsStr.lineRange(for: sel)
        guard lineRange.length > 0 else { return }
        let lines = nsStr.substring(with: lineRange).components(separatedBy: "\n")

        func isBlank(_ c: Character) -> Bool { c == " " || c == "\t" || c == "\r" }
        // Splits a line into (indent, content, trailing whitespace).
        func parts(_ line: String) -> (String, String, String) {
            let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
            var content = String(line.dropFirst(indent.count))
            var trail = ""
            while let l = content.last, isBlank(l) {
                trail.insert(l, at: trail.startIndex)
                content.removeLast()
            }
            return (indent, content, trail)
        }
        func isCommented(_ content: String) -> Bool {
            guard content.hasPrefix(prefix) else { return false }
            guard let suffix else { return true }
            return content.count >= prefix.count + suffix.count && content.hasSuffix(suffix)
        }

        let nonEmpty = lines.map(parts).filter { !$0.1.isEmpty }
        let allCommented = !nonEmpty.isEmpty && nonEmpty.allSatisfy { isCommented($0.1) }

        let transformed = lines.map { line -> String in
            let (indent, content, trail) = parts(line)
            guard !content.isEmpty else { return line }
            var out = content
            if allCommented {
                out.removeFirst(prefix.count)
                if out.hasPrefix(" ") { out.removeFirst() }
                if let suffix {
                    out.removeLast(suffix.count)
                    if out.hasSuffix(" ") { out.removeLast() }
                }
            } else {
                out = suffix.map { "\(prefix) \(content) \($0)" } ?? "\(prefix) \(content)"
            }
            return indent + out + trail
        }.joined(separator: "\n")

        if shouldChangeText(in: lineRange, replacementString: transformed) {
            textStorage?.replaceCharacters(in: lineRange, with: transformed)
            didChangeText()
            setSelectedRange(NSRange(location: lineRange.location, length: (transformed as NSString).length))
        }
    }
}

// MARK: - Line Number Ruler View

public final class LineNumberRulerView: NSRulerView {
    private weak var textView: ProofTextView?
    /// Line number -> true when the line has at least one error, false for warnings only.
    var diagnosticLines: [Int: Bool] = [:]

    init(textView: ProofTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        self.clientView = textView
        self.ruleThickness = 44
        setAccessibilityElement(false)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    public override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = self.textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        NSColor.textBackgroundColor.setFill()
        bounds.fill()

        let visibleRect = textView.visibleRect
        let starts = textView.lineStartOffsets()
        let length = textView.textStorage?.length ?? 0
        let activeLine = textView.currentLineAndColumn().0
        let numSize = max(9, (textView.font?.pointSize ?? 13) - 2)

        let defaultAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: numSize, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.65)
        ]
        let activeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: numSize, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]

        let glyphCount = layoutManager.numberOfGlyphs
        let visibleGlyphs = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        var firstChar = 0, lastChar = 0
        if visibleGlyphs.length > 0, glyphCount > 0 {
            firstChar = layoutManager.characterIndexForGlyph(at: min(visibleGlyphs.location, glyphCount - 1))
            lastChar = layoutManager.characterIndexForGlyph(at: min(NSMaxRange(visibleGlyphs), glyphCount) - 1)
        }
        let reachesEnd = visibleGlyphs.length == 0 || NSMaxRange(visibleGlyphs) >= glyphCount

        var i = ProofTextView.lineIndex(of: firstChar, in: starts)
        while i < starts.count {
            let start = starts[i]
            let atEnd = start >= length
            if start > lastChar && !(atEnd && reachesEnd) { break }

            var lineRect: NSRect
            if atEnd || glyphCount == 0 {
                lineRect = layoutManager.extraLineFragmentRect
                if lineRect.isEmpty { lineRect = NSRect(x: 0, y: 0, width: 0, height: 18) }
            } else {
                let gi = min(layoutManager.glyphIndexForCharacter(at: start), glyphCount - 1)
                lineRect = layoutManager.lineFragmentRect(forGlyphAt: gi, effectiveRange: nil)
            }
            let y = lineRect.minY + textView.textContainerInset.height - visibleRect.minY
            if y > bounds.height { break }

            let label = "\(i + 1)" as NSString
            let attrs = (i + 1 == activeLine) ? activeAttrs : defaultAttrs
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 10, y: y + (lineRect.height - size.height) * 0.5), withAttributes: attrs)
            if let isError = diagnosticLines[i + 1] {
                (isError ? NSColor.systemRed : NSColor.systemYellow).setFill()
                let dot = NSBezierPath(ovalIn: NSRect(x: 6, y: y + (lineRect.height - 6) * 0.5, width: 6, height: 6))
                dot.fill()
            }
            i += 1
        }
    }
}

// MARK: - Xcode-Inspired Native Syntax Highlighter

enum SyntaxHighlighter {
    private static func dyn(_ light: (CGFloat, CGFloat, CGFloat), _ dark: (CGFloat, CGFloat, CGFloat)) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        }
    }

    // Dynamic colors: resolved against the view's appearance at draw time.
    private static let cmdColor = dyn((0.05, 0.35, 0.75), (0.40, 0.72, 0.98))
    private static let kwColor = dyn((0.61, 0.14, 0.58), (0.98, 0.37, 0.64))
    private static let mathColor = dyn((0.04, 0.46, 0.39), (0.38, 0.85, 0.77))
    private static let strColor = dyn((0.77, 0.10, 0.09), (0.99, 0.42, 0.36))

    private static let texCommandRegex = try! NSRegularExpression(pattern: #"\\[a-zA-Z@]+\*?"#)
    private static let texEnvRegex = try! NSRegularExpression(pattern: #"\\(?:begin|end)\{[^}]*\}"#)
    // ponytail: line-local, so multi-line $$...$$ is not colored; needed for paragraph-local re-highlighting.
    private static let texMathRegex = try! NSRegularExpression(pattern: #"\$\$?[^$\n]+\$\$?"#)
    // A % starts a comment iff preceded by an even number of backslashes; group 2 is the comment.
    private static let texCommentRegex = try! NSRegularExpression(pattern: #"(?<!\\)((?:\\\\)*)(%.*$)"#, options: [.anchorsMatchLines])

    private static let mdHeadingRegex = try! NSRegularExpression(pattern: #"^#{1,6}[ \t]+.*$"#, options: [.anchorsMatchLines])
    private static let mdBoldRegex = try! NSRegularExpression(pattern: #"\*\*[^*\n]+\*\*"#)
    private static let mdCodeRegex = try! NSRegularExpression(pattern: #"`[^`\n]+`"#)
    private static let mdLinkRegex = try! NSRegularExpression(pattern: #"\[[^\]\n]+\]\([^)\n]+\)"#)

    private static let mmdKeywordRegex = try! NSRegularExpression(
        pattern: #"\b(graph|flowchart|sequenceDiagram|classDiagram|stateDiagram(?:-v2)?|erDiagram|gantt|pie|journey|gitGraph|mindmap|timeline|subgraph|end|participant|actor|loop|alt|else|opt|par|note|title|section|class|state|direction|style|classDef)\b"#
    )
    private static let mmdArrowRegex = try! NSRegularExpression(pattern: #"-->|==>|-\.->|---"#)
    private static let mmdStringRegex = try! NSRegularExpression(pattern: #""[^"\n]*""#)
    private static let mmdCommentRegex = try! NSRegularExpression(pattern: #"%%.*$"#, options: [.anchorsMatchLines])

    private static let mdFenceRegex = try! NSRegularExpression(pattern: #"^(```|~~~)[^\n]*\n[\s\S]*?^\1[^\n]*$"#, options: [.anchorsMatchLines])
    private static let texVerbatimRegex = try! NSRegularExpression(pattern: #"\\begin\{(verbatim|lstlisting|minted)\*?\}[\s\S]*?\\end\{\1\*?\}"#)

    static func paragraphStyle() -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.32
        return p
    }

    /// Multi-line code regions (Markdown fences, LaTeX verbatim-like environments).
    static func blocks(in string: NSString, mode: WorkspaceMode) -> [NSRange] {
        let full = NSRange(location: 0, length: string.length)
        guard full.length > 0 else { return [] }
        let regex: NSRegularExpression
        switch mode {
        case .markdown: regex = mdFenceRegex
        case .latex: regex = texVerbatimRegex
        case .mermaid: return []
        }
        return regex.matches(in: string as String, range: full).map(\.range)
    }

    static func containsDelimiter(_ text: String, mode: WorkspaceMode) -> Bool {
        switch mode {
        case .markdown: return text.contains("```") || text.contains("~~~")
        case .latex: return text.contains("{verbatim") || text.contains("{lstlisting") || text.contains("{minted")
        case .mermaid: return false
        }
    }

    /// Highlights `range` (or the whole storage when nil). Attribute-only; does not touch undo.
    static func highlight(textStorage: NSTextStorage, mode: WorkspaceMode, fontSize: CGFloat, range: NSRange?, blocks: [NSRange]) {
        let length = textStorage.length
        guard length > 0 else { return }
        let target = NSIntersectionRange(range ?? NSRange(location: 0, length: length), NSRange(location: 0, length: length))
        guard target.length > 0 else { return }

        let baseFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let boldFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
        let paragraphStyle = Self.paragraphStyle()
        let commentColor = NSColor.secondaryLabelColor

        textStorage.beginEditing()
        textStorage.setAttributes([
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle
        ], range: target)

        let str = textStorage.string
        switch mode {
        case .latex:
            apply(texCommandRegex, in: str, range: target, to: textStorage, attrs: [.foregroundColor: cmdColor])
            apply(texEnvRegex, in: str, range: target, to: textStorage, attrs: [.foregroundColor: kwColor, .font: boldFont])
            apply(texMathRegex, in: str, range: target, to: textStorage, attrs: [.foregroundColor: mathColor])
            apply(texCommentRegex, in: str, range: target, to: textStorage, attrs: [.foregroundColor: commentColor], group: 2)
        case .markdown:
            apply(mdHeadingRegex, in: str, range: target, to: textStorage, attrs: [.foregroundColor: kwColor, .font: boldFont])
            apply(mdBoldRegex, in: str, range: target, to: textStorage, attrs: [.font: boldFont])
            apply(mdCodeRegex, in: str, range: target, to: textStorage, attrs: [.foregroundColor: mathColor])
            apply(mdLinkRegex, in: str, range: target, to: textStorage, attrs: [.foregroundColor: cmdColor])
            apply(texMathRegex, in: str, range: target, to: textStorage, attrs: [.foregroundColor: mathColor])
        case .mermaid:
            apply(mmdKeywordRegex, in: str, range: target, to: textStorage, attrs: [.foregroundColor: kwColor, .font: boldFont])
            apply(mmdArrowRegex, in: str, range: target, to: textStorage, attrs: [.foregroundColor: cmdColor])
            apply(mmdStringRegex, in: str, range: target, to: textStorage, attrs: [.foregroundColor: strColor])
            apply(mmdCommentRegex, in: str, range: target, to: textStorage, attrs: [.foregroundColor: commentColor])
        }

        for b in blocks {
            let r = NSIntersectionRange(b, target)
            guard r.length > 0 else { continue }
            textStorage.setAttributes([
                .font: baseFont,
                .foregroundColor: mathColor,
                .paragraphStyle: paragraphStyle
            ], range: r)
        }
        textStorage.endEditing()
    }

    private static func apply(
        _ regex: NSRegularExpression,
        in string: String,
        range: NSRange,
        to storage: NSTextStorage,
        attrs: [NSAttributedString.Key: Any],
        group: Int = 0
    ) {
        let limit = storage.length
        regex.enumerateMatches(in: string, range: range) { match, _, _ in
            guard let r = match?.range(at: group), r.location != NSNotFound, NSMaxRange(r) <= limit else { return }
            storage.addAttributes(attrs, range: r)
        }
    }
}
