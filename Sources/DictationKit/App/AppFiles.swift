import Foundation

/// Where the app keeps its files: `~/Library/Application Support/DictationApp` (History, recordings,
/// commands, setups, secrets). Nothing in it leaves the Mac. Tests pass their own URLs instead.
enum AppPaths {
    static let folder: URL = {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DictationApp", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    static func file(_ name: String) -> URL { folder.appendingPathComponent(name) }
    static func directory(_ name: String) -> URL { folder.appendingPathComponent(name, isDirectory: true) }
}

/// A Codable value in a JSON file, dates as ISO 8601, written atomically (a crash mid-save leaves the
/// old file, never half a new one).
enum JSONFile {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// For files people read (recordings' notes, learned prompts).
    static let prettyEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    /// The value in `url`; nil when there's no file or it doesn't decode.
    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    static func write<T: Encodable>(_ value: T, to url: URL, pretty: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (pretty ? prettyEncoder : encoder).encode(value).write(to: url, options: .atomic)
    }

    /// `write`, for saves whose failure there's nothing to do about (the next save tries again).
    static func save<T: Encodable>(_ value: T, to url: URL, pretty: Bool = false) {
        try? write(value, to: url, pretty: pretty)
    }
}
