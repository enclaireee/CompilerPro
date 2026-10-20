import XCTest
@testable import ProofCore

final class UpdateCheckerTests: XCTestCase {

    // MARK: - Version comparison

    func testNewerVersions() {
        XCTAssertTrue(AppVersion.isNewer("0.2.0", than: "0.1.9"))
        XCTAssertTrue(AppVersion.isNewer("1.0.0", than: "0.9.9"))
        XCTAssertTrue(AppVersion.isNewer("0.2.1", than: "0.2.0"))
        XCTAssertTrue(AppVersion.isNewer("v1.2.0", than: "1.1.9"))
        XCTAssertTrue(AppVersion.isNewer("1.0", than: "0.9.9"))
    }

    func testSameVersionInDifferentSpellings() {
        XCTAssertFalse(AppVersion.isNewer("0.2.0", than: "0.2.0"))
        XCTAssertFalse(AppVersion.isNewer("v0.2.0", than: "0.2.0"))
        XCTAssertFalse(AppVersion.isNewer("1.0", than: "1.0.0"))
        XCTAssertFalse(AppVersion.isNewer("1.0.0+build.7", than: "1.0.0"))
    }

    func testPrereleases() {
        XCTAssertTrue(AppVersion.isNewer("1.0.0", than: "1.0.0-beta.2"))
        XCTAssertFalse(AppVersion.isNewer("1.0.0-beta.2", than: "1.0.0"))
        XCTAssertTrue(AppVersion.isNewer("1.0.0-beta.2", than: "1.0.0-beta.1"))
        XCTAssertTrue(AppVersion.isNewer("1.0.0-beta.10", than: "1.0.0-beta.9"))
    }

    func testUnparseableVersionsAreNotNewer() {
        XCTAssertFalse(AppVersion.isNewer("latest", than: "0.2.0"))
        XCTAssertFalse(AppVersion.isNewer("0.2.0", than: "latest"))
    }

    // MARK: - Response handling

    func testDecodesReleaseAndPrefersDiskImage() async throws {
        let checker = makeChecker(status: 200, body: """
        {
          "tag_name": "v0.3.0",
          "name": "Proof 0.3.0",
          "body": "Faster previews.\\n\\n- One\\n- Two",
          "html_url": "https://github.com/enclaireee/CompilerPro/releases/tag/v0.3.0",
          "published_at": "2026-10-18T13:54:46Z",
          "assets": [
            {"name": "Proof-0.3.0.zip", "browser_download_url": "https://example.test/Proof-0.3.0.zip"},
            {"name": "Proof-0.3.0.dmg", "browser_download_url": "https://example.test/Proof-0.3.0.dmg"}
          ]
        }
        """)

        let release = try await checker.latestRelease()
        XCTAssertEqual(release?.version, "0.3.0")
        XCTAssertEqual(release?.name, "Proof 0.3.0")
        XCTAssertEqual(release?.downloadURL.absoluteString, "https://example.test/Proof-0.3.0.dmg")
        XCTAssertEqual(release?.pageURL.absoluteString,
                       "https://github.com/enclaireee/CompilerPro/releases/tag/v0.3.0")
        XCTAssertNotNil(release?.publishedAt)
    }

    func testFallsBackToZipThenReleasePage() async throws {
        let zipOnly = makeChecker(status: 200, body: """
        {"tag_name": "0.3.0", "html_url": "https://example.test/r", "assets": [
          {"name": "Proof-0.3.0.zip", "browser_download_url": "https://example.test/p.zip"}
        ]}
        """)
        let zipRelease = try await zipOnly.latestRelease()
        XCTAssertEqual(zipRelease?.downloadURL.absoluteString, "https://example.test/p.zip")

        let noAssets = makeChecker(status: 200, body: """
        {"tag_name": "0.3.0", "html_url": "https://example.test/r", "assets": []}
        """)
        let bareRelease = try await noAssets.latestRelease()
        XCTAssertEqual(bareRelease?.downloadURL.absoluteString, "https://example.test/r")
        XCTAssertEqual(bareRelease?.name, "Proof 0.3.0")
    }

    func testNoReleasesYetReturnsNil() async throws {
        let checker = makeChecker(status: 404, body: #"{"message": "Not Found"}"#)
        let release = try await checker.latestRelease()
        XCTAssertNil(release)
    }

    func testRateLimitIsReported() async {
        let checker = makeChecker(status: 403, body: #"{"message": "API rate limit exceeded"}"#)
        await assertThrows(.rateLimited) { try await checker.latestRelease() }
    }

    func testUnexpectedStatusIsReported() async {
        let checker = makeChecker(status: 500, body: "")
        await assertThrows(.badStatus(500)) { try await checker.latestRelease() }
    }

    func testMalformedJSONIsReported() async {
        let checker = makeChecker(status: 200, body: "not json")
        await assertThrows(.malformedResponse) { try await checker.latestRelease() }
    }

    func testTransportFailureIsReported() async {
        let checker = UpdateChecker(feedURL: URL(string: "https://example.test/feed")!) { _ in
            throw URLError(.notConnectedToInternet)
        }
        do {
            _ = try await checker.latestRelease()
            XCTFail("Expected a transport failure")
        } catch let error as UpdateCheckError {
            guard case .transport = error else {
                return XCTFail("Expected .transport, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testRequestCarriesGitHubHeaders() async throws {
        let box = HeaderBox()
        let checker = UpdateChecker(feedURL: URL(string: "https://example.test/feed")!) { request in
            await box.record(request)
            return (Data(#"{"tag_name":"1.0.0","html_url":"https://example.test/r","assets":[]}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        _ = try await checker.latestRelease()

        let headers = await box.headers
        XCTAssertEqual(headers?["Accept"], "application/vnd.github+json")
        XCTAssertTrue(headers?["User-Agent"]?.hasPrefix("Proof/") == true)
    }

    // MARK: - Helpers

    private func makeChecker(status: Int, body: String) -> UpdateChecker {
        UpdateChecker(feedURL: URL(string: "https://example.test/feed")!) { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }

    private func assertThrows(_ expected: UpdateCheckError,
                              file: StaticString = #filePath, line: UInt = #line,
                              _ body: () async throws -> ReleaseInfo?) async {
        do {
            _ = try await body()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as UpdateCheckError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error \(error)", file: file, line: line)
        }
    }
}

private actor HeaderBox {
    private(set) var headers: [String: String]?

    func record(_ request: URLRequest) {
        headers = request.allHTTPHeaderFields
    }
}
