import XCTest
@testable import DictationKit

/// Vocabulary around the polish runs that have no dictation around them: `VocabularyPolish`,
/// Learn's student and Corrections' suggestion.
final class VocabularyPolishTests: XCTestCase {
    private let claude = Vocabulary([VocabularyEntry(term: "Claude", heardAs: ["cloud"], added: fixedDate(2026, 11, 1, 9, 0))])

    func testReplacesWhatItsGivenAndWhatItAnswers() async throws {
        let inner = FakePolish(output: "Ask cloud, please.")
        let log = EventLog()
        final class Recorder: PolishBackend {
            let log: EventLog
            init(_ log: EventLog) { self.log = log }
            func polish(_ text: String) async throws -> String { log.add(text); return text + " and cloud" }
        }
        let polished = try await VocabularyPolish(backend: Recorder(log), vocabulary: claude).polish("ask cloud")
        XCTAssertEqual(log.events, ["ask Claude"])
        XCTAssertEqual(polished, "ask Claude and Claude")
        let fixed = try await VocabularyPolish(backend: inner, vocabulary: claude).polish("x")
        XCTAssertEqual(fixed, "Ask Claude, please.")
    }

    /// The protocol's defaults would drop the prewarm and call the model "VocabularyPolish" in History.
    func testForwardsPrepareAndName() {
        let log = EventLog()
        let inner = FakePolish(log: log)
        inner.name = "openrouter:deepseek/deepseek-v4.1-flash"
        let wrapped = VocabularyPolish(backend: inner, vocabulary: claude)
        wrapped.prepare()
        XCTAssertEqual(log.events, ["prepare"])
        XCTAssertEqual(wrapped.name, "openrouter:deepseek/deepseek-v4.1-flash")
        XCTAssertEqual(PolishService(backend: wrapped).backend.name, inner.name)
    }

    /// A tune counts what its student calls cost: the meter has to reach the model inside the wrapper.
    func testForwardsTheUsageMeter() throws {
        let meter = UsageMeter()
        let model = OpenRouterPolish(model: "deepseek/deepseek-v4.1-flash", apiKey: "k")
        let metered = try XCTUnwrap(VocabularyPolish(backend: model, vocabulary: claude).metered(by: meter) as? VocabularyPolish)
        XCTAssertTrue((metered.backend as? OpenRouterPolish)?.meter === meter)
    }

    func testNoTermsNoWrapper() {
        let inner = FakePolish()
        XCTAssertTrue(VocabularyPolish.wrap(inner, .none) is FakePolish)
        XCTAssertTrue(VocabularyPolish.wrap(inner, claude) is VocabularyPolish)
    }

    /// Corrections' suggestion polishes the way a dictation does: told the terms, replaced around.
    func testTheSuggestionUsesTheVocabulary() throws {
        let wrapped = try XCTUnwrap(CorrectionSuggester.backend(apiKey: "k", setup: .cloudFlash, vocabulary: claude) as? VocabularyPolish)
        let model = try XCTUnwrap(wrapped.backend as? OpenRouterPolish)
        XCTAssertEqual(model.instructions, DictationSetup.cloudFlash.instructions(claude))
        XCTAssertEqual(wrapped.name, "openrouter:" + CorrectionSuggester.defaultModel)
        let bare = try XCTUnwrap(CorrectionSuggester.backend(apiKey: "k", setup: .cloudFlash, vocabulary: .none) as? OpenRouterPolish)
        XCTAssertEqual(bare.instructions, DictationSetup.cloudFlash.promptText, "no terms: as before")
    }
}

/// Learn runs with the vocabulary: in the student, never in the prompt the teacher rewrites.
final class VocabularyLearnTests: XCTestCase {
    private let claude = Vocabulary([VocabularyEntry(term: "Claude", heardAs: ["cloud"], added: fixedDate(2026, 11, 1, 9, 0))])

    func testTheStudentGetsTheTermsAndTheTeacherNever() async throws {
        let teacher = PromptTunerTests.FakeTeacher()
        let instructions = Locked<[String]>([])
        let inputs = Locked<[String]>([])
        final class Student: PolishBackend {
            let instructions: String
            let inputs: Locked<[String]>
            init(_ instructions: String, _ inputs: Locked<[String]>) { self.instructions = instructions; self.inputs = inputs }
            func polish(_ text: String) async throws -> String { inputs.update { $0.append(text) }; return text + " cloud" }
        }
        let student = LearnController.student(vocabulary: claude) { prompt -> PolishBackend in
            instructions.update { $0.append(prompt) }
            return Student(prompt, inputs)
        }
        let cases = (1...5).map { TuneCase(id: UUID(), input: "ask cloud \($0)", wanted: "ask Claude \($0) Claude") }
        let tuner = PromptTuner(student: student, teacher: teacher.call, general: [], repeats: 1)
        let result = try await tuner.tune(cases: cases, prompt: "Clean it up.") { _ in }

        XCTAssertFalse(instructions.value.isEmpty)
        XCTAssertTrue(instructions.value.allSatisfy { $0.contains(self.claude.promptBlock) }, "every student call is told the terms")
        XCTAssertTrue(inputs.value.allSatisfy { $0.hasPrefix("ask Claude") }, "the student gets the replaced transcript")
        XCTAssertEqual(result.mineBefore, 100, "its output is replaced too: the current prompt already gets these right")
        XCTAssertFalse(teacher.inputs.contains { $0.user.contains("Vocabulary (") || $0.system.contains("Vocabulary (") },
                       "the teacher never sees the list, so it can't copy it into the kept prompt")
        XCTAssertFalse(result.prompt.contains("Vocabulary ("))
    }

    func testNoTermsTheStudentIsAsBefore() {
        var given: String?
        let student = LearnController.student(vocabulary: .none) { given = $0; return FakePolish() }
        XCTAssertTrue(student("P") is FakePolish)
        XCTAssertEqual(given, "P")
    }
}

/// A value several tasks write to.
final class Locked<T> {
    private var stored: T
    private let lock = NSLock()
    init(_ value: T) { stored = value }
    var value: T { lock.withLock { stored } }
    func update(_ change: (inout T) -> Void) { lock.withLock { change(&stored) } }
}

/// The Learn tile with a vocabulary: what a tune is given, and when a measurement is stale.
@MainActor
final class VocabularyLearnControllerTests: XCTestCase {
    /// The fixture's tuner, also recording the vocabulary each tune was made with.
    private func recordingTuner(_ fx: LearnFixture, _ given: Locked<[Vocabulary]>) {
        let tuner = fx.controller.makeTuner
        fx.controller.makeTuner = { setup, key, vocabulary in given.update { $0.append(vocabulary) }; return tuner(setup, key, vocabulary) }
    }

    /// Inputs the current prompt was asked to polish (the fixture's student logs "polish:current:<text>").
    private func inputs(_ fx: LearnFixture) -> Set<String> {
        Set(fx.log.events.filter { $0.hasPrefix("polish:current:can you") }.map { String($0.dropFirst("polish:current:".count)) })
    }

    func testATuneTakesTheNewest60Fixes() {
        let fx = LearnFixture(self, count: 70)
        fx.controller.learn()
        waitUntil(timeout: 10) { fx.controller.gate == .done }
        XCTAssertEqual(inputs(fx), Set((11...70).map { "can you install cloud code \($0)" }), "the 10 oldest are left out")
        XCTAssertEqual(fx.controller.measured?.corrections, 60)
    }

    /// Yours first (typed or accepted, newest first), then captured fixes nobody reviewed (`auto`,
    /// phase 4), up to 60; a waiting capture isn't a correction at all.
    func testATuneTakesYourFixesBeforeUnreviewedOnes() {
        let now = Date()
        func entry(_ text: String, ago: TimeInterval, _ state: Capture.State?) -> HistoryEntry {
            var e = HistoryEntry(date: now.addingTimeInterval(-ago), text: text, duration: 1)
            e.correction = text + "!"
            e.capture = state.map { Capture(edited: text + "!", mode: .readback, app: "Slack", state: $0) }
            return e
        }
        let fixes = [entry("auto new", ago: 1, .auto), entry("typed old", ago: 300, nil), entry("accepted", ago: 100, .accepted)]
            + (0..<60).map { entry("typed \($0)", ago: 200 + Double($0), nil) }
        let taken = LearnController.tuneFixes(fixes)
        XCTAssertEqual(taken.count, 60)
        XCTAssertEqual(taken.first?.text, "accepted")
        XCTAssertFalse(taken.contains { $0.text == "auto new" }, "unreviewed ones come last, so past the cap they're left out")
    }

    func testTheTileCountsCapturedFixesApart() throws {
        let fx = LearnFixture(self, count: 12)
        XCTAssertEqual(fx.controller.counts.yours, 12)
        XCTAssertEqual(fx.controller.counts.captured, 0)
        let id = try XCTUnwrap(fx.history.add(text: "cloud", duration: 1))
        fx.history.setCapture(Capture(edited: "Claude", mode: .readback, app: "Slack"), for: id)
        XCTAssertEqual(fx.controller.counts.captured, 0, "waiting: not training yet")
        fx.history.accept(id)
        XCTAssertEqual(fx.controller.counts.yours, 12)
        XCTAssertEqual(fx.controller.counts.captured, 1)
    }

    func testATuneGetsReplacedTranscriptsAndOneSnapshot() {
        let fx = LearnFixture(self, studentDelay: 0.02)
        fx.vocabulary.add(term: "Claude", heardAs: ["cloud"])
        let given = Locked<[Vocabulary]>([])
        recordingTuner(fx, given)
        fx.controller.learn()
        let fingerprint = fx.vocabulary.fingerprint(enabled: true)
        fx.vocabulary.add(term: "Codex", heardAs: ["code x"])  // mid-tune: not this tune's
        waitUntil(timeout: 10) { fx.controller.gate == .done }
        XCTAssertEqual(given.value.map { $0.entries.map(\.term) }, [["Claude"]])
        XCTAssertTrue(inputs(fx).contains("can you install Claude code 3"), "\(inputs(fx))")
        XCTAssertFalse(inputs(fx).contains { $0.contains("cloud") })
        XCTAssertNotNil(fx.store.measurement(setup: "cloud-flash", prompt: "v7", vocabulary: fingerprint),
                        "its baseline is kept with the vocabulary it ran with")
    }

    /// A measurement made with other terms is stale and measured again; a term being used isn't a change.
    func testAnotherVocabularyMakesTheMeasurementStale() {
        let fx = LearnFixture(self)
        fx.controller.measureIfNeeded()
        waitUntil(timeout: 5) { !fx.controller.measuring }
        XCTAssertNotNil(fx.controller.measured)
        let claude = fx.vocabulary.add(term: "Claude", heardAs: ["cloud"])!
        XCTAssertNil(fx.controller.measured, "stale: measured without this term")
        let polishes = fx.log.events.count
        fx.controller.measureIfNeeded()
        waitUntil(timeout: 5) { !fx.controller.measuring }
        XCTAssertGreaterThan(fx.log.events.count, polishes, "measured again")
        XCTAssertEqual(fx.controller.measured?.vocabulary, fx.vocabulary.fingerprint(enabled: true))
        fx.vocabulary.recordUses([claude.id: 3])
        XCTAssertNotNil(fx.controller.measured, "uses don't make it stale")
        fx.settings.vocabularyEnabled = false
        XCTAssertNil(fx.controller.measured, "Use vocabulary off: the one kept was made with terms, so it's stale too")
    }
}

/// Past 60 corrections a tune takes the newest 60, and the gate asks about those same 60.
@MainActor
final class LearnCapTests: XCTestCase {
    func testThe60NewestLearnedIsAllLearned() throws {
        let fx = LearnFixture(self, count: 70)
        XCTAssertEqual(fx.controller.gate, .ready(count: 70))
        let newest = fx.history.corrections.sorted { $0.date > $1.date }.prefix(60)
        let errors = Dictionary(uniqueKeysWithValues: newest.map { ($0.id.uuidString, 0.0) })
        fx.store.keep(LearnedPrompt(version: "v8", setup: "cloud-flash", basedOn: "v7", date: fixedDate(2026, 11, 1, 9, 0), text: "P",
                                    lens: .both, corrections: 60, tokens: 1,
                                    score: .init(mine: 90, mineBefore: 80, general: 90, generalBefore: 90),
                                    errors: errors, errorsBefore: errors))
        XCTAssertEqual(fx.controller.gate, .allLearned(count: 70), "not a Learn button that can only fail")
    }
}
