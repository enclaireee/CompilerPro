import Foundation

/// A crash-recovery copy of an unsaved buffer. The editor writes one after a pause in
/// typing and removes it as soon as the buffer is saved or the user discards it.
public struct RecoverySnapshot: Codable, Equatable, Sendable {
    public let path: String
    public let folder: String
    public let text: String
    public let format: TextFormat
    public let savedAt: Double

    public init(path: String, folder: String, text: String, format: TextFormat, savedAt: Double = Date().timeIntervalSince1970) {
        self.path = path
        self.folder = folder
        self.text = text
        self.format = format
        self.savedAt = savedAt
    }

    public var savedAtDate: Date { Date(timeIntervalSince1970: savedAt) }
}

/// Stores recovery snapshots in Application Support, one per project file.
/// Filenames are a stable hash of the folder and path, so no user path ends up in a filename.
public enum RecoveryStore {
    /// Overridable for tests and for keeping preview builds separate.
    public static var directoryOverride: URL?

    public static func directory() -> URL {
        if let directoryOverride { return directoryOverride }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Proof", isDirectory: true)
            .appendingPathComponent("Recovery", isDirectory: true)
    }

    public static func snapshotURL(folder: String, path: String) -> URL {
        directory().appendingPathComponent("\(fingerprint(folder: folder, path: path)).json")
    }

    /// Writes atomically. Failures are silent: recovery must never interrupt editing.
    @discardableResult
    public static func write(path: String, folder: String, text: String, format: TextFormat) -> Bool {
        let snapshot = RecoverySnapshot(path: path, folder: folder, text: text, format: format)
        guard let data = try? JSONEncoder().encode(snapshot) else { return false }
        do {
            try FileManager.default.createDirectory(at: directory(), withIntermediateDirectories: true)
            try FileService.atomicWrite(path: snapshotURL(folder: folder, path: path).path, data: data)
            return true
        } catch {
            return false
        }
    }

    public static func load(folder: String, path: String) -> RecoverySnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL(folder: folder, path: path)),
              let snapshot = try? JSONDecoder().decode(RecoverySnapshot.self, from: data),
              snapshot.path == path, snapshot.folder == folder else { return nil }
        return snapshot
    }

    public static func remove(folder: String, path: String) {
        try? FileManager.default.removeItem(at: snapshotURL(folder: folder, path: path))
    }

    /// Removes every snapshot for a project (e.g. when its window is closed for good).
    public static func removeAll(folder: String) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory(), includingPropertiesForKeys: nil
        ) else { return }
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let snapshot = try? JSONDecoder().decode(RecoverySnapshot.self, from: data),
                  snapshot.folder == folder else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// FNV-1a, 64-bit: deterministic across launches (unlike `hashValue`).
    public static func fingerprint(folder: String, path: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array("\(folder)\u{0}\(path)".utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
