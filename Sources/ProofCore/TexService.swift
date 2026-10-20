import Foundation

public enum TexError: LocalizedError, Equatable {
    case texNotFound
    case invalidTexbin(String)
    case unreadableRoot(path: String, reason: String)
    case spawnFailed(path: String, reason: String)
    case unsafeFileName(String)
    case unsafeCleanTarget(String)

    public var errorDescription: String? {
        switch self {
        case .texNotFound:
            return "TeX Live not found (looked in /Library/TeX/texbin, /opt/homebrew/bin, /usr/local/bin and /usr/local/texlive)"
        case .invalidTexbin(let dir):
            return "The selected TeX folder \(dir) does not contain an executable latexmk"
        case .unreadableRoot(let path, let reason):
            return "Cannot read \(path): \(reason)"
        case .spawnFailed(let path, let reason):
            return "Could not start \(path): \(reason)"
        case .unsafeFileName(let name):
            return "\(name): This file name can't be compiled safely. Rename it to use only letters, numbers, spaces, dashes and underscores."
        case .unsafeCleanTarget(let path):
            return "Refusing to delete \(path): it is not a build folder inside the project."
        }
    }
}

public enum TexService {
    public static let outDir = ".build"

    private static let cacheLock = NSLock()
    private static var cachedTexbin: String?

    /// Returns the TeX bin directory. A non-empty `override` (user-chosen folder) is used only if it
    /// contains an executable `latexmk`, otherwise `nil` is returned. Without an override, probes
    /// standard macOS TeX Live and Homebrew locations; hits are cached (see `refreshTexbin()`).
    public static func texbin(override: String? = nil) -> String? {
        let fm = FileManager.default
        if let raw = override?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let dir = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL.path
            return fm.isExecutableFile(atPath: "\(dir)/latexmk") ? dir : nil
        }

        cacheLock.lock()
        let hit = cachedTexbin
        cacheLock.unlock()
        if let hit { return hit }

        var found: String?
        for dir in ["/Library/TeX/texbin", "/opt/homebrew/bin", "/usr/local/bin"]
        where fm.isExecutableFile(atPath: "\(dir)/latexmk") {
            found = dir
            break
        }
        if found == nil, let years = try? fm.contentsOfDirectory(atPath: "/usr/local/texlive").sorted().reversed() {
            outer: for year in years {
                let binRoot = "/usr/local/texlive/\(year)/bin"
                for arch in (try? fm.contentsOfDirectory(atPath: binRoot)) ?? [] {
                    let candidate = "\(binRoot)/\(arch)"
                    if fm.isExecutableFile(atPath: "\(candidate)/latexmk") {
                        found = candidate
                        break outer
                    }
                }
            }
        }
        if let found {
            cacheLock.lock()
            cachedTexbin = found
            cacheLock.unlock()
        }
        return found
    }

    /// Drops the cached probe result and probes again (e.g. after the user installs MacTeX).
    @discardableResult
    public static func refreshTexbin() -> String? {
        cacheLock.lock()
        cachedTexbin = nil
        cacheLock.unlock()
        return texbin()
    }

    /// Detects `% !TEX program = xelatex | lualatex | pdflatex` in the first 20 lines.
    public static func detectEngine(source: String) -> String {
        for line in source.components(separatedBy: .newlines).prefix(20) {
            let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
            guard trimmed.hasPrefix("%") else { continue }
            let rest = trimmed.dropFirst().replacingOccurrences(of: " ", with: "")
            let value: Substring?
            if rest.hasPrefix("!texprogram=") {
                value = rest.dropFirst("!texprogram=".count)
            } else if rest.hasPrefix("!tex:program=") {
                value = rest.dropFirst("!tex:program=".count)
            } else {
                value = nil
            }
            if let v = value {
                switch v {
                case "xelatex": return "xelatex"
                case "lualatex": return "lualatex"
                default: return "pdflatex"
                }
            }
        }
        return "pdflatex"
    }

    public static func hasDocumentClass(source: String) -> Bool {
        for line in source.components(separatedBy: .newlines) {
            let code = line.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            if code.contains("\\documentclass") {
                return true
            }
        }
        return false
    }

    public static func magicRoot(source: String) -> String? {
        for line in source.components(separatedBy: .newlines).prefix(20) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("%") else { continue }
            let rest = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            let parts = rest.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "")
            if key == "!texroot" {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// latexmk interpolates the file name into its own `sh -c` strings (inside double quotes), so
    /// option-like names and shell metacharacters must never reach it.
    public static func isSafeRootName(_ basename: String) -> Bool {
        !basename.isEmpty && !basename.hasPrefix("-")
            && !basename.contains(where: { "\"$`\\;&|<>()".contains($0) || $0.isNewline })
    }

    /// Symlink-resolved absolute path, or nil if it does not exist.
    static func realPath(_ path: String) -> String? {
        guard let p = realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    /// Resolves both root `.tex` file and engine in a single pass. `nil` root indicates a math snippet.
    /// With `workspaceRoot`, a `% !TEX root` outside that folder (after resolving symlinks) is ignored.
    public static func resolveRootAndEngine(file: String, workspaceRoot: String? = nil) -> (root: String?, engine: String) {
        guard let src = try? String(contentsOfFile: file, encoding: .utf8) else {
            return (nil, "pdflatex")
        }
        if hasDocumentClass(source: src) {
            return (file, detectEngine(source: src))
        }
        let dir = (file as NSString).deletingLastPathComponent
        let fm = FileManager.default

        if let magic = magicRoot(source: src) {
            let resolved = URL(fileURLWithPath: dir).appendingPathComponent(magic).standardizedFileURL.path
            let inWorkspace = workspaceRoot.map { ws in
                guard let real = realPath(resolved), let wsReal = realPath(ws) else { return false }
                return real.hasPrefix(wsReal.hasSuffix("/") ? wsReal : wsReal + "/")
            } ?? true
            // Outside the workspace or unsafe name: ignore the magic comment and fall back to detection.
            if inWorkspace, isSafeRootName((resolved as NSString).lastPathComponent) {
                if fm.fileExists(atPath: resolved) {
                    let engine = (try? String(contentsOfFile: resolved, encoding: .utf8)).map(detectEngine(source:)) ?? "pdflatex"
                    return (resolved, engine)
                }
                return (nil, "pdflatex")
            }
        }

        guard let items = try? fm.contentsOfDirectory(atPath: dir) else {
            return (nil, "pdflatex")
        }
        let candidates = items
            .filter { ($0 as NSString).pathExtension.lowercased() == "tex" }
            .map { (dir as NSString).appendingPathComponent($0) }
            .filter { $0 != file }
            .sorted { a, b in
                let aMain = (a as NSString).lastPathComponent == "main.tex"
                let bMain = (b as NSString).lastPathComponent == "main.tex"
                if aMain != bMain { return aMain && !bMain }
                return a < b
            }

        for cand in candidates {
            if let candSrc = try? String(contentsOfFile: cand, encoding: .utf8),
               hasDocumentClass(source: candSrc) {
                return (cand, detectEngine(source: candSrc))
            }
        }
        return (nil, "pdflatex")
    }

    public static func detectRoot(file: String, workspaceRoot: String? = nil) -> String? {
        resolveRootAndEngine(file: file, workspaceRoot: workspaceRoot).root
    }

    public static func pdfPath(forRoot root: String) -> String {
        let dir = (root as NSString).deletingLastPathComponent
        let stem = ((root as NSString).lastPathComponent as NSString).deletingPathExtension
        return ((dir as NSString).appendingPathComponent(outDir) as NSString).appendingPathComponent("\(stem).pdf")
    }

    private static let errorLineRegex = try? NSRegularExpression(pattern: #"^(\S.*?\.[A-Za-z0-9]+):(\d+): (.*)$"#)
    private static let boxRegex = try? NSRegularExpression(pattern: #"^(?:Overfull|Underfull) \\[hv]box .*? at lines? (\d+)"#)
    private static let texLineRegex = try? NSRegularExpression(pattern: #"^l\.(\d+)"#)
    // ponytail: file names in the log are wrapped at 79 chars, so very long paths are not recognised;
    // attribution then falls back to the enclosing file or root. Upgrade path: parse with max_print_line raised.
    private static let openFileRegex = try? NSRegularExpression(pattern: #"(\.{0,2}/[^()\n]*?\.[A-Za-z0-9]+)(?=[\s()\[\]{}]|$)"#)

    /// Absolute paths are kept; relative ones (`./a b.tex`, `ch/x.tex`) are joined to `base`. Result is standardized.
    private static func resolvePath(_ path: String, base: String) -> String {
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(fileURLWithPath: base).appendingPathComponent(path)
        return url.standardizedFileURL.path
    }

    private static func firstMatch(_ regex: NSRegularExpression?, _ s: String) -> [String]? {
        guard let regex, let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..<s.endIndex, in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: s).map { String(s[$0]) } ?? ""
        }
    }

    /// Parses `-file-line-error` errors, `! ...` errors, `... on input line N` warnings and over/underfull
    /// box warnings, attributing them to the file currently open in the log (falling back to `root`).
    /// Deduplicates across passes.
    public static func parseLog(log: String, root: String) -> [TexDiagnostic] {
        let dir = (root as NSString).deletingLastPathComponent
        func resolve(_ file: String) -> String { resolvePath(file, base: dir) }

        let lines = log.components(separatedBy: .newlines)
        var stack: [String?] = []  // open-paren stack: file path or nil for non-file parens
        func currentFile() -> String {
            for entry in stack.reversed() {
                if let f = entry, ["tex", "ltx"].contains((f as NSString).pathExtension.lowercased()) {
                    return resolve(f)
                }
            }
            return root
        }

        var out: [TexDiagnostic] = []
        var seen = Set<String>()
        func add(_ file: String, _ line: Int, _ msg: String, warning: Bool) {
            let d = TexDiagnostic(file: file, line: max(1, line), message: msg, isWarning: warning,
                                  explanation: DiagnosticExplainer.explain(msg))
            if seen.insert(d.id).inserted { out.append(d) }
        }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            defer { i += 1 }

            if let m = firstMatch(errorLineRegex, line), let n = Int(m[2]) {
                add(resolve(m[1]), n, m[3].trimmingCharacters(in: .whitespaces), warning: false)
                continue
            }
            if line.hasPrefix("! ") {
                var n = 1
                for j in (i + 1)..<min(i + 12, lines.count) {
                    if let m = firstMatch(texLineRegex, lines[j]), let v = Int(m[1]) { n = v; break }
                }
                add(currentFile(), n, String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces), warning: false)
                continue
            }
            if let m = firstMatch(boxRegex, line), let n = Int(m[1]) {
                add(currentFile(), n, line.trimmingCharacters(in: .whitespaces), warning: true)
                continue
            }
            if let warnRange = line.range(of: "Warning:") {
                // Warnings wrap across lines; join until "input line N" or a blank line.
                var text = String(line[warnRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                var j = i
                while !text.contains("input line "), j + 1 < lines.count, j - i < 5,
                      !lines[j + 1].trimmingCharacters(in: .whitespaces).isEmpty {
                    j += 1
                    var cont = lines[j].trimmingCharacters(in: .whitespaces)
                    // Package continuation lines start with "(pkgname)".
                    if cont.hasPrefix("("), let close = cont.firstIndex(of: ")") {
                        cont = cont[cont.index(after: close)...].trimmingCharacters(in: .whitespaces)
                    }
                    // TeX hard-wraps at 79 columns (no space at the break); other breaks are word breaks.
                    text += (lines[j - 1].count >= 79 ? "" : " ") + cont
                }
                if let inputRange = text.range(of: "input line ", options: .backwards),
                   let n = Int(text[inputRange.upperBound...].prefix { $0.isNumber }) {
                    add(currentFile(), n, text, warning: true)
                    i = j
                    continue
                }
                continue
            }
            if firstMatch(texLineRegex, line) != nil { continue }

            // Track the open-file stack.
            let ns = line as NSString
            var k = 0
            while k < ns.length {
                let c = ns.character(at: k)
                if c == 0x28 { // (
                    let range = NSRange(location: k + 1, length: ns.length - k - 1)
                    if let m = openFileRegex?.firstMatch(in: line, options: .anchored, range: range) {
                        stack.append(ns.substring(with: m.range(at: 1)))
                        k = m.range.location + m.range.length
                        continue
                    }
                    stack.append(nil)
                } else if c == 0x29, !stack.isEmpty { // )
                    stack.removeLast()
                }
                k += 1
            }
        }
        return out
    }

    private static let commentRegex = try? NSRegularExpression(pattern: #"(^|[^\\])%.*$"#, options: [.anchorsMatchLines])
    private static let blankLineRegex = try? NSRegularExpression(pattern: #"\n\s*\n"#)
    private static let equationRegex = try? NSRegularExpression(pattern: #"^\\begin\{(equation\*?)\}([\s\S]*)\\end\{\1\}$"#)

    /// Extracts math blocks from a snippet `.tex` file (strips `%` comments, splits on blank lines, unwraps `\[ \]`, `$$ $$`, `equation`).
    public static func mathBlocks(text: String) -> [String] {
        guard let commentRegex, let blankLineRegex else { return [] }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let stripped = commentRegex.stringByReplacingMatches(in: text, range: fullRange, withTemplate: "$1")

        let splitRange = NSRange(stripped.startIndex..<stripped.endIndex, in: stripped)
        var blocks: [String] = []
        var lastIndex = stripped.startIndex

        blankLineRegex.enumerateMatches(in: stripped, range: splitRange) { match, _, _ in
            guard let match, let r = Range(match.range, in: stripped) else { return }
            blocks.append(String(stripped[lastIndex..<r.lowerBound]))
            lastIndex = r.upperBound
        }
        blocks.append(String(stripped[lastIndex...]))

        return blocks.compactMap { raw in
            var b = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !b.isEmpty else { return nil }
            if b.hasPrefix("\\[") && b.hasSuffix("\\]") && b.count >= 4 {
                b = String(b.dropFirst(2).dropLast(2))
            } else if b.hasPrefix("$$") && b.hasSuffix("$$") && b.count >= 4 {
                b = String(b.dropFirst(2).dropLast(2))
            } else {
                let r = NSRange(b.startIndex..<b.endIndex, in: b)
                if let m = equationRegex?.firstMatch(in: b, range: r),
                   let bodyRange = Range(m.range(at: 2), in: b) {
                    b = String(b[bodyRange])
                }
            }
            let cleaned = b.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        }
    }

    // MARK: - SyncTeX output parsing

    private static func synctexField(_ key: String, in text: some StringProtocol) -> String? {
        for l in text.split(whereSeparator: \.isNewline) where l.hasPrefix(key) {
            return l.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Parses `synctex view` output into highlight rectangles (top-left origin). Malformed records are skipped.
    public static func parseSynctexView(_ text: String) -> [SyncTexSpot] {
        text.components(separatedBy: "Output:").dropFirst().compactMap { block in
            guard let page = synctexField("Page:", in: block).flatMap({ Int($0) }), page >= 1,
                  let h = synctexField("h:", in: block).flatMap({ Double($0) }),
                  let v = synctexField("v:", in: block).flatMap({ Double($0) }),
                  let w = synctexField("W:", in: block).flatMap({ Double($0) }),
                  let hh = synctexField("H:", in: block).flatMap({ Double($0) }),
                  [h, v, w, hh].allSatisfy(\.isFinite) else {
                return nil
            }
            return SyncTexSpot(page: page, x: h, y: v - hh, w: w, h: hh)
        }
    }

    /// Parses `synctex edit` output. Relative `Input:` paths (e.g. `./ch 1.tex`) resolve against the
    /// project folder (parent of the `.build` folder holding `pdf`). Returns nil on malformed output.
    public static func parseSynctexEdit(_ text: String, pdf: String) -> SourceLocation? {
        guard let input = synctexField("Input:", in: text), !input.isEmpty,
              let line = synctexField("Line:", in: text).flatMap({ Int($0) }) else {
            return nil
        }
        let projectDir = ((pdf as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        return SourceLocation(file: resolvePath(input, base: projectDir), line: max(1, line))
    }
}

/// Manages `latexmk` compilation and `synctex` queries.
///
/// One compile runs at a time per runner: starting a new compile cancels the previous one, whose
/// result comes back with `cancelled == true` and `superseded == true`.
public final class TexProcessRunner: @unchecked Sendable {
    private final class Run {
        let id: Int
        let done = DispatchGroup()
        var pid: pid_t = 0
        var reaped = false
        var cancelled = false
        var termSentAt: DispatchTime?
        var killSent = false
        init(id: Int) {
            self.id = id
            done.enter()
        }
    }

    private let lock = NSLock()
    private var generation = 0      // latest reserved/started run id
    private var cancelledUpTo = 0   // reserved ids <= this were cancelled before they started
    private var current: Run?
    private let latexmkPath: String?

    /// - Parameter latexmkPath: explicit `latexmk` executable (used by tests); nil = resolve via `TexService.texbin`.
    public init(latexmkPath: String? = nil) {
        self.latexmkPath = latexmkPath
    }

    /// Stops the running compile (latexmk and every engine/biber it spawned). The pending
    /// `compile` call returns promptly with `cancelled == true`.
    /// Also cancels a reserved run (`reserveRunID()`) whose `compile` has not started yet.
    public func cancelCompile() {
        lock.lock()
        cancelledUpTo = generation
        if let run = current {
            run.cancelled = true
            terminateLocked(run)
        }
        lock.unlock()
    }

    /// Allocates the next run id and makes it the current run, stopping any older running compile.
    /// Call synchronously (e.g. on main) before handing the id to `compile(..., runID:)` on a
    /// background task, so a `cancelCompile()` issued in between is not lost.
    public func reserveRunID() -> Int {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        if let run = current {
            run.cancelled = true
            terminateLocked(run)
        }
        return generation
    }

    /// True when `runID` belongs to the most recently reserved or started compile.
    public func isCurrentRun(_ runID: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return runID == generation
    }

    /// Must hold `lock`. SIGTERMs the run's process group once; escalation happens in `collect`.
    private func terminateLocked(_ run: Run) {
        guard run.termSentAt == nil else { return }
        run.termSentAt = .now()
        if run.pid > 0, !run.reaped {
            kill(-run.pid, SIGTERM)
        }
    }

    /// Runs latexmk synchronously (call off the main actor).
    /// - Parameters:
    ///   - engine: "pdflatex", "xelatex" or "lualatex"; nil (or anything else) = `% !TEX program` detection.
    ///   - texbinOverride: user-chosen TeX bin folder (must contain latexmk).
    ///   - timeout: seconds before the build is stopped and `timedOut` is reported.
    ///   - runID: id from `reserveRunID()`; nil = allocate one now. A reserved id that was cancelled
    ///     returns `cancelled`, one that is no longer current returns `superseded`; neither spawns.
    public func compile(
        root: String,
        engine engineOverride: String? = nil,
        texbinOverride: String? = nil,
        timeout: TimeInterval = 300,
        runID reservedID: Int? = nil
    ) throws -> CompileResult {
        let latexmk: String
        if let latexmkPath {
            latexmk = latexmkPath
        } else if let bin = TexService.texbin(override: texbinOverride) {
            latexmk = "\(bin)/latexmk"
        } else if let o = texbinOverride, !o.trimmingCharacters(in: .whitespaces).isEmpty {
            throw TexError.invalidTexbin(o)
        } else {
            throw TexError.texNotFound
        }

        let srcData: Data
        do {
            srcData = try Data(contentsOf: URL(fileURLWithPath: root))
        } catch {
            throw TexError.unreadableRoot(path: root, reason: error.localizedDescription)
        }
        let engine: String
        if let o = engineOverride?.lowercased(), ["pdflatex", "xelatex", "lualatex"].contains(o) {
            engine = o
        } else {
            engine = TexService.detectEngine(source: String(decoding: srcData, as: UTF8.self))
        }
        let rootName = (root as NSString).lastPathComponent
        guard TexService.isSafeRootName(rootName) else { throw TexError.unsafeFileName(rootName) }

        lock.lock()
        let runID: Int
        if let reservedID {
            runID = reservedID
        } else {
            generation += 1
            runID = generation
        }
        if runID <= cancelledUpTo || runID != generation {
            let superseded = runID != generation
            lock.unlock()
            return CompileResult(ok: false, cancelled: true, pdfPath: nil, diagnostics: [],
                                 log: "Compilation cancelled.", elapsedMs: 0, engine: engine,
                                 runID: runID, superseded: superseded)
        }
        let run = Run(id: runID)
        let previous = current
        current = run
        if let previous {
            previous.cancelled = true
            terminateLocked(previous)
        }
        lock.unlock()
        defer {
            lock.lock()
            if current === run { current = nil }
            lock.unlock()
            run.done.leave()
        }
        // Both runs share the .build folder; let the old one die first (it escalates to SIGKILL at 2 s).
        if let previous {
            _ = previous.done.wait(timeout: .now() + 3)
        }

        let startTime = DispatchTime.now()
        let startDate = Date()
        let dir = (root as NSString).deletingLastPathComponent
        let pdf = TexService.pdfPath(forRoot: root)
        let fm = FileManager.default
        let beforeMtime = (try? fm.attributesOfItem(atPath: pdf))?[.modificationDate] as? Date
        func elapsedMs() -> Int {
            Int((DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000)
        }
        func finished(_ r: (ok: Bool, cancelled: Bool, timedOut: Bool, pdf: String?, log: String)) -> CompileResult {
            lock.lock()
            let superseded = generation != run.id
            lock.unlock()
            return CompileResult(
                ok: r.ok, cancelled: r.cancelled, pdfPath: r.pdf,
                diagnostics: TexService.parseLog(log: r.log, root: root),
                log: r.log, elapsedMs: elapsedMs(), engine: engine,
                timedOut: r.timedOut, runID: run.id, superseded: superseded
            )
        }

        lock.lock()
        let cancelledEarly = run.cancelled
        lock.unlock()
        if cancelledEarly {
            return finished((false, true, false, nil, "Compilation cancelled."))
        }

        let flag: String
        switch engine {
        case "xelatex": flag = "-xelatex"
        case "lualatex": flag = "-lualatex"
        default: flag = "-pdf"
        }
        let binDir = (latexmk as NSString).deletingLastPathComponent
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(binDir):/usr/bin:/bin:/usr/sbin:/sbin"
        // kpathsea reads these from the environment: no \write18, no reading/writing outside the project.
        env["shell_escape"] = "f"
        env["openin_any"] = "p"
        env["openout_any"] = "p"

        let (pid, fd) = try Self.spawnInNewGroup(
            executable: latexmk,
            arguments: ["-norc", flag, "-interaction=nonstopmode", "-file-line-error", "-synctex=1",
                        "-no-shell-escape", "-outdir=\(TexService.outDir)", "./" + rootName],
            environment: env,
            directory: dir
        )
        lock.lock()
        run.pid = pid
        if run.termSentAt != nil {  // cancelled while spawning
            run.termSentAt = .now()
            kill(-pid, SIGTERM)
        }
        lock.unlock()

        let (status, output, timedOut) = collect(run: run, pid: pid, fd: fd, deadline: startTime + timeout)

        lock.lock()
        let wasCancelled = run.cancelled
        lock.unlock()

        let logPath = (pdf as NSString).deletingPathExtension + ".log"
        let logMtime = (try? fm.attributesOfItem(atPath: logPath))?[.modificationDate] as? Date
        let outputText = String(decoding: output, as: UTF8.self)
        // Nothing changed since a failed build: latexmk skips the engine and only reports that the
        // last run failed. That run's .log still holds the real error, so show it instead.
        let skippedFailedBuild = outputText.contains("gave an error in previous invocation of latexmk")
        var log: String
        if let logMtime, logMtime >= startDate.addingTimeInterval(-1),
           let data = fm.contents(atPath: logPath) {
            log = String(decoding: data, as: UTF8.self)
        } else if skippedFailedBuild, let data = fm.contents(atPath: logPath) {
            log = "Nothing changed since the last build, which failed. Showing its log; fix the error and compile again.\n\n"
                + String(decoding: data, as: UTF8.self)
        } else {
            log = outputText
        }
        if timedOut {
            log = "Compilation timed out after \(Int(timeout)) seconds and was stopped.\n\n" + log
        } else if wasCancelled {
            log = "Compilation cancelled.\n\n" + log
        }

        let exitedCleanly = status.map { $0 & 0x7f == 0 && ($0 >> 8) & 0xff == 0 } ?? false
        let succeeded = exitedCleanly && !wasCancelled && !timedOut
        let afterMtime = (try? fm.attributesOfItem(atPath: pdf))?[.modificationDate] as? Date
        let isFresh = afterMtime != nil && afterMtime != beforeMtime
        let hasPdf = isFresh || (succeeded && fm.fileExists(atPath: pdf))
        return finished((succeeded, wasCancelled, timedOut, hasPdf ? pdf : nil, log))
    }

    // ponytail: merged stdout+stderr output is capped; latexmk's real log is read from disk anyway.
    private static let outputCap = 8 << 20

    /// Reads the child's output until it exits, enforcing the deadline and SIGKILL escalation.
    /// Returns the raw wait status (nil if it could not be collected).
    private func collect(run: Run, pid: pid_t, fd: Int32, deadline: DispatchTime) -> (Int32?, Data, Bool) {
        defer { close(fd) }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var eof = false
        var timedOut = false

        while true {
            if eof {
                usleep(50_000)
            } else {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                _ = poll(&pfd, 1, 100)
                eof = Self.drain(fd, into: &output, buffer: &buffer)
            }

            if Self.hasExited(pid) {
                lock.lock()
                run.reaped = true
                // Mop up group members that ignored SIGTERM while the zombie still pins the pgid.
                if run.termSentAt != nil { kill(-pid, SIGKILL) }
                lock.unlock()
                var status: Int32 = 0
                var rc: pid_t
                repeat { rc = waitpid(pid, &status, 0) } while rc == -1 && errno == EINTR
                if !eof { _ = Self.drain(fd, into: &output, buffer: &buffer) }
                return (rc == pid ? status : nil, output, timedOut)
            }

            let now = DispatchTime.now()
            lock.lock()
            if !timedOut, now >= deadline {
                timedOut = true
                terminateLocked(run)
            }
            if let t = run.termSentAt, !run.killSent, now >= t + 2 {
                run.killSent = true
                kill(-pid, SIGKILL)
            }
            lock.unlock()
        }
    }

    /// Non-blocking read of everything available. Returns true on EOF (or a hard read error).
    private static func drain(_ fd: Int32, into output: inout Data, buffer: inout [UInt8]) -> Bool {
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                if output.count < outputCap { output.append(contentsOf: buffer[0..<n]) }
            } else if n == 0 {
                return true
            } else if errno == EINTR {
                continue
            } else {
                return errno != EAGAIN
            }
        }
    }

    /// Checks for exit without reaping, so the pid (and its process group id) stays reserved.
    private static func hasExited(_ pid: pid_t) -> Bool {
        var info = siginfo_t()
        while true {
            if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 {
                return info.si_pid == pid
            }
            if errno != EINTR { return true }
        }
    }

    /// Spawns `executable` as leader of a new process group with stdout+stderr merged into one pipe.
    private static func spawnInNewGroup(
        executable: String, arguments: [String], environment: [String: String], directory: String
    ) throws -> (pid_t, Int32) {
        func failure(_ code: Int32) -> TexError {
            .spawnFailed(path: executable, reason: String(cString: strerror(code)))
        }
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw failure(errno) }
        let (readFD, writeFD) = (fds[0], fds[1])
        _ = fcntl(readFD, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeFD, F_SETFD, FD_CLOEXEC)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addchdir_np(&actions, directory)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeFD, 1)
        posix_spawn_file_actions_adddup2(&actions, writeFD, 2)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setpgroup(&attr, 0)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attr, &emptyMask)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for sig in [SIGPIPE, SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGCHLD] { sigaddset(&defaults, sig) }
        posix_spawnattr_setsigdefault(&attr, &defaults)
        // CLOEXEC_DEFAULT: the child inherits only fds 0-2 set up above, nothing else from the app.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK
                                              | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &actions, &attr, argv, envp)
        close(writeFD)
        guard rc == 0 else {
            close(readFD)
            throw failure(rc)
        }
        _ = fcntl(readFD, F_SETFL, fcntl(readFD, F_GETFL) | O_NONBLOCK)
        return (pid, readFD)
    }

    /// Deletes the root's `.build` folder. Refuses (throws) when it resolves anywhere other than
    /// directly inside the root's folder, e.g. a symlink planted by a downloaded project.
    public static func cleanBuild(root: String) throws {
        let rootDir = (root as NSString).deletingLastPathComponent
        let dir = (rootDir as NSString).appendingPathComponent(TexService.outDir)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) else { return }
        let attrs = try? FileManager.default.attributesOfItem(atPath: dir)
        guard isDir.boolValue, attrs?[.type] as? FileAttributeType == .typeDirectory,
              let realDir = TexService.realPath(dir), let realRootDir = TexService.realPath(rootDir),
              (realDir as NSString).deletingLastPathComponent == realRootDir else {
            throw TexError.unsafeCleanTarget(dir)
        }
        try FileManager.default.removeItem(atPath: realDir)
    }

    private static func runSynctex(_ arguments: [String], texbinOverride: String?) -> String? {
        guard let bin = TexService.texbin(override: texbinOverride) else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "\(bin)/synctex")
        proc.arguments = arguments
        let pipe = Pipe()
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// Forward SyncTeX: source `file:line:col` -> PDF highlight rectangles.
    public static func synctexView(file: String, line: Int, col: Int, pdf: String, texbinOverride: String? = nil) -> [SyncTexSpot] {
        guard let text = runSynctex(["view", "-i", "\(line):\(col):\(file)", "-o", pdf], texbinOverride: texbinOverride) else { return [] }
        return TexService.parseSynctexView(text)
    }

    /// Inverse SyncTeX: PDF `page:x:y` (top-left origin in points) -> source `file:line`.
    public static func synctexEdit(pdf: String, page: Int, x: Double, y: Double, texbinOverride: String? = nil) -> SourceLocation? {
        let spec = "\(page):\(String(format: "%.2f", x)):\(String(format: "%.2f", y)):\(pdf)"
        guard let text = runSynctex(["edit", "-o", spec], texbinOverride: texbinOverride) else { return nil }
        return TexService.parseSynctexEdit(text, pdf: pdf)
    }
}
