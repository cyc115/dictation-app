import Foundation
import FoundationModels

/// A model that cleans up a dictated transcript.
protocol PolishBackend {
    /// Called when dictation starts, so slow setup (loading a model) overlaps with speaking.
    func prepare()
    /// The cleaned text. Throws when the model is unavailable or fails.
    func polish(_ text: String) async throws -> String
    /// Which model, for kept recordings: e.g. "openrouter:openai/gpt-oss-120b".
    var name: String { get }
}

extension PolishBackend {
    func prepare() {}
    var name: String { String(describing: Self.self) }
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

/// Optional LLM cleanup of the transcript. OFF by default (menu bar toggle). The setup picks the
/// model and prompt (`DictationSetup.polishService`): on-device for On-device, so nothing leaves
/// the Mac; a cloud model for the cloud setups, where the audio already went.
///
/// Cloud polish usually answers in well under a second but now and then takes 5 s or more, or the
/// host is down. So, as speech does (`UploadRace`), a cloud setup can also ask a `backup` once the
/// main model is `backupAfter` seconds late or fails, and gives up at `deadline`: you get your raw
/// words then rather than waiting.
class PolishService {
    let backend: PolishBackend
    let backup: PolishBackend?
    let backupAfter: TimeInterval
    /// Seconds before polishing gives up; nil waits (on-device: it's slow, but it's there).
    let deadline: TimeInterval?

    init(backend: PolishBackend, backup: PolishBackend? = nil, backupAfter: TimeInterval = 0, deadline: TimeInterval? = nil) {
        self.backend = backend
        self.backup = backup
        self.backupAfter = backupAfter
        self.deadline = deadline
    }

    /// Starts loading the model while you're still speaking (call when dictation starts).
    func prepare() {
        backend.prepare()
        backup?.prepare()
    }

    /// The polished text and which model gave it, or the raw text if polishing fails or runs out of
    /// time (you always get your words), and why.
    func polishReporting(_ text: String) async -> (text: String, error: String?, by: ModelAnswer?) {
        do {
            let answer = try await answer(text)
            return (answer.text, nil, answer.by)
        } catch { return (text, error.localizedDescription, nil) }
    }

    /// The transcript as the model sees it. `wrap` (every backend's default) marks it as data, not a
    /// request to the model: in bench/suite.py polish it stopped models answering what was dictated.
    static func userMessage(_ text: String, wrap: Bool) -> String {
        wrap ? "<transcript>\n\(text)\n</transcript>" : text
    }

    /// The polished text; throws instead of falling back, so benchmarks see failures.
    func polished(_ text: String) async throws -> String { try await answer(text).text }

    /// The polished text and which model gave it (`by.model`: the backup's, if it answered first).
    func answer(_ text: String) async throws -> (text: String, by: ModelAnswer) {
        let backend = backend, backup = backup
        let (reply, byBackup, backupAsked) = try await FirstAnswer.race(
            main: { try await backend.polish(text) },
            backup: backup.map { backup in { try await backup.polish(text) } },
            backupAfter: backupAfter, deadline: deadline)
        let cleaned = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let by = ModelAnswer(main: backend.name, backup: backupAsked ? backup?.name : nil, byBackup: byBackup)
        return (cleaned.isEmpty ? text : cleaned, by)
    }
}

/// Apple's on-device model (Apple Intelligence). Polish took ~2.4 s typical when the session was
/// created after you stopped (bench/results/latency/BASELINE-pre-optimization.md), so `prepare()`
/// creates and prewarms the next dictation's session while you speak. Each dictation gets a fresh
/// session: a reused one would carry earlier dictations in its context.
final class OnDevicePolish: PolishBackend {
    let instructions: String
    let wrap: Bool
    private var prepared: LanguageModelSession?
    private let lock = NSLock()  // prepare() runs on main, polish() in a Task

    init(instructions: String = DictationSetup.onDevice.promptText, wrap: Bool = true) {
        self.instructions = instructions
        self.wrap = wrap
    }

    var name: String { "apple:on-device" }

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
        return try await session.respond(to: PolishService.userMessage(text, wrap: wrap)).content
    }
}

/// A cloud LLM through OpenRouter's chat completions API: the cloud setups' polish, and any
/// OpenRouter model in benchmarks.
struct OpenRouterPolish: PolishBackend {
    let model: String
    let apiKey: String
    var session: URLSession = .shared
    var instructions = DictationSetup.cloudFlash.promptText
    var wrap = true
    /// Only these OpenRouter providers, in order, comma-separated ("Together,DeepInfra": the second
    /// if the first fails); nil lets OpenRouter route.
    var provider: String?
    /// The request's "reasoning" field; nil is `OpenRouter.reasoning(for:)` (off, or minimal). The
    /// prompt tuner's teacher model sets it high.
    var reasoning: [String: Any]?

    var name: String { ModelSpec.openRouter(id: model, providers: provider).description }

    func polish(_ text: String) async throws -> String {
        let request = Self.request(model: model, apiKey: apiKey, text: PolishService.userMessage(text, wrap: wrap),
                                   instructions: instructions, provider: provider, reasoning: reasoning)
        let (data, status) = try await OpenRouter.send(request, session: session)
        return try Self.parse(data: data, status: status).get()
    }

    static func request(model: String, apiKey: String, text: String,
                        instructions: String, provider: String? = nil, reasoning: [String: Any]? = nil) -> URLRequest {
        // `provider`: only these, in order, no others.
        let pinned: [String: Any] = provider.map {
            ["provider": ["order": $0.split(separator: ",").map(String.init), "allow_fallbacks": false]]
        } ?? [:]
        return OpenRouter.chat(model: model, system: instructions, user: text, apiKey: apiKey, reasoning: reasoning, extra: pinned)
    }

    static func parse(data: Data, status: Int) -> Result<String, Error> {
        let json = OpenRouter.json(data)
        guard let content = OpenRouter.content(json, status: status) else {
            return .failure(PolishError.failed(OpenRouter.errorMessage(json) ?? "Polish failed (HTTP \(status))."))
        }
        return .success(content)
    }
}
