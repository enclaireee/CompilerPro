import Foundation

/// The running app's version and the small amount of version logic the update check needs.
///
/// When the app is packaged, `CFBundleShortVersionString` is the source of truth. During
/// `swift run` there is no bundle, so the compiled-in fallback is used instead — bump it
/// alongside the release tag so a development build still notices a newer release.
public enum AppVersion {
    /// Keep in step with the tag of the release this source is cut from.
    public static let fallback = "0.2.0"

    public static var current: String {
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return version.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return fallback
    }

    public static var build: String? {
        guard let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              !build.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              build != current else { return nil }
        return build.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "0.2.0", or "0.2.0 (42)" when the bundle carries a separate build number.
    public static var display: String {
        if let build { return "\(current) (\(build))" }
        return current
    }

    /// True when `candidate` is a strictly later release than `current`.
    ///
    /// Unparseable versions never count as newer: a malformed tag should not nag the user.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let new = SemanticVersion(candidate), let old = SemanticVersion(current) else { return false }
        return new > old
    }
}

/// A lenient semantic version: `1.2`, `v1.2.0`, `1.2.0-beta.1` and `1.2.0+build` all parse.
public struct SemanticVersion: Comparable, Equatable, CustomStringConvertible {
    public let components: [Int]
    public let prerelease: String?

    public init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        if let plus = text.firstIndex(of: "+") { text = String(text[text.startIndex..<plus]) }

        let halves = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = halves[0].split(separator: ".", omittingEmptySubsequences: false)
        guard !numbers.isEmpty else { return nil }

        var components: [Int] = []
        for number in numbers {
            guard let value = Int(number), value >= 0 else { return nil }
            components.append(value)
        }

        self.components = components
        let suffix = halves.count > 1 ? String(halves[1]) : ""
        self.prerelease = suffix.isEmpty ? nil : suffix
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let width = max(lhs.components.count, rhs.components.count)
        for index in 0..<width {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        // A release outranks any of its prereleases: 1.0.0 > 1.0.0-beta.2.
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): return false
        case (nil, _): return false
        case (_, nil): return true
        case let (left?, right?): return Self.comparePrerelease(left, right) < 0
        }
    }

    private static func comparePrerelease(_ lhs: String, _ rhs: String) -> Int {
        let left = lhs.split(separator: ".")
        let right = rhs.split(separator: ".")
        for index in 0..<max(left.count, right.count) {
            guard index < left.count else { return -1 }
            guard index < right.count else { return 1 }
            let l = left[index], r = right[index]
            if l == r { continue }
            if let ln = Int(l), let rn = Int(r) { return ln < rn ? -1 : 1 }
            if let _ = Int(l) { return -1 }   // numeric identifiers sort before alphanumeric
            if let _ = Int(r) { return 1 }
            return l < r ? -1 : 1
        }
        return 0
    }

    public var description: String {
        let base = components.map(String.init).joined(separator: ".")
        return prerelease.map { "\(base)-\($0)" } ?? base
    }
}
