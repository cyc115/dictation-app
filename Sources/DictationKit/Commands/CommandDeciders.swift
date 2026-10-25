import AppKit

/// What the decider picked for what you said: a command and one of its choices, or nothing.
struct CommandDecision: Equatable {
    /// nil: none of them does it.
    var command: String?
    var choice: String?
    /// How sure, 0…1.
    var confidence: Double

    /// Below this it's "Command not found" rather than a guess run on your Mac.
    static let minConfidence = 0.5

    /// Told to every decider: what you said reached it through a speech model, which gets short
    /// commands wrong ("Presenter" for "press Enter"). Its examples aren't the bench's cases.
    static let heard = "The user spoke this and speech-to-text wrote it down, so words may be misheard: go by how they sound "
        + "(“lower the bright knees” is “lower the brightness”, “press and her” is “press Enter”). "
        + "A stray word or two that sounds like no command is none."

    /// The multiple-choice question that picks the command, for the decision models (Jev, Decider).
    static func commandQuestion(_ commands: [Command]) -> [String: Any] {
        var which = Dictionary(commands.map { ($0.name, $0.summary) }, uniquingKeysWith: { a, _ in a })
        which["none"] = "None of these does what the user asked"
        return ["type": "choice", "instructions": "Which command does what the user asked for?", "criteria": which]
    }

    /// The question that picks `command`'s choice. A choice whose meaning is just its value (an app:
    /// "Safari": "Safari") is sent without one: the same answers for a quarter less to read
    /// (bench/results/commands: open's 135 apps were most of Jev's request).
    static func choiceQuestion(_ command: Command) -> [String: Any] {
        ["type": "choice", "instructions": "If the user wants \(command.name) (\(command.summary)): which of these?",
         "criteria": Dictionary(command.choices.map { ($0.value, $0.meaning == $0.value ? NSNull() : $0.meaning as Any) },
                                uniquingKeysWith: { a, _ in a })]
    }
}

protocol CommandDecider {
    func decide(_ said: String, among commands: [Command]) async throws -> CommandDecision
    /// Called as command recording starts, so the decider is ready by the time you stop talking.
    func prepare()
}

extension CommandDecider {
    func prepare() {}
}

/// TypeSafe's Jev through OpenRouter's decisions API: multiple-choice questions, answered in about
/// 0.2 s. One question picks the command ("none" if nothing fits); one per command with choices
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

    /// Opens the connection to OpenRouter while you speak: commands come minutes apart, by when the
    /// last one's has closed, and a new one (TLS) is ~65 ms of a ~230 ms wait (bench: p50 230 → 164 ms).
    func prepare() {
        Self.warm(session: session)
    }

    /// A HEAD to the endpoint: no key, no cost, just the connection the decision then reuses.
    static func warm(session: URLSession) {
        var request = URLRequest(url: endpoint, timeoutInterval: 5)
        request.httpMethod = "HEAD"
        session.dataTask(with: request).resume()
    }

    static func request(_ said: String, among commands: [Command], apiKey: String) -> URLRequest {
        var questions: [String: Any] = ["command": CommandDecision.commandQuestion(commands)]
        for command in commands where !command.choices.isEmpty {
            questions["choice:" + command.name] = CommandDecision.choiceQuestion(command)
        }
        return OpenRouter.post(endpoint, body: ["model": model, "state": CommandDecision.heard + "\nThe user said: " + said, "questions": questions],
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
        var lines = ["You pick the command for what the user said (often transcribed speech, English, Chinese or both).",
                     CommandDecision.heard, "Commands:"]
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

/// Perplexity's Decider for Mac, a free app that runs a 4B decision model on this Mac and answers
/// the same kind of questions as Jev at 127.0.0.1:8080 (Settings › Experimental). Nothing leaves the
/// Mac and no key is needed; ~0.9 s a command on an M1 Max, to Jev's ~0.2 s, about as often right.
/// It takes one question per request and its wait follows how much it reads (~1.4 ms a token), so it
/// gets the command question, then only that command's choice, without `heard`, which matters for
/// the command but not the choice: 10% less to read, same answers (bench/results/commands).
struct LocalDecider: CommandDecider {
    /// The `commandModel` that picks it.
    static let name = "local"
    static let server = URL(string: "http://127.0.0.1:8080")!
    static let model = "pplx-decider-flash-v1.2"
    static let bundleID = "ai.perplexity.decider"
    /// The app's download (a DMG), and the page about it.
    static let download = URL(string: "https://macos-download.perplexity.ai/Decider.dmg")!
    static let about = URL(string: "https://docs.perplexity.ai/docs/decisions/decider-for-mac")!
    var session: URLSession = .shared

    func decide(_ said: String, among commands: [Command]) async throws -> CommandDecision {
        let pick = try await ask(CommandDecision.heard + "\nThe user said: " + said, "command", CommandDecision.commandQuestion(commands))
        let name = pick.choice == "none" ? nil : pick.choice
        guard let name, pick.confidence >= CommandDecision.minConfidence,
              let command = commands.first(where: { $0.name == name }), !command.choices.isEmpty else {
            return CommandDecision(command: name, confidence: pick.confidence)
        }
        let choice = try await ask("The user said: " + said, "choice:" + name, CommandDecision.choiceQuestion(command))
        return CommandDecision(command: name, choice: choice.choice, confidence: pick.confidence)
    }

    private func ask(_ state: String, _ key: String, _ question: [String: Any]) async throws -> (choice: String?, confidence: Double) {
        let data: Data, status: Int
        do {
            (data, status) = try await OpenRouter.send(Self.request(state: state, questions: [key: question]), session: session)
        } catch let error as URLError where [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost].contains(error.code) {
            throw TranscriptionError.message("Decider isn't running: open it, or turn off Settings › Experimental › Decide commands on this Mac")
        }
        return try Self.parse(data: data, status: status, key: key).get()
    }

    static func request(state: String, questions: [String: Any]) -> URLRequest {
        var request = URLRequest(url: server.appendingPathComponent("v1/decisions"), timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "state": state, "questions": questions])
        return request
    }

    static func parse(data: Data, status: Int, key: String) -> Result<(choice: String?, confidence: Double), Error> {
        let json = OpenRouter.json(data)
        guard status == 200, let answer = (json?["answers"] as? [String: Any])?[key] as? [String: Any] else {
            let message = OpenRouter.errorMessage(json) ?? "HTTP \(status)"
            return .failure(TranscriptionError.message("Decider couldn't pick a command: \(message)"))
        }
        return .success((answer["choice"] as? String, answer["confidence"] as? Double ?? 0))
    }

    /// Whether Decider can answer now, for Settings.
    enum Status: Equatable {
        case ready
        /// Running but not ready yet (on first launch it downloads its 5.8 GB model): what it says.
        case starting(String)
        case notRunning
        case notInstalled
    }

    /// Asks its /health; if nothing answers, whether the app is installed.
    static func status(session: URLSession = .shared, installed: () -> Bool = {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }) async -> Status {
        let request = URLRequest(url: server.appendingPathComponent("health"), timeoutInterval: 2)
        if let (data, response) = try? await session.data(for: request) {
            let said = OpenRouter.json(data)?["status"] as? String
            return (response as? HTTPURLResponse)?.statusCode == 200 && said == "ready" ? .ready : .starting(said ?? "starting")
        }
        return installed() ? .notRunning : .notInstalled
    }
}

/// The decider for a model setting: "jev" (default), "local" (Decider on this Mac), or an OpenRouter
/// chat model id.
func makeCommandDecider(model: String, apiKey: String) -> CommandDecider {
    switch model {
    case "jev", JevDecider.model: JevDecider(apiKey: apiKey)
    case LocalDecider.name: LocalDecider()
    default: ChatDecider(model: model, apiKey: apiKey)
    }
}
