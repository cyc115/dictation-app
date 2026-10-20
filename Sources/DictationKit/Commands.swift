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

/// What the decider picked for what you said: a command and one of its choices, or nothing.
struct CommandDecision: Equatable {
    /// nil: none of them does it.
    var command: String?
    var choice: String?
    /// How sure, 0…1.
    var confidence: Double

    /// Below this it's "Command not found" rather than a guess run on your Mac.
    static let minConfidence = 0.5
}

protocol CommandDecider {
    func decide(_ said: String, among commands: [Command]) async throws -> CommandDecision
}

/// TypeSafe's Jev through OpenRouter's decisions API: multiple-choice questions, answered in about
/// 0.3 s. One question picks the command ("none" if nothing fits); one per command with choices
/// picks its choice, all in the same call.
struct JevDecider: CommandDecider {
    static let endpoint = URL(string: "https://openrouter.ai/api/alpha/decisions")!
    static let model = "~typesafe/jev-latest"
    let apiKey: String
    var session: URLSession = .shared

    func decide(_ said: String, among commands: [Command]) async throws -> CommandDecision {
        let (data, response) = try await session.data(for: Self.request(said, among: commands, apiKey: apiKey))
        return try Self.parse(data: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0).get()
    }

    static func request(_ said: String, among commands: [Command], apiKey: String) -> URLRequest {
        var request = OpenRouter.request(endpoint, apiKey: apiKey)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var which = Dictionary(uniqueKeysWithValues: commands.map { ($0.name, $0.summary) })
        which["none"] = "None of these does what the user asked"
        var questions: [String: Any] = ["command": [
            "type": "choice", "instructions": "Which command does what the user asked for?", "criteria": which,
        ]]
        for command in commands where !command.choices.isEmpty {
            questions["choice:" + command.name] = [
                "type": "choice",
                "instructions": "If the user wants \(command.name) (\(command.summary)): which of these?",
                "criteria": Dictionary(command.choices.map { ($0.value, $0.meaning) }, uniquingKeysWith: { a, _ in a }),
            ]
        }
        let body: [String: Any] = ["model": model, "state": "The user said: " + said, "questions": questions]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func parse(data: Data, status: Int) -> Result<CommandDecision, Error> {
        let json = OpenRouter.json(data)
        guard status == 200, let answers = json?["answers"] as? [String: Any],
              let pick = answers["command"] as? [String: Any], let name = pick["choice"] as? String else {
            let message = OpenRouter.errorMessage(json) ?? "HTTP \(status)"
            return .failure(TranscriptionError.message("Couldn't pick a command: \(message)"))
        }
        let choice = (answers["choice:" + name] as? [String: Any])?["choice"] as? String
        return .success(CommandDecision(command: name == "none" ? nil : name, choice: choice,
                                        confidence: pick["confidence"] as? Double ?? 0))
    }
}

/// Any OpenRouter chat model as the decider (bench/suite.py commands compares them with Jev): told
/// the commands and their choices, it answers JSON {"command", "choice"}, the command an enum.
struct ChatDecider: CommandDecider {
    let model: String
    let apiKey: String
    var session: URLSession = .shared

    func decide(_ said: String, among commands: [Command]) async throws -> CommandDecision {
        let (data, response) = try await session.data(for: Self.request(said, among: commands, model: model, apiKey: apiKey))
        return try Self.parse(data: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0, among: commands).get()
    }

    static func prompt(_ commands: [Command]) -> String {
        var lines = ["You pick the command for what the user said (often transcribed speech, English, Chinese or both).", "Commands:"]
        for command in commands {
            let choices = command.choices.map { "\($0.value) = \($0.meaning)" }.joined(separator: "; ")
            lines.append("- \(command.name): \(command.summary)" + (choices.isEmpty ? "" : ". Choices: " + choices))
        }
        lines.append(#"Answer JSON {"command": <name, or "none" if no command does it>, "choice": <one of that command's choices, or "" if it has none>}. If it isn't a request to run one of these, answer none."#)
        return lines.joined(separator: "\n")
    }

    static func request(_ said: String, among commands: [Command], model: String, apiKey: String) -> URLRequest {
        var request = OpenRouter.request(OpenRouterPolish.endpoint, apiKey: apiKey)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let values = Array(Set(commands.flatMap { $0.choices.map(\.value) } + [""])).sorted()
        let schema: [String: Any] = ["type": "object", "additionalProperties": false, "required": ["command", "choice"], "properties": [
            "command": ["type": "string", "enum": commands.map(\.name) + ["none"]],
            "choice": ["type": "string", "enum": values],
        ]]
        let body: [String: Any] = [
            "model": model, "temperature": 0, "max_tokens": 80, "reasoning": OpenRouterPolish.reasoning(for: model),
            "messages": [["role": "system", "content": prompt(commands)], ["role": "user", "content": said]],
            "response_format": ["type": "json_schema", "json_schema": ["name": "command", "strict": true, "schema": schema]],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// A command it named that doesn't exist is "none"; a choice that isn't that command's is dropped.
    static func parse(data: Data, status: Int, among commands: [Command]) -> Result<CommandDecision, Error> {
        let json = OpenRouter.json(data)
        guard status == 200, let content = ((json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String,
              let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}"),
              let picked = OpenRouter.json(Data(content[start...end].utf8)) else {
            let message = OpenRouter.errorMessage(json) ?? "HTTP \(status)"
            return .failure(TranscriptionError.message("Couldn't pick a command: \(message)"))
        }
        guard let name = picked["command"] as? String, let command = commands.first(where: { $0.name == name }) else {
            return .success(CommandDecision(command: nil, confidence: 1))
        }
        let choice = (picked["choice"] as? String).flatMap { value in command.choices.contains { $0.value == value } ? value : nil }
        return .success(CommandDecision(command: name, choice: choice, confidence: 1))
    }
}

/// The decider for a model setting: "jev" (default), or an OpenRouter chat model id.
func makeCommandDecider(model: String, apiKey: String) -> CommandDecider {
    model == "jev" || model == JevDecider.model ? JevDecider(apiKey: apiKey) : ChatDecider(model: model, apiKey: apiKey)
}

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
    static let shared = CommandMode(history: .shared)
    /// Beside History, so you (or an AI you ask) can add and change commands there; read afresh for
    /// every command.
    static let defaultFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DictationApp/Commands", isDirectory: true)
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
