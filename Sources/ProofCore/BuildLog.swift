import Foundation

/// One line of a TeX build log, with the source location parsed out when there is one.
/// The Problems inspector renders these in a virtualized list instead of a single huge
/// `Text`, and makes located lines jump to the editor.
public struct BuildLogLine: Identifiable, Equatable, Sendable {
    public enum Severity: String, Sendable {
        case error, warning, info
    }

    /// Zero-based position in the log; stable identity for `List`.
    public let id: Int
    public let text: String
    /// Absolute path when a source location was found.
    public let file: String?
    public let line: Int?
    public let severity: Severity

    public init(id: Int, text: String, file: String? = nil, line: Int? = nil, severity: Severity = .info) {
        self.id = id
        self.text = text
        self.file = file
        self.line = line
        self.severity = severity
    }

    public var isNavigable: Bool { file != nil && line != nil }
}

public enum BuildLog {
    /// Matches `source.tex:12:`, `./ch/one.tex:12:`, `/abs/main.tex:12:`.
    /// The extension list is deliberately narrow: lines like `Package: foo` must not
    /// turn into bogus links.
    private static let locationRegex = try! NSRegularExpression(
        pattern: #"^((?:\.{0,2}/)?[^:\s][^:]*?\.(?:tex|ltx|sty|cls|bib|bst|md|markdown|mmd|txt|cfg|def|bbx|cbx)):(\d+):"#,
        options: [.caseInsensitive]
    )

    public static func parse(_ log: String, root: String) -> [BuildLogLine] {
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL
        // `split(separator: "\n")` would miss CRLF: Swift treats "\r\n" as one Character.
        let normalized = TextFile.normalize(log)
        var rawLines = normalized.components(separatedBy: "\n")
        if rawLines.last == "" { rawLines.removeLast() }
        return rawLines.enumerated().map { index, text in
            let severity = severity(of: text)
            guard let (file, line) = location(in: text, root: rootURL) else {
                return BuildLogLine(id: index, text: text, severity: severity)
            }
            return BuildLogLine(id: index, text: text, file: file, line: line, severity: severity)
        }
    }

    static func severity(of text: String) -> BuildLogLine.Severity {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("!") { return .error }
        let lower = trimmed.lowercased()
        // Word boundaries matter: a file named "errors.tex" or a "0 errors" summary is
        // not itself an error.
        if errorWord.firstMatch(in: lower, range: NSRange(location: 0, length: (lower as NSString).length)) != nil {
            return .error
        }
        if warningWord.firstMatch(in: lower, range: NSRange(location: 0, length: (lower as NSString).length)) != nil {
            return .warning
        }
        return .info
    }

    private static let errorWord = try! NSRegularExpression(pattern: #"\berror\b"#)
    private static let warningWord = try! NSRegularExpression(pattern: #"\bwarning\b"#)

    static func location(in text: String, root: URL) -> (String, Int)? {
        let ns = text as NSString
        guard let match = locationRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 3 else { return nil }
        let filePart = ns.substring(with: match.range(at: 1))
        guard let lineNumber = Int(ns.substring(with: match.range(at: 2))), lineNumber > 0 else { return nil }

        let url: URL
        if filePart.hasPrefix("/") {
            url = URL(fileURLWithPath: filePart)
        } else {
            url = root.appendingPathComponent(filePart)
        }
        return (url.standardizedFileURL.path, lineNumber)
    }
}
