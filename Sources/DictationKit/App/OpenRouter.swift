import Foundation

/// What every OpenRouter call shares: transcription, AI polish, the command deciders, Corrections'
/// suggestions and Learn. A new cloud call is `chat(…)` or `post(…)`, then `send`, then `content`.
enum OpenRouter {
    static let chatEndpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    /// A POST to `url` with the API key and the app's name. `apiKey` nil: a server that takes none
    /// (Decider on this Mac).
    static func request(_ url: URL, apiKey: String?, timeout: TimeInterval = 60) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.setValue("DictationApp", forHTTPHeaderField: "X-Title")
        return request
    }

    /// A POST of `body` as JSON.
    static func post(_ url: URL, body: [String: Any], apiKey: String?, timeout: TimeInterval = 60) -> URLRequest {
        var request = request(url, apiKey: apiKey, timeout: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Thinking adds seconds and nothing to the app's short jobs (a cleanup, picking a command): off
    /// where the model allows it, else the lowest effort (gpt-oss, gpt-5 and gpt-6 models can't turn
    /// it off). The bench tries the same (bench/openrouter.py).
    static let mustThink = ["openai/gpt-oss", "openai/gpt-5", "openai/gpt-6"]
    static func reasoning(for model: String) -> [String: Any] {
        mustThink.contains { model.hasPrefix($0) } ? ["effort": "minimal"] : ["enabled": false]
    }

    /// A chat completion: `system` and `user` messages at temperature 0, reasoning off or lowest
    /// unless given; `extra` adds fields (provider, response_format, max_tokens).
    static func chat(model: String, system: String, user: String, apiKey: String, reasoning: [String: Any]? = nil,
                     extra: [String: Any] = [:], timeout: TimeInterval = 60) -> URLRequest {
        var body: [String: Any] = ["model": model, "temperature": 0, "reasoning": reasoning ?? Self.reasoning(for: model),
                                   "messages": [["role": "system", "content": system], ["role": "user", "content": user]]]
        body.merge(extra) { _, new in new }
        return post(chatEndpoint, body: body, apiKey: apiKey, timeout: timeout)
    }

    /// Sends it: the response body and its HTTP status.
    static func send(_ request: URLRequest, session: URLSession) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// A response body as a JSON object, or nil.
    static func json(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// A chat completion's text; nil when the call failed (`errorMessage` says why).
    static func content(_ json: [String: Any]?, status: Int) -> String? {
        guard (200..<300).contains(status), let choices = json?["choices"] as? [[String: Any]] else { return nil }
        return (choices.first?["message"] as? [String: Any])?["content"] as? String
    }

    /// The `error.message` OpenRouter puts in a failed response.
    static func errorMessage(_ json: [String: Any]?) -> String? {
        (json?["error"] as? [String: Any])?["message"] as? String
    }

    /// Why a call failed, for a message: `errorMessage`, else the HTTP status.
    static func problem(_ json: [String: Any]?, status: Int) -> String {
        errorMessage(json) ?? "HTTP \(status)"
    }
}
