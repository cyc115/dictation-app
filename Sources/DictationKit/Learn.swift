import AppKit
import Combine
import SwiftUI

// MARK: - Controller

/// The Learn tile's state: whether a tune can start, the one running, its result, and Keep/Discard.
/// Reads Settings (the setup to tune), History (the corrections) and the learned prompts; forwards
/// their changes so one `@ObservedObject` is enough for the tile.
@MainActor
final class LearnController: ObservableObject {
    static let shared = LearnController(settings: .shared, history: .shared, store: .shared, general: GeneralCase.app ?? [])

    /// Corrections needed before the first tune.
    static let minimum = 10
    /// The teacher: the strongest polish model benchmarked, thinking (Corrections' suggestions use it too).
    static let teacherModel = ModelSpec(CorrectionSuggester.model)!.openRouterID!

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

    /// The setup's polish model as student, GPT-6.1 Sol Pro (thinking) as teacher.
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

    /// The scores on the rings: the result's, else the active learned prompt's, else the current
    /// prompt's measurement; nil before any.
    var mine: Double? { result?.mine ?? store.active(for: setup.id)?.score.mine ?? measured?.mine }
    var generalScore: Double? { result?.general ?? store.active(for: setup.id)?.score.general ?? measured?.general }
    var mineBefore: Double? { result?.mineBefore ?? store.active(for: setup.id)?.score.mineBefore }
    var generalBefore: Double? { result?.generalBefore ?? store.active(for: setup.id)?.score.generalBefore }

    /// What the next kept prompt will be called.
    var nextVersion: String { store.nextVersion }

    /// How a correction fares: with the result not yet kept, else with the setup's active learned prompt.
    func fit(for id: UUID) -> Fit? {
        if let result, let before = result.errorsBefore[id], let now = result.errors[id], let running {
            return Fit(from: running.setup.prompt, to: nextVersion, before: before, now: now)
        }
        guard let learned = store.active(for: setup.id), let errors = store.errors(for: id, setup: setup.id) else { return nil }
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
    /// a cloud setup, a key, no learned version and no stored measurement). Called when the tile appears.
    func measureIfNeeded() {
        switch gate {
        case .ready, .allLearned: break
        default: return
        }
        guard store.active(for: setup.id) == nil, store.measurement(setup: setup.id, prompt: setup.prompt) == nil,
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
        }
    }
}

// MARK: - Tile

/// The Learn tile at the top of Corrections: your score and the general set's, the Learn button,
/// and, while a tune runs, the candidates racing, what changed in the prompt, and Keep/Discard.
struct LearnView: View {
    @ObservedObject var controller: LearnController
    @Environment(\.dateContext) private var dates
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let good = Color(nsColor: .systemGreen)
    static let learning = [Color(nsColor: .systemBlue), Color(nsColor: .systemPurple), Color(nsColor: .systemOrange)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            scores
            if let status = controller.status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("learn.status")
                    .transition(.opacity)
            }
            if let phase = controller.phase, phase != .reading, !isMeasured(phase) {
                candidates(phase)
            }
            if let result = controller.result {
                diff(result)
                resultRow(result)
            }
        }
        .padding(16)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(reduceMotion ? nil : .spring(duration: 0.5), value: controller.phase)
        .animation(reduceMotion ? nil : .spring(duration: 0.5), value: controller.result)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("learn.tile")
        .onAppear { controller.measureIfNeeded() }
        .onChange(of: controller.setup.id) { controller.measureIfNeeded() }
    }

    /// One card: the two scores on a grid, the Learn button (or why it can't run) at the trailing edge.
    private var scores: some View {
        HStack(alignment: .center, spacing: 16) {
            ScoreRing(value: controller.mine, before: controller.mineBefore, up: controller.result != nil,
                      label: "Your corrections · \(controller.setup.title)", id: "learn.score.mine", deltaAsHeld: false)
                .frame(minWidth: 230, alignment: .leading)
            ScoreRing(value: controller.generalScore, before: controller.generalBefore, up: false,
                      label: "General test set · guard", id: "learn.score.general", deltaAsHeld: true)
                .frame(minWidth: 230, alignment: .leading)
            Spacer(minLength: 12)
            action
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator))
    }

    @ViewBuilder private var action: some View {
        switch controller.gate {
        case .ready:
            LearnButton(title: "Learn", busy: false) { controller.learn() }
        case .running:
            LearnButton(title: "Learning…", busy: true) {}
        case .measuring:
            LearnButton(title: "Measuring…", busy: true) {}
        case .done:
            LearnButton(title: "Learned", busy: false, disabled: true) {}
        case .allLearned:
            VStack(alignment: .trailing, spacing: 4) {
                LearnButton(title: "Learned", busy: false, disabled: true) {}
                Text("Every correction is learned. Correct more to go on.").font(.caption).foregroundStyle(.secondary)
            }
        case .needMore(let have):
            VStack(alignment: .trailing, spacing: 6) {
                Text("Correct \(LearnController.minimum) dictations to start learning · \(have) of \(LearnController.minimum)")
                    .font(.caption).foregroundStyle(.secondary)
                ProgressView(value: Double(have), total: Double(LearnController.minimum))
                    .progressViewStyle(.linear)
                    .frame(width: 140)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("learn.gate")
        case .cloudOnly:
            Text("Learning tunes the cloud setups' prompt. Choose Cloud Flash or Cloud Big in Settings › Model.")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: 200).multilineTextAlignment(.trailing)
                .accessibilityIdentifier("learn.gate")
        case .noKey:
            Text("Add the cloud API key in Settings to learn from your corrections.")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: 200).multilineTextAlignment(.trailing)
                .accessibilityIdentifier("learn.gate")
        }
    }

    private func isMeasured(_ phase: TunePhase) -> Bool { if case .measured = phase { return true } else { return false } }

    private func candidates(_ phase: TunePhase) -> some View {
        let winner = controller.result?.lens
        return VStack(spacing: 8) {
            ForEach(Lens.allCases) { lens in
                let row: (score: Double?, progress: Double, writing: Bool, stage: String?) = {
                    if case .racing(let all) = phase, let p = all[lens] {
                        return (p.score, Double(p.scored) / Double(max(1, p.of)), p.writing,
                                p.scored == p.of ? nil : p.scored == 0 ? "writing…" : "scoring \(p.scored) of \(p.of)")
                    }
                    return (controller.result?.lensScores[lens], 1, false, nil)
                }()
                CandidateRow(lens: lens, score: row.score, progress: row.progress, writing: row.writing, stage: row.stage,
                             state: winner == nil ? .running : winner == lens ? .won : .lost)
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func diff(_ result: TuneResult) -> some View {
        let hunks = PromptDiff.hunks(old: controller.setup.promptText, new: result.prompt)
        return VStack(alignment: .leading, spacing: 6) {
            Text("WHAT CHANGED IN THE PROMPT").font(.caption.weight(.semibold)).foregroundStyle(.secondary).kerning(0.5)
            // A rewrite from top to bottom scrolls instead of pushing the cards away.
            if hunks.reduce(0, { $0 + $1.lines.count }) > 14 {
                ScrollView { hunkList(hunks) }.frame(height: 260)
            } else {
                hunkList(hunks)
            }
            if hunks.isEmpty {
                Text("Nothing: the prompt came back unchanged.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("learn.diff")
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func hunkList(_ hunks: [PromptDiff.Hunk]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(hunks) { hunk in
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                        Text(line.text)
                            .font(.caption.monospaced())
                            .strikethrough(line.kind == .removed, color: Color(nsColor: .systemRed))
                            .foregroundStyle(line.kind == .context ? AnyShapeStyle(.tertiary) : line.kind == .removed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                            .padding(.horizontal, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(line.kind == .added ? Self.good.opacity(0.14) : line.kind == .removed ? Color(nsColor: .systemRed).opacity(0.12) : .clear,
                                        in: RoundedRectangle(cornerRadius: 3))
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
        }
    }

    private func resultRow(_ result: TuneResult) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("**Prompt \(controller.nextVersion)** · learned from \(result.errors.count) corrections · \(dates.string(controller.now(), .dateTime.month(.abbreviated).day())) · ~\(result.tokens) tokens")
                    .font(.callout)
                if let verdict = controller.verdictText {
                    Text(verdict).font(.caption).foregroundStyle(Color(nsColor: .systemOrange))
                        .accessibilityIdentifier("learn.verdict")
                }
            }
            Spacer()
            Button("Discard") { controller.discard() }
                .accessibilityIdentifier("learn.discard")
            Button("Keep \(controller.nextVersion)") { controller.keep() }
                .buttonStyle(.borderedProminent)
                .tint(Self.good)
                .disabled(result.verdict != .pass)
                .accessibilityIdentifier("learn.keep")
        }
        .transition(.opacity)
    }
}

/// A score as a ring and a figure; the delta pill pops in once there is a result.
struct ScoreRing: View {
    let value: Double?
    let before: Double?
    /// Draw the ring green (it went up).
    let up: Bool
    let label: String
    let id: String
    /// "held" when unchanged instead of "+0".
    let deltaAsHeld: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.12), lineWidth: 4.5)
                Circle()
                    .trim(from: 0, to: (value ?? 0) / 100)
                    .stroke(up ? LearnView.good : Color(nsColor: .systemBlue), style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .easeOut(duration: 1.2), value: value)
            }
            .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    if let value {
                        Text("\(Int(value.rounded()))")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .contentTransition(.numericText())
                            .animation(reduceMotion ? nil : .easeOut(duration: 1.2), value: value)
                        Text("%").font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                    } else {
                        Text("Not measured yet")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(height: 40)  // the figure's height, so the card doesn't jump at the first score
                    }
                    if let delta {
                        Text(delta.text)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(delta.good ? LearnView.good : .secondary)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background((delta.good ? LearnView.good : Color.secondary).opacity(0.16), in: Capsule())
                            .padding(.leading, 6)
                            .transition(.scale.combined(with: .opacity))
                            .accessibilityIdentifier(id + ".delta")
                    }
                }
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(value.map { "\(Int($0.rounded()))%" } ?? "not measured yet")
        .accessibilityIdentifier(id)
    }

    private var delta: (text: String, good: Bool)? {
        guard let value, let before else { return nil }
        let d = Int(value.rounded()) - Int(before.rounded())
        if d == 0 { return deltaAsHeld ? ("held", false) : nil }
        return (d > 0 ? "+\(d)" : "\(d)", d > 0)
    }
}

/// The Learn button; while a tune runs it carries the app's three colours, moving.
struct LearnButton: View {
    let title: String
    let busy: Bool
    var disabled = false
    let action: () -> Void
    @State private var shift: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(disabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white))
                .padding(.horizontal, 26).padding(.vertical, 10)
                .background(background, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled || busy)
        .accessibilityIdentifier("learn.button")
        .onAppear { if busy && !reduceMotion { withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) { shift = 1 } } }
    }

    private var background: AnyShapeStyle {
        if disabled { return AnyShapeStyle(Color.primary.opacity(0.08)) }
        if busy {
            return AnyShapeStyle(LinearGradient(colors: LearnView.learning + [LearnView.learning[0]],
                                                startPoint: UnitPoint(x: -2 + shift * 2, y: 0.5), endPoint: UnitPoint(x: shift * 2, y: 0.5)))
        }
        return AnyShapeStyle(Color(nsColor: .systemBlue))
    }
}

/// One candidate prompt in the race: name, lens, score so far, a bar that fills a correction at a
/// time, with a highlight running along the unfilled part while a teacher is still writing.
struct CandidateRow: View {
    enum State { case running, won, lost }
    let lens: Lens
    let score: Double?
    let progress: Double
    var writing = false
    /// "writing…", "scoring 7 of 15".
    var stage: String?
    let state: State
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                (Text(lens.title).fontWeight(.medium) + Text(" · \(lens.blurb)").foregroundStyle(.secondary)).font(.callout)
                if state == .won {
                    Text("best").font(.caption2.weight(.semibold)).foregroundStyle(LearnView.good)
                        .padding(.horizontal, 6).padding(.vertical, 1).background(LearnView.good.opacity(0.16), in: Capsule())
                }
                Spacer()
                if let stage {
                    Text(stage).font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                        .transition(.opacity)
                }
                Text(score.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(.callout.weight(state == .won ? .semibold : .regular))
                    .foregroundStyle(state == .won ? LearnView.good : .secondary)
                    .contentTransition(.numericText())
                    .monospacedDigit()
            }
            GeometryReader { geo in
                let filled = geo.size.width * min(1, max(0, progress))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    if writing && !reduceMotion {
                        // A highlight sweeping the unfilled part, once every 1.4 s.
                        TimelineView(.animation) { context in
                            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                            let span = geo.size.width - filled, width: CGFloat = 90
                            Capsule()
                                .fill(LinearGradient(colors: [.clear, Color(nsColor: .systemBlue).opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing))
                                .frame(width: width)
                                .offset(x: filled - width + (span + width) * t)
                        }
                        .mask(Capsule())
                    }
                    Capsule()
                        .fill(state == .won ? AnyShapeStyle(LearnView.good)
                              : AnyShapeStyle(LinearGradient(colors: LearnView.learning, startPoint: .leading, endPoint: .trailing)))
                        .frame(width: filled)
                        .animation(.spring(duration: 0.35), value: progress)
                }
            }
            .frame(height: 3)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .opacity(state == .lost ? 0.35 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityValue((score.map { "\(Int($0.rounded()))%" } ?? "running") + (stage.map { " · \($0)" } ?? ""))
        .accessibilityIdentifier("learn.candidate." + lens.rawValue)
    }
}

/// A soft wash that sweeps down the corrections once each time `trigger` changes.
struct SweepOverlay: View {
    let trigger: Int
    @State private var progress: CGFloat = 0
    @State private var visible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            LinearGradient(colors: [.clear, Color(nsColor: .systemBlue).opacity(0.12), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 90)
                .offset(y: -90 + progress * (geo.size.height + 90))
                .opacity(visible ? 1 : 0)
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) {
            guard !reduceMotion else { return }
            progress = 0
            visible = true
            withAnimation(.easeInOut(duration: 1.3)) { progress = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { visible = false }
        }
    }
}
