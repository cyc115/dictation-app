import Foundation

/// "fix the volume command, louder doesn't work": starts a background Claude Code session
/// (`claude --bg`) that finds and fixes what's wrong with the command, told what you said, the
/// command's recent runs and its errors.log entries (FixCommand.txt). It runs in the app's source
/// folder (a built-in is fixed there: tested, committed, pushed, rebuilt) with the commands folder
/// added (a script is fixed in place), and shows a notification when it's done. `claude attach <id>`
/// to watch it.
struct CommandFixer {
    static let instructions = Bundle.module.url(forResource: "FixCommand", withExtension: "txt")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    static let claudePaths = [NSHomeDirectory() + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]

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

    /// `claude`'s arguments: in the background, with the commands folder, without asking (auto mode).
    func arguments(_ command: Command, prompt: String) -> [String] {
        // --add-dir takes several folders: an option after it ends the list, or it takes the prompt for one.
        ["--bg", "--add-dir", folder.path, "-n", "fix-\(command.name)", "--permission-mode", "auto", prompt]
    }

    /// Starts the session; says how to watch it. A built-in needs the source.
    func start(_ command: Command, prompt: String) async -> CommandResult {
        guard command.script != nil || source != nil else {
            return CommandResult(ok: false, message: "Fixing a built-in needs the app's source", details: "Info.plist has no DictationSource: build with build.sh")
        }
        guard let claude = Self.claudePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return CommandResult(ok: false, message: "Claude Code isn't installed", details: "no claude at \(Self.claudePaths.joined(separator: ", "))")
        }
        let arguments = arguments(command, prompt: prompt)
        let started = await Task.detached { [source, folder] in
            CommandMode.process(claude, arguments, directory: source ?? folder, timeout: 30)
        }.value
        switch started {
        case .success(let done) where done.status == 0 && !done.timedOut:
            let id = Self.sessionID(done.output)
            return CommandResult(ok: true, message: "Fixing \(command.name) in the background" + (id.map { " · claude attach \($0)" } ?? ""))
        case .success(let done):
            let printed = [done.errors, done.output].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return CommandResult(ok: false, message: "Couldn't start the fix",
                                 details: (done.timedOut ? "claude --bg took over 30 s\n" : "claude exited \(done.status)\n") + printed)
        case .failure(let error):
            return CommandResult(ok: false, message: "Couldn't start the fix", details: "\(error)")
        }
    }

    /// The id in "backgrounded · 87c66017 · fix-volume".
    static func sessionID(_ output: String) -> String? {
        output.components(separatedBy: .newlines).lazy
            .compactMap { line -> String? in
                let parts = line.components(separatedBy: " · ")
                return parts.count >= 2 && parts[0].hasSuffix("backgrounded") ? parts[1].trimmingCharacters(in: .whitespaces) : nil
            }
            .first
    }
}
