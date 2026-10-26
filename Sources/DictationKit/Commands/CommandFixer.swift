import Foundation

/// "fix the volume command, louder doesn't work": opens a terminal window (Ghostty, else Terminal)
/// running a Claude Code session that finds and fixes what's wrong with the command, told what you
/// said, the command's recent runs and its errors.log entries (FixCommand.txt), so you can watch it
/// work and step in. It runs in the app's source folder (a built-in is fixed there: tested, committed,
/// pushed, rebuilt) with the commands folder added (a script is fixed in place), and shows a
/// notification when it's done.
struct CommandFixer {
    static let instructions = Bundle.module.url(forResource: "FixCommand", withExtension: "txt")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    static let claudePaths = [NSHomeDirectory() + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    static let ghosttyPaths = ["/Applications/Ghostty.app", NSHomeDirectory() + "/Applications/Ghostty.app"]

    /// Where the session shows: Ghostty when it's installed, else the Terminal that comes with macOS.
    enum Terminal: String {
        case ghostty = "Ghostty"
        case terminal = "Terminal"

        /// How long opening the window may take: Terminal's first use asks you to allow DictationApp
        /// to control it, and the dialog waits for you.
        var timeout: TimeInterval { self == .terminal ? 120 : 30 }
    }

    /// The commands folder (a script's home, and errors.log) and the app's source (nil: built from
    /// somewhere else, so a built-in can't be fixed).
    let folder: URL
    let source: URL?

    /// The session's instructions for fixing `command`.
    func prompt(for command: Command, said: String, runs: [CommandRun], errors: [String]) -> String {
        let (place, finish): (String, String)
        if let script = command.script {
            place = "It's the user's own script, not in git: \(script.path). Before you change it, copy it as it is to \(script.path).orig (the app reads only .py files)."
            finish = """
                   Run it as the app does, with a choice that changes nothing if it has one: COMMAND_SAID='<what was said>' uv run --quiet --script "\(script.path)" <choice>. On failure it must print the underlying error in full to stderr and end with one short line for the user: the rules the app writes commands by are in Sources/DictationKit/Commands/WriteCommand.txt.
                """
        } else {
            place = "It's built into the app, in Swift: its definition is in Sources/DictationKit/Commands/Command.swift (Command.builtIn), and what it does in Sources/DictationKit/Commands/ (SystemCommands.swift, a file named after it, or CommandMode.swift). Follow the repo's AGENTS.md."
            finish = """
                   Add a test that fails without the fix. Then, as AGENTS.md says: ./test.sh; keep bench/built_in_commands.json word for word in step with Command.builtIn; after a change to a summary or choices, bench/suite.py commands run -m jev; commit, rebase onto origin/main, push; then ./build.sh --keep-running.
                """
        }
        let runLines = runs.map { run in
            "- \(run.date.formatted(.iso8601)): “\(run.said)” → \(run.label) → \(run.ok ? "ok" : "failed"): \(run.result)"
        }
        return Self.instructions
            .replacingOccurrences(of: "{said}", with: said)
            .replacingOccurrences(of: "{name}", with: command.name)
            .replacingOccurrences(of: "{summary}", with: command.summary)
            .replacingOccurrences(of: "{where}", with: place)
            .replacingOccurrences(of: "{finish}", with: finish)
            .replacingOccurrences(of: "{log}", with: CommandLog(folder: folder).file.path)
            .replacingOccurrences(of: "{errors}", with: errors.isEmpty ? "(none)" : errors.joined(separator: "\n"))
            .replacingOccurrences(of: "{runs}", with: runLines.isEmpty ? "(none)" : runLines.joined(separator: "\n"))
    }

    /// `claude`'s arguments: with the commands folder, named after the command, without asking (auto mode).
    func arguments(_ command: Command, prompt: String) -> [String] {
        // --add-dir takes several folders: an option after it ends the list, or it takes the prompt for one.
        ["--add-dir", folder.path, "-n", "fix-\(command.name)", "--permission-mode", "auto", prompt]
    }

    /// What opens a new `terminal` window running `claude` with `arguments` in `directory`: the
    /// executable and its arguments.
    static func launch(_ terminal: Terminal, claude: String, arguments: [String], in directory: URL) -> (String, [String]) {
        switch terminal {
        case .ghostty:
            // open hands the arguments over as they are (spaces, quotes and line breaks included), and
            // Ghostty runs what follows -e in a new window; the CLI itself can't open windows on macOS.
            // The window stays when claude exits, so you see why if it exits at once.
            return ("/usr/bin/open", ["-na", "Ghostty.app", "--args", "--working-directory=\(directory.path)", "--wait-after-command=true",
                                      "-e", claude] + arguments)
        case .terminal:
            // Terminal types one line into your login shell, whichever it is: it runs zsh with the
            // real line, single-quoted (which every shell reads alike), then that's AppleScript-quoted.
            let line = "cd \(shellQuoted(directory.path)) && exec " + ([claude] + arguments).map(shellQuoted).joined(separator: " ")
            return ("/usr/bin/osascript", ["-e", "tell application \"Terminal\"", "-e", "activate",
                                           "-e", "do script \(appleScriptQuoted("exec /bin/zsh -c " + shellQuoted(line)))", "-e", "end tell"])
        }
    }

    /// `text` as one zsh word: single-quoted, with a line break as $'\n' (and a carriage return as
    /// $'\r') so the line stays one line.
    static func shellQuoted(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            line.components(separatedBy: "\r")
                .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
                .joined(separator: "$'\\r'")
        }.joined(separator: "$'\\n'")
    }

    /// `text` as an AppleScript string literal.
    static func appleScriptQuoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Opens the terminal window with the session; says where. A built-in needs the source.
    func start(_ command: Command, prompt: String) async -> CommandResult {
        guard command.script != nil || source != nil else {
            return CommandResult(ok: false, message: "Fixing a built-in needs the app's source", details: "Info.plist has no DictationSource: build with build.sh")
        }
        guard let claude = Self.claudePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return CommandResult(ok: false, message: "Claude Code isn't installed", details: "no claude at \(Self.claudePaths.joined(separator: ", "))")
        }
        let terminal: Terminal = Self.ghosttyPaths.contains(where: { FileManager.default.fileExists(atPath: $0) }) ? .ghostty : .terminal
        let (executable, arguments) = Self.launch(terminal, claude: claude, arguments: arguments(command, prompt: prompt), in: source ?? folder)
        let opened = await Task.detached {
            Subprocess.run(executable, arguments, timeout: terminal.timeout)
        }.value
        switch opened {
        case .success(let done) where done.status == 0 && !done.timedOut:
            return CommandResult(ok: true, message: "Fixing \(command.name) in \(terminal.rawValue)")
        case .success(let done):
            let printed = [done.errors, done.output].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return CommandResult(ok: false, message: "Couldn't open \(terminal.rawValue)",
                                 details: (done.timedOut ? "\(executable) took over \(Int(terminal.timeout)) s\n" : "\(executable) exited \(done.status)\n") + printed)
        case .failure(let error):
            return CommandResult(ok: false, message: "Couldn't open \(terminal.rawValue)", details: "\(error)")
        }
    }
}
