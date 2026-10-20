import Foundation

/// How a command went: its script's first line of output ("Brightness 70%"), or why it failed.
struct CommandResult: Equatable {
    var ok: Bool
    var message: String

    /// From a finished script: on success its first line of output, else its last line of errors.
    static func from(status: Int32, output: String, errors: String, timedOut: Bool, name: String) -> CommandResult {
        func line(_ text: String, last: Bool) -> String? {
            let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return last ? lines.last : lines.first
        }
        if timedOut { return CommandResult(ok: false, message: "Took longer than \(Int(CommandMode.timeout)) s") }
        if status == 0 { return CommandResult(ok: true, message: line(output, last: false) ?? "Ran \(name)") }
        return CommandResult(ok: false, message: line(errors, last: true) ?? line(output, last: true) ?? "Exited with \(status)")
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
    var pressReturn: () -> Void = { TextInjector().pressReturn() }

    init(folder: URL = CommandMode.defaultFolder, history: HistoryStore) {
        self.folder = folder
        self.history = history
    }

    var commands: [Command] { Command.all(in: folder) }

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
                let result = await perform(name, choice: decision.choice, among: commands)
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

    /// Runs a command again, as it was (History's ↻); saved as a new run.
    @MainActor
    func again(_ previous: CommandRun) async -> CommandRun {
        var run = CommandRun(said: previous.said, command: previous.command, choice: previous.choice)
        if let name = previous.command {
            let result = await perform(name, choice: previous.choice, among: commands)
            run.ok = result.ok
            run.result = result.message
        }
        history.addCommand(run)
        return run
    }

    @MainActor
    private func perform(_ name: String, choice: String?, among commands: [Command]) async -> CommandResult {
        switch name {
        case Command.pressReturn.name:
            pressReturn()
            return CommandResult(ok: true, message: "Pressed Return")
        case Command.again.name:
            guard let last = history.commands.first(where: { $0.ok && $0.command != nil && $0.command != Command.again.name }),
                  let lastName = last.command else {
                return CommandResult(ok: false, message: "Nothing to repeat")
            }
            return await perform(lastName, choice: last.choice, among: commands)
        default:
            guard let script = commands.first(where: { $0.name == name })?.script else {
                return CommandResult(ok: false, message: "No \(name) script")
            }
            return await runScript(script, choice)
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
        guard let uv = uvPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return CommandResult(ok: false, message: "uv isn't installed")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: uv)
        process.arguments = ["run", "--quiet", "--script", script.path] + (choice.map { [$0] } ?? [])
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch {
            return CommandResult(ok: false, message: "Couldn't start \(name): \(error.localizedDescription)")
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
        return CommandResult.from(status: process.terminationStatus, output: String(decoding: outputData, as: UTF8.self),
                                  errors: String(decoding: errorData, as: UTF8.self), timedOut: process.terminationReason == .uncaughtSignal, name: name)
    }
}
