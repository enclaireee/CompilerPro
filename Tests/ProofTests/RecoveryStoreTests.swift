import ProofCore
import Foundation
import XCTest

final class RecoveryStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("proof-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        RecoveryStore.directoryOverride = dir
    }

    override func tearDownWithError() throws {
        RecoveryStore.directoryOverride = nil
        try? FileManager.default.removeItem(at: dir)
    }

    func testRoundTrip() {
        let format = TextFormat(encoding: .utf16LittleEndian, lineEnding: .crlf)
        XCTAssertTrue(RecoveryStore.write(path: "/tmp/notes.md", folder: "/tmp", text: "hi\nthere", format: format))
        let loaded = RecoveryStore.load(folder: "/tmp", path: "/tmp/notes.md")
        XCTAssertEqual(loaded?.text, "hi\nthere")
        XCTAssertEqual(loaded?.format, format)
    }

    func testSnapshotsArePerFileAndFolder() {
        RecoveryStore.write(path: "/tmp/a.md", folder: "/tmp", text: "a", format: .default)
        RecoveryStore.write(path: "/tmp/b.md", folder: "/tmp", text: "b", format: .default)
        XCTAssertEqual(RecoveryStore.load(folder: "/tmp", path: "/tmp/a.md")?.text, "a")
        XCTAssertEqual(RecoveryStore.load(folder: "/tmp", path: "/tmp/b.md")?.text, "b")
        XCTAssertNil(RecoveryStore.load(folder: "/other", path: "/tmp/a.md"))
    }

    func testRemoveAndRemoveAll() {
        RecoveryStore.write(path: "/tmp/a.md", folder: "/tmp", text: "a", format: .default)
        RecoveryStore.write(path: "/tmp/b.md", folder: "/tmp", text: "b", format: .default)
        RecoveryStore.write(path: "/elsewhere/c.md", folder: "/elsewhere", text: "c", format: .default)
        RecoveryStore.remove(folder: "/tmp", path: "/tmp/a.md")
        XCTAssertNil(RecoveryStore.load(folder: "/tmp", path: "/tmp/a.md"))
        XCTAssertNotNil(RecoveryStore.load(folder: "/tmp", path: "/tmp/b.md"))
        RecoveryStore.removeAll(folder: "/tmp")
        XCTAssertNil(RecoveryStore.load(folder: "/tmp", path: "/tmp/b.md"))
        XCTAssertNotNil(RecoveryStore.load(folder: "/elsewhere", path: "/elsewhere/c.md"))
    }

    func testFingerprintIsStable() {
        let a = RecoveryStore.fingerprint(folder: "/tmp", path: "/tmp/a.md")
        let b = RecoveryStore.fingerprint(folder: "/tmp", path: "/tmp/a.md")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, RecoveryStore.fingerprint(folder: "/tmp", path: "/tmp/b.md"))
    }
}
