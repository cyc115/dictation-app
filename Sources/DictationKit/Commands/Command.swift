import Foundation

/// Something you can say in command mode: a Python script in the commands folder, or one built in
/// (`Command.builtIn`).
///
/// A script says what it does in its docstring, and what it can be told under "Choices:", one
/// `value: meaning` per line. It's run as `uv run --script <file> <value>`.
///
///     """Set the screen brightness.
///
///     Choices:
///         +10: a bit brighter
///         50: half
///     """
struct Command: Equatable {
    struct Choice: Equatable {
        let value: String
        let meaning: String
    }

    let name: String
    /// What it does: the docstring's first line.
    let summary: String
    /// What it can be told; empty: nothing.
    let choices: [Choice]
    /// The script; nil for a built-in command.
    let script: URL?

    static let pressReturn = Command(name: "return", summary: "Press Return (send) in the front app", choices: [], script: nil)
    static let again = Command(name: "repeat", summary: "Run the last command again", choices: [], script: nil)
    static let builtIn = [pressReturn, again]

    /// The command a script defines, from its text (never run to find out).
    static func parse(_ text: String, script: URL) -> Command? {
        guard let docstring = docstring(text) else { return nil }
        let lines = docstring.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let summary = lines.first(where: { !$0.isEmpty }) else { return nil }
        var choices: [Choice] = []
        if let start = lines.firstIndex(where: { $0.lowercased() == "choices:" }) {
            for line in lines[(start + 1)...] {
                if line.isEmpty { break }
                guard let colon = line.firstIndex(of: ":") else { continue }
                let value = line[..<colon].trimmingCharacters(in: .whitespaces)
                let meaning = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if !value.isEmpty, !value.contains(" ") { choices.append(Choice(value: value, meaning: meaning)) }
            }
        }
        return Command(name: script.deletingPathExtension().lastPathComponent, summary: summary,
                       choices: choices, script: script)
    }

    /// The first triple-quoted string.
    private static func docstring(_ text: String) -> String? {
        for quote in ["\"\"\"", "'''"] {
            guard let open = text.range(of: quote),
                  let close = text.range(of: quote, range: open.upperBound..<text.endIndex) else { continue }
            return String(text[open.upperBound..<close.lowerBound])
        }
        return nil
    }

    /// The built-in commands, then the folder's scripts by name (one named like a built-in is skipped).
    static func all(in folder: URL) -> [Command] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let scripts = files.filter { $0.pathExtension == "py" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in (try? String(contentsOf: url, encoding: .utf8)).flatMap { parse($0, script: url) } }
        return builtIn + scripts.filter { script in !builtIn.contains { $0.name == script.name } }
    }
}
