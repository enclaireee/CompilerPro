import ProofCore
import Foundation
import XCTest

final class TexServiceTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("cp-tex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Writes an executable fake `latexmk` and a root file; returns (runner, root path).
    private func fakeLatexmk(_ body: String, root: String = "main.tex") throws -> (TexProcessRunner, String) {
        let script = dir.appendingPathComponent("latexmk")
        try "#!/bin/sh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let rootPath = dir.appendingPathComponent(root).path
        try "\\documentclass{article}".write(toFile: rootPath, atomically: true, encoding: .utf8)
        return (TexProcessRunner(latexmkPath: script.path), rootPath)
    }

    private func compileAsync(_ runner: TexProcessRunner, _ root: String, timeout: TimeInterval = 300) -> (XCTestExpectation, () -> CompileResult?) {
        let exp = expectation(description: "compile \(root)")
        let box = ResultBox()
        DispatchQueue.global().async {
            box.value = try? runner.compile(root: root, timeout: timeout)
            exp.fulfill()
        }
        return (exp, { box.value })
    }

    private func waitForFile(_ path: String, seconds: Double = 5) -> String? {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let s = try? String(contentsOfFile: path, encoding: .utf8), s.hasSuffix("\n") { return s }
            usleep(20_000)
        }
        return nil
    }

    private func isGone(_ pid: pid_t, within seconds: Double) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if kill(pid, 0) != 0 { return true }
            usleep(50_000)
        }
        return kill(pid, 0) != 0
    }

    // MARK: - Runner

    func testLargeStderrDoesNotDeadlock() throws {
        let (runner, root) = try fakeLatexmk("""
        head -c 250000 /dev/zero | tr '\\0' 'e' >&2
        echo hello-stdout
        exit 0
        """)
        let (exp, result) = compileAsync(runner, root)
        wait(for: [exp], timeout: 10)
        let res = try XCTUnwrap(result())
        XCTAssertTrue(res.ok)
        XCTAssertFalse(res.cancelled)
        XCTAssertTrue(res.log.contains("hello-stdout"))
        XCTAssertGreaterThan(res.log.count, 250_000)
    }

    func testSkippedFailedBuildShowsPreviousLog() throws {
        let buildDir = dir.appendingPathComponent(TexService.outDir)
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
        let oldLog = buildDir.appendingPathComponent("main.log")
        try "./main.tex:3: Undefined control sequence.\nl.3 \\foo\n".write(to: oldLog, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: oldLog.path)
        let (runner, root) = try fakeLatexmk("""
        echo "Latexmk: Nothing to do for './main.tex'."
        echo "  pdflatex: gave an error in previous invocation of latexmk."
        exit 12
        """)
        let (exp, result) = compileAsync(runner, root)
        wait(for: [exp], timeout: 10)
        let res = try XCTUnwrap(result())
        XCTAssertFalse(res.ok)
        XCTAssertTrue(res.log.contains("Undefined control sequence"))
        XCTAssertFalse(res.diagnostics.isEmpty)
    }

    func testCancelKillsWholeProcessGroup() throws {
        let pidFile = dir.appendingPathComponent("pids").path
        let (runner, root) = try fakeLatexmk("""
        sleep 60 &
        echo "$$ $!" > '\(pidFile)'
        sleep 60
        """)
        let (exp, result) = compileAsync(runner, root)
        let pids = try XCTUnwrap(waitForFile(pidFile)).split(separator: " ").compactMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        XCTAssertEqual(pids.count, 2)
        runner.cancelCompile()
        wait(for: [exp], timeout: 5)
        let res = try XCTUnwrap(result())
        XCTAssertTrue(res.cancelled)
        XCTAssertFalse(res.ok)
        for pid in pids {
            XCTAssertTrue(isGone(pid, within: 3), "pid \(pid) still alive")
        }
    }

    func testTimeoutStopsBuild() throws {
        let pidFile = dir.appendingPathComponent("pids").path
        let (runner, root) = try fakeLatexmk("""
        sleep 60 &
        echo "$!" > '\(pidFile)'
        sleep 60
        """)
        let start = Date()
        let (exp, result) = compileAsync(runner, root, timeout: 1)
        wait(for: [exp], timeout: 8)
        let res = try XCTUnwrap(result())
        XCTAssertTrue(res.timedOut)
        XCTAssertFalse(res.ok)
        XCTAssertFalse(res.cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertTrue(res.log.contains("timed out"))
        if let child = waitForFile(pidFile, seconds: 0).flatMap({ pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) {
            XCTAssertTrue(isGone(child, within: 3))
        }
    }

    func testNewCompileSupersedesRunningOne() throws {
        let pidFile = dir.appendingPathComponent("slow.pid").path
        let (runner, slowRoot) = try fakeLatexmk("""
        case "$*" in *slow*) echo "$$" > '\(pidFile)'; sleep 60;; esac
        echo done
        """, root: "slow.tex")
        let fastRoot = dir.appendingPathComponent("fast.tex").path
        try "\\documentclass{article}".write(toFile: fastRoot, atomically: true, encoding: .utf8)

        let (slowExp, slowResult) = compileAsync(runner, slowRoot)
        let slowPid = try XCTUnwrap(waitForFile(pidFile).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        let fast = try runner.compile(root: fastRoot)
        wait(for: [slowExp], timeout: 5)
        let slow = try XCTUnwrap(slowResult())

        XCTAssertTrue(slow.cancelled)
        XCTAssertTrue(slow.superseded)
        XCTAssertTrue(fast.ok)
        XCTAssertFalse(fast.superseded)
        XCTAssertGreaterThan(fast.runID, slow.runID)
        XCTAssertTrue(runner.isCurrentRun(fast.runID))
        XCTAssertFalse(runner.isCurrentRun(slow.runID))
        XCTAssertTrue(isGone(slowPid, within: 3))
    }

    func testEngineOverrideAndUnreadableRoot() throws {
        let argsFile = dir.appendingPathComponent("args").path
        let (runner, root) = try fakeLatexmk("echo \"$*\" > '\(argsFile)'")
        let res = try runner.compile(root: root, engine: "xelatex")
        XCTAssertEqual(res.engine, "xelatex")
        XCTAssertTrue(try String(contentsOfFile: argsFile, encoding: .utf8).contains("-xelatex"))
        XCTAssertEqual(try runner.compile(root: root).engine, "pdflatex")

        XCTAssertThrowsError(try runner.compile(root: dir.appendingPathComponent("missing.tex").path)) { err in
            guard case TexError.unreadableRoot = err else { return XCTFail("unexpected \(err)") }
        }
    }

    func testTexbinOverride() throws {
        _ = try fakeLatexmk("exit 0")
        XCTAssertEqual(TexService.texbin(override: dir.path), dir.standardizedFileURL.path)
        XCTAssertNil(TexService.texbin(override: dir.appendingPathComponent("nope").path))
    }

    // MARK: - Security / race

    func testUnsafeRootNameRejected() throws {
        let marker = dir.appendingPathComponent("spawned").path
        let argsFile = dir.appendingPathComponent("args").path
        let (runner, _) = try fakeLatexmk("touch '\(marker)'; printf '%s\\n' \"$@\" > '\(argsFile)'")
        for name in ["-pdflatex=open -a Calculator #.tex", "a$(x).tex", "a`x`.tex", "a\"b.tex", "a;b.tex", "a\nb.tex"] {
            let path = dir.appendingPathComponent(name).path
            try "\\documentclass{article}".write(toFile: path, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try runner.compile(root: path)) { err in
                XCTAssertEqual(err as? TexError, .unsafeFileName(name))
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))

        let ok = dir.appendingPathComponent("my doc-1_2.tex").path
        try "\\documentclass{article}".write(toFile: ok, atomically: true, encoding: .utf8)
        XCTAssertTrue(try runner.compile(root: ok).ok)
        let args = try String(contentsOfFile: argsFile, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(args.last, "./my doc-1_2.tex")
        XCTAssertTrue(args.contains("-no-shell-escape"))
    }

    func testMagicRootOutsideWorkspaceIgnored() throws {
        let ws = dir.appendingPathComponent("ws")
        let other = dir.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: ws.appendingPathComponent("ch"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try "\\documentclass{article}".write(to: other.appendingPathComponent("x.tex"), atomically: true, encoding: .utf8)
        let mainPath = ws.appendingPathComponent("ch/main.tex").path
        try "\\documentclass{article}".write(toFile: mainPath, atomically: true, encoding: .utf8)
        let chap = ws.appendingPathComponent("ch/one.tex").path
        try "% !TEX root = ../../Other/x.tex\n\\section{A}".write(toFile: chap, atomically: true, encoding: .utf8)

        XCTAssertEqual(TexService.detectRoot(file: chap, workspaceRoot: ws.path), mainPath)
        XCTAssertEqual(TexService.detectRoot(file: chap), other.appendingPathComponent("x.tex").path)  // legacy: no workspace given

        // A symlink inside the workspace pointing outside is also ignored.
        try FileManager.default.createSymbolicLink(atPath: ws.appendingPathComponent("ch/link.tex").path,
                                                   withDestinationPath: other.appendingPathComponent("x.tex").path)
        try "% !TEX root = link.tex\n".write(toFile: chap, atomically: true, encoding: .utf8)
        XCTAssertEqual(TexService.detectRoot(file: chap, workspaceRoot: ws.path), mainPath)
    }

    func testCleanBuildRefusesSymlinkedBuildDir() throws {
        let victim = dir.appendingPathComponent("victim")
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        let proj = dir.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        let root = proj.appendingPathComponent("main.tex").path
        XCTAssertNoThrow(try TexProcessRunner.cleanBuild(root: root))  // no .build: no-op
        try FileManager.default.createSymbolicLink(atPath: proj.appendingPathComponent(".build").path, withDestinationPath: victim.path)
        XCTAssertThrowsError(try TexProcessRunner.cleanBuild(root: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path))
    }

    func testReserveThenCancelDoesNotSpawn() throws {
        let marker = dir.appendingPathComponent("spawned").path
        let (runner, root) = try fakeLatexmk("touch '\(marker)'")
        let id = runner.reserveRunID()
        runner.cancelCompile()
        let res = try runner.compile(root: root, runID: id)
        XCTAssertTrue(res.cancelled)
        XCTAssertFalse(res.ok)
        XCTAssertFalse(res.superseded)
        XCTAssertEqual(res.runID, id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))

        // Out-of-order: an older reservation arriving after a newer one is superseded and does not spawn.
        let old = runner.reserveRunID()
        let new = runner.reserveRunID()
        XCTAssertTrue(try runner.compile(root: root, runID: old).superseded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
        let fresh = try runner.compile(root: root, runID: new)
        XCTAssertTrue(fresh.ok)
        XCTAssertTrue(runner.isCurrentRun(new))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker))
    }

    func testScannerSkipsSymlinkLoop() throws {
        try "".write(to: dir.appendingPathComponent("a.tex"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("loop").path, withDestinationPath: ".")
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("alias.tex").path, withDestinationPath: "a.tex")
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("out.tex").path, withDestinationPath: "/etc/hosts")
        let tree = FileService.listTree(root: dir.path, extensions: ["tex"])
        XCTAssertEqual(tree.map(\.name), ["a.tex", "alias.tex"])
    }

    // MARK: - Parsing

    func testWarningsAttributedToOpenFile() {
        let root = "/p/main.tex"
        let log = """
        (./main.tex
        LaTeX2e <2023-11-01>
        (/usr/local/texlive/2024/texmf-dist/tex/latex/base/article.cls
        Document Class: article 2023/05/17 v1.4n Standard LaTeX document class
        (/usr/local/texlive/2024/texmf-dist/tex/latex/base/size10.clo))
        (./my chapter.tex [1]
        LaTeX Warning: Reference `fig:a' on page 1 undefined on input line 4.

        )
        LaTeX Warning: Citation `knuth' on page 2 undefined on input line 9.

        Package natbib Warning: Citation `a-very-long-citation-key-that-wraps' on page
        (natbib)                2 undefined on input line 12.

        Overfull \\hbox (15.0pt too wide) in paragraph at lines 20--21
        ./main.tex:30: Undefined control sequence.
        l.30 \\foo(
        """
        let diags = TexService.parseLog(log: log, root: root)
        XCTAssertEqual(diags.count, 5, "\(diags)")
        XCTAssertEqual(diags[0].file, "/p/my chapter.tex")
        XCTAssertEqual(diags[0].line, 4)
        XCTAssertEqual(diags[1].file, root)
        XCTAssertEqual(diags[1].line, 9)
        XCTAssertNotNil(diags[1].explanation)
        XCTAssertEqual(diags[2].file, root)
        XCTAssertEqual(diags[2].line, 12)
        XCTAssertEqual(diags[3].line, 20)
        XCTAssertTrue(diags[3].isWarning)
        XCTAssertFalse(diags[4].isWarning)
        XCTAssertEqual(diags[4].file, root)
        XCTAssertEqual(diags[4].line, 30)
        XCTAssertNotNil(diags[4].explanation)
    }

    func testBangErrorUsesFollowingLineNumber() {
        let log = """
        (./main.tex (./sub/part.tex
        ! Missing $ inserted.
        <inserted text>
        l.7 a_
        """
        let diags = TexService.parseLog(log: log, root: "/p/main.tex")
        XCTAssertEqual(diags, [TexDiagnostic(file: "/p/sub/part.tex", line: 7, message: "Missing $ inserted.",
                                             isWarning: false, explanation: DiagnosticExplainer.explain("Missing $ inserted."))])
    }

    func testExplainer() {
        XCTAssertNotNil(DiagnosticExplainer.explain("Undefined control sequence."))
        XCTAssertTrue(DiagnosticExplainer.explain("LaTeX Error: File `tikzz.sty' not found.")?.contains("tikzz.sty") ?? false)
        XCTAssertTrue(DiagnosticExplainer.explain("LaTeX Error: \\begin{itemize} on input line 3 ended by \\end{document}.")?.contains("mismatched") ?? false)
        XCTAssertTrue(DiagnosticExplainer.explain("LaTeX Error: Environment alignn undefined.")?.contains("environment") ?? false)
        XCTAssertTrue(DiagnosticExplainer.explain("Reference `x' on page 1 undefined on input line 3.")?.contains("\\ref") ?? false)
        XCTAssertTrue(DiagnosticExplainer.explain("Citation `x' on page 1 undefined on input line 3.")?.contains("\\cite") ?? false)
        XCTAssertTrue(DiagnosticExplainer.explain("There were undefined references.")?.contains("Compile again") ?? false)
        XCTAssertTrue(DiagnosticExplainer.explain("Package fontspec Error: The font \"Foo\" cannot be found.")?.contains("font") ?? false)
        XCTAssertNotNil(DiagnosticExplainer.explain("Emergency stop."))
        XCTAssertNotNil(DiagnosticExplainer.explain("Label `a' multiply defined."))
        XCTAssertNil(DiagnosticExplainer.explain("Something entirely unrelated"))
    }

    func testSynctexParsing() {
        let view = """
        This is SyncTeX command line utility, version 1.5
        SyncTeX result begin
        Output:/Users/a/My Docs/.build/main.pdf
        Page:2
        x:100.0
        y:200.0
        h:72.5
        v:150.0
        W:300.0
        H:10.0
        Output:garbage
        Page:x
        SyncTeX result end
        """
        XCTAssertEqual(TexService.parseSynctexView(view), [SyncTexSpot(page: 2, x: 72.5, y: 140, w: 300, h: 10)])
        XCTAssertEqual(TexService.parseSynctexView("not synctex at all"), [])

        let pdf = "/Users/a/My Docs/.build/main.pdf"
        let rel = "SyncTeX result begin\nOutput:main.pdf\nInput:./ch 1.tex\nLine:42\nColumn:-1\nSyncTeX result end\n"
        XCTAssertEqual(TexService.parseSynctexEdit(rel, pdf: pdf), SourceLocation(file: "/Users/a/My Docs/ch 1.tex", line: 42))
        let abs = "Input:/Users/a/My Docs/./sub/x.tex\nLine:3\n"
        XCTAssertEqual(TexService.parseSynctexEdit(abs, pdf: pdf), SourceLocation(file: "/Users/a/My Docs/sub/x.tex", line: 3))
        XCTAssertNil(TexService.parseSynctexEdit("Input:\nLine:abc\n", pdf: pdf))
        XCTAssertNil(TexService.parseSynctexEdit("", pdf: pdf))
    }

    func testMarkdownCommentSyntax() {
        XCTAssertEqual(WorkspaceMode.markdown.commentSyntax.prefix, "<!--")
        XCTAssertEqual(WorkspaceMode.markdown.commentSyntax.suffix, "-->")
        XCTAssertEqual(WorkspaceMode.latex.commentSyntax.prefix, "%")
        XCTAssertNil(WorkspaceMode.latex.commentSyntax.suffix)
    }
}

private final class ResultBox: @unchecked Sendable {
    var value: CompileResult?
}
