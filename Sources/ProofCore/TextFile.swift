import Foundation

/// How a text file is stored on disk. Reading records the original byte encoding and
/// line-ending style so a save can put the file back the way it was found instead of
/// silently rewriting it as UTF-8/LF.
public struct TextFormat: Equatable, Sendable, Codable {
    public enum Encoding: String, Equatable, Sendable, Codable {
        case utf8
        case utf8WithBOM
        case utf16LittleEndian
        case utf16BigEndian
        case windows1252
        case isoLatin1

        /// Human-readable name for the status bar.
        public var displayName: String {
            switch self {
            case .utf8, .utf8WithBOM: return "UTF-8"
            case .utf16LittleEndian, .utf16BigEndian: return "UTF-16"
            case .windows1252: return "Windows-1252"
            case .isoLatin1: return "ISO Latin-1"
            }
        }

        var stringEncoding: String.Encoding {
            switch self {
            case .utf8: return .utf8
            case .utf8WithBOM: return .utf8
            case .utf16LittleEndian: return .utf16LittleEndian
            case .utf16BigEndian: return .utf16BigEndian
            case .windows1252: return .windowsCP1252
            case .isoLatin1: return .isoLatin1
            }
        }
    }

    public enum LineEnding: String, Equatable, Sendable, Codable {
        case lf
        case crlf
        case cr

        /// Sequence written for each `\n` in the buffer.
        public var sequence: String {
            switch self {
            case .lf: return "\n"
            case .crlf: return "\r\n"
            case .cr: return "\r"
            }
        }

        public var displayName: String {
            switch self {
            case .lf: return "LF"
            case .crlf: return "CRLF"
            case .cr: return "CR"
            }
        }
    }

    public var encoding: Encoding
    public var lineEnding: LineEnding

    public init(encoding: Encoding = .utf8, lineEnding: LineEnding = .lf) {
        self.encoding = encoding
        self.lineEnding = lineEnding
    }

    public static let `default` = TextFormat()

    /// Serializes the buffer (which uses `\n` internally) back to the file's format.
    /// Returns nil when the text cannot be represented in the original encoding, so
    /// saving never silently replaces characters with `?`.
    public func data(for text: String) -> Data? {
        // Newline translation works on the decoded string so multi-byte encodings stay valid.
        let converted = lineEnding == .lf
            ? text
            : text.replacingOccurrences(of: "\n", with: lineEnding.sequence)
        switch encoding {
        case .utf8WithBOM:
            return Data([0xEF, 0xBB, 0xBF]) + Data(converted.utf8)
        case .utf16LittleEndian:
            guard let body = converted.data(using: .utf16LittleEndian, allowLossyConversion: false) else { return nil }
            return Data([0xFF, 0xFE]) + body
        case .utf16BigEndian:
            guard let body = converted.data(using: .utf16BigEndian, allowLossyConversion: false) else { return nil }
            return Data([0xFE, 0xFF]) + body
        case .utf8, .windows1252, .isoLatin1:
            return converted.data(using: encoding.stringEncoding, allowLossyConversion: false)
        }
    }
}

public enum TextFileError: LocalizedError, Equatable {
    case unreadable(path: String, reason: String)
    case binary(path: String)
    case undecodable(path: String)
    case unwritable(path: String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let path, let reason):
            return "Could not read \((path as NSString).lastPathComponent): \(reason)"
        case .binary(let path):
            return "\((path as NSString).lastPathComponent) looks like a binary file, not text."
        case .undecodable(let path):
            return "\((path as NSString).lastPathComponent) uses an encoding Proof can't read."
        case .unwritable(let path):
            return "Could not encode \((path as NSString).lastPathComponent) in its original format."
        }
    }
}

/// Reads and writes text while preserving the file's encoding and line endings.
public enum TextFile {
    /// Result of a read: normalized to `\n`, without a byte-order mark.
    public struct Contents: Equatable, Sendable {
        public var text: String
        public var format: TextFormat

        public init(text: String, format: TextFormat) {
            self.text = text
            self.format = format
        }
    }

    public static func read(path: String) throws -> Contents {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw TextFileError.unreadable(path: path, reason: error.localizedDescription)
        }
        return try decode(data, path: path)
    }

    public static func decode(_ data: Data, path: String = "file") throws -> Contents {
        if data.isEmpty {
            return Contents(text: "", format: .default)
        }
        // A NUL byte in the first few KB is the usual binary heuristic. UTF-16 also has NULs,
        // so only apply it after the BOM checks below.
        let bytes = [UInt8](data.prefix(4))
        var encoding: TextFormat.Encoding
        var body = data

        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            encoding = .utf8WithBOM
            body = data.dropFirst(3)
        } else if bytes.starts(with: [0xFF, 0xFE]) {
            encoding = .utf16LittleEndian
            body = data.dropFirst(2)
        } else if bytes.starts(with: [0xFE, 0xFF]) {
            encoding = .utf16BigEndian
            body = data.dropFirst(2)
        } else {
            if data.prefix(8_192).contains(0) {
                throw TextFileError.binary(path: path)
            }
            encoding = .utf8
        }

        var decoded = String(data: body, encoding: encoding.stringEncoding)
        if decoded == nil {
            // Legacy 8-bit files are common in older LaTeX projects. Windows-1252 is a
            // superset of Latin-1 that round-trips every byte except a handful of
            // undefined control codes, so it is the better first fallback.
            if let legacy = String(data: body, encoding: .windowsCP1252) {
                decoded = legacy
                encoding = .windows1252
            } else if let latin = String(data: body, encoding: .isoLatin1) {
                decoded = latin
                encoding = .isoLatin1
            } else {
                throw TextFileError.undecodable(path: path)
            }
        }
        guard let text = decoded else { throw TextFileError.undecodable(path: path) }
        let lineEnding = detectLineEnding(in: body, encoding: encoding)
        return Contents(text: normalize(text), format: TextFormat(encoding: encoding, lineEnding: lineEnding))
    }

    public static func encode(text: String, format: TextFormat, path: String = "file") throws -> Data {
        guard let data = format.data(for: text) else { throw TextFileError.unwritable(path: path) }
        return data
    }

    /// `\r\n` and `\r` become `\n`; everything else is left alone.
    public static func normalize(_ text: String) -> String {
        // Character-based `contains("\r")` is false for CRLF, because Swift treats
        // "\r\n" as one grapheme cluster. Test the scalars instead.
        guard text.unicodeScalars.contains(where: { $0.value == 13 }) else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// Dominant line ending. Mixed files keep the most frequent style; ties prefer LF.
    static func detectLineEnding(in data: Data, encoding: TextFormat.Encoding) -> TextFormat.LineEnding {
        var crlf = 0, lf = 0, cr = 0
        let bytes = [UInt8](data.prefix(1 << 20))
        var i = 0
        // Only ASCII-compatible encodings put 0x0A/0x0D in the low byte like this.
        let asciiCompatible = encoding == .utf8 || encoding == .utf8WithBOM
            || encoding == .windows1252 || encoding == .isoLatin1
        if asciiCompatible {
            while i < bytes.count {
                let b = bytes[i]
                if b == 0x0D {
                    if i + 1 < bytes.count, bytes[i + 1] == 0x0A { crlf += 1; i += 1 } else { cr += 1 }
                } else if b == 0x0A {
                    lf += 1
                }
                i += 1
            }
        } else {
            // UTF-16: scan code units in the declared byte order.
            let little = encoding == .utf16LittleEndian || (encoding == .utf16BigEndian ? false : true)
            i = 0
            while i + 1 < bytes.count {
                let unit = little ? UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8 : UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1])
                if unit == 0x0D {
                    if i + 3 < bytes.count {
                        let next = little ? UInt16(bytes[i + 2]) | UInt16(bytes[i + 3]) << 8 : UInt16(bytes[i + 2]) << 8 | UInt16(bytes[i + 3])
                        if next == 0x0A { crlf += 1; i += 4; continue }
                    }
                    cr += 1
                } else if unit == 0x0A {
                    lf += 1
                }
                i += 2
            }
        }
        if crlf > lf && crlf >= cr { return .crlf }
        if cr > lf && cr > crlf { return .cr }
        return .lf
    }
}
