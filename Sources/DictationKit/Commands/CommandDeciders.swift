import Foundation

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
        let (data, status) = try await OpenRouter.send(Self.request(said, among: commands, apiKey: apiKey), session: session)
        return try Self.parse(data: data, status: status).get()
    }

    static func request(_ said: String, among commands: [Command], apiKey: String) -> URLRequest {
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
        return OpenRouter.post(endpoint, body: ["model": model, "state": "The user said: " + said, "questions": questions],
                               apiKey: apiKey, timeout: 10)
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
        let (data, status) = try await OpenRouter.send(Self.request(said, among: commands, model: model, apiKey: apiKey), session: session)
        return try Self.parse(data: data, status: status, among: commands).get()
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
        let values = Array(Set(commands.flatMap { $0.choices.map(\.value) } + [""])).sorted()
        let schema: [String: Any] = ["type": "object", "additionalProperties": false, "required": ["command", "choice"], "properties": [
            "command": ["type": "string", "enum": commands.map(\.name) + ["none"]],
            "choice": ["type": "string", "enum": values],
        ]]
        return OpenRouter.chat(model: model, system: prompt(commands), user: said, apiKey: apiKey, extra: [
            "max_tokens": 80,
            "response_format": ["type": "json_schema", "json_schema": ["name": "command", "strict": true, "schema": schema]],
        ], timeout: 10)
    }

    /// A command it named that doesn't exist is "none"; a choice that isn't that command's is dropped.
    static func parse(data: Data, status: Int, among commands: [Command]) -> Result<CommandDecision, Error> {
        let json = OpenRouter.json(data)
        guard let content = OpenRouter.content(json, status: status), let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}"),
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
