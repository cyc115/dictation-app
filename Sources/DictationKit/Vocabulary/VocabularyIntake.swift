import Foundation

/// The idle pass: works out each fix's word changes (`FixIntake`: your correction, or a captured edit
/// you haven't dismissed, `HistoryEntry.fixTarget`) and counts candidates from
/// them (`CandidateTally`), then learns the terms seen often enough (`VocabularyStore.updateCandidates`).
/// Made once in `AppServices`.
///
/// It runs 30 s after the last dictation ended (and 30 s after launch: the first pass is the
/// backfill of every existing correction), and when the Vocabulary or Corrections tab is shown;
/// never while a dictation is in progress. The work runs off the main thread on a copy of History,
/// so nothing a dictation does waits on it; its result is applied on the main thread, or dropped if
/// a dictation started meanwhile (the next pass redoes it). Only entries whose fix differs from
/// `intake.of` are worked out again, so typing a correction costs nothing, and a pass that changes
/// nothing writes nothing.
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
    /// Passes applied so far.
    private(set) var passes = 0
    /// The newest timer; an older one that fires does nothing.
    private var timer = 0
    private var running = false

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

    /// The Vocabulary or Corrections tab was shown.
    func tabShown() { runIfIdle() }

    /// Runs a pass now, unless a dictation (or a pass) is in progress.
    func runIfIdle() {
        guard !running, !isBusy() else { return }
        running = true
        let entries = history.entries
        background { [weak self] in
            let (intakes, support) = Self.work(entries)
            self?.toMain {
                guard let self else { return }
                self.running = false
                guard !self.isBusy() else { return }
                // A fix changed while it worked: counting from the old one could learn a term from a
                // fix that's gone (and learning can't be taken back). Try again later.
                guard Self.fixes(self.history.entries) == Self.fixes(entries) else { return self.scheduleAfterIdle() }
                if !intakes.isEmpty { self.history.setIntakes(intakes) }
                self.vocabulary.updateCandidates(support, learnAfter: self.settings.vocabularyEnabled ? self.settings.vocabularyLearnAfter : nil)
                self.passes += 1
            }
        }
    }

    /// Each dictation's fix, by id: what a pass's result depends on.
    private static func fixes(_ entries: [HistoryEntry]) -> [UUID: String] {
        Dictionary(entries.compactMap { entry in entry.fixTarget.map { (entry.id, $0) } }, uniquingKeysWith: { first, _ in first })
    }

    /// The pass's work, on a copy of History (newest first): the intake of each entry whose fix
    /// changed since its intake was worked out (nil where the fix is gone), and the candidates
    /// counted with it.
    static func work(_ entries: [HistoryEntry]) -> (intakes: [UUID: Intake?], support: [VocabularyCandidate]) {
        var entries = entries
        var intakes: [UUID: Intake?] = [:]
        for i in entries.indices where entries[i].fixTarget != entries[i].intake?.of {
            let intake = entries[i].fixTarget.map { FixIntake.intake(of: entries[i].text, target: $0) }
            intakes.updateValue(intake, forKey: entries[i].id)  // a nil value is kept, not a removal
            entries[i].intake = intake
        }
        return (intakes, CandidateTally.support(in: entries))
    }
}
