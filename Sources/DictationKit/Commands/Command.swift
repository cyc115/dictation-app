import Foundation

/// Something you can say in command mode: a Python script in the commands folder, or one built in
/// (`Command.builtIn`; the app does it itself, `SystemCommands`).
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
    /// Its summary is read by the writer too: a longer one ("Do the last thing again: …, whichever
    /// came later") had it answer "EXISTING: ask-muse" to unrelated requests 3 times in 5.
    static let again = Command(name: "repeat", summary: "Run the last command again, or type the last dictation again", choices: [], script: nil)
    /// Writes a new script from what you describe (`CommandWriter`).
    static let create = Command(name: "create", summary: "Create a new command: the user asks for a new command (“create command”, “新建命令”, “写一个命令”) and describes what it should do",
                                choices: [], script: nil)
    /// Opens an app; its choices are the installed apps (`installedApps`), filled in by `all(in:apps:running:)`.
    static let openApp = Command(name: "open", summary: "Open an app installed on this Mac (not a website)", choices: [], script: nil)
    static let brightness = Command(name: "brightness", summary: "Set the screen brightness",
                                    choices: levels(more: "brighter", less: "dimmer", none: "lowest"), script: nil)
    static let volume = Command(name: "volume", summary: "Set the sound volume, or mute it",
                                choices: levels(more: "louder", less: "quieter", none: "silent")
                                    + [Choice(value: "mute", meaning: "mute"), Choice(value: "unmute", meaning: "unmute")],
                                script: nil)
    static let lockScreen = Command(name: "lock-screen", summary: "Lock the screen", choices: [], script: nil)
    static let media = Command(name: "media-control", summary: "Control music or video playback: play or pause, next or previous track",
                               choices: [Choice(value: "play-pause", meaning: "play or pause (resume, stop)"),
                                         Choice(value: "next", meaning: "the next track (skip)"),
                                         Choice(value: "previous", meaning: "the previous track (back)")],
                               script: nil)
    static let openWebsite = Command(name: "open-website", summary: "Open a website in the browser: YouTube, Gmail, Hacker News, any site the user names",
                                     choices: Websites.sites.map { Choice(value: $0.value, meaning: $0.meaning) }
                                         + [Choice(value: Websites.other, meaning: "any other website (named in what was said)")],
                                     script: nil)
    /// Brings an app that's already open to the front; its choices are the running apps
    /// (`SwitchApp.running`), filled in by `all(in:apps:running:)`.
    static let switchApp = Command(name: "switch-app", summary: "Switch to another app that's already open, by name",
                                   choices: [], script: nil)
    /// Starts a background Claude Code session that fixes a command (`CommandFixer`); its choices are
    /// the other commands, filled in by `all(in:apps:running:)`.
    static let fix = Command(name: "fix", summary: "Fix a command that isn't working: the user names the command (“fix the volume command”, “修一下 open-website”) and says what goes wrong",
                             choices: [], script: nil)
    /// Sends what was said to Muse in a new side chat (`AskMuse`).
    static let askMuse = Command(name: "ask-muse", summary: "Ask Muse, the AI assistant app, to do something: the user says “ask Muse to …”, “tell Muse …”, “让 Muse …” and what it should do",
                                 choices: [], script: nil)
    static let builtIn = [pressReturn, again, create, fix, openApp, brightness, volume, lockScreen, media, openWebsite, switchApp, askMuse]
    /// Words the built-ins are asked with, for the speech model (`CommandMode.speechContext`): the
    /// ones it got wrong ("Presenter", "Increase fitness", "focus on news") come first.
    static let builtInWords = ["press Enter", "send", "brightness", "increase brightness", "reduce brightness", "lower brightness",
                               "Muse", "ask Muse", "open", "switch to", "volume", "mute", "play music", "pause", "next track",
                               "lock the screen", "go to", "create a command", "fix", "repeat",
                               "回车", "发送", "亮度", "音量", "声音", "打开", "切换到"]

    /// Brightness's and volume's choices: change it by some ("+10": a bit brighter), or set it ("50": half).
    static func levels(more: String, less: String, none: String) -> [Choice] {
        [("+10", "a bit \(more)"), ("-10", "a bit \(less)"), ("+30", "a lot \(more)"), ("-30", "a lot \(less)"), ("0", none),
         ("25", "a quarter"), ("50", "half"), ("75", "three quarters"), ("100", "full, max")].map { Choice(value: $0.0, meaning: $0.1) }
    }

    /// Where the apps are, in order: an app's name means the first one found. Yours, then the ones
    /// macOS comes with (Music, Notes, Messages; not Utilities: Disk Utility, Terminal, …).
    static let appFolders = ["/Applications", NSHomeDirectory() + "/Applications", "/System/Applications"]
        .map { URL(fileURLWithPath: $0) }
    /// Jev takes up to 255 choices a question: the apps and `noApp`.
    static let maxApps = 254
    /// Open's and switch-app's last choice, so something that isn't one of the apps ("打开下载的文件夹")
    /// opens nothing rather than the closest app.
    static let noApp = Choice(value: "none", meaning: "Not one of these apps")
    /// Fix's last choice: no command named, so the last one that failed.
    static let noCommand = Choice(value: "none", meaning: "None named: the last command that failed")

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

    /// The built-in commands (open's choices: `apps`; switch-app's: `running`), then the folder's
    /// scripts by name (one named like a built-in is skipped).
    static func all(in folder: URL, apps: [String] = installedApps().keys.sorted(),
                    running: [String] = SwitchApp.running().keys.sorted()) -> [Command] {
        func named(_ apps: [String], _ command: Command) -> Command {
            Command(name: command.name, summary: command.summary,
                    choices: apps.prefix(maxApps).map { Choice(value: $0, meaning: $0) } + [noApp], script: nil)
        }
        let commands = builtIn.map { $0 == openApp ? named(apps, $0) : $0 == switchApp ? named(running, $0) : $0 }
            + scripts(in: folder).filter { script in !builtIn.contains { $0.name == script.name } }
        let fixable = commands.filter { $0 != fix }.map { Choice(value: $0.name, meaning: $0.summary) }
        return commands.map { $0 == fix ? Command(name: fix.name, summary: fix.summary, choices: fixable + [noCommand], script: nil) : $0 }
    }

    /// Open's and switch-app's choices are the apps on this Mac, not fixed ones.
    var choosesAnApp: Bool { name == Command.openApp.name || name == Command.switchApp.name }
    /// Choices filled in from this Mac (its apps, its commands), not written down: left out where the
    /// built-ins are described (the writer, the bench's copy).
    var choicesFromThisMac: Bool { choosesAnApp || name == Command.fix.name }

    /// The scripts turned off (the Commands tab): in the folder's Disabled folder,
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
