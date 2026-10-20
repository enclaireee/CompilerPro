import ProofCore
import Foundation
import XCTest

final class BuildLogTests: XCTestCase {
    private let root = "/Users/a/My Docs"

    func testParsesRelativeLocationAndError() {
        let lines = BuildLog.parse("./ch/one.tex:12: LaTeX Error: Undefined control sequence.\n", root: root)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].file, "/Users/a/My Docs/ch/one.tex")
        XCTAssertEqual(lines[0].line, 12)
        XCTAssertEqual(lines[0].severity, .error)
        XCTAssertTrue(lines[0].isNavigable)
    }

    func testParsesAbsoluteLocationWithSpaces() {
        let log = "/Users/a/My Docs/main.tex:4: LaTeX Warning: Reference undefined."
        let lines = BuildLog.parse(log, root: root)
        XCTAssertEqual(lines[0].file, "/Users/a/My Docs/main.tex")
        XCTAssertEqual(lines[0].line, 4)
        XCTAssertEqual(lines[0].severity, .warning)
    }

    func testDoesNotLinkUnrelatedColonLines() {
        let lines = BuildLog.parse("Package: hyperref 2024/01/01 v7.01\n(./main.aux)", root: root)
        XCTAssertNil(lines[0].file)
        XCTAssertFalse(lines[1].isNavigable)
    }

    func testBareErrorHasNoLocationButKeepsSeverity() {
        let lines = BuildLog.parse("! Emergency stop.\nl.42 \\foo", root: root)
        XCTAssertNil(lines[0].file)
        XCTAssertEqual(lines[0].severity, .error)
        XCTAssertEqual(lines[1].severity, .info)
    }

    func testSummaryZeroErrorsIsNotAnError() {
        let lines = BuildLog.parse("0 errors, 0 warnings", root: root)
        XCTAssertEqual(lines[0].severity, .info)
    }

    func testLineNumbersAreStableAndStripCarriageReturns() {
        let lines = BuildLog.parse("a\r\nb\r\n", root: root)
        XCTAssertEqual(lines.map(\.id), [0, 1])
        XCTAssertEqual(lines[0].text, "a")
        XCTAssertEqual(lines[1].text, "b")
    }
}
