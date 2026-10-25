import AppKit

/// How a command went: what it says ("Brightness 70%"), or why it failed.
struct CommandResult: Equatable {
    var ok: Bool
    var message: String
    /// When it failed, everything there is to know about why (a script's exit status and all it
    /// printed): for `CommandLog`, not the pill.
    var details: String?

    /// From a finished script: on success its first line of output, else its last line of errors.
    static func from(_ finished: CommandMode.Finished, name: String) -> CommandResult {
        func line(_ text: String, last: Bool) -> String? {
            let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return last ? lines.last : lines.first
        }
        if finished.status == 0, !finished.timedOut { return CommandResult(ok: true, message: line(finished.output, last: false) ?? "Ran \(name)") }
        let ended = finished.timedOut ? "stopped after \(Int(CommandMode.timeout)) s" : "exit status \(finished.status)"
        let printed = [("stderr", finished.errors), ("stdout", finished.output)]
            .filter { !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { "\($0.0):\n\($0.1.trimmingCharacters(in: .newlines))" }
        let details = ([ended] + printed).joined(separator: "\n")
        if finished.timedOut { return CommandResult(ok: false, message: "Took longer than \(Int(CommandMode.timeout)) s", details: details) }
        return CommandResult(ok: false, message: line(finished.errors, last: true) ?? line(finished.output, last: true)
                             ?? "Exited with \(finished.status)", details: details)
    }
}

/// Command mode: what you said → a command (`CommandDecider`) → run it → History's Commands list;
/// one that fails goes in the commands folder's `errors.log` too (`CommandLog`).
final class CommandMode {
    /// Beside History, so you (or an AI you ask) can add and change commands there; read afresh for
    /// every command.
    static let defaultFolder = AppPaths.directory("Commands")
    static let timeout: TimeInterval = 10

    let folder: URL
    let history: HistoryStore
    let log: CommandLog
    /// (model, API key) → the decider; tests fake it.
    var makeDecider: (String, String) -> CommandDecider = { makeCommandDecider(model: $0, apiKey: $1) }
    /// Runs a script with a choice and what you said (tests fake it).
    var runScript: (URL, String?, String) async -> CommandResult = { await CommandMode.run(script: $0, choice: $1, said: $2) }
    /// (what you said, the commands, API key) → the new script, or the command that already does it.
    var writeCommand: (String, [Command], String) async throws -> CommandWriter.Reply = {
        try await CommandWriter(apiKey: $2).write($0, among: $1)
    }
    var pressReturn: () -> Void = { TextInjector().pressReturn() }
    /// The installed apps by name, and opening one (tests fake both).
    var apps: () -> [String: URL] = { Command.installedApps() }
    var openApp: (URL) -> Void = { NSWorkspace.shared.openApplication(at: $0, configuration: NSWorkspace.OpenConfiguration()) }
    /// The apps open now, by name: switch-app's choices (tests fake it).
    var running: () -> [String] = { SwitchApp.running().keys.sorted() }
    /// The built-ins that work the Mac (brightness, volume, …) by name; tests fake them.
    var system: [String: SystemCommands.Action] = SystemCommands.live
    /// "fix": starts the background session that fixes a command (tests fake it).
    var startFix: (CommandFixer, Command, String) async -> CommandResult = { await $0.start($1, prompt: $2) }
    /// The app's source folder, where "fix" works on a built-in.
    var source: URL? = AppVersion.current.source

    init(folder: URL = CommandMode.defaultFolder, history: HistoryStore) {
        self.folder = folder
        self.history = history
        log = CommandLog(folder: folder)
    }

    var commands: [Command] { Command.all(in: folder, apps: apps().keys.sorted(), running: running()) }

    /// What a command is likely to say, for the speech model: the built-ins' words, your commands'
    /// names ("tail-error-log" as "tail error log") and the apps open now. Not the installed apps:
    /// hundreds of names would drown out the rest.
    func speechContext() -> SpeechContext {
        let own = Command.all(in: folder, apps: [], running: []).filter { $0.script != nil }
            .map { $0.name.replacingOccurrences(of: "-", with: " ") }
        var seen = Set<String>()
        return SpeechContext(words: (Command.builtInWords + own + running()).filter { seen.insert($0).inserted })
    }

    /// Decides what `said` asks for and runs it; the run is saved to History.
    @MainActor
    func handle(_ said: String, apiKey: String, model: String = "jev") async -> CommandRun {
        let commands = self.commands
        var run = CommandRun(said: said)
        do {
            let decision = try await makeDecider(model, apiKey).decide(said, among: commands)
            if let name = decision.command, decision.confidence >= CommandDecision.minConfidence {
                run.command = name
                run.choice = decision.choice
                let result = await perform(name, choice: decision.choice, said: said, apiKey: apiKey, among: commands)
                run.ok = result.ok
                run.result = result.message
                if !result.ok { log.add(run, details: result.details) }
            } else {
                run.result = "Command not found"
            }
        } catch {
            run.result = error.localizedDescription
        }
        history.addCommand(run)
        return run
    }

    /// Runs a command again, as it was (History's ↻; not a create); saved as a new run.
    @MainActor
    func again(_ previous: CommandRun) async -> CommandRun {
        var run = CommandRun(said: previous.said, command: previous.command, choice: previous.choice)
        if let name = previous.command {
            let result = await perform(name, choice: previous.choice, said: previous.said, apiKey: nil, among: commands)
            run.ok = result.ok
            run.result = result.message
            if !result.ok { log.add(run, details: result.details) }
        }
        history.addCommand(run)
        return run
    }

    /// `apiKey`: nil when it's run again from History, which doesn't create.
    @MainActor
    private func perform(_ name: String, choice: String?, said: String, apiKey: String?, among commands: [Command]) async -> CommandResult {
        switch name {
        case Command.pressReturn.name:
            pressReturn()
            return CommandResult(ok: true, message: "Pressed Return")
        case Command.again.name:
            guard let last = history.commands.first(where: { $0.ok && $0.canRunAgain && $0.command != Command.again.name }),
                  let lastName = last.command else {
                return CommandResult(ok: false, message: "Nothing to repeat")
            }
            return await perform(lastName, choice: last.choice, said: last.said, apiKey: nil, among: commands)
        case Command.openApp.name:
            guard let choice, choice != Command.noApp.value, let app = apps()[choice] else {
                return CommandResult(ok: false, message: "No app by that name")
            }
            openApp(app)
            return CommandResult(ok: true, message: "Opened \(choice)")
        case Command.create.name:
            guard let apiKey else { return CommandResult(ok: false, message: "Say it again to create another") }
            return await create(said, apiKey: apiKey, among: commands)
        case Command.fix.name:
            return await fix(choice, said: said, among: commands)
        case _ where system[name] != nil:
            return await system[name]!(choice, said)
        default:
            guard let script = commands.first(where: { $0.name == name })?.script else {
                return CommandResult(ok: false, message: "No \(name) script")
            }
            return await runScript(script, choice, said)
        }
    }

    /// Writes the command `said` describes into the folder, ready next time (checked that the app can
    /// read it and Python can parse it, not run), or says which command already does it.
    @MainActor
    private func create(_ said: String, apiKey: String, among commands: [Command]) async -> CommandResult {
        func failed(_ why: String) -> CommandResult { CommandResult(ok: false, message: "Couldn't write it: " + why) }
        do {
            var reply = try await writeCommand(said, commands, apiKey)
            // A slip ("EXISTING: none", a few in a hundred): asked once more, it writes the script.
            if case .existing(let name) = reply, !commands.contains(where: { $0.name == name }) {
                reply = try await writeCommand(said, commands, apiKey)
            }
            switch reply {
            case .existing(let name):
                guard commands.contains(where: { $0.name == name }) else { return failed("it named \(name), which isn't a command") }
                return CommandResult(ok: true, message: "\(name) already does that")
            case .new(let name, let script):
                guard CommandWriter.validName(name) else { return failed("“\(name)” can't be a command's name") }
                let url = Command.freeURL(for: name, in: folder)
                guard Command.parse(script, script: url) != nil else { return failed("its description is missing") }
                if let problem = await Self.syntaxProblem(script) { return failed(problem) }
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try script.write(to: url, atomically: true, encoding: .utf8)
                return CommandResult(ok: true, message: "Created \(url.deletingPathExtension().lastPathComponent)")
            }
        } catch {
            return CommandResult(ok: false, message: error.localizedDescription)
        }
    }

    /// Starts a background Claude Code session that fixes the command named (else the last one that
    /// failed), told what you said, its recent runs and its errors.log entries (`CommandFixer`).
    @MainActor
    private func fix(_ choice: String?, said: String, among commands: [Command]) async -> CommandResult {
        let named = choice.flatMap { $0 == Command.noCommand.value ? nil : $0 }
        let lastFailed = history.commands.first { !$0.ok && $0.command != nil && $0.command != Command.fix.name }?.command
        guard let name = named ?? lastFailed, let command = commands.first(where: { $0.name == name }) else {
            return CommandResult(ok: false, message: "Which command? Say “fix” and its name")
        }
        let fixer = CommandFixer(folder: folder, source: source)
        let runs = Array(history.commands.filter { $0.command == name }.prefix(10))
        return await startFix(fixer, command, fixer.prompt(for: command, said: said, runs: runs, errors: log.entries(for: name)))
    }

    /// Why Python can't parse `script`, or nil if it can (or uv isn't there to ask).
    static func syntaxProblem(_ script: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let check = ["run", "--quiet", "--no-project", "python", "-I", "-c", "import ast, sys; ast.parse(sys.argv[1])", script]
                guard case .success(let finished) = uv(check), finished.status != 0 else { return continuation.resume(returning: nil) }
                let lines = finished.errors.components(separatedBy: .newlines).filter { !$0.isEmpty }
                continuation.resume(returning: lines.last ?? "Python can't read it")
            }
        }
    }

    /// `uv run --script <script> <choice>`, with no shell (what you said can't become another command)
    /// and a time limit. What you said is in $COMMAND_SAID, for free text a choice can't hold (a
    /// website that isn't listed, something to search for).
    static func run(script: URL, choice: String?, said: String = "") async -> CommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runNow(script: script, choice: choice, said: said))
            }
        }
    }

    static let uvPaths = ["/opt/homebrew/bin/uv", NSHomeDirectory() + "/.local/bin/uv", "/usr/local/bin/uv"]

    static let saidVariable = "COMMAND_SAID"

    private static func runNow(script: URL, choice: String?, said: String) -> CommandResult {
        let name = script.deletingPathExtension().lastPathComponent
        switch uv(["run", "--quiet", "--script", script.path] + (choice.map { [$0] } ?? []), environment: [saidVariable: said]) {
        case .success(let finished): return CommandResult.from(finished, name: name)
        case .failure(.notInstalled): return CommandResult(ok: false, message: "uv isn't installed")
        case .failure(.couldNotStart(let why)): return CommandResult(ok: false, message: "Couldn't start \(name): \(why)")
        }
    }

    /// How a uv run ended.
    struct Finished {
        var status: Int32
        var output: String
        var errors: String
        var timedOut: Bool
    }

    enum StartError: Error {
        case notInstalled
        case couldNotStart(String)
    }

    /// Runs uv with `arguments` (and `environment` added), with no shell and the time limit.
    static func uv(_ arguments: [String], environment extra: [String: String] = [:]) -> Result<Finished, StartError> {
        guard let uv = uvPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return .failure(.notInstalled)
        }
        return process(uv, arguments, environment: extra)
    }

    /// Runs `executable` with `arguments` (and `environment` added, in `directory`), with no shell and
    /// a time limit.
    static func process(_ executable: String, _ arguments: [String], environment extra: [String: String] = [:],
                        directory: URL? = nil, timeout: TimeInterval = CommandMode.timeout) -> Result<Finished, StartError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.currentDirectoryURL = directory
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment.merge(extra) { _, new in new }
        process.environment = environment
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch {
            return .failure(.couldNotStart(error.localizedDescription))
        }
        let limit = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: limit)
        // Errors are read alongside, so a script that writes a lot of them can't block on a full pipe.
        var errorData = Data()
        let reading = DispatchGroup()
        reading.enter()
        DispatchQueue.global().async { errorData = errors.fileHandleForReading.readDataToEndOfFile(); reading.leave() }
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        reading.wait()
        process.waitUntilExit()
        limit.cancel()
        return .success(Finished(status: process.terminationStatus, output: String(decoding: outputData, as: UTF8.self),
                                 errors: String(decoding: errorData, as: UTF8.self), timedOut: process.terminationReason == .uncaughtSignal))
    }
}
