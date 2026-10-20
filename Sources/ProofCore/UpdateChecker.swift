import Foundation

/// One published release, in the terms the app cares about.
public struct ReleaseInfo: Sendable, Equatable {
    /// Normalised for display and comparison: no leading `v`, no build metadata.
    public let version: String
    public let name: String
    public let notes: String
    public let pageURL: URL
    /// A disk image or zip when the release carries one, otherwise the release page.
    public let downloadURL: URL
    public let publishedAt: Date?

    public init(version: String, name: String, notes: String, pageURL: URL,
                downloadURL: URL, publishedAt: Date?) {
        self.version = version
        self.name = name
        self.notes = notes
        self.pageURL = pageURL
        self.downloadURL = downloadURL
        self.publishedAt = publishedAt
    }
}

public enum UpdateCheckError: Error, Equatable, LocalizedError {
    case transport(String)
    case rateLimited
    case badStatus(Int)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .transport(let detail):
            return "Couldn't reach the update server. \(detail)"
        case .rateLimited:
            return "GitHub is limiting update checks right now. Try again in a little while."
        case .badStatus(let code):
            return "The update server returned HTTP \(code)."
        case .malformedResponse:
            return "The update server sent a response Proof didn't understand."
        }
    }
}

/// Reads the newest published release from a GitHub releases endpoint.
///
/// The network call is injected so the parsing and decision logic can be tested
/// without a network, and so a different feed can replace GitHub later without
/// touching the UI.
public struct UpdateChecker: Sendable {
    public typealias FeedLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// The repository is public, so this endpoint needs no token.
    public static let defaultFeedURL = URL(string: "https://api.github.com/repos/enclaireee/CompilerPro/releases/latest")!

    public let feedURL: URL
    private let load: FeedLoader

    public init(feedURL: URL = UpdateChecker.defaultFeedURL,
                load: @escaping FeedLoader = UpdateChecker.urlSessionLoader) {
        self.feedURL = feedURL
        self.load = load
    }

    /// Returns `nil` when the repository has no published releases yet.
    public func latestRelease() async throws -> ReleaseInfo? {
        var request = URLRequest(url: feedURL)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Proof/\(AppVersion.current) (macOS)", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await load(request)
        } catch {
            throw UpdateCheckError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw UpdateCheckError.malformedResponse }
        switch http.statusCode {
        case 200: break
        case 404: return nil
        case 403, 429: throw UpdateCheckError.rateLimited
        default: throw UpdateCheckError.badStatus(http.statusCode)
        }

        let payload: GitHubRelease
        do {
            payload = try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw UpdateCheckError.malformedResponse
        }
        return try payload.release()
    }

    public static let urlSessionLoader: FeedLoader = { request in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        return try await session.data(for: request)
    }
}

// MARK: - GitHub payload

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: String
    let publishedAt: String?
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body, assets
        case htmlURL = "html_url"
        case publishedAt = "published_at"
    }

    func release() throws -> ReleaseInfo {
        guard let pageURL = URL(string: htmlURL) else { throw UpdateCheckError.malformedResponse }
        let version = Self.normalise(tagName)
        guard !version.isEmpty else { throw UpdateCheckError.malformedResponse }

        let assetURL = preferredAsset().flatMap { URL(string: $0.browserDownloadURL) }
        return ReleaseInfo(
            version: version,
            name: (name?.isEmpty == false ? name : nil) ?? "Proof \(version)",
            notes: body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            pageURL: pageURL,
            downloadURL: assetURL ?? pageURL,
            publishedAt: publishedAt.flatMap(Self.parseDate)
        )
    }

    /// Disk images first, then archives, then whatever the release happens to attach.
    private func preferredAsset() -> Asset? {
        let ordered = ["dmg", "zip", "tar.gz", "pkg"]
        for suffix in ordered {
            if let asset = assets.first(where: { $0.name.lowercased().hasSuffix(".\(suffix)") }) {
                return asset
            }
        }
        return assets.first
    }

    static func normalise(_ tag: String) -> String {
        var text = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        return text
    }

    static func parseDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}
