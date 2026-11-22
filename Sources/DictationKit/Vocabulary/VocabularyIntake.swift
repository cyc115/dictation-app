import Foundation

/// The idle pass: works out each fix's word changes (`FixIntake`: your correction, or a captured edit
/// you haven't dismissed, `HistoryEntry.fixTarget`) and counts candidates from
/// them (`CandidateTally`), then learns the terms seen often enough (`VocabularyStore.updateCandidates`).
/// With *Ask a model about my fixes* on, it then sends the judge a batch when one is due (`FixJudge`).
/// Made once in `AppServices`.
///
/// It runs 30 s after the last dictation ended (and 30 s after launch: the first pass is the
/// backfill of every existing correction), and when the Vocabulary or Corrections tab is shown;
/// never while a dictation is in progress. The work runs off the main thread on a copy of History,
/// so nothing a dictation does waits on it; its result is applied on the main thread, or dropped if
/// a dictation started meanwhile (the next pass redoes it). Only entries whose fix differs from
/// `intake.of` are worked out again, so typing a correction costs nothing, and a pass that changes
/// nothing writes nothing.
///
/// The judge: a batch goes after a pass when 5 fixes wait, the oldest has waited 10 minutes (a timer
/// wakes the pass for it), or the tab was shown; one request at a time, never while busy. Its answer
/// is applied when it arrives if the app is idle, else held for the next pass (it was paid for); then
/// the pass runs again, so the verdicts count at once and the next batch goes if one is due. A failed
/// request, or an answer that covers nothing, waits 10 minutes before the next (a tab shown still asks);
/// a refused one (not offline or a busy host) counts a try, so one fix can't hold the rest up. An
/// on-device call stops when a dictation starts.
final class VocabularyIntake {
    /// How long after the last dictation the pass runs.
    static let idleDelay: TimeInterval = 30

    private let history: HistoryStore
    private let vocabulary: VocabularyStore
    private let settings: AppSettings
    /// A dictation is in progress (`DictationController.isBusy`); AppDelegate sets it.
    var isBusy: () -> Bool = { false }
    /// Runs a closure on the main thread after a delay (tests fake the clock).
    var after: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    /// Where the work runs, and how its result gets back to the main thread (tests run both inline).
    var background: (@escaping () -> Void) -> Void = { DispatchQueue.global(qos: .utility).async(execute: $0) }
    var toMain: (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }
    /// The judge for your setup now (`FixJudge.backend`), nil when it can't run. `AppServices.live()`
    /// hands in the real one; tests a fake, so none can reach a model.
    var judgeBackend: () -> FixJudgeBackend? = { nil }
    /// Where a judge request runs, and how to cancel it (tests hold it back, then run it).
    var send: (@escaping () async -> Void) -> () -> Void = { work in
        let task = Task.detached(priority: .utility) { await work() }
        return { task.cancel() }
    }
    var now: () -> Date = Date.init
    /// What the judge's requests cost, added up. In memory only: the app keeps no record of spend.
    let judgeUsage = UsageMeter()
    /// Passes applied so far.
    private(set) var passes = 0
    /// Batches sent to the judge so far.
    private(set) var batches = 0
    /// The newest timer; an older one that fires does nothing.
    private var timer = 0
    /// The same, for the judge's wake-up (the 10-minute rule, the back-off).
    private var judgeTimer = 0
    private var running = false
    /// A batch is out (one at a time).
    private var judging = false
    /// Cancels the batch that's out, when it runs on this Mac (Apple Intelligence): a dictation
    /// starting stops it, so it never competes with on-device polish.
    private var cancelLocalJudge: (() -> Void)?
    /// The batch out was stopped for a dictation: however it fails, it costs no try.
    private var stoppedForDictation = false
    /// The judge answered while a pass was running: run another once it's done (true: as if the tab
    /// were shown).
    private var rerun: Bool?
    /// An answer that came back during a dictation: applied by the next pass.
    private var held: [FixJudge.Judged] = []
    /// When each fix waiting for the judge was first seen waiting, and for which target. In memory:
    /// at launch every waiting fix starts its 10 minutes again.
    private var waitingSince: [UUID: (target: String, at: Date)] = [:]
    /// No batch before this (after a failed request or an answer that covered nothing), unless a tab is shown.
    private var backoffUntil: Date?

    init(history: HistoryStore, vocabulary: VocabularyStore, settings: AppSettings) {
        self.history = history
        self.vocabulary = vocabulary
        self.settings = settings
    }

    /// (Re)starts the 30 s timer: after a dictation, and at launch.
    func scheduleAfterIdle() {
        timer += 1
        let mine = timer
        after(Self.idleDelay) { [weak self] in
            guard let self, mine == self.timer else { return }
            self.runIfIdle()
        }
    }

    /// The Vocabulary or Corrections tab was shown: a pass, and a batch if anything waits for the judge.
    func tabShown() { runIfIdle(tab: true) }

    /// A dictation started: an on-device judge call stops (it's asked again at the next pass).
    func dictationStarted() {
        guard let cancel = cancelLocalJudge else { return }
        cancel()
        cancelLocalJudge = nil
        stoppedForDictation = true
    }

    /// The judge is on and can run: changes then wait for its verdicts instead of counting by the rules.
    private var judge: FixJudgeBackend? { settings.judgeFixes ? judgeBackend() : nil }

    /// Runs a pass now, unless a dictation (or a pass) is in progress.
    func runIfIdle(tab: Bool = false) {
        guard !running, !isBusy() else { return }
        if !held.isEmpty {
            if settings.judgeFixes { history.applyVerdicts(held) }  // turned off meanwhile: not used
            held = []
        }
        running = true
        let entries = history.entries
        let judging = judge != nil
        background { [weak self] in
            let (intakes, support) = Self.work(entries, judging: judging)
            self?.toMain {
                guard let self else { return }
                self.running = false
                let again = self.rerun  // a judge answer landed meanwhile
                self.rerun = nil
                guard !self.isBusy() else { return }
                // A fix changed while it worked: counting from the old one could learn a term from a
                // fix that's gone (and learning can't be taken back). Try again later.
                guard Self.fixes(self.history.entries) == Self.fixes(entries) else { return self.scheduleAfterIdle() }
                if !intakes.isEmpty { self.history.setIntakes(intakes) }
                self.vocabulary.updateCandidates(support, learnAfter: self.settings.vocabularyEnabled ? self.settings.vocabularyLearnAfter : nil)
                self.passes += 1
                if let again { return self.runIfIdle(tab: again || tab) }
                self.judgeIfDue(tab: tab)
            }
        }
    }

    /// Sends the judge a batch if one is due (see the type's notes); otherwise sets the wake-up for
    /// when the oldest waiting fix reaches 10 minutes.
    private func judgeIfDue(tab: Bool) {
        guard !judging, !isBusy(), let backend = judge else { return }
        let pending = FixJudge.pending(history.entries)
        let now = now()
        waitingSince = Dictionary(pending.map { item in
            let since = waitingSince[item.id].flatMap { $0.target == item.target ? $0 : nil } ?? (item.target, now)
            return (item.id, since)
        }, uniquingKeysWith: { first, _ in first })
        guard let oldest = waitingSince.values.map(\.at).min() else { return }
        let due = pending.count >= FixJudge.enough ? now : oldest.addingTimeInterval(FixJudge.maxWait)
        if !tab {
            if let backoffUntil, backoffUntil > now { return wake(at: max(due, backoffUntil)) }
            guard due <= now else { return wake(at: due) }
        }
        // Longest waiting first; among those seen together, oldest dictation first.
        let order = pending.indices.sorted { a, b in
            let x = waitingSince[pending[a].id]!.at, y = waitingSince[pending[b].id]!.at
            return x != y ? x < y : a > b
        }
        let batch = order.prefix(max(1, backend.batchSize)).map { pending[$0] }
        let terms = vocabulary.vocabulary(enabled: settings.vocabularyEnabled).promptTerms
        judging = true
        batches += 1
        let cancel = send { [weak self] in
            let outcome: Outcome
            do {
                outcome = .answer(try await backend.judge(batch, terms: terms))
            } catch is CancellationError {
                outcome = .cancelled
            } catch let error as URLError where error.code == .cancelled {
                outcome = .cancelled
            } catch {
                outcome = .failed(countsATry: FixJudge.countsATry(error))
            }
            self?.toMain { self?.judged(batch, outcome, tab: tab) }
        }
        cancelLocalJudge = backend.onThisMac ? cancel : nil
    }

    private enum Outcome {
        case answer(JudgeAnswer)
        /// `countsATry`: it would fail the same way again (a refused request, Apple Intelligence
        /// declining), so it counts toward `FixJudge.maxTries`; offline or a busy host doesn't.
        case failed(countsATry: Bool)
        /// A dictation started (on-device): asked again at the next pass.
        case cancelled
    }

    /// A batch came back. Sent for a tab shown and useful, the next pass judges what's left too.
    private func judged(_ batch: [JudgeItem], _ outcome: Outcome, tab: Bool) {
        judging = false
        cancelLocalJudge = nil
        let stopped = stoppedForDictation
        stoppedForDictation = false
        guard settings.judgeFixes else { return }  // turned off meanwhile: its answer isn't used
        let results: [FixJudge.Judged]
        switch outcome {
        case .cancelled:
            return
        case .failed where stopped:
            return
        case .failed(let countsATry):
            backOff()
            guard countsATry else { return }
            results = batch.map { FixJudge.Judged(item: $0, verdicts: nil) }
        case .answer(let answer):
            if let usage = answer.usage { judgeUsage.add(usage) }
            results = batch.indices.map { FixJudge.Judged(item: batch[$0], verdicts: $0 < answer.verdicts.count ? answer.verdicts[$0] : nil) }
            if results.contains(where: { $0.verdicts != nil }) { backoffUntil = nil } else { backOff() }
        }
        let useful = results.contains { $0.verdicts != nil }
        guard !isBusy() else { return held += results }
        history.applyVerdicts(results)
        if running { rerun = tab && useful } else { runIfIdle(tab: tab && useful) }
    }

    private func backOff() {
        let until = now().addingTimeInterval(FixJudge.maxWait)
        backoffUntil = until
        wake(at: until)
    }

    /// A pass at `date` (the newest wake-up replaces the last).
    private func wake(at date: Date) {
        judgeTimer += 1
        let mine = judgeTimer
        after(max(1, date.timeIntervalSince(now()))) { [weak self] in
            guard let self, mine == self.judgeTimer else { return }
            self.runIfIdle()
        }
    }

    /// Each dictation's fix, by id: what a pass's result depends on.
    private static func fixes(_ entries: [HistoryEntry]) -> [UUID: String] {
        Dictionary(entries.compactMap { entry in entry.fixTarget.map { (entry.id, $0) } }, uniquingKeysWith: { first, _ in first })
    }

    /// The pass's work, on a copy of History (newest first): the intake of each entry whose fix
    /// changed since its intake was worked out (nil where the fix is gone), and the candidates
    /// counted with it (`judging`: unjudged changes wait for the judge).
    static func work(_ entries: [HistoryEntry], judging: Bool = false) -> (intakes: [UUID: Intake?], support: [VocabularyCandidate]) {
        var entries = entries
        var intakes: [UUID: Intake?] = [:]
        for i in entries.indices where entries[i].fixTarget != entries[i].intake?.of {
            let intake = entries[i].fixTarget.map { FixIntake.intake(of: entries[i].text, target: $0) }
            intakes.updateValue(intake, forKey: entries[i].id)  // a nil value is kept, not a removal
            entries[i].intake = intake
        }
        return (intakes, CandidateTally.support(in: entries, judging: judging))
    }
}
