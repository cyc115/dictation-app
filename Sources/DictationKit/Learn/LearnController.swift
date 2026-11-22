import AppKit
import Combine
import SwiftUI

/// The Learn tile's state: whether a tune can start, the one running, its result, and Keep/Discard.
/// Reads Settings (the setup to tune), History (the corrections), the learned prompts and your
/// vocabulary; forwards their changes so one `@ObservedObject` is enough for the tile.
///
/// A tune runs with your vocabulary as a dictation does (replaced transcripts, the student told the
/// terms, its answers replaced), one snapshot for the whole tune, but the prompt the teacher rewrites
/// never holds the list: it would copy it into the kept prompt.
@MainActor
final class LearnController: ObservableObject {
    /// Corrections needed before the first tune.
    static let minimum = 10
    /// Fixes a tune takes at most, newest first: it makes 10 teacher calls that each carry most
    /// unlearned fixes, and about 8 student calls per fix.
    static let maxFixes = 60
    /// The teacher: Claude Sonnet 5.5, thinking at medium effort. In the Oct 14 bake-off
    /// (bench/results/polish/README.md) it tuned as well as any teacher tried (+7 points on the
    /// corrections, general set held) in 45 s, against 94 s for GPT-6.1 Sol and 6–7 minutes for Qwen3.8
    /// Max; same list price as the Sol Pro that Corrections' suggestions use, a fraction of its reasoning spend.
    static let teacherModel = "anthropic/claude-sonnet-5.5"

    enum Gate: Equatable {
        case cloudOnly
        case noKey
        case needMore(have: Int)
        case ready(count: Int)
        case allLearned(count: Int)
        /// The current prompt is being measured (no teacher; the tile opened with nothing to show).
        case measuring
        case running
        case done
    }

    /// A correction's error before and after, for its card.
    struct Fit: Equatable {
        var from: String
        var to: String
        var before: Double
        var now: Double
        var learned: Bool { now <= PromptTuner.learnedError }
    }

    let settings: AppSettings
    let history: HistoryStore
    let store: LearnedPromptStore
    let vocabulary: VocabularyStore
    let general: [GeneralCase]
    /// The tuner for a setup, API key and vocabulary (nil: that setup can't be tuned). Tests inject fakes.
    var makeTuner: (DictationSetup, String, Vocabulary) -> PromptTuner?
    var now: () -> Date = Date.init

    @Published private(set) var phase: TunePhase?
    @Published private(set) var result: TuneResult?
    @Published private(set) var error: String?
    /// One line after Keep/Discard ("Cloud Flash now polishes with prompt v5.").
    @Published private(set) var notice: String?
    /// Goes up when a tune starts reading the corrections (the cards' sweep follows it).
    @Published private(set) var sweep = 0
    /// Seconds since the tune started (the status line's stopwatch).
    @Published private(set) var elapsed = 0
    @Published private(set) var measuring = false
    /// The running tune's baseline, once it has measured it.
    private var baseline: PromptMeasurement?
    private var started = Date()
    private var clock: Timer?
    /// What the running tune was started with (`vocabulary`: its snapshot's fingerprint).
    private var running: (setup: DictationSetup, cases: [TuneCase], vocabulary: String?)?
    private var task: Task<Void, Never>?
    private var forwards: [AnyCancellable] = []

    init(settings: AppSettings, history: HistoryStore, store: LearnedPromptStore, vocabulary: VocabularyStore,
         general: [GeneralCase], makeTuner: ((DictationSetup, String, Vocabulary) -> PromptTuner?)? = nil) {
        self.settings = settings
        self.history = history
        self.store = store
        self.vocabulary = vocabulary
        self.general = general
        self.makeTuner = makeTuner ?? { Self.appTuner(setup: $0, apiKey: $1, general: general, vocabulary: $2) }
        for object in [settings.objectWillChange.eraseToAnyPublisher(), history.objectWillChange.eraseToAnyPublisher(),
                       store.objectWillChange.eraseToAnyPublisher(), vocabulary.objectWillChange.eraseToAnyPublisher()] {
            forwards.append(object.sink { [weak self] _ in self?.objectWillChange.send() })
        }
    }

    /// The setup's polish model as student (with the vocabulary), `teacherModel` (thinking) as teacher.
    nonisolated static func appTuner(setup: DictationSetup, apiKey: String, general: [GeneralCase], vocabulary: Vocabulary) -> PromptTuner? {
        guard case .openRouter(let id, let providers) = ModelSpec(setup.polish) else { return nil }
        let student = Self.student(vocabulary: vocabulary) {
            OpenRouterPolish(model: id, apiKey: apiKey, instructions: $0, wrap: setup.wrap, provider: providers)
        }
        let teacher: PromptTuner.Teacher = { request in
            try await PromptTuner.openRouterTeacher(model: teacherModel, apiKey: apiKey, reasoning: ["effort": "medium"])(request)
        }
        return PromptTuner(student: student, teacher: teacher, general: general)
    }

    /// The student for a candidate prompt: `model` told the prompt plus the terms block
    /// (`Vocabulary.instructions`), its input and answer replaced (`VocabularyPolish`). With no terms,
    /// `model` with the prompt alone.
    nonisolated static func student(vocabulary: Vocabulary, model: @escaping (String) -> PolishBackend) -> PromptTuner.Student {
        { prompt in VocabularyPolish.wrap(model(vocabulary.instructions(prompt)), vocabulary) }
    }

    /// The vocabulary a tune would run with now (from memory; `learn()` re-reads the file first).
    private var terms: Vocabulary { vocabulary.vocabulary(enabled: settings.vocabularyEnabled) }

    /// The fixes a tune takes: the newest `maxFixes` corrections. The gate asks whether these are
    /// learned, so past the cap it reaches "all learned" rather than offering a tune with nothing to learn.
    private var tuneFixes: [HistoryEntry] { Array(corrections.sorted { $0.date > $1.date }.prefix(Self.maxFixes)) }

    /// What a tune is given: `tuneFixes`, each transcript with the vocabulary replaced (what the
    /// student would be given in a dictation).
    private func tuneCases(_ terms: Vocabulary) -> [TuneCase] {
        tuneFixes.map {
            TuneCase(id: $0.id, input: terms.apply($0.input).text, wanted: $0.correction ?? $0.text,
                     learned: store.isLearned($0.id, setup: setup.id))
        }
    }

    var setup: DictationSetup { settings.setup }
    var corrections: [HistoryEntry] { history.corrections }

    var gate: Gate {
        if result != nil { return .done }
        if measuring { return .measuring }
        if phase != nil { return .running }
        if setup.polishesOnDevice { return .cloudOnly }
        if !settings.hasOpenRouterKey { return .noKey }
        let count = corrections.count
        if count < Self.minimum { return .needMore(have: count) }
        if tuneFixes.allSatisfy({ store.isLearned($0.id, setup: setup.id) }) { return .allLearned(count: count) }
        return .ready(count: count)
    }

    /// The current prompt as measured (the tune's own baseline while it runs, else the stored one).
    var measured: PromptMeasurement? {
        if case .measured(let m)? = phase, let running {
            return PromptMeasurement(setup: running.setup.id, prompt: running.setup.prompt, date: started, mine: m.mine, general: m.general,
                                     corrections: running.cases.count, vocabulary: running.vocabulary)
        }
        if phase != nil, let baseline { return baseline }
        return store.measurement(setup: setup.id, prompt: setup.prompt, vocabulary: vocabulary.fingerprint(enabled: settings.vocabularyEnabled))
    }

    /// The scores on the rings: the result's, else the active learned prompt's (learned on this setup),
    /// else the current prompt's measurement; nil before any.
    var mine: Double? { result?.mine ?? store.scored(for: setup.id)?.score.mine ?? measured?.mine }
    var generalScore: Double? { result?.general ?? store.scored(for: setup.id)?.score.general ?? measured?.general }
    var mineBefore: Double? { result?.mineBefore ?? store.scored(for: setup.id)?.score.mineBefore }
    var generalBefore: Double? { result?.generalBefore ?? store.scored(for: setup.id)?.score.generalBefore }

    /// What the next kept prompt will be called.
    var nextVersion: String { store.nextVersion }

    /// How a correction fares: with the result not yet kept, else with the setup's active learned prompt.
    func fit(for id: UUID) -> Fit? {
        if let result, let before = result.errorsBefore[id], let now = result.errors[id], let running {
            return Fit(from: running.setup.prompt, to: nextVersion, before: before, now: now)
        }
        guard let learned = store.scored(for: setup.id), let errors = store.errors(for: id, setup: setup.id) else { return nil }
        return Fit(from: learned.basedOn, to: learned.version, before: errors.before, now: errors.now)
    }

    func learn() {
        guard case .ready = gate, let key = settings.openRouterKey else { return }
        vocabulary.reloadIfChanged()
        let terms = terms  // one snapshot for the whole tune: a term added meanwhile can't shift the baseline
        guard let tuner = makeTuner(setup, key, terms) else { return }
        let setup = setup, fingerprint = terms.fingerprint
        let cases = tuneCases(terms)
        running = (setup, cases, fingerprint)
        error = nil; result = nil; notice = nil
        phase = .reading
        sweep += 1
        started = now(); elapsed = 0
        clock?.invalidate()
        clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in guard let self else { return }; self.elapsed = Int(self.now().timeIntervalSince(self.started)) }
        }
        baseline = nil
        task = Task { @MainActor [weak self] in
            defer { self?.clock?.invalidate(); self?.clock = nil }
            do {
                let result = try await tuner.tune(cases: cases, prompt: setup.promptText) { phase in
                    Task { @MainActor in
                        guard let self else { return }
                        if case .measured(let m) = phase {
                            self.baseline = PromptMeasurement(setup: setup.id, prompt: setup.prompt, date: self.now(), mine: m.mine, general: m.general,
                                                              corrections: cases.count, vocabulary: fingerprint)
                            self.store.record(self.baseline!)
                        }
                        self.phase = phase
                    }
                }
                self?.phase = .done
                self?.result = result
            } catch is CancellationError {
                self?.phase = nil
            } catch {
                self?.error = error.localizedDescription
                self?.phase = nil
            }
        }
    }

    /// Measures the current prompt when the tile has nothing to show for it yet (enough corrections,
    /// a cloud setup, a key, no version learned on it and no measurement with this vocabulary).
    /// Called when the tile appears.
    func measureIfNeeded() {
        switch gate {
        case .ready, .allLearned: break
        default: return
        }
        vocabulary.reloadIfChanged()
        let terms = terms, fingerprint = terms.fingerprint
        guard store.scored(for: setup.id) == nil, store.measurement(setup: setup.id, prompt: setup.prompt, vocabulary: fingerprint) == nil,
              let key = settings.openRouterKey, let tuner = makeTuner(setup, key, terms) else { return }
        let setup = setup
        let cases = tuneCases(terms).map { TuneCase(id: $0.id, input: $0.input, wanted: $0.wanted) }
        measuring = true
        error = nil; notice = nil
        task = Task { @MainActor [weak self] in
            defer { self?.measuring = false }
            do {
                let m = try await tuner.measure(cases: cases, prompt: setup.promptText)
                self?.store.record(PromptMeasurement(setup: setup.id, prompt: setup.prompt, date: self?.now() ?? Date(),
                                                     mine: m.mine, general: m.general, corrections: cases.count, vocabulary: fingerprint))
            } catch is CancellationError {
            } catch {
                self?.error = error.localizedDescription
            }
        }
    }

    /// Keeps the result as the next prompt version and makes the setup polish with it.
    func keep() {
        guard let result, result.verdict == .pass, let running else { return }
        let version = nextVersion
        store.keep(LearnedPrompt(
            version: version, setup: running.setup.id, basedOn: running.setup.prompt, date: now(), text: result.prompt,
            lens: result.lens, corrections: running.cases.count, tokens: result.tokens,
            score: .init(mine: result.mine, mineBefore: result.mineBefore, general: result.general, generalBefore: result.generalBefore),
            errors: Dictionary(uniqueKeysWithValues: result.errors.map { ($0.key.uuidString, $0.value) }),
            errorsBefore: Dictionary(uniqueKeysWithValues: result.errorsBefore.map { ($0.key.uuidString, $0.value) })))
        self.result = nil
        phase = nil
        self.running = nil
        notice = "\(running.setup.title) now polishes with prompt \(version). Older versions are in Settings › Model."
    }

    func discard() {
        task?.cancel()
        result = nil
        phase = nil
        running = nil
        notice = nil
    }

    /// The status line under the scores.
    var status: String? {
        if let error { return error }
        if let notice { return notice }
        if measuring { return "Measuring prompt \(setup.prompt) on your \(min(corrections.count, Self.maxFixes)) corrections and the general test set" }
        guard let phase, let running else { return nil }
        switch phase {
        case .reading: return "Measuring prompt \(running.setup.prompt) on your \(running.cases.count) corrections"
        case .measured: return "Reading your \(running.cases.count) corrections"
        case .racing(let progress):
            let scored = progress.values.map(\.scored).reduce(0, +), of = progress.values.map(\.of).reduce(0, +)
            return "Trying \(Lens.allCases.count) prompts on \(running.setup.title) · \(scored) of \(of) scored · \(elapsed) s"
        case .writing: return "Writing the prompt from every correction"
        case .checking: return "Checking it on the general test set"
        case .done:
            guard let result else { return nil }
            let within = result.errors.values.filter { $0 <= PromptTuner.learnedError }.count
            let before = result.errorsBefore.values.filter { $0 <= PromptTuner.learnedError }.count
            let general = result.general >= result.generalBefore
                ? "General set \(result.general == result.generalBefore ? "held at" : "up to") \(Int(result.general.rounded()))%."
                : "General set dropped \(Int(result.generalBefore.rounded()))% → \(Int(result.general.rounded()))%."
            return "\(nextVersion): \(within) of \(result.errors.count) corrections now within \(Int(PromptTuner.learnedError * 100))% of what you wanted (\(running.setup.prompt): \(before)). \(general)"
        }
    }

    /// Why the result can't be kept, when it can't.
    var verdictText: String? {
        guard let result else { return nil }
        switch result.verdict {
        case .pass: return nil
        case .noImprovement: return "Not kept: your score didn't improve."
        case .generalDropped: return "Not kept: the general set dropped more than \(Int(PromptTuner.maxGeneralDrop)) points."
        case .actedOnDictation:
            return "Not kept: it answered or carried out \(result.acted) test dictation\(result.acted == 1 ? "" : "s") instead of cleaning "
                + "\(result.acted == 1 ? "it" : "them") up (\(running?.setup.prompt ?? "before"): \(result.actedBefore)). A prompt must never act on what you dictate."
        }
    }
}
