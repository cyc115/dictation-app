import Foundation

/// One fix as the judge is shown it: what the app wrote, what it should have been (`fixTarget`), and
/// its word changes (without verdicts).
struct JudgeItem: Equatable {
    let id: UUID
    let wrote: String
    let target: String
    let changes: [WordChange]
}

/// What a judge said: per item, in order, a verdict per change, or nil where the answer didn't cover
/// it; and what the call cost (nil: not an OpenRouter call).
struct JudgeAnswer {
    var verdicts: [[WordChange.Verdict]?]
    var usage: OpenRouter.Usage?
}

/// A model that judges fixes, up to `FixJudge.batchSize` a call (`FixJudge.backend` picks yours;
/// tests pass fakes).
protocol FixJudgeBackend {
    func judge(_ items: [JudgeItem], terms: [String]) async throws -> JudgeAnswer
}

/// A cloud judge call that failed. `transient` (rate limited, a timeout, the host down): asking again
/// unchanged may work, so it costs the fixes no try.
struct JudgeFailure: LocalizedError {
    let message: String
    let transient: Bool
    var errorDescription: String? { message }

    /// From an OpenRouter answer with no content.
    init(json: [String: Any]?, status: Int) {
        message = OpenRouter.problem(json, status: status)
        transient = status == 0 || status == 408 || status == 429 || status >= 500
    }
}

/// *Ask a model about my fixes*: a verdict for each word change of a fix (misheard, style, a change of
/// mind, unclear), so only misheard words go into vocabulary and a captured edit keeps only its
/// misheard and style changes. Every captured edit still waits for your Accept (`auto` only with
/// `trainOnUnreviewedCaptures`, off, no Settings row). The idle pass (`VocabularyIntake`) sends the
/// batches; nothing here runs during a dictation. This is the logic: which fixes wait, the message,
/// reading the answer, and what the verdicts do. Cloud setups only: on a setup that polishes on this
/// Mac nothing is sent and the rules count.
enum FixJudge {
    /// Fixes in one request. Batches of 10 scored as well as one at a time (better, for Claude
    /// Sonnet 5.5) in the Nov 22 run (bench/results/edits/README.md).
    static let batchSize = 10
    /// A batch goes once this many fixes wait…
    static let enough = 5
    /// …or once the oldest has waited this long (or Vocabulary or Corrections is shown).
    static let maxWait: TimeInterval = 600
    /// Answers that may leave a fix out before it's asked no more: one that never parses mustn't
    /// cost forever.
    static let maxTries = 3

    /// The stable part of every request, first so a provider can cache it. `bench/suite.py edits`
    /// sends the same file.
    static let instructions = Bundle.module.url(forResource: "JudgeFixes", withExtension: "txt")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    /// A fix as it was judged, and what the answer said about it (nil: left out, or unreadable).
    struct Judged {
        let item: JudgeItem
        let verdicts: [WordChange.Verdict]?
    }

    /// Fixes with a change not yet judged (newest first, as History is): the intake is the current
    /// fix's, and fewer than `maxTries` answers left it out.
    static func pending(_ entries: [HistoryEntry]) -> [JudgeItem] {
        entries.compactMap { entry in
            guard let target = entry.fixTarget, let intake = entry.intake, intake.of == target, (intake.tries ?? 0) < maxTries,
                  intake.changes.contains(where: { $0.verdict == nil }) else { return nil }
            return JudgeItem(id: entry.id, wrote: entry.text, target: target, changes: intake.changes.map { WordChange(old: $0.old, new: $0.new) })
        }
    }

    /// The user message: the terms (they change rarely, so they're the cacheable `prefix`), then the
    /// numbered fixes. `bench/judge_message_fixture.json` pins the format for both the app and the bench.
    static func message(_ items: [JudgeItem], terms: [String]) -> (prefix: String, rest: String) {
        let prefix = "Vocabulary terms: " + (terms.isEmpty ? "(none)" : terms.joined(separator: ", ")) + "\n\n"
        let fixes = items.enumerated().map { n, item in
            (["<fix n=\"\(n + 1)\">", "wrote: " + item.wrote, "wanted: " + item.target]
             + item.changes.enumerated().map { "change \($0 + 1): \($1.old) → \($1.new)" } + ["</fix>"]).joined(separator: "\n")
        }
        return (prefix, fixes.joined(separator: "\n\n"))
    }

    /// The verdicts in an answer, per item. An item is covered only by an entry with its number (an
    /// integer) and exactly one known verdict per change, the first such entry if there are more;
    /// anything else (prose, a cut-off answer, a wrong count, an unknown verdict) leaves it nil, to
    /// be asked again.
    static func parse(_ answer: String, items: [JudgeItem]) -> [[WordChange.Verdict]?] {
        var found = [[WordChange.Verdict]?](repeating: nil, count: items.count)
        guard !items.isEmpty, let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"), start < end,
              let json = try? JSONSerialization.jsonObject(with: Data(answer[start...end].utf8)) as? [String: Any],
              let fixes = json["fixes"] as? [[String: Any]] else { return found }
        for fix in fixes {
            guard let number = fix["fix"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), !CFNumberIsFloatType(number),
                  case let n = number.intValue, (1...items.count).contains(n), found[n - 1] == nil,
                  let words = fix["verdicts"] as? [String], words.count == items[n - 1].changes.count else { continue }
            let verdicts = words.compactMap(verdict)
            if verdicts.count == words.count { found[n - 1] = verdicts }
        }
        return found
    }

    /// "misheard", "style", "changedMind" (or "changed mind", "changed_mind"), "unclear"; any case.
    static func verdict(_ word: String) -> WordChange.Verdict? {
        switch word.lowercased().filter(\.isLetter) {
        case "misheard": return .misheard
        case "style": return .style
        case "changedmind": return .changedMind
        case "unclear": return .unclear
        default: return nil
        }
    }

    /// What verdicts do to one dictation.
    /// - A correction you typed (or a capture you accepted) is yours: its changes get their verdicts,
    ///   and it's never rewritten.
    /// - A waiting capture keeps only its misheard and style changes: the others are put back as the
    ///   app wrote them (what isn't a word change, like a period or a removed filler, stays as you
    ///   made it). With none kept it's dismissed.
    /// - It stays `waiting` for your Accept. Only with `trainUnreviewed` (`trainOnUnreviewedCaptures`,
    ///   off by default) does it become `auto` (trains Learn unreviewed), and then only when it was
    ///   read back from the text box, keeps a change, has nothing unclear and no words only added (a
    ///   change of mind no verdict covers). Keystroke captures always wait.
    /// The new intake is of the new target with the verdicts, so the next pass doesn't judge it again.
    static func judged(_ entry: HistoryEntry, verdicts: [WordChange.Verdict], trainUnreviewed: Bool) -> HistoryEntry {
        var entry = entry
        guard var intake = entry.intake, intake.changes.count == verdicts.count else { return entry }
        for i in verdicts.indices { intake.changes[i].verdict = verdicts[i] }
        guard entry.correction == nil, var capture = entry.capture, capture.state == .waiting else {
            entry.intake = intake
            return entry
        }
        let keep = verdicts.map { $0 == .misheard || $0 == .style }
        let target = FixIntake.keeping(keep, text: entry.text, target: capture.edited)
        guard keep.contains(true), target != entry.text else {
            capture.state = .dismissed
            entry.capture = capture
            entry.intake = nil
            return entry
        }
        let auto = trainUnreviewed && capture.mode == .readback && !verdicts.contains(.unclear)
            && !FixIntake.wordsOnlyAdded(from: entry.text, to: capture.edited)
            && !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        capture.edited = target
        if auto {
            capture.state = .auto
            entry.correction = target
        }
        entry.capture = capture
        entry.intake = Intake(of: target, changes: zip(intake.changes, keep).filter(\.1).map(\.0))
        return entry
    }

    /// A failed call that would fail the same way again (a refused request, an answer with no text):
    /// it counts a try. Offline, a timeout, a rate limit, a busy host: not.
    static func countsATry(_ error: Error) -> Bool {
        if let failure = error as? JudgeFailure { return !failure.transient }
        return !(error is URLError)
    }

    /// The model id as typed, trimmed; the default (Learn's teacher) when blank.
    static func modelID(_ model: String) -> String {
        let id = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? LearnController.teacherModel : id
    }

    /// Your judge: `judgeModel` on OpenRouter with your key, on a setup whose polish goes to the cloud.
    /// Nil (the judge can't run; the rules count changes as with the setting off) on a setup that
    /// polishes on this Mac, where your choice of local means nothing of this leaves it: Apple
    /// Intelligence got 37% of the bench's changes right (Nov 22) and isn't used. Nil without a key.
    static func backend(settings: AppSettings) -> FixJudgeBackend? {
        if settings.setup.polishesOnDevice { return nil }
        guard let key = settings.openRouterKey, !key.isEmpty else { return nil }
        return OpenRouterJudge(model: modelID(settings.judgeModel), apiKey: key)
    }
}

/// The cloud judge: up to 10 fixes a request through OpenRouter, so it names the app like every
/// other call. Thinking off (or lowest), temperature 0. The instructions come first and the terms
/// next, marked cacheable for models that need a breakpoint; whether a batch ever hits the cache is
/// unmeasured (batches are minutes apart, and the shared part is short).
struct OpenRouterJudge: FixJudgeBackend {
    let model: String
    let apiKey: String
    var session: URLSession = .shared

    func judge(_ items: [JudgeItem], terms: [String]) async throws -> JudgeAnswer {
        func ask(_ reasoning: [String: Any]?) async throws -> ([String: Any]?, Int) {
            let (data, status) = try await OpenRouter.send(request(items, terms: terms, reasoning: reasoning), session: session)
            return (OpenRouter.json(data), status)
        }
        var (json, status) = try await ask(nil)
        // A model that can't turn thinking off (the model is a setting): ask again at the lowest effort.
        if OpenRouter.content(json, status: status) == nil,
           OpenRouterPolish.refusesReasoningOff(PolishError.failed(OpenRouter.problem(json, status: status))) {
            (json, status) = try await ask(["effort": "minimal"])
        }
        guard let text = OpenRouter.content(json, status: status) else { throw JudgeFailure(json: json, status: status) }
        return JudgeAnswer(verdicts: FixJudge.parse(text, items: items), usage: OpenRouter.Usage(json))
    }

    func request(_ items: [JudgeItem], terms: [String], reasoning: [String: Any]? = nil) -> URLRequest {
        let (prefix, rest) = FixJudge.message(items, terms: terms)
        return OpenRouter.chat(model: model, system: FixJudge.instructions,
                               userContent: OpenRouter.content(caching: prefix, then: rest, model: model),
                               apiKey: apiKey, reasoning: reasoning)
    }
}
