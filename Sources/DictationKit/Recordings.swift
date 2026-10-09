import AppKit
import Foundation

/// What the app heard for one kept recording (the JSON next to its WAV).
struct RecordingInfo: Codable, Equatable {
    var date: Date
    /// Speech model that heard it, e.g. "apple:en-US" or "openrouter:qwen/qwen3-asr-1.7b".
    var model: String
    /// The model's transcript — nobody has checked it, so correct it before scoring accuracy against it.
    var transcript: String
    var seconds: Double
    var error: String?
}

/// Keeps dictation audio for building benchmark sets (Settings → Keep recordings, off by default):
/// 16 kHz mono WAVs, each with a JSON of what the app heard (`bench/bench.py import-recordings`).
/// Stays on this Mac. Cancelled dictations are never kept.
final class RecordingArchive {
    static let shared = RecordingArchive()
    static let defaultDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DictationApp/Recordings", isDirectory: true)

    let directory: URL

    init(directory: URL = RecordingArchive.defaultDirectory) { self.directory = directory }

    private static let nameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f
    }()

    /// Moves a finished recording into the archive and writes its JSON. Returns the kept WAV,
    /// or nil (and deletes the recording) if it couldn't be stored.
    @discardableResult
    func keep(wav: URL, info: RecordingInfo) -> URL? {
        let fm = FileManager.default
        var name = Self.nameFormatter.string(from: info.date)
        var n = 2
        while fm.fileExists(atPath: directory.appendingPathComponent(name + ".wav").path) {
            name = Self.nameFormatter.string(from: info.date) + "-\(n)"
            n += 1
        }
        let dest = directory.appendingPathComponent(name + ".wav")
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try fm.moveItem(at: wav, to: dest)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(info).write(to: directory.appendingPathComponent(name + ".json"))
            return dest
        } catch {
            try? fm.removeItem(at: wav)
            return nil
        }
    }

    /// Kept recordings, oldest first.
    var recordings: [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func showInFinder() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }
}
