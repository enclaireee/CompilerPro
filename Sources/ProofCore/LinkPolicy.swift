import Foundation

/// Decides which links clicked inside a (possibly untrusted) document preview may be followed.
public enum LinkPolicy {
    public static let externalSchemes: Set<String> = ["http", "https", "mailto"]

    /// Returns a URL to hand to the system only for http(s) with a host, or mailto. Everything else is nil.
    public static func externalURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              externalSchemes.contains(scheme) else { return nil }
        if scheme != "mailto" && (url.host ?? "").isEmpty { return nil }
        return url
    }

    /// Resolves a document link (relative path, absolute path or file: URL) to an existing file
    /// inside `workspaceRoot` whose extension is in `allowedExtensions`. Returns the resolved path or nil.
    public static func resolveWorkspaceFile(
        href raw: String,
        baseDirectory: String,
        workspaceRoot: String,
        allowedExtensions: [String],
        fileManager: FileManager = .default
    ) -> String? {
        let href = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !href.isEmpty, !href.hasPrefix("//") else { return nil }

        let path: String
        if href.range(of: #"^[A-Za-z][A-Za-z0-9+.\-]*:"#, options: .regularExpression) != nil {
            // Only file: URLs (WebKit resolves relative hrefs against the file base URL) are local.
            guard href.lowercased().hasPrefix("file:"), let url = URL(string: href), url.isFileURL else { return nil }
            path = url.path
        } else {
            let end = href.firstIndex(where: { $0 == "#" || $0 == "?" }) ?? href.endIndex
            guard let decoded = String(href[..<end]).removingPercentEncoding, !decoded.isEmpty else { return nil }
            path = decoded.hasPrefix("/") ? decoded : (baseDirectory as NSString).appendingPathComponent(decoded)
        }
        guard !path.isEmpty, !path.contains("\0") else { return nil }

        // Containment must hold both lexically (after resolving `..`) and after resolving symlinks,
        // so neither `../` nor a symlink inside the workspace can reach files outside it.
        let lexical = URL(fileURLWithPath: path).standardizedFileURL
        let lexicalRoot = URL(fileURLWithPath: workspaceRoot, isDirectory: true).standardizedFileURL
        guard isPath(lexical.path, inside: lexicalRoot.path),
              isPath(lexical.resolvingSymlinksInPath().path, inside: lexicalRoot.resolvingSymlinksInPath().path)
        else { return nil }

        let ext = lexical.pathExtension.lowercased()
        guard allowedExtensions.contains(where: { $0.lowercased() == ext }) else { return nil }

        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: lexical.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        return lexical.path
    }

    private static func isPath(_ path: String, inside root: String) -> Bool {
        path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}
