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
    let backend: PolishBackend

    init(backend: PolishBackend = OnDevicePolish()) { self.backend = backend }

    /// Starts loading the model while you're still speaking (call when dictation starts).
    func prepare() { backend.prepare() }

    /// The polished text, or the raw text if polishing fails — you always get your words.
    func polish(_ text: String) async -> String {
        (try? await polished(text)) ?? text
    }

    /// The polished text; throws instead of falling back, so benchmarks see failures.
    func polished(_ text: String) async throws -> String {
        let cleaned = try await backend.polish(text).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? text : cleaned
    }
}

#if canImport(FoundationModels)
import FoundationModels

/// Apple's on-device model (Apple Intelligence). Polish took ~2.4 s typical when the session was
/// created after you stopped (bench/results/latency/BASELINE-pre-optimization.md), so `prepare()`
/// creates and prewarms the next dictation's session while you speak. Each dictation gets a fresh
/// session: a reused one would carry earlier dictations in its context.
final class OnDevicePolish: PolishBackend {
    private var prepared: LanguageModelSession?
    private let lock = NSLock()  // prepare() runs on main, polish() in a Task

    func prepare() {
        guard case .available = SystemLanguageModel.default.availability else { return }
        let session = LanguageModelSession(instructions: PolishService.instructions)
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
        let session = takePrepared() ?? LanguageModelSession(instructions: PolishService.instructions)
        return try await session.respond(to: text).content
    }
}
#else
final class OnDevicePolish: PolishBackend {
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

    func polish(_ text: String) async throws -> String {
        let (data, response) = try await session.data(for: Self.request(model: model, apiKey: apiKey, text: text))
        return try Self.parse(data: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0).get()
    }

    static func request(model: String, apiKey: String, text: String) -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("DictationApp", forHTTPHeaderField: "X-Title")
        let body: [String: Any] = ["model": model, "temperature": 0, "messages": [
            ["role": "system", "content": PolishService.instructions],
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
