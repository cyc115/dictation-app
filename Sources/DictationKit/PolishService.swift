import Foundation

/// A model that cleans up a dictated transcript.
protocol PolishBackend {
    /// Called when dictation starts, so slow setup (loading a model) overlaps with speaking.
    func prepare()
    /// The cleaned text. Throws when the model is unavailable or fails.
    func polish(_ text: String) async throws -> String
}

extension PolishBackend {
    func prepare() {}
}

enum PolishError: LocalizedError {
    case unavailable(String)
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .unavailable(let m), .failed(let m): return m
        }
    }
}

/// Optional LLM cleanup of the transcript. OFF by default (menu bar toggle).
/// The app uses Apple's on-device model only — nothing leaves the Mac. `OpenRouterPolish`
/// exists so cloud models can be compared against it (bench/: `suite.py latency`).
class PolishService {
    /// Shared by every backend so they're compared on the same task.
    static let instructions = """
        Clean up dictated text: remove filler words (um, uh, like, you know), \
        collapse repeated words, resolve obvious self-corrections, add light \
        punctuation. Keep the speaker's exact meaning, wording and tone. \
        Never add new ideas or rephrase beyond cleanup. Output only the cleaned text.
        """
    /// For `OnDevicePolish(tailWords:)`: rewrite only the newest part, the rest is context.
    static let tailInstructions = instructions + """
         The user message has the earlier, already-written part and then the newest part. \
        Output only the cleaned-up newest part; never repeat the earlier part.
        """
    let backend: PolishBackend

    init(backend: PolishBackend = OnDevicePolish()) { self.backend = backend }

    /// Starts loading the model while you're still speaking (call when dictation starts).
    func prepare() { backend.prepare() }

    /// The polished text, or the raw text if polishing fails — you always get your words.
    func polish(_ text: String) async -> String {
        (try? await polished(text)) ?? text
    }

    /// The transcript as the model sees it. `wrap` marks it as data, not a request to the model
    /// (benchmarked with bench/suite.py polish --wrap).
    static func userMessage(_ text: String, wrap: Bool) -> String {
        wrap ? "<transcript>\n\(text)\n</transcript>" : text
    }

    /// The polished text; throws instead of falling back, so benchmarks see failures.
    func polished(_ text: String) async throws -> String {
        let cleaned = try await backend.polish(text).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? text : cleaned
    }

    private static let word = try! NSRegularExpression(
        pattern: "[\\u3400-\\u9fff\\uf900-\\ufaff]|[A-Za-z0-9]+(?:'[A-Za-z]+)?")

    /// `text` split before its last `words` words (a Chinese character or an English word each);
    /// nil when it has no more than that, so there's no earlier part.
    static func splitTail(_ text: String, words: Int) -> (context: String, tail: String)? {
        let matches = word.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard words > 0, matches.count > words,
              let cut = Range(matches[matches.count - words].range, in: text)?.lowerBound else { return nil }
        return (text[..<cut].trimmingCharacters(in: .whitespaces), String(text[cut...]))
    }

    /// The prompt that rewrites only the last `words` words, with the rest as read-only context;
    /// just `text` when it's that short.
    static func tailPrompt(_ text: String, words: Int) -> String {
        guard let (context, tail) = splitTail(text, words: words) else { return text }
        return "Earlier part (already written):\n\(context)\n\nNewest part (clean up and output only this):\n\(tail)"
    }
}

#if canImport(FoundationModels)
import FoundationModels

/// Apple's on-device model (Apple Intelligence). Polish took ~2.4 s typical when the session was
/// created after you stopped (bench/results/latency/BASELINE-pre-optimization.md), so `prepare()`
/// creates and prewarms the next dictation's session while you speak. Each dictation gets a fresh
/// session: a reused one would carry earlier dictations in its context.
final class OnDevicePolish: PolishBackend {
    /// Benchmark-only ("apple-tail" in bench/): rewrite only the last `tailWords` words with the rest
    /// as context — what polishing phrases while you speak would leave for after you stop. Its
    /// output is just that last part, so it's timed, never pasted.
    let tailWords: Int?
    /// Benchmark overrides (bench/suite.py polish --prompt-file / --wrap); the app uses the defaults.
    let customInstructions: String?
    let wrap: Bool
    private var prepared: LanguageModelSession?
    private let lock = NSLock()  // prepare() runs on main, polish() in a Task

    init(tailWords: Int? = nil, instructions: String? = nil, wrap: Bool = false) {
        self.tailWords = tailWords
        customInstructions = instructions
        self.wrap = wrap
    }

    private var instructions: String {
        customInstructions ?? (tailWords == nil ? PolishService.instructions : PolishService.tailInstructions)
    }

    func prepare() {
        guard case .available = SystemLanguageModel.default.availability else { return }
        let session = LanguageModelSession(instructions: instructions)
        session.prewarm()
        lock.lock(); prepared = session; lock.unlock()
    }

    /// The prewarmed session, used once.
    private func takePrepared() -> LanguageModelSession? {
        lock.lock(); defer { lock.unlock() }
        let session = prepared
        prepared = nil
        return session
    }

    func polish(_ text: String) async throws -> String {
        guard case .available = SystemLanguageModel.default.availability else {
            throw PolishError.unavailable("Apple Intelligence isn't available on this Mac.")
        }
        let session = takePrepared() ?? LanguageModelSession(instructions: instructions)
        let prompt = tailWords.map { PolishService.tailPrompt(text, words: $0) } ?? PolishService.userMessage(text, wrap: wrap)
        return try await session.respond(to: prompt).content
    }
}
#else
final class OnDevicePolish: PolishBackend {
    let tailWords: Int?
    let customInstructions: String?
    let wrap: Bool
    init(tailWords: Int? = nil, instructions: String? = nil, wrap: Bool = false) {
        self.tailWords = tailWords
        customInstructions = instructions
        self.wrap = wrap
    }
    func polish(_ text: String) async throws -> String {
        throw PolishError.unavailable("Apple Intelligence isn't available on this Mac.")
    }
}
#endif

/// A cloud LLM through OpenRouter's chat completions API. Benchmark-only for now: Settings
/// doesn't offer it, so the app's polish stays on-device.
struct OpenRouterPolish: PolishBackend {
    static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    let model: String
    let apiKey: String
    var session: URLSession = .shared
    var instructions = PolishService.instructions
    var wrap = false

    func polish(_ text: String) async throws -> String {
        let request = Self.request(model: model, apiKey: apiKey, text: PolishService.userMessage(text, wrap: wrap),
                                   instructions: instructions)
        let (data, response) = try await session.data(for: request)
        return try Self.parse(data: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0).get()
    }

    static func request(model: String, apiKey: String, text: String,
                        instructions: String = PolishService.instructions) -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("DictationApp", forHTTPHeaderField: "X-Title")
        let body: [String: Any] = ["model": model, "temperature": 0, "messages": [
            ["role": "system", "content": instructions],
            ["role": "user", "content": text],
        ]]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func parse(data: Data, status: Int) -> Result<String, Error> {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if (200..<300).contains(status), let choices = json?["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any], let content = message["content"] as? String {
            return .success(content)
        }
        let apiMessage = (json?["error"] as? [String: Any])?["message"] as? String
        return .failure(PolishError.failed(apiMessage ?? "Polish failed (HTTP \(status))."))
    }
}
