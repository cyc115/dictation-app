import Foundation

/// "create command …": a cloud model writes the command you describe as a Python script, or names
/// the command that already does it. Its instructions are WriteCommand.txt, with the commands filled
/// in; `bench/suite.py create` asks the same and runs the scripts (about 0.7 s, all of them working).
struct CommandWriter {
    static let model = "deepseek/deepseek-v4.1-flash"
    static let providers = ["Together", "DeepInfra"]
    static let instructions = Bundle.module.url(forResource: "WriteCommand", withExtension: "txt")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""

    enum Reply: Equatable {
        /// This command already does it.
        case existing(String)
        /// A new command: its file name (without .py) and the script.
        case new(name: String, script: String)
    }

    let apiKey: String
    var session: URLSession = .shared

    func write(_ said: String, among commands: [Command]) async throws -> Reply {
        let request = OpenRouter.chat(model: Self.model, system: Self.prompt(commands), user: said, apiKey: apiKey,
                                      extra: ["provider": ["order": Self.providers], "max_tokens": 4000])
        let (data, status) = try await OpenRouter.send(request, session: session)
        let json = OpenRouter.json(data)
        guard let text = OpenRouter.content(json, status: status) else {
            throw TranscriptionError.message("Couldn't write it: " + (OpenRouter.errorMessage(json) ?? "HTTP \(status)"))
        }
        guard let reply = Self.parse(text) else { throw TranscriptionError.message("Couldn't write it: the answer wasn't a script") }
        return reply
    }

    /// The instructions with the commands listed, as "- name: summary (choices: value = meaning, …)";
    /// open's and switch-app's choices (the apps) are left out, or the model names an app as the command.
    static func prompt(_ commands: [Command]) -> String {
        let lines = commands.filter { $0.name != Command.create.name }.map { command in
            let choices = command.choosesAnApp ? "" : command.choices.map { "\($0.value) = \($0.meaning)" }.joined(separator: ", ")
            return "- \(command.name): \(command.summary)" + (choices.isEmpty ? "" : " (choices: \(choices))")
        }
        return instructions.replacingOccurrences(of: "{commands}", with: lines.joined(separator: "\n"))
    }

    /// "EXISTING: <name>", or "NAME: <name>" and a ```python block; nil for anything else.
    static func parse(_ text: String) -> Reply? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        func capture(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
        if let name = capture(#"\AEXISTING:\s*([\w-]+)\s*\z"#) { return .existing(name) }
        guard let name = capture(#"(?m)^NAME:\s*(\S+)\s*$"#),
              let script = capture(#"(?s)```(?:python)?[ \t]*\n(.*?)```"#) else { return nil }
        return .new(name: name, script: script.trimmingCharacters(in: .newlines) + "\n")
    }

    /// One to a few lowercase words joined by hyphens: window-left.
    static func validName(_ name: String) -> Bool {
        name.range(of: #"^[a-z][a-z0-9]*(-[a-z0-9]+)*$"#, options: .regularExpression) != nil
    }
}
