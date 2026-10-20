import ProofCore
import Foundation
import XCTest

final class LinkPolicyTests: XCTestCase {
    func testExternalAllowlist() {
        XCTAssertNotNil(LinkPolicy.externalURL("https://example.com/a?b#c"))
        XCTAssertNotNil(LinkPolicy.externalURL("HTTP://example.com"))
        XCTAssertNotNil(LinkPolicy.externalURL("mailto:a@b.c"))
        for bad in ["file:///etc/passwd", "javascript:alert(1)", "x-apple-helpviewer://x", "ssh://host",
                    "data:text/html,hi", "https:///nohost", "notes.md", "", "vnc://host"] {
            XCTAssertNil(LinkPolicy.externalURL(bad), bad)
        }
    }

    func testResolveWorkspaceFile() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("cp-link-\(UUID().uuidString)")
        let root = base.appendingPathComponent("ws")
        let sub = root.appendingPathComponent("docs")
        let outside = base.appendingPathComponent("outside")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        for p in ["docs/a.md", "docs/my note.md", "top.markdown", "docs/img.png"] {
            try "x".write(to: root.appendingPathComponent(p), atomically: true, encoding: .utf8)
        }
        try "x".write(to: outside.appendingPathComponent("secret.md"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: sub.appendingPathComponent("link.md"),
                                  withDestinationURL: outside.appendingPathComponent("secret.md"))

        let exts = ["md", "markdown"]
        func resolve(_ href: String) -> String? {
            LinkPolicy.resolveWorkspaceFile(href: href, baseDirectory: sub.path, workspaceRoot: root.path, allowedExtensions: exts)
        }
        let canonical = { (p: String) in root.appendingPathComponent(p).standardizedFileURL.path }

        XCTAssertEqual(resolve("a.md"), canonical("docs/a.md"))
        XCTAssertEqual(resolve("./a.md#section"), canonical("docs/a.md"))
        XCTAssertEqual(resolve("a.md?x=1"), canonical("docs/a.md"))
        XCTAssertEqual(resolve("my%20note.md"), canonical("docs/my note.md"))
        XCTAssertEqual(resolve("../top.markdown"), canonical("top.markdown"))
        XCTAssertEqual(resolve(root.appendingPathComponent("docs/a.md").path), canonical("docs/a.md"))
        XCTAssertEqual(resolve(root.appendingPathComponent("docs/a.md").absoluteString), canonical("docs/a.md"))

        XCTAssertNil(resolve("../../outside/secret.md"), "escapes root via ..")
        XCTAssertNil(resolve("link.md"), "escapes root via symlink")
        XCTAssertNil(resolve(outside.appendingPathComponent("secret.md").path), "absolute path outside root")
        XCTAssertNil(resolve("img.png"), "unsupported extension")
        XCTAssertNil(resolve("missing.md"), "file must exist")
        XCTAssertNil(resolve("../docs"), "directory")
        XCTAssertNil(resolve("#heading"))
        XCTAssertNil(resolve("https://example.com/a.md"))
        XCTAssertNil(resolve("javascript:alert(1)"))
        XCTAssertNil(resolve("//host/a.md"))
        XCTAssertNil(resolve("%E0%A4%A.md"), "invalid percent encoding")
    }
}
