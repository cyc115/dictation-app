import Foundation

/// Commands that ran and failed, with everything they printed: `errors.log` in the commands folder,
/// beside the scripts, so a broken one can be figured out (or handed to an AI to fix). The pill and
/// History show only one line; this has the whole traceback. Newest last; trimmed to its last half
/// once it passes `maxBytes`.
struct CommandLog {
    static let name = "errors.log"
    static let maxBytes = 512 * 1024

    let file: URL

    init(folder: URL) { file = folder.appendingPathComponent(Self.name) }

    func add(_ run: CommandRun, details: String?) {
        let stamp = ISO8601DateFormatter.string(from: run.date, timeZone: .current, formatOptions: [.withInternetDateTime])
        var entry = "── \(stamp)  \(run.label)  ✗ \(run.result)\nsaid: \(run.said)\n"
        if let details, !details.isEmpty { entry += details.hasSuffix("\n") ? details : details + "\n" }
        append(entry + "\n")
    }

    /// `name`'s latest entries, oldest first (for "fix").
    func entries(for name: String, last count: Int = 5) -> [String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let entries = text.components(separatedBy: "\n── ").map { $0.hasPrefix("── ") ? String($0.dropFirst(3)) : $0 }
        let mine = entries.filter { entry in
            let header = entry.prefix { $0 != "\n" }
            return header.contains("  \(name)  ✗") || header.contains("  \(name) ")
        }
        return mine.suffix(count).map { "── " + $0.trimmingCharacters(in: .newlines) }
    }

    private func append(_ text: String) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let handle = try? FileHandle(forWritingTo: file) else {
            try? text.write(to: file, atomically: true, encoding: .utf8)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
        if let size = try? handle.offset(), size > Self.maxBytes { trim() }
    }

    /// Keeps the newer half, from the first entry in it.
    private func trim() {
        guard let data = try? Data(contentsOf: file) else { return }
        let half = String(decoding: data.suffix(Self.maxBytes / 2), as: UTF8.self)
        let kept = half.range(of: "\n── ").map { String(half[half.index(after: $0.lowerBound)...]) } ?? half
        try? kept.write(to: file, atomically: true, encoding: .utf8)
    }
}
