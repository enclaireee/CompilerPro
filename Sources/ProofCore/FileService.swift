import Foundation

public enum FileService {
    private static let skippedDirectories: Set<String> = [
        "node_modules", "target", "dist", "build", ".build", ".proof", ".git"
    ]

    /// Extra files that are useful to see (and sometimes edit) inside a project, beyond
    /// the mode's own document types.
    public static let textExtensions: Set<String> = [
        "txt", "csv", "tsv", "json", "yaml", "yml", "toml", "xml", "plist",
        "cfg", "def", "bst", "bbx", "cbx", "lua", "sh", "py", "html", "htm", "css",
        "js", "svg", "bibtex", "ris"
    ]
    public static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp", "eps", "pdf"
    ]
    public static var supportExtensions: [String] {
        Array(textExtensions.union(imageExtensions)).sorted()
    }

    /// Whether Proof can open this file in the text editor (as opposed to Quick Look).
    public static func isTextPath(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return textExtensions.contains(ext) || WorkspaceMode.allCases.contains { $0.extensions.contains(ext) }
    }

    public static func isImagePath(_ path: String) -> Bool {
        imageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// Crash-safe atomic save: writes to a temporary sibling file, fsyncs, preserves POSIX permissions, and renames over the target.
    public static func atomicWrite(path: String, data: Data) throws {
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        let nanos = DispatchTime.now().uptimeNanoseconds
        let tmpURL = dir.appendingPathComponent(".\(name).\(nanos).cpsave")

        let fm = FileManager.default
        let existingPerms = (try? fm.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber

        guard fm.createFile(atPath: tmpURL.path, contents: nil, attributes: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        do {
            let handle = try FileHandle(forWritingTo: tmpURL)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()

            if let perms = existingPerms {
                try? fm.setAttributes([.posixPermissions: perms], ofItemAtPath: tmpURL.path)
            }
            if fm.fileExists(atPath: path) {
                _ = try fm.replaceItemAt(url, withItemAt: tmpURL)
            } else {
                try fm.moveItem(at: tmpURL, to: url)
            }
        } catch {
            try? fm.removeItem(at: tmpURL)
            throw error
        }
    }

    public static func atomicWriteText(path: String, contents: String) throws {
        guard let data = contents.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try atomicWrite(path: path, data: data)
    }

    /// Atomic save that writes the buffer back in the format it was opened with.
    public static func atomicWriteText(path: String, contents: String, format: TextFormat) throws {
        let data = try TextFile.encode(text: contents, format: format, path: path)
        try atomicWrite(path: path, data: data)
    }

    /// Recursively walks `root` up to `maxDepth`, filtering files to `extensions`. Folders are
    /// always kept, even empty ones, so a newly created folder is visible immediately.
    public static func listTree(root: String, extensions: [String], maxDepth: Int = 6) -> [FileEntry] {
        let extSet = Set(extensions.map { $0.lowercased() })
        let rootURL = URL(fileURLWithPath: root)
        let realRoot = rootURL.resolvingSymlinksInPath().path
        return walk(dir: rootURL, realRoot: realRoot.hasSuffix("/") ? realRoot : realRoot + "/",
                    extSet: extSet, depth: 0, maxDepth: maxDepth)
    }

    /// Symlinked directories are never descended (no loops, no escaping the project); symlinked
    /// files are listed only when they resolve inside `realRoot` (which ends in "/").
    private static func walk(dir: URL, realRoot: String, extSet: Set<String>, depth: Int, maxDepth: Int) -> [FileEntry] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .nameKey]
        guard let urls = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var entries: [FileEntry] = []
        for url in urls {
            let name = url.lastPathComponent
            if name.hasPrefix(".") || skippedDirectories.contains(name) {
                continue
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true {
                var dirFlag: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &dirFlag), !dirFlag.boolValue,
                      url.resolvingSymlinksInPath().path.hasPrefix(realRoot) else { continue }
            }

            if values?.isDirectory == true {
                let children = depth < maxDepth ? walk(dir: url, realRoot: realRoot, extSet: extSet, depth: depth + 1, maxDepth: maxDepth) : []
                // Keep empty folders: a user who just made one should see it, and it is
                // where the next New File will go.
                entries.append(FileEntry(name: name, path: url.path, isDirectory: true, children: children))
            } else {
                let ext = url.pathExtension.lowercased()
                if extSet.contains(ext) {
                    entries.append(FileEntry(name: name, path: url.path, isDirectory: false))
                }
            }
        }

        entries.sort { a, b in
            if a.isDirectory != b.isDirectory {
                return a.isDirectory && !b.isDirectory
            }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        return entries
    }

    public static func flattenFiles(_ entries: [FileEntry]) -> [String] {
        var result: [String] = []
        func visit(_ list: [FileEntry]) {
            for item in list {
                if item.isDirectory {
                    visit(item.children)
                } else {
                    result.append(item.path)
                }
            }
        }
        visit(entries)
        return result
    }

    // MARK: - Outline Extraction

    private static let texLevels: [String: Int] = [
        "part": 0,
        "chapter": 1,
        "section": 2,
        "subsection": 3,
        "subsubsection": 4,
        "paragraph": 5
    ]

    private static let texHeadingRegex = try? NSRegularExpression(
        pattern: #"^\s*\\(part|chapter|section|subsection|subsubsection|paragraph)\*?\s*(?:\[[^\]]*\])?\{([^}]*)"#
    )
    private static let mdFenceRegex = try? NSRegularExpression(pattern: #"^\s*(```|~~~)"#)
    private static let mdHeadingRegex = try? NSRegularExpression(pattern: #"^(#{1,6})\s+(.+?)\s*#*\s*$"#)

    public static func outlineOf(mode: WorkspaceMode, text: String) -> [OutlineHeading] {
        guard mode != .mermaid else { return [] }
        let lines = text.components(separatedBy: "\n")
        var raw: [(line: Int, depth: Int, title: String)] = []
        var inFence = false

        for (idx, line) in lines.enumerated() {
            let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
            if mode == .latex {
                if let match = texHeadingRegex?.firstMatch(in: line, range: nsRange),
                   let cmdRange = Range(match.range(at: 1), in: line),
                   let titleRange = Range(match.range(at: 2), in: line) {
                    let cmd = String(line[cmdRange])
                    let rawTitle = String(line[titleRange]).trimmingCharacters(in: .whitespaces)
                    let depth = texLevels[cmd] ?? 2
                    raw.append((idx + 1, depth, rawTitle.isEmpty ? cmd : rawTitle))
                }
            } else if mode == .markdown {
                if mdFenceRegex?.firstMatch(in: line, range: nsRange) != nil {
                    inFence.toggle()
                    continue
                }
                if !inFence,
                   let match = mdHeadingRegex?.firstMatch(in: line, range: nsRange),
                   let hashesRange = Range(match.range(at: 1), in: line),
                   let titleRange = Range(match.range(at: 2), in: line) {
                    let depth = line[hashesRange].count
                    let title = String(line[titleRange])
                    raw.append((idx + 1, depth, title))
                }
            }
        }

        guard let minDepth = raw.map(\.depth).min() else { return [] }
        return raw.map { OutlineHeading(line: $0.line, depth: $0.depth - minDepth, title: $0.title) }
    }

    // MARK: - Subsequence Fuzzy Matching (Quick Open ⌘P)

    /// Subsequence match score; lower is better. Returns `nil` when `query` is not a subsequence of `candidate`.
    public static func fuzzyScore(query: String, candidate: String) -> Double? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        if q.isEmpty { return 0 }
        let s = Array(candidate.lowercased())
        var qi = 0
        var gaps = 0
        var lastMatch = -1

        for (si, ch) in s.enumerated() {
            if qi < q.count && ch == q[qi] {
                if lastMatch >= 0 {
                    gaps += si - lastMatch - 1
                }
                lastMatch = si
                qi += 1
            }
        }

        guard qi == q.count else { return nil }
        return Double(gaps) + Double(s.count - lastMatch) * 0.01
    }

    public static func fuzzyFilter(query: String, files: [String], rootFolder: String, limit: Int = 50) -> [String] {
        let prefix = rootFolder.hasSuffix("/") ? rootFolder : rootFolder + "/"
        let scored: [(String, Double)] = files.compactMap { path in
            let rel = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : (path as NSString).lastPathComponent
            guard let s = fuzzyScore(query: query, candidate: rel) else { return nil }
            return (path, s)
        }
        return scored.sorted { $0.1 < $1.1 }.prefix(limit).map(\.0)
    }
}
