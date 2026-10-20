import Foundation

public enum WorkspaceMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case latex
    case mermaid
    case markdown

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .latex: return "LaTeX"
        case .mermaid: return "Mermaid"
        case .markdown: return "Markdown"
        }
    }

    public var subtitle: String {
        switch self {
        case .latex: return "Documents & math, compiled with TeX Live"
        case .mermaid: return "Flowcharts, sequences & architecture diagrams"
        case .markdown: return "Technical notes with KaTeX math & diagrams"
        }
    }

    public var symbolName: String {
        switch self {
        case .latex: return "function"
        case .mermaid: return "point.3.connected.trianglepath.dotted"
        case .markdown: return "doc.richtext"
        }
    }

    public var extensions: [String] {
        switch self {
        case .latex: return ["tex", "bib", "sty", "cls", "ltx"]
        case .mermaid: return ["mmd", "mermaid"]
        case .markdown: return ["md", "markdown"]
        }
    }

    public var primaryExtensions: [String] {
        Array(extensions.prefix(2))
    }

    public var starterFile: (name: String, contents: String, initialLine: Int) {
        switch self {
        case .latex:
            return (
                "main.tex",
                """
                \\documentclass{article}
                \\usepackage{amsmath}

                \\title{Untitled}
                \\author{}

                \\begin{document}
                \\maketitle

                \\section{Introduction}


                \\end{document}
                """,
                11
            )
        case .mermaid:
            return (
                "diagram.mmd",
                """
                flowchart LR
                  A[Start] --> B[End]
                """,
                2
            )
        case .markdown:
            return (
                "notes.md",
                """
                # Untitled

                """,
                2
            )
        }
    }

    /// Line comment syntax; `suffix` is non-nil for wrapping comments (Markdown `<!-- -->`).
    public var commentSyntax: (prefix: String, suffix: String?) {
        switch self {
        case .latex: return ("%", nil)
        case .mermaid: return ("%%", nil)
        case .markdown: return ("<!--", "-->")
        }
    }

    public static func mode(forPath path: String) -> WorkspaceMode? {
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        return Self.allCases.first { $0.extensions.contains(ext) }
    }
}

public enum AppThemePreference: String, Codable, CaseIterable, Sendable {
    case auto
    case light
    case dark

    public var label: String {
        switch self {
        case .auto: return "Match System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    public var symbolName: String {
        switch self {
        case .auto: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    public func next() -> AppThemePreference {
        switch self {
        case .auto: return .light
        case .light: return .dark
        case .dark: return .auto
        }
    }
}

public struct FileEntry: Identifiable, Equatable, Codable, Sendable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let children: [FileEntry]

    public init(name: String, path: String, isDirectory: Bool, children: [FileEntry] = []) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.children = children
    }
}

public struct OutlineHeading: Identifiable, Equatable, Sendable {
    public var id: Int { line }
    public let line: Int
    public let depth: Int
    public let title: String

    public init(line: Int, depth: Int, title: String) {
        self.line = line
        self.depth = depth
        self.title = title
    }
}

public struct TexDiagnostic: Identifiable, Equatable, Codable, Sendable {
    public var id: String { "\(file):\(line):\(isWarning):\(message)" }
    public let file: String
    public let line: Int
    public let message: String
    public let isWarning: Bool
    /// Beginner-friendly explanation with a fix hint (see `DiagnosticExplainer`).
    public let explanation: String?

    public init(file: String, line: Int, message: String, isWarning: Bool, explanation: String? = nil) {
        self.file = file
        self.line = line
        self.message = message
        self.isWarning = isWarning
        self.explanation = explanation
    }
}

public struct CompileResult: Equatable, Sendable {
    public let ok: Bool
    public let cancelled: Bool
    public let pdfPath: String?
    public let diagnostics: [TexDiagnostic]
    public let log: String
    public let elapsedMs: Int
    public let engine: String
    /// The build hit the runner's timeout and was stopped.
    public let timedOut: Bool
    /// Monotonic id of the compile; compare with `TexProcessRunner.isCurrentRun(_:)`.
    public let runID: Int
    /// A newer compile was started on the same runner; this result is stale and should be ignored.
    public let superseded: Bool

    public init(
        ok: Bool,
        cancelled: Bool,
        pdfPath: String?,
        diagnostics: [TexDiagnostic],
        log: String,
        elapsedMs: Int,
        engine: String,
        timedOut: Bool = false,
        runID: Int = 0,
        superseded: Bool = false
    ) {
        self.ok = ok
        self.cancelled = cancelled
        self.pdfPath = pdfPath
        self.diagnostics = diagnostics
        self.log = log
        self.elapsedMs = elapsedMs
        self.engine = engine
        self.timedOut = timedOut
        self.runID = runID
        self.superseded = superseded
    }
}

public struct SyncTexSpot: Equatable, Sendable {
    public let page: Int
    /// Coordinates in PDF points, origin top-left, y down.
    public let x: Double
    public let y: Double
    public let w: Double
    public let h: Double

    public init(page: Int, x: Double, y: Double, w: Double, h: Double) {
        self.page = page
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

public struct SourceLocation: Equatable, Sendable {
    public let file: String
    public let line: Int

    public init(file: String, line: Int) {
        self.file = file
        self.line = line
    }
}

public struct RecentProject: Identifiable, Codable, Equatable, Sendable {
    public var id: String { "\(mode.rawValue):\(folder)" }
    public let mode: WorkspaceMode
    public let folder: String
    public let file: String?
    public let timestamp: Double

    public init(mode: WorkspaceMode, folder: String, file: String?, timestamp: Double = Date().timeIntervalSince1970) {
        self.mode = mode
        self.folder = folder
        self.file = file
        self.timestamp = timestamp
    }

    public var displayLabel: String {
        let folderName = (folder as NSString).lastPathComponent
        if let file, !file.isEmpty {
            return "\(folderName) › \((file as NSString).lastPathComponent)"
        }
        return folderName
    }

    public var abbreviatedFolder: String {
        (folder as NSString).abbreviatingWithTildeInPath
    }
}

public struct WorkspaceSession: Codable, Equatable, Sendable {
    public let mode: WorkspaceMode
    public let folder: String
    public let file: String?

    public init(mode: WorkspaceMode, folder: String, file: String?) {
        self.mode = mode
        self.folder = folder
        self.file = file
    }
}
