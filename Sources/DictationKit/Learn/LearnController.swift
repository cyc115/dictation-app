import AppKit
import Combine
import SwiftUI

/// The Learn tile's state: whether a tune can start, the one running, its result, and Keep/Discard.
/// Reads Settings (the setup to tune), History (the corrections) and the learned prompts; forwards
/// their changes so one `@ObservedObject` is enough for the tile.
@MainActor
final class LearnController: ObservableObject {
    /// Corrections needed before the first tune.
    static let minimum = 10
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
    let general: [GeneralCase]
    /// The tuner for a setup and API key (nil: that setup can't be tuned). Tests inject fakes.
    var makeTuner: (DictationSetup, String) -> PromptTuner?
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
    /// What the running tune was started with.
    private var running: (setup: DictationSetup, cases: [TuneCase])?
    private var task: Task<Void, Never>?
    private var forwards: [AnyCancellable] = []

    init(settings: AppSettings, history: HistoryStore, store: LearnedPromptStore, general: [GeneralCase],
         makeTuner: ((DictationSetup, String) -> PromptTuner?)? = nil) {
        self.settings = settings
        self.history = history
        self.store = store
        self.general = general
        self.makeTuner = makeTuner ?? { Self.appTuner(setup: $0, apiKey: $1, general: general) }
        for object in [settings.objectWillChange.eraseToAnyPublisher(), history.objectWillChange.eraseToAnyPublisher(),
                       store.objectWillChange.eraseToAnyPublisher()] {
            forwards.append(object.sink { [weak self] _ in self?.objectWillChange.send() })
        }
    }

    /// The setup's polish model as student, `teacherModel` (thinking) as teacher.
    nonisolated static func appTuner(setup: DictationSetup, apiKey: String, general: [GeneralCase]) -> PromptTuner? {
        guard case .openRouter(let id, let providers) = ModelSpec(setup.polish) else { return nil }
        let student: PromptTuner.Student = { OpenRouterPolish(model: id, apiKey: apiKey, instructions: $0, wrap: setup.wrap, provider: providers) }
        let teacher: PromptTuner.Teacher = { system, user in
            try await OpenRouterPolish(model: teacherModel, apiKey: apiKey, instructions: system, wrap: false, reasoning: ["effort": "medium"]).polish(user)
        }
        return PromptTuner(student: student, teacher: teacher, general: general)
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
        if corrections.allSatisfy({ store.isLearned($0.id, setup: setup.id) }) { return .allLearned(count: count) }
        return .ready(count: count)
    }

    /// The current prompt as measured (the tune's own baseline while it runs, else the stored one).
    var measured: PromptMeasurement? {
        if case .measured(let m)? = phase, let running {
            return PromptMeasurement(setup: running.setup.id, prompt: running.setup.prompt, date: started, mine: m.mine, general: m.general, corrections: running.cases.count)
        }
        if phase != nil, let baseline { return baseline }
        return store.measurement(setup: setup.id, prompt: setup.prompt)
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
        guard case .ready = gate, let key = settings.openRouterKey, let tuner = makeTuner(setup, key) else { return }
        let setup = setup
        let cases = corrections.map { TuneCase(id: $0.id, input: $0.input, wanted: $0.correction ?? $0.text, learned: store.isLearned($0.id, setup: setup.id)) }
        running = (setup, cases)
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
                            self.baseline = PromptMeasurement(setup: setup.id, prompt: setup.prompt, date: self.now(), mine: m.mine, general: m.general, corrections: cases.count)
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
    /// a cloud setup, a key, no version learned on it and no stored measurement). Called when the tile appears.
    func measureIfNeeded() {
        switch gate {
        case .ready, .allLearned: break
        default: return
        }
        guard store.scored(for: setup.id) == nil, store.measurement(setup: setup.id, prompt: setup.prompt) == nil,
              let key = settings.openRouterKey, let tuner = makeTuner(setup, key) else { return }
        let setup = setup
        let cases = corrections.map { TuneCase(id: $0.id, input: $0.input, wanted: $0.correction ?? $0.text) }
        measuring = true
        error = nil; notice = nil
        task = Task { @MainActor [weak self] in
            defer { self?.measuring = false }
            do {
                let m = try await tuner.measure(cases: cases, prompt: setup.promptText)
                self?.store.record(PromptMeasurement(setup: setup.id, prompt: setup.prompt, date: self?.now() ?? Date(),
                                                     mine: m.mine, general: m.general, corrections: cases.count))
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
        if measuring { return "Measuring prompt \(setup.prompt) on your \(corrections.count) corrections and the general test set" }
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
