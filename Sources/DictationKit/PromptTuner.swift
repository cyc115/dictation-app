import Foundation

/// One correction as the tuner sees it: what polish was given, what you wanted, and whether an
/// earlier learned prompt already gets it right (then it's scored but not shown to the teacher).
struct TuneCase: Identifiable, Equatable {
    let id: UUID
    let input: String
    let wanted: String
    var learned = false
}

/// How the teacher may change the prompt. Three candidates per fold, one per lens.
enum Lens: String, CaseIterable, Codable, Identifiable {
    case rules, examples, both
    var id: String { rawValue }

    /// "Candidate A".
    var title: String { "Candidate " + ["A", "B", "C"][Lens.allCases.firstIndex(of: self)!] }

    var blurb: String {
        switch self {
        case .rules: return "stricter rules"
        case .examples: return "your corrections as examples"
        case .both: return "both, shorter"
        }
    }

    var instruction: String {
        switch self {
        case .rules:
            return "Change only the rules: tighten, add or reorder cleanup rules so the model would have written the wanted text. Keep the examples exactly as they are."
        case .examples:
            return "Change only the examples: replace them with up to three short input → output pairs drawn from these corrections (shorten each to one sentence; keep the speaker's languages). Keep the rules exactly as they are."
        case .both:
            return "Change the rules and the examples as needed, and keep the whole prompt under 400 words."
        }
    }
}

/// Where a tune is, for the Learn tile.
enum TunePhase: Equatable {
    case reading
    /// Fold `fold` of `of` running; each lens's score over the cases held out so far.
    case racing(fold: Int, of: Int, scores: [Lens: Double])
    case writing
    case checking
    case done
}

enum Verdict: String, Codable, Equatable {
    case pass
    /// Your score didn't go up by a point.
    case noImprovement
    /// The general set lost more than `PromptTuner.maxGeneralDrop` points.
    case generalDropped
}

/// What a tune showed: a teacher input is a fold's training cases; the held-out ones scored it.
struct TuneTrace: Equatable {
    let fold: Int
    let lens: Lens
    let shown: [UUID]
    let heldOut: [UUID]
}

struct TuneResult: Equatable {
    var prompt: String
    var lens: Lens
    /// 100 × (1 − mean error) over every correction, cross-validated (new) and with the current prompt (before).
    var mine: Double
    var mineBefore: Double
    /// Pass rate on the general set, 0–100.
    var general: Double
    var generalBefore: Double
    /// Each correction's held-out error with the winning lens, and with the current prompt.
    var errors: [UUID: Double]
    var errorsBefore: [UUID: Double]
    var lensScores: [Lens: Double]
    /// Rough token count of the new prompt.
    var tokens: Int
    var verdict: Verdict
    var trace: [TuneTrace] = []
}

enum TuneError: LocalizedError, Equatable {
    case nothingToLearn
    case teacher(String)
    case student(String)
    case noPrompt

    var errorDescription: String? {
        switch self {
        case .nothingToLearn: return "Every correction is already learned."
        case .teacher(let m): return "The teacher model failed: \(m)"
        case .student(let m): return "Polishing failed: \(m)"
        case .noPrompt: return "The teacher model didn't return a prompt."
        }
    }
}

/// Tunes a polish prompt from corrections. A *teacher* (a strong model) rewrites the prompt from
/// the corrections it may see; the *student* (the setup's own polish model) runs each candidate,
/// scored with `PolishScore.errorRate` against what you wanted.
///
/// The score is honest: K-fold. The corrections are split into folds; for each fold the teacher
/// sees only the other folds and the candidate is scored on this one, so no correction scores a
/// prompt that was written from it. The lens with the best cross-validated score wins; the final
/// prompt is that lens written from every correction, and its score is the lens's cross-validated
/// one. The general test set (bench/polish_cases*.json, the bench pass rule) guards against a prompt
/// that learned your corrections and forgot everything else.
final class PromptTuner {
    typealias Student = (_ instructions: String) -> PolishBackend
    typealias Teacher = (_ system: String, _ user: String) async throws -> String

    /// A correction is learned when its held-out error is at most this.
    static let learnedError = 0.15
    /// Keep needs your score up by this much…
    static let minGain = 1.0
    /// …and the general pass rate down by at most this much.
    static let maxGeneralDrop = 2.0

    let student: Student
    let teacher: Teacher
    let general: [GeneralCase]
    let folds: Int
    let repeats: Int
    let seed: UInt64
    let concurrency: Int

    init(student: @escaping Student, teacher: @escaping Teacher, general: [GeneralCase],
         folds: Int = 5, repeats: Int = 2, seed: UInt64 = 1, concurrency: Int = 6) {
        self.student = student
        self.teacher = teacher
        self.general = general
        self.folds = folds
        self.repeats = repeats
        self.seed = seed
        self.concurrency = concurrency
    }

    func tune(cases: [TuneCase], prompt: String, progress: @escaping (TunePhase) -> Void) async throws -> TuneResult {
        let teachable = cases.filter { !$0.learned }
        guard !teachable.isEmpty else { throw TuneError.nothingToLearn }
        progress(.reading)

        // Baseline: the current prompt on every correction (its outputs are what the teacher is shown).
        let baseline = try await errors(prompt: prompt, cases: cases)
        let folded = Self.fold(cases, into: min(folds, teachable.count), seed: seed)
        var lensErrors: [Lens: [UUID: Double]] = [:]
        var trace: [TuneTrace] = []
        for (f, heldOut) in folded.enumerated() {
            try Task.checkCancellation()
            progress(.racing(fold: f + 1, of: folded.count, scores: Self.scores(lensErrors)))
            let shown = cases.filter { c in !c.learned && !heldOut.contains { $0.id == c.id } }
            let candidates = try await withThrowingTaskGroup(of: (Lens, String?).self) { group -> [Lens: String?] in
                for lens in Lens.allCases {
                    group.addTask { (lens, try await self.candidate(prompt: prompt, lens: lens, examples: shown, baseline: baseline)) }
                }
                var found: [Lens: String?] = [:]
                for try await (lens, text) in group { found[lens] = text }
                return found
            }
            for lens in Lens.allCases {
                let scored: [UUID: Double]
                if let text = candidates[lens] ?? nil {
                    scored = try await errors(prompt: text, cases: heldOut).mapValues(\.error)
                } else {
                    scored = Dictionary(uniqueKeysWithValues: heldOut.map { ($0.id, baseline[$0.id]!.error) })  // a failed candidate scores as the current prompt
                }
                lensErrors[lens, default: [:]].merge(scored) { _, new in new }
                trace.append(TuneTrace(fold: f + 1, lens: lens, shown: shown.map(\.id), heldOut: heldOut.map(\.id)))
            }
        }
        let scores = Self.scores(lensErrors)
        let winner = Lens.allCases.max { scores[$0]! < scores[$1]! }!
        progress(.racing(fold: folded.count, of: folded.count, scores: scores))

        try Task.checkCancellation()
        progress(.writing)
        guard let final = try await candidate(prompt: prompt, lens: winner, examples: teachable, baseline: baseline) else {
            throw TuneError.noPrompt
        }

        try Task.checkCancellation()
        progress(.checking)
        async let before = passRate(prompt: prompt)
        async let after = passRate(prompt: final)
        let (generalBefore, generalNow) = try await (before, after)

        let mine = scores[winner]!, mineBefore = Self.score(baseline.mapValues(\.error))
        let verdict: Verdict = mine < mineBefore + Self.minGain ? .noImprovement
            : generalNow < generalBefore - Self.maxGeneralDrop ? .generalDropped : .pass
        progress(.done)
        return TuneResult(prompt: final, lens: winner, mine: mine, mineBefore: mineBefore,
                          general: generalNow, generalBefore: generalBefore,
                          errors: lensErrors[winner]!, errorsBefore: baseline.mapValues(\.error),
                          lensScores: scores, tokens: Self.tokenEstimate(final), verdict: verdict, trace: trace)
    }

    // MARK: Folds and scores

    /// `k` folds: the unlearned cases dealt round-robin first (so every fold's training set has some
    /// to learn from), then the learned ones. Shuffled first with a fixed seed.
    static func fold(_ cases: [TuneCase], into k: Int, seed: UInt64) -> [[TuneCase]] {
        var rng = SeededRandom(seed)
        let shuffled = cases.shuffled(using: &rng)
        var folds = [[TuneCase]](repeating: [], count: max(1, k))
        var n = 0
        for c in shuffled.filter({ !$0.learned }) + shuffled.filter(\.learned) {
            folds[n % folds.count].append(c)
            n += 1
        }
        return folds.filter { !$0.isEmpty }
    }

    /// 100 × (1 − mean error); 100 with nothing scored.
    static func score(_ errors: [UUID: Double]) -> Double {
        errors.isEmpty ? 100 : 100 * (1 - errors.values.reduce(0, +) / Double(errors.count))
    }

    static func scores(_ lensErrors: [Lens: [UUID: Double]]) -> [Lens: Double] {
        Dictionary(uniqueKeysWithValues: Lens.allCases.map { ($0, score(lensErrors[$0] ?? [:])) })
    }

    static func tokenEstimate(_ prompt: String) -> Int { Int(Double(PolishScore.tokens(prompt).count) * 1.3) }

    // MARK: Student

    struct Scored: Equatable {
        var error: Double
        var output: String
    }

    /// Each case polished `repeats` times with `prompt`; the mean error, and the first output.
    func errors(prompt: String, cases: [TuneCase]) async throws -> [UUID: Scored] {
        let backend = student(prompt)
        let jobs = cases.flatMap { c in (0..<repeats).map { (c, $0) } }
        let results = try await Self.run(jobs, concurrency: concurrency) { (c, _) -> (UUID, Double, String) in
            let output: String
            do { output = try await backend.polish(c.input) } catch { throw TuneError.student(error.localizedDescription) }
            return (c.id, PolishScore.errorRate(reference: c.wanted, hypothesis: output), output)
        }
        var scored: [UUID: Scored] = [:], counts: [UUID: Int] = [:]
        for (id, error, output) in results {
            scored[id, default: Scored(error: 0, output: output)].error += error
            counts[id, default: 0] += 1
        }
        for (id, n) in counts { scored[id]!.error /= Double(n) }
        return scored
    }

    /// The share of the general set `prompt` passes, 0–100 (one run each; 100 with no set).
    func passRate(prompt: String) async throws -> Double {
        guard !general.isEmpty else { return 100 }
        let backend = student(prompt)
        let passed = try await Self.run(general, concurrency: concurrency) { c -> Bool in
            let output: String
            do { output = try await backend.polish(c.raw) } catch { throw TuneError.student(error.localizedDescription) }
            return PolishScore.check(c, output: output).passed
        }
        return 100 * Double(passed.filter { $0 }.count) / Double(general.count)
    }

    /// `work` on every job, at most `concurrency` at a time; results in job order.
    static func run<Job, Out>(_ jobs: [Job], concurrency: Int, _ work: @escaping (Job) async throws -> Out) async throws -> [Out] {
        try await withThrowingTaskGroup(of: (Int, Out).self) { group in
            var next = 0
            func add() { let i = next; next += 1; group.addTask { (i, try await work(jobs[i])) } }
            while next < min(concurrency, jobs.count) { add() }
            var out = [Out?](repeating: nil, count: jobs.count)
            for try await (i, result) in group {
                out[i] = result
                if next < jobs.count { add() }
            }
            return out.map { $0! }
        }
    }

    // MARK: Teacher

    static let teacherSystem = """
        You improve the system prompt of a dictation cleanup model: a small, fast model that turns a speech \
        recognizer's transcript into the text the speaker meant to write. You are given the current prompt \
        and corrections: transcripts, what the model wrote with the current prompt, and what the speaker wanted.

        Rewrite the prompt so the model would write what was wanted, for these corrections and for \
        dictations like them. Rules must be general, not fixes for one dictation; a term the recognizer \
        mishears more than once may be listed by name. Keep the prompt's structure (introduction, the \
        Cleanup list, the "Otherwise keep…" paragraph, Examples, the final output line) and its rule that \
        the transcript is never a request. Keep every language the prompt handles. Never mention the \
        speaker or these corrections.

        Answer with the complete new prompt inside <prompt></prompt> tags and nothing else.
        """

    static func teacherMessage(prompt: String, lens: Lens, examples: [(input: String, wrote: String, wanted: String)]) -> String {
        var text = "Current prompt:\n<current>\n\(prompt)\n</current>\n\nCorrections:\n"
        for (n, e) in examples.enumerated() {
            text += "\n### Correction \(n + 1)\nTranscript:\n\(e.input)\nModel wrote:\n\(e.wrote)\nWanted:\n\(e.wanted)\n"
        }
        return text + "\nYour task: \(lens.instruction)"
    }

    /// The prompt in the teacher's answer; nil if it gave none.
    static func extractPrompt(_ answer: String) -> String? {
        guard let open = answer.range(of: "<prompt>"), let close = answer.range(of: "</prompt>", options: .backwards),
              open.upperBound <= close.lowerBound else { return nil }
        let text = answer[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func candidate(prompt: String, lens: Lens, examples: [TuneCase], baseline: [UUID: Scored]) async throws -> String? {
        let shown = examples.map { (input: $0.input, wrote: baseline[$0.id]?.output ?? "", wanted: $0.wanted) }
        let answer: String
        do { answer = try await teacher(Self.teacherSystem, Self.teacherMessage(prompt: prompt, lens: lens, examples: shown)) }
        catch { throw TuneError.teacher(error.localizedDescription) }
        return Self.extractPrompt(answer)
    }
}

/// A small deterministic generator (SplitMix64), so folds are the same on every run.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
