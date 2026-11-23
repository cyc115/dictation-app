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
    /// The same backend, adding each call's usage to `meter` where it can tell (OpenRouter); else itself.
    func metered(by meter: UsageMeter) -> PolishBackend
}

extension PolishBackend {
    func prepare() {}
    func metered(by meter: UsageMeter) -> PolishBackend { self }
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
    /// Each model's failure, a backup asked, giving up (`CloudLog`).
    let log: CloudLog

    init(backend: PolishBackend, backup: PolishBackend? = nil, backupAfter: TimeInterval = 0, deadline: TimeInterval? = nil,
         log: CloudLog = .polish) {
        self.log = log
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
    /// `by` is set when polish failed too (`failed`, with each model's failure), so History shows it.
    func polishReporting(_ text: String) async -> (text: String, error: String?, by: ModelAnswer?) {
        let (result, by) = await run(text)
        switch result {
        case .success(let polished): return (polished, nil, by)
        case .failure(let error): return (text, error.localizedDescription, by)
        }
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
        let (result, by) = await run(text)
        return (try result.get(), by)
    }

    /// Each model's failure, kept for `ModelAnswer.failures` (the models run concurrently).
    private final class Failures: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [ModelAnswer.Failure] = []
        func add(_ failure: ModelAnswer.Failure) { lock.withLock { items.append(failure) } }
        var all: [ModelAnswer.Failure] { lock.withLock { items } }
    }

    /// The race: the polished text (the transcript if it came back empty) or why it failed, and who
    /// answered and which requests failed.
    private func run(_ text: String) async -> (Result<String, Error>, ModelAnswer) {
        let backend = backend, backup = backup, log = log, started = Date(), failures = Failures()
        let took = { CloudLog.seconds(Date().timeIntervalSince(started)) }
        // A failure is logged even when the other model goes on to answer: that's how a dead backup shows.
        let logged = { (model: PolishBackend) -> @Sendable () async throws -> String in
            { do { return try await model.polish(text) } catch {
                if !(error is CancellationError) && (error as? URLError)?.code != .cancelled {
                    log.error("\(model.name) failed after \(took()): \(error.localizedDescription)")
                    failures.add(.init(model: model.name, message: error.localizedDescription))
                }
                throw error
            } }
        }
        let reply: String, byBackup: Bool, backupAsked: Bool
        do {
            (reply, byBackup, backupAsked) = try await FirstAnswer.race(
                main: logged(backend), backup: backup.map(logged), backupAfter: backupAfter, deadline: deadline)
        } catch {
            log.error("polish gave up after \(took()), the raw text is used: \(error.localizedDescription)")
            // Out of time: the main model is the one that didn't answer.
            if error is FirstAnswer.TimedOut { failures.add(.init(model: backend.name, message: error.localizedDescription)) }
            let all = failures.all
            return (.failure(error), ModelAnswer(main: backend.name, backup: backup?.name, failures: all.isEmpty ? nil : all, failed: true))
        }
        if backupAsked {
            log.notice("polish from \(byBackup ? backup?.name ?? "" : backend.name) in \(took())"
                + (byBackup ? " (backup)" : "; backup \(backup?.name ?? "") was slower or failed"))
        } else {
            log.info("polish from \(backend.name) in \(took())")
        }
        let cleaned = reply.trimmingCharacters(in: .whitespacesAndNewlines), all = failures.all
        let by = ModelAnswer(main: backend.name, backup: backupAsked ? backup?.name : nil, byBackup: byBackup,
                             failures: all.isEmpty ? nil : all)
        return (.success(cleaned.isEmpty ? text : cleaned), by)
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
        lock.withLock { prepared = session }
    }

    /// The prewarmed session, used once.
    private func takePrepared() -> LanguageModelSession? {
        lock.withLock {
            defer { prepared = nil }
            return prepared
        }
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
    /// Adds up what each call used and cost (the prompt tuner's student calls); nil: nothing kept.
    var meter: UsageMeter?

    var name: String { ModelSpec.openRouter(id: model, providers: provider).description }

    func metered(by meter: UsageMeter) -> PolishBackend {
        var metered = self
        metered.meter = meter
        return metered
    }

    func polish(_ text: String) async throws -> String {
        let message = PolishService.userMessage(text, wrap: wrap)
        func ask(_ reasoning: [String: Any]?) async throws -> (answer: Result<String, Error>, refused: Bool) {
            let request = Self.request(model: model, apiKey: apiKey, text: message, instructions: instructions,
                                       provider: provider, reasoning: reasoning)
            let (data, status) = try await OpenRouter.send(request, session: session)
            let json = OpenRouter.json(data)
            if let meter, let usage = OpenRouter.Usage(json) { meter.add(usage) }
            return (Self.parse(data: data, status: status), OpenRouter.refusesReasoningOff(json, status: status))
        }
        let first = try await ask(reasoning)
        // A model not in `OpenRouter.mustThink` that still refuses "reasoning off" (the model is a
        // setting for Corrections): ask again at the lowest effort.
        if reasoning == nil, first.refused {
            return try await ask(["effort": "minimal"]).answer.get()
        }
        return try first.answer.get()
    }

    static func request(model: String, apiKey: String, text: String,
                        instructions: String, provider: String? = nil, reasoning: [String: Any]? = nil) -> URLRequest {
        let pinned: [String: Any] = provider.map { ["provider": OpenRouter.provider($0)] } ?? [:]
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
