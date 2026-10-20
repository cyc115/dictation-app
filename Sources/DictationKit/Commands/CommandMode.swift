import AppKit

/// How a command went: its script's first line of output ("Brightness 70%"), or why it failed.
struct CommandResult: Equatable {
    var ok: Bool
    var message: String
    /// The script ran and failed (a non-zero exit, or too slow), so it's turned off; not when uv is
    /// missing or it couldn't start.
    var scriptFailed = false

    /// From a finished script: on success its first line of output, else its last line of errors.
    static func from(_ finished: CommandMode.Finished, name: String) -> CommandResult {
        func line(_ text: String, last: Bool) -> String? {
            let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return last ? lines.last : lines.first
        }
        if finished.timedOut { return CommandResult(ok: false, message: "Took longer than \(Int(CommandMode.timeout)) s", scriptFailed: true) }
        if finished.status == 0 { return CommandResult(ok: true, message: line(finished.output, last: false) ?? "Ran \(name)") }
        return CommandResult(ok: false, message: line(finished.errors, last: true) ?? line(finished.output, last: true)
                             ?? "Exited with \(finished.status)", scriptFailed: true)
    }
}

/// Command mode: what you said → a command (`CommandDecider`) → run it → History's Commands list.
final class CommandMode {
    /// Beside History, so you (or an AI you ask) can add and change commands there; read afresh for
    /// every command.
    static let defaultFolder = AppPaths.directory("Commands")
    /// The commands the app comes with (brightness, volume).
    static let examples = Bundle.module.url(forResource: "ExampleCommands", withExtension: nil)
    static let timeout: TimeInterval = 10

    let folder: URL
    let history: HistoryStore
    /// (model, API key) → the decider; tests fake it.
    var makeDecider: (String, String) -> CommandDecider = { makeCommandDecider(model: $0, apiKey: $1) }
    /// Runs a script with a choice (tests fake it).
    var runScript: (URL, String?) async -> CommandResult = { await CommandMode.run(script: $0, choice: $1) }
    /// (what you said, the commands, API key) → the new script, or the command that already does it.
    var writeCommand: (String, [Command], String) async throws -> CommandWriter.Reply = {
        try await CommandWriter(apiKey: $2).write($0, among: $1)
    }
    var pressReturn: () -> Void = { TextInjector().pressReturn() }
    /// The installed apps by name, and opening one (tests fake both).
    var apps: () -> [String: URL] = { Command.installedApps() }
    var openApp: (URL) -> Void = { NSWorkspace.shared.openApplication(at: $0, configuration: NSWorkspace.OpenConfiguration()) }

    init(folder: URL = CommandMode.defaultFolder, history: HistoryStore) {
        self.folder = folder
        self.history = history
    }

    var commands: [Command] { Command.all(in: folder, apps: apps().keys.sorted()) }

    /// The first time (no folder yet): makes it, with the example commands in it. After that the
    /// folder is yours: a command you delete stays deleted.
    static func installExamples(into folder: URL = defaultFolder, from examples: URL? = examples) {
        guard !FileManager.default.fileExists(atPath: folder.path) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let examples else { return }
        for file in (try? FileManager.default.contentsOfDirectory(at: examples, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.copyItem(at: file, to: folder.appendingPathComponent(file.lastPathComponent))
        }
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
        default:
            guard let script = commands.first(where: { $0.name == name })?.script else {
                return CommandResult(ok: false, message: "No \(name) script")
            }
            let result = await runScript(script, choice)
            // A command that fails is turned off until you turn it back on (Settings › Commands).
            guard result.scriptFailed, (try? Command.setEnabled(false, script: script, folder: folder)) != nil else { return result }
            return CommandResult(ok: false, message: result.message + " · turned off", scriptFailed: true)
        }
    }

    /// Writes the command `said` describes into the folder, ready next time (checked that the app can
    /// read it and Python can parse it, not run), or says which command already does it.
    @MainActor
    private func create(_ said: String, apiKey: String, among commands: [Command]) async -> CommandResult {
        func failed(_ why: String) -> CommandResult { CommandResult(ok: false, message: "Couldn't write it: " + why) }
        do {
            switch try await writeCommand(said, commands, apiKey) {
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
    /// and a time limit.
    static func run(script: URL, choice: String?) async -> CommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runNow(script: script, choice: choice))
            }
        }
    }

    static let uvPaths = ["/opt/homebrew/bin/uv", NSHomeDirectory() + "/.local/bin/uv", "/usr/local/bin/uv"]

    private static func runNow(script: URL, choice: String?) -> CommandResult {
        let name = script.deletingPathExtension().lastPathComponent
        switch uv(["run", "--quiet", "--script", script.path] + (choice.map { [$0] } ?? [])) {
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

    /// Runs uv with `arguments`, with no shell and the time limit.
    static func uv(_ arguments: [String]) -> Result<Finished, StartError> {
        guard let uv = uvPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return .failure(.notInstalled)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: uv)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
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
