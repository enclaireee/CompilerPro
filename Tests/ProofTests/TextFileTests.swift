import ProofCore
import Foundation
import XCTest

final class TextFileTests: XCTestCase {
    func testPreservesCRLF() throws {
        let contents = try TextFile.decode(Data("a\r\nb\r\n".utf8))
        XCTAssertEqual(contents.text, "a\nb\n")
        XCTAssertEqual(contents.format.lineEnding, .crlf)
        XCTAssertEqual(try TextFile.encode(text: contents.text, format: contents.format), Data("a\r\nb\r\n".utf8))
    }

    func testPreservesLoneCR() throws {
        let contents = try TextFile.decode(Data("a\rb\r".utf8))
        XCTAssertEqual(contents.text, "a\nb\n")
        XCTAssertEqual(contents.format.lineEnding, .cr)
        XCTAssertEqual(try TextFile.encode(text: contents.text, format: contents.format), Data("a\rb\r".utf8))
    }

    func testPreservesUTF8BOM() throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("héllo\n".utf8))
        let contents = try TextFile.decode(data)
        XCTAssertEqual(contents.text, "héllo\n")
        XCTAssertEqual(contents.format.encoding, .utf8WithBOM)
        XCTAssertEqual(try TextFile.encode(text: contents.text, format: contents.format), data)
    }

    func testUTF16RoundTrip() throws {
        let original = "ünïcode\r\nsecond"
        var data = Data([0xFF, 0xFE])
        data.append(original.data(using: .utf16LittleEndian)!)
        let contents = try TextFile.decode(data)
        XCTAssertEqual(contents.text, "ünïcode\nsecond")
        XCTAssertEqual(contents.format.encoding, .utf16LittleEndian)
        XCTAssertEqual(contents.format.lineEnding, .crlf)
        XCTAssertEqual(try TextFile.encode(text: contents.text, format: contents.format), data)
    }

    func testLatin1Fallback() throws {
        // 0xE9 is not valid UTF-8 but is "é" in both Windows-1252 and Latin-1.
        let contents = try TextFile.decode(Data([0x63, 0x61, 0x66, 0xE9]))
        XCTAssertEqual(contents.text, "café")
        XCTAssertNotEqual(contents.format.encoding, .utf8)
        XCTAssertEqual(try TextFile.encode(text: contents.text, format: contents.format), Data([0x63, 0x61, 0x66, 0xE9]))
    }

    func testBinaryIsRejected() {
        XCTAssertThrowsError(try TextFile.decode(Data([0x50, 0x4B, 0x00, 0x01]))) { error in
            guard case TextFileError.binary = error else { return XCTFail("\(error)") }
        }
    }

    func testMixedLineEndingsPickTheMajority() throws {
        let contents = try TextFile.decode(Data("a\r\nb\r\nc\n".utf8))
        XCTAssertEqual(contents.format.lineEnding, .crlf)
        XCTAssertEqual(contents.text, "a\nb\nc\n")
    }

    func testUnrepresentableTextIsRejectedInsteadOfLossy() {
        let format = TextFormat(encoding: .windows1252, lineEnding: .lf)
        XCTAssertThrowsError(try TextFile.encode(text: "日本語", format: format)) { error in
            guard case TextFileError.unwritable = error else { return XCTFail("\(error)") }
        }
    }
}
