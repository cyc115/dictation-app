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

        /// As the model wrote it (`parse` reads it back).
        var text: String {
            switch self {
            case .existing(let name): "EXISTING: \(name)"
            case .new(let name, let script): "NAME: \(name)\n```python\n\(script)```"
            }
        }
    }

    /// A reply that couldn't be used, and why ("Python can't parse it: …", with the line and caret).
    struct Retry: Equatable {
        var reply: Reply
        var problem: String
    }

    let apiKey: String
    var session: URLSession = .shared

    /// `fixing` a reply that couldn't be used, the model is shown it and why, and asked again: shown
    /// Python's error, it fixes the line (4 of 4); asked afresh, about half the time it slips again.
    func write(_ said: String, among commands: [Command], fixing retry: Retry? = nil) async throws -> Reply {
        var extra: [String: Any] = ["provider": ["order": Self.providers], "max_tokens": 4000]
        if let retry { extra["messages"] = Self.messages(said, among: commands, fixing: retry) }
        let request = OpenRouter.chat(model: Self.model, system: Self.prompt(commands), user: said, apiKey: apiKey, extra: extra)
        let (data, status) = try await OpenRouter.send(request, session: session)
        let json = OpenRouter.json(data)
        guard let text = OpenRouter.content(json, status: status) else {
            throw TranscriptionError.message("Couldn't write it: " + OpenRouter.problem(json, status: status))
        }
        guard let reply = Self.parse(text) else { throw TranscriptionError.message("Couldn't write it: the answer wasn't a script") }
        return reply
    }

    /// The instructions with the commands listed, as "- name: summary (choices: value = meaning, …)";
    /// open's, switch-app's and fix's choices (apps, commands) are left out, or the model names an app as the command.
    static func prompt(_ commands: [Command]) -> String {
        let lines = commands.filter { $0.name != Command.create.name }.map { command in
            let choices = command.choicesFromThisMac ? "" : command.choices.map { "\($0.value) = \($0.meaning)" }.joined(separator: ", ")
            return "- \(command.name): \(command.summary)" + (choices.isEmpty ? "" : " (choices: \(choices))")
        }
        return instructions.replacingOccurrences(of: "{commands}", with: lines.joined(separator: "\n"))
    }

    /// The conversation that asks again: the request, the reply, and what was wrong with it.
    static func messages(_ said: String, among commands: [Command], fixing retry: Retry) -> [[String: String]] {
        [["role": "system", "content": prompt(commands)], ["role": "user", "content": said],
         ["role": "assistant", "content": retry.reply.text],
         ["role": "user", "content": "That can't be used: \(retry.problem)\nReply again, in the same form, with it fixed."]]
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
