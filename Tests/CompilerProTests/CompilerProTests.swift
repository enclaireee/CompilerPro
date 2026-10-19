import CompilerProCore
import Foundation
import XCTest

final class CompilerProTests: XCTestCase {
    private func makeTempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cp-swift-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testAtomicWriteReplacesAndLeavesNoTemp() throws {
        let dir = try makeTempDir("aw")
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("a.md").path
        try FileService.atomicWriteText(path: file, contents: "one")
        try FileService.atomicWriteText(path: file, contents: "two")

        let readBack = try String(contentsOfFile: file, encoding: .utf8)
        XCTAssertEqual(readBack, "two")

        let items = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(items, ["a.md"])
    }

    func testTreeFiltersAndDropsEmptyDirs() throws {
        let dir = try makeTempDir("tree")
        defer { try? FileManager.default.removeItem(at: dir) }

        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("ch"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent(".build"), withIntermediateDirectories: true)

        for rel in ["main.tex", "notes.md", "ch/one.tex", ".build/main.tex"] {
            try "".write(to: dir.appendingPathComponent(rel), atomically: true, encoding: .utf8)
        }

        let tree = FileService.listTree(root: dir.path, extensions: ["tex"])
        XCTAssertEqual(tree.map(\.name), ["ch", "main.tex"])
        XCTAssertEqual(tree[0].children.map(\.name), ["one.tex"])
    }

    func testEngineMagicComment() {
        XCTAssertEqual(TexService.detectEngine(source: "% !TEX program = xelatex\n\\documentclass{article}"), "xelatex")
        XCTAssertEqual(TexService.detectEngine(source: "%!TEX TS-program = lualatex"), "pdflatex")
        XCTAssertEqual(TexService.detectEngine(source: "% !TEX program=LuaLaTeX"), "lualatex")
        XCTAssertEqual(TexService.detectEngine(source: "\\documentclass{article}"), "pdflatex")
    }

    func testRootDetection() throws {
        let dir = try makeTempDir("root")
        defer { try? FileManager.default.removeItem(at: dir) }

        let mainPath = dir.appendingPathComponent("main.tex").path
        let chPath = dir.appendingPathComponent("ch.tex").path
        let magicPath = dir.appendingPathComponent("magic.tex").path
        let commentedPath = dir.appendingPathComponent("commented.tex").path

        try "\\documentclass{article}\n\\begin{document}\\input{ch}\\end{document}".write(toFile: mainPath, atomically: true, encoding: .utf8)
        try "\\section{A}".write(toFile: chPath, atomically: true, encoding: .utf8)
        try "% !TEX root = main.tex\n".write(toFile: magicPath, atomically: true, encoding: .utf8)
        try "% \\documentclass{article}\n$x$".write(toFile: commentedPath, atomically: true, encoding: .utf8)

        XCTAssertEqual(TexService.detectRoot(file: mainPath), mainPath)
        XCTAssertEqual(TexService.detectRoot(file: chPath), mainPath)
        XCTAssertEqual(TexService.detectRoot(file: magicPath), mainPath)

        let loneDir = try makeTempDir("snippet")
        defer { try? FileManager.default.removeItem(at: loneDir) }
        let snipPath = loneDir.appendingPathComponent("snip.tex").path
        try "\\int_0^1 x\\,dx".write(toFile: snipPath, atomically: true, encoding: .utf8)
        XCTAssertNil(TexService.detectRoot(file: snipPath))
    }

    func testLogParsing() {
        let root = "/p/main.tex"
        let log = """
        ./ch.tex:12: Undefined control sequence.
        LaTeX Warning: Reference `fig' on page 1 undefined on input line 7.
        ./ch.tex:12: Undefined control sequence.
        Overfull \\hbox in paragraph
        """
        let diags = TexService.parseLog(log: log, root: root)
        XCTAssertEqual(diags.count, 2)
        XCTAssertEqual(diags[0].line, 12)
        XCTAssertFalse(diags[0].isWarning)
        XCTAssertTrue(diags[0].file.hasSuffix("ch.tex"))
        XCTAssertEqual(diags[1].line, 7)
        XCTAssertTrue(diags[1].isWarning)
    }

    func testOutlineAndMathBlocks() {
        let md = """
        # Title
        ```markdown
        # Ignored inside fence
        ```
        ## Section Two
        """
        let headings = FileService.outlineOf(mode: .markdown, text: md)
        XCTAssertEqual(headings.count, 2)
        XCTAssertEqual(headings[0].title, "Title")
        XCTAssertEqual(headings[0].depth, 0)
        XCTAssertEqual(headings[1].title, "Section Two")
        XCTAssertEqual(headings[1].depth, 1)

        let snip = """
        % comment
        \\[ E = mc^2 \\]

        $$\\int_0^1 x^2 dx$$
        """
        let blocks = TexService.mathBlocks(text: snip)
        XCTAssertEqual(blocks, ["E = mc^2", "\\int_0^1 x^2 dx"])
    }
}
