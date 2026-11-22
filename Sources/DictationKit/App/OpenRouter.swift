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
        for (field, value) in appHeaders { request.setValue(value, forHTTPHeaderField: field) }
        return request
    }

    /// OpenRouter app attribution, so Activity lists the app by name. HTTP-Referer is what creates
    /// the app (a title alone stays "Unknown"); hidden keeps it out of OpenRouter's public rankings.
    static let appHeaders = [
        "HTTP-Referer": "http://dictation-app.mac/",
        "X-OpenRouter-Title": "DictationApp",
        "X-Title": "DictationApp",
        "X-OpenRouter-App-Visibility": "hidden",
    ]

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

    /// What calls used and cost, from the `usage` block OpenRouter puts in every response (no request
    /// field needed: openrouter.ai/docs/use-cases/usage-accounting). Added up, a sum over `calls`.
    struct Usage: Equatable {
        var calls = 0
        /// Prompt tokens, of them `cached` read from the provider's prompt cache and `cacheWrite` written to it.
        var prompt = 0, cached = 0, cacheWrite = 0
        /// Completion tokens, of them `reasoning` spent thinking.
        var completion = 0, reasoning = 0
        /// US dollars, as charged to the key.
        var cost = 0.0

        /// One call's usage; nil when the response has none (a failed call, a server that isn't OpenRouter).
        init?(_ json: [String: Any]?) {
            guard let usage = json?["usage"] as? [String: Any] else { return nil }
            func number(_ object: Any?, _ key: String) -> NSNumber? { (object as? [String: Any])?[key] as? NSNumber }
            calls = 1
            prompt = number(usage, "prompt_tokens")?.intValue ?? 0
            cached = number(usage["prompt_tokens_details"], "cached_tokens")?.intValue ?? 0
            cacheWrite = number(usage["prompt_tokens_details"], "cache_write_tokens")?.intValue ?? 0
            completion = number(usage, "completion_tokens")?.intValue ?? 0
            reasoning = number(usage["completion_tokens_details"], "reasoning_tokens")?.intValue ?? 0
            cost = number(usage, "cost")?.doubleValue ?? 0
        }

        init(calls: Int = 0, prompt: Int = 0, cached: Int = 0, cacheWrite: Int = 0, completion: Int = 0, reasoning: Int = 0, cost: Double = 0) {
            self.calls = calls; self.prompt = prompt; self.cached = cached; self.cacheWrite = cacheWrite
            self.completion = completion; self.reasoning = reasoning; self.cost = cost
        }

        static func + (a: Usage, b: Usage) -> Usage {
            Usage(calls: a.calls + b.calls, prompt: a.prompt + b.prompt, cached: a.cached + b.cached, cacheWrite: a.cacheWrite + b.cacheWrite,
                  completion: a.completion + b.completion, reasoning: a.reasoning + b.reasoning, cost: a.cost + b.cost)
        }

        /// For a JSON report (the teacher bake-off).
        var json: [String: Any] {
            ["calls": calls, "promptTokens": prompt, "cachedTokens": cached, "cacheWriteTokens": cacheWrite,
             "completionTokens": completion, "reasoningTokens": reasoning, "cost": cost]
        }
    }
}

/// Adds up the usage of calls made from many tasks at once (a tune's student calls).
final class UsageMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var usages: [OpenRouter.Usage] = []

    func add(_ usage: OpenRouter.Usage) { lock.withLock { usages.append(usage) } }

    /// Calls recorded so far: a mark for `total(from:)`.
    var count: Int { lock.withLock { usages.count } }

    /// The sum of the calls recorded since `mark`.
    func total(from mark: Int = 0) -> OpenRouter.Usage {
        lock.withLock { usages.dropFirst(mark).reduce(OpenRouter.Usage(), +) }
    }
}
