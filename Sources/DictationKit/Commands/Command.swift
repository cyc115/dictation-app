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
struct Command: Hashable {
    struct Choice: Hashable {
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
    /// Writes a new script from what you describe (`CommandWriter`).
    static let create = Command(name: "create", summary: "Create a new command: the user asks for a new command (“create command”, “新建命令”, “写一个命令”) and describes what it should do",
                                choices: [], script: nil)
    /// Opens an app; its choices are the installed apps (`installedApps`), filled in by `all(in:apps:)`.
    static let openApp = Command(name: "open", summary: "Open an app", choices: [], script: nil)
    static let builtIn = [pressReturn, again, create, openApp]

    /// Where the apps you installed are, in order: an app's name means the first one found. Not the
    /// ones macOS comes with (/System/Applications, Utilities: Disk Utility, Font Book, …).
    static let appFolders = ["/Applications", NSHomeDirectory() + "/Applications"].map { URL(fileURLWithPath: $0) }
    /// Jev takes up to 255 choices a question: the apps and `noApp`.
    static let maxApps = 254
    /// Open's last choice, so something that isn't one of the apps ("打开下载的文件夹") opens nothing
    /// rather than the closest app.
    static let noApp = Choice(value: "none", meaning: "Not one of these apps")

    /// The installed apps by name ("Google Chrome"), read afresh each time.
    static func installedApps(in folders: [URL] = appFolders) -> [String: URL] {
        var apps: [String: URL] = [:]
        for folder in folders {
            for url in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            where url.pathExtension == "app" {
                let name = url.deletingPathExtension().lastPathComponent
                if apps[name] == nil { apps[name] = url }
            }
        }
        return apps
    }

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

    /// The built-in commands (open's choices: `apps`), then the folder's scripts by name (one named
    /// like a built-in is skipped).
    static func all(in folder: URL, apps: [String] = installedApps().keys.sorted()) -> [Command] {
        let open = Command(name: openApp.name, summary: openApp.summary,
                           choices: apps.prefix(maxApps).map { Choice(value: $0, meaning: $0) } + [noApp], script: nil)
        return builtIn.map { $0.name == openApp.name ? open : $0 }
            + scripts(in: folder).filter { script in !builtIn.contains { $0.name == script.name } }
    }

    /// The scripts turned off (Settings › Commands, or by failing): in the folder's Disabled folder,
    /// where command mode doesn't look.
    static func disabled(in folder: URL) -> [Command] { scripts(in: disabledFolder(folder)) }

    static func disabledFolder(_ folder: URL) -> URL { folder.appendingPathComponent("Disabled") }

    private static func scripts(in folder: URL) -> [Command] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "py" }
            .sorted { $0.deletingPathExtension().lastPathComponent < $1.deletingPathExtension().lastPathComponent }
            .compactMap { url in (try? String(contentsOf: url, encoding: .utf8)).flatMap { parse($0, script: url) } }
    }

    /// Turns a script on or off by moving it out of or into the Disabled folder; where it is now.
    @discardableResult
    static func setEnabled(_ enabled: Bool, script: URL, folder: URL) throws -> URL {
        let destination = enabled ? folder : disabledFolder(folder)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let moved = freeURL(for: script.deletingPathExtension().lastPathComponent, in: destination)
        try FileManager.default.moveItem(at: script, to: moved)
        return moved
    }

    /// `<name>.py` in `folder`, or `<name>-2.py`, … when it's taken there or a built-in has the name.
    static func freeURL(for name: String, in folder: URL) -> URL {
        var candidate = name, number = 1
        while builtIn.contains(where: { $0.name == candidate })
                || FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate + ".py").path) {
            number += 1
            candidate = "\(name)-\(number)"
        }
        return folder.appendingPathComponent(candidate + ".py")
    }
}
