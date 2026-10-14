import XCTest
@testable import DictationKit

/// A polish model whose answer depends on the prompt it was given: a prompt the fake teacher
/// wrote for `lens` carries "LENS:<lens>", and `right` says which corrections that lens fixes.
final class FakeStudent: PolishBackend {
    let instructions: String
    /// Which case inputs each lens gets right (returns the wanted text); others get the "wrong" text.
    let right: [Lens: Set<String>]
    let wanted: [String: String]
    /// General cases this prompt fails on, by raw text (any lens).
    let generalFails: [Lens: Set<String>]
    let log: EventLog?
    let error: PolishError?
    var name = "FakeStudent"

    init(instructions: String, right: [Lens: Set<String>], wanted: [String: String], generalFails: [Lens: Set<String>] = [:],
         log: EventLog? = nil, error: PolishError? = nil) {
        self.instructions = instructions; self.right = right; self.wanted = wanted; self.generalFails = generalFails
        self.log = log; self.error = error
    }

    var lens: Lens? { Lens.allCases.first { instructions.contains("LENS:\($0.rawValue)") } }

    func polish(_ text: String) async throws -> String {
        log?.add("polish:\(lens?.rawValue ?? "current"):\(text)")
        if let error { throw error }
        if let w = wanted[text] {  // a correction
            return (lens.flatMap { right[$0] }?.contains(text) ?? false) ? w : "wrong " + w
        }
        if let lens, generalFails[lens]?.contains(text) ?? false { return "nonsense" }
        return text  // a general case, or the current prompt: the raw text is "the expected" in these tests
    }
}

final class PromptTunerTests: XCTestCase {
    let cases: [TuneCase] = (1...10).map { TuneCase(id: UUID(), input: "raw \($0)", wanted: "wanted \($0)") }
    var wanted: [String: String] { Dictionary(uniqueKeysWithValues: cases.map { ($0.input, $0.wanted) }) }
    let general = [GeneralCase(id: "g1", raw: "general one", expected: "general one"),
                   GeneralCase(id: "g2", raw: "general two", expected: "general two"),
                   GeneralCase(id: "g3", raw: "general three", expected: "general three"),
                   GeneralCase(id: "g4", raw: "general four", expected: "general four")]

    /// A teacher that returns the current prompt tagged with its lens, and remembers what it was shown.
    final class FakeTeacher {
        var inputs: [(system: String, user: String)] = []
        /// The answer for a lens, given the teacher's user message (which holds the current prompt).
        var answer: (Lens, String) -> String = { lens, _ in "<prompt>Clean it up. LENS:\(lens.rawValue)</prompt>" }
        let lock = NSLock()
        func call(_ system: String, _ user: String) async throws -> String {
            lock.lock(); inputs.append((system, user)); lock.unlock()
            let lens = Lens.allCases.first { user.hasSuffix($0.instruction) }!
            return answer(lens, user)
        }
    }

    func makeTuner(right: [Lens: Set<String>], generalFails: [Lens: Set<String>] = [:], teacher: FakeTeacher,
                   log: EventLog? = nil, general: [GeneralCase]? = nil, studentError: PolishError? = nil) -> PromptTuner {
        let wanted = wanted
        return PromptTuner(student: { FakeStudent(instructions: $0, right: right, wanted: wanted, generalFails: generalFails, log: log, error: studentError) },
                           teacher: teacher.call, general: general ?? self.general, repeats: 2)
    }

    func testTheBestLensWinsAndTheScoresAreCrossValidated() async throws {
        let teacher = FakeTeacher()
        let inputs = cases.map(\.input)
        // rules fixes 4 of 10, examples none, both all 10.
        let tuner = makeTuner(right: [.rules: Set(inputs.prefix(4)), .both: Set(inputs)], teacher: teacher)
        var phases: [TunePhase] = []
        let result = try await tuner.tune(cases: cases, prompt: "Clean it up.") { phases.append($0) }

        XCTAssertEqual(result.lens, .both)
        XCTAssertEqual(result.mine, 100, "every held-out correction right")
        XCTAssertEqual(result.lensScores[.examples], result.mineBefore, "a lens that fixes nothing scores like the current prompt")
        XCTAssertGreaterThan(result.lensScores[.rules]!, result.lensScores[.examples]!)
        XCTAssertLessThan(result.lensScores[.rules]!, 100)
        XCTAssertEqual(result.mineBefore, 50, accuracy: 0.01, "\"wrong wanted 1\" vs \"wanted 1\": 1 of 2 tokens off")
        XCTAssertEqual(result.errors.count, 10)
        XCTAssertTrue(result.errors.values.allSatisfy { $0 == 0 })
        XCTAssertEqual(result.errorsBefore.count, 10)
        XCTAssertEqual(result.general, 100)
        XCTAssertEqual(result.generalBefore, 100)
        XCTAssertEqual(result.verdict, .pass)
        XCTAssertEqual(result.prompt, "Clean it up. LENS:both")
        XCTAssertEqual(result.tokens, Int(Double(PolishScore.tokens(result.prompt).count) * 1.3))

        XCTAssertEqual(phases.first, .reading)
        XCTAssertEqual(phases.last, .done)
        XCTAssertTrue(phases.contains(.writing) && phases.contains(.checking))
        let folds = phases.compactMap { if case .racing(let f, let of, _) = $0 { return (f, of) } else { return nil } }
        XCTAssertEqual(folds.map(\.0), [1, 2, 3, 4, 5, 5], "five folds, then the final scores")
        XCTAssertTrue(folds.allSatisfy { $0.1 == 5 })
        XCTAssertEqual(teacher.inputs.count, 5 * 3 + 1, "three candidates per fold, then the final prompt")
    }

    func testTheTeacherNeverSeesAHeldOutCorrection() async throws {
        let teacher = FakeTeacher()
        let tuner = makeTuner(right: [.both: Set(cases.map(\.input))], teacher: teacher)
        let result = try await tuner.tune(cases: cases, prompt: "P") { _ in }
        XCTAssertEqual(result.trace.count, 15)
        for t in result.trace {
            XCTAssertTrue(Set(t.shown).isDisjoint(with: t.heldOut), "fold \(t.fold) \(t.lens)")
            XCTAssertEqual(Set(t.shown).union(t.heldOut), Set(cases.map(\.id)), "every case is shown or held out")
            XCTAssertEqual(t.heldOut.count, 2)
        }
        let heldOutByFold = Dictionary(grouping: result.trace, by: \.fold).mapValues { Set($0.flatMap(\.heldOut)) }
        XCTAssertEqual(Set(heldOutByFold.values.flatMap { $0 }).count, 10, "each case is held out exactly once")
        // The teacher's messages hold the training cases' wanted text and never a held-out one's.
        for (i, input) in teacher.inputs.prefix(15).enumerated() {
            let t = result.trace[i]
            for c in cases {
                XCTAssertEqual(input.user.contains("Wanted:\n\(c.wanted)\n"), t.shown.contains(c.id), "fold \(t.fold) \(t.lens): \(c.wanted)")
            }
            XCTAssertTrue(input.user.contains("Model wrote:\nwrong wanted"), "shows what the current prompt wrote")
            XCTAssertEqual(input.system, PromptTuner.teacherSystem)
        }
        XCTAssertTrue(teacher.inputs[15].user.contains("Wanted:\n\(cases[0].wanted)\n"), "the final prompt is written from every correction")
    }

    func testLearnedCorrectionsAreScoredButNotShownToTheTeacher() async throws {
        var cases = cases
        for i in 0..<4 { cases[i].learned = true }
        let teacher = FakeTeacher()
        let tuner = makeTuner(right: [.both: Set(cases.map(\.input))], teacher: teacher)
        let result = try await tuner.tune(cases: cases, prompt: "P") { _ in }
        let learned = Set(cases.prefix(4).map(\.id))
        XCTAssertTrue(result.trace.allSatisfy { Set($0.shown).isDisjoint(with: learned) })
        XCTAssertEqual(Set(result.errors.keys), Set(cases.map(\.id)), "learned ones are still scored")
        XCTAssertEqual(result.trace.map(\.fold).max(), 5, "6 unlearned: still 5 folds")

        for i in 0..<9 { cases[i].learned = true }
        let fewer = try await tuner.tune(cases: cases, prompt: "P") { _ in }
        XCTAssertEqual(fewer.trace.map(\.fold).max(), 1, "one unlearned: one fold")
        XCTAssertEqual(Set(fewer.errors.keys).count, 10)

        for i in 0..<10 { cases[i].learned = true }
        do {
            _ = try await tuner.tune(cases: cases, prompt: "P") { _ in }
            XCTFail("nothing to learn")
        } catch let error as TuneError {
            XCTAssertEqual(error, .nothingToLearn)
        }
    }

    func testVerdictFailsWhenTheGeneralSetDropsOrNothingImproves() async throws {
        let teacher = FakeTeacher()
        let all = Set(cases.map(\.input))
        let dropped = try await makeTuner(right: [.both: all], generalFails: [.both: ["general one", "general two"]], teacher: teacher)
            .tune(cases: cases, prompt: "P") { _ in }
        XCTAssertEqual(dropped.general, 50)
        XCTAssertEqual(dropped.generalBefore, 100)
        XCTAssertEqual(dropped.verdict, .generalDropped)

        let flat = try await makeTuner(right: [:], teacher: teacher).tune(cases: cases, prompt: "P") { _ in }
        XCTAssertEqual(flat.mine, flat.mineBefore)
        XCTAssertEqual(flat.verdict, .noImprovement)

        let noGeneral = try await makeTuner(right: [.both: all], teacher: teacher, general: []).tune(cases: cases, prompt: "P") { _ in }
        XCTAssertEqual(noGeneral.general, 100, "no general set: nothing to drop")
        XCTAssertEqual(noGeneral.verdict, .pass)
    }

    func testATeacherAnswerWithoutAPromptFailsThatCandidateOnly() async throws {
        let teacher = FakeTeacher()
        teacher.answer = { lens, _ in lens == .rules ? "I can't help with that." : "<prompt>Clean it up. LENS:\(lens.rawValue)</prompt>" }
        let tuner = makeTuner(right: [.both: Set(cases.map(\.input)), .rules: Set(cases.map(\.input))], teacher: teacher)
        let result = try await tuner.tune(cases: cases, prompt: "P") { _ in }
        XCTAssertEqual(result.lensScores[.rules], result.mineBefore, "scored as the current prompt")
        XCTAssertEqual(result.lens, .both)

        teacher.answer = { _, _ in "no tags here" }
        do {
            _ = try await tuner.tune(cases: cases, prompt: "P") { _ in }
            XCTFail("no final prompt")
        } catch let error as TuneError {
            XCTAssertEqual(error, .noPrompt)
        }
        XCTAssertNil(PromptTuner.extractPrompt("<prompt>  </prompt>"))
        XCTAssertEqual(PromptTuner.extractPrompt("Sure:\n<prompt>\nA\nB\n</prompt>\nDone."), "A\nB")
    }

    func testModelFailuresNameTheModel() async throws {
        let teacher = FakeTeacher()
        do {
            _ = try await makeTuner(right: [:], teacher: teacher, studentError: .failed("HTTP 429")).tune(cases: cases, prompt: "P") { _ in }
            XCTFail("student failed")
        } catch let error as TuneError {
            XCTAssertEqual(error, .student("HTTP 429"))
            XCTAssertEqual(error.localizedDescription, "Polishing failed: HTTP 429")
        }
        let failing = PromptTuner(student: { FakeStudent(instructions: $0, right: [:], wanted: [:]) },
                                  teacher: { _, _ in throw PolishError.failed("No credits.") }, general: [])
        do {
            _ = try await failing.tune(cases: cases, prompt: "P") { _ in }
            XCTFail("teacher failed")
        } catch let error as TuneError {
            XCTAssertEqual(error, .teacher("No credits."))
        }
    }

    func testStudentCallsAreRepeatedAndLimited() async throws {
        let teacher = FakeTeacher(), log = EventLog()
        let tuner = makeTuner(right: [.both: Set(cases.map(\.input))], teacher: teacher, log: log)
        _ = try await tuner.tune(cases: cases, prompt: "P") { _ in }
        let polishes = log.events.filter { $0.hasPrefix("polish:") }
        // baseline 10×2, three lenses × 10 held-out × 2, general 4 × 2 prompts.
        XCTAssertEqual(polishes.count, 20 + 60 + 8)
        XCTAssertEqual(polishes.filter { $0.hasPrefix("polish:current:raw") }.count, 20)
    }

    func testFoldsAreStableAndDealUnlearnedFirst() {
        var cases = cases
        cases[0].learned = true; cases[1].learned = true
        let a = PromptTuner.fold(cases, into: 3, seed: 1), b = PromptTuner.fold(cases, into: 3, seed: 1)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.map(\.count), [4, 3, 3])
        XCTAssertTrue(a.allSatisfy { fold in fold.contains { !$0.learned } }, "every fold has something unlearned")
        XCTAssertNotEqual(PromptTuner.fold(cases, into: 3, seed: 2).map { $0.map(\.id) }, a.map { $0.map(\.id) })
        XCTAssertEqual(PromptTuner.fold([], into: 3, seed: 1), [])
    }

    func testReasoningOverrideReachesTheRequest() throws {
        var polish = OpenRouterPolish(model: "openai/gpt-6.1-sol-pro", apiKey: "k")
        func reasoning(_ p: OpenRouterPolish) throws -> [String: Any] {
            let request = OpenRouterPolish.request(model: p.model, apiKey: p.apiKey, text: "t", instructions: "i", reasoning: p.reasoning)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            return try XCTUnwrap(body["reasoning"] as? [String: Any])
        }
        XCTAssertEqual(try reasoning(polish)["effort"] as? String, "minimal", "cleanup: the lowest effort")
        polish.reasoning = ["effort": "high"]
        XCTAssertEqual(try reasoning(polish)["effort"] as? String, "high")
    }

    /// The real teacher and student through the tuner's own code path (`LearnController.appTuner`):
    /// one teacher call and two general cases. Opt-in: LIVE_OPENROUTER=1 OPENROUTER_API_KEY=… (~$0.01).
    func testLiveTeacherWritesAPromptAndStudentIsScored() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["LIVE_OPENROUTER"] == "1", let key = env["OPENROUTER_API_KEY"] else {
            throw XCTSkip("set LIVE_OPENROUTER=1 and OPENROUTER_API_KEY to run")
        }
        let general = try XCTUnwrap(GeneralCase.loadAll(from: benchFolder)).filter { ["en-correction-time", "zh-correction-name"].contains($0.id) }
        XCTAssertFalse(general.isEmpty)
        let tuner = try XCTUnwrap(LearnController.appTuner(setup: .cloudFlash, apiKey: key, general: general))
        let example = (input: "can you install cloud code", wrote: "Can you install Cloud Code?", wanted: "Can you install Claude Code?")
        let answer = try await tuner.teacher(PromptTuner.teacherSystem,
                                             PromptTuner.teacherMessage(prompt: PolishPrompt.v4, lens: .rules, examples: [example]))
        let prompt = try XCTUnwrap(PromptTuner.extractPrompt(answer), "the teacher answers inside <prompt> tags: \(answer.prefix(200))")
        XCTAssertTrue(prompt.contains("Output only"), "keeps the prompt's structure: \(prompt.suffix(80))")
        XCTAssertNotEqual(prompt, PolishPrompt.v4, "changed something")
        print("[live] teacher's prompt:\n\(prompt)\n[live] end")
        let rate = try await tuner.passRate(prompt: prompt)
        XCTAssertGreaterThanOrEqual(rate, 50, "the student passes at least one of the two self-correction cases with the new prompt")
    }
}
