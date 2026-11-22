import XCTest
@testable import DictationKit

/// Compares teacher models on a real tune (bench/README.md, "Teacher bake-off"). Opt-in: skipped unless
///   BAKEOFF_TEACHER=openai/gpt-6.1-sol BAKEOFF_HISTORY=<copy of history.json> BAKEOFF_OUT=<result.json> OPENROUTER_API_KEY=…
/// (optional: BAKEOFF_PROMPT=<version or file>, default v4; BAKEOFF_FOLDS=<n>, default the tuner's).
/// Tunes the prompt for the Cloud Flash setup from the copy's corrections, through the tuner's real
/// code path (the app's own teacher, `PromptTuner.openRouterTeacher`), timing every teacher call and
/// phase, recording each call's tokens and cost and the tune's teacher and student totals, and writes
/// the result as JSON. Always give it a copy of the history, never the live file: a test must not read
/// this Mac's real one.
final class TeacherBakeoffTests: XCTestCase {
    /// Teacher calls and phase changes, recorded from the tuner's concurrent callbacks.
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [[String: Any]] = []
        private(set) var phases: [[String: Any]] = []
        /// `session`: the fold's cache key (its `session_id`), or "final".
        func call(seconds: TimeInterval, characters: Int, hadPrompt: Bool, at: TimeInterval, session: String, usage: OpenRouter.Usage?) {
            lock.lock(); defer { lock.unlock() }
            var call: [String: Any] = ["seconds": seconds, "characters": characters, "hadPrompt": hadPrompt, "finishedAt": at, "session": session]
            if let usage { call["usage"] = usage.json }
            calls.append(call)
        }
        func phase(_ name: String, at: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            guard phases.last?["phase"] as? String != name else { return }
            phases.append(["phase": name, "at": at])
        }
    }

    func testLiveTeacherBakeoff() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let model = env["BAKEOFF_TEACHER"], let historyPath = env["BAKEOFF_HISTORY"], let out = env["BAKEOFF_OUT"],
              let key = env["OPENROUTER_API_KEY"] else {
            throw XCTSkip("set BAKEOFF_TEACHER, BAKEOFF_HISTORY, BAKEOFF_OUT and OPENROUTER_API_KEY to run")
        }
        XCTAssertNotEqual(URL(fileURLWithPath: historyPath).standardizedFileURL, HistoryStore.defaultFileURL.standardizedFileURL, "a copy, never the live history")
        let general = try XCTUnwrap(GeneralCase.loadAll(from: benchFolder))
        let history = HistoryStore(fileURL: URL(fileURLWithPath: historyPath), defaults: makeDefaults(self))
        let cases = history.corrections.map { TuneCase(id: $0.id, input: $0.input, wanted: $0.correction ?? $0.text) }
        XCTAssertGreaterThanOrEqual(cases.count, 10, "LearnController.minimum")

        let prompt = try PolishPrompt.text(for: env["BAKEOFF_PROMPT"] ?? "v4")
        let folds = try env["BAKEOFF_FOLDS"].map { try XCTUnwrap(Int($0), "BAKEOFF_FOLDS must be a number") }
        let setup = DictationSetup.cloudFlash
        guard case .openRouter(let id, let providers) = ModelSpec(setup.polish) else { return XCTFail("Cloud Flash polishes through OpenRouter") }
        let student: PromptTuner.Student = { OpenRouterPolish(model: id, apiKey: key, instructions: $0, wrap: setup.wrap, provider: providers) }
        let log = Log()
        let start = Date()
        let real = PromptTuner.openRouterTeacher(model: model, apiKey: key, reasoning: ["effort": "medium"])
        let teacher: PromptTuner.Teacher = { request in
            let began = Date()
            let answer = try await real(request)
            log.call(seconds: Date().timeIntervalSince(began), characters: answer.text.count, hadPrompt: PromptTuner.extractPrompt(answer.text) != nil,
                     at: Date().timeIntervalSince(start), session: request.cacheKey ?? "final", usage: answer.usage)
            return answer
        }
        let tuner = folds.map { PromptTuner(student: student, teacher: teacher, general: general, folds: $0) }
            ?? PromptTuner(student: student, teacher: teacher, general: general)
        var failure: String?
        var result: TuneResult?
        do {
            result = try await tuner.tune(cases: cases, prompt: prompt) { phase in
                let name: String
                switch phase {
                case .reading: name = "reading"
                case .measured: name = "measured"
                case .racing: name = "racing"
                case .writing: name = "writing"
                case .checking: name = "checking"
                case .done: name = "done"
                }
                log.phase(name, at: Date().timeIntervalSince(start))
            }
        } catch {
            failure = error.localizedDescription
        }
        let elapsed = Date().timeIntervalSince(start)

        // The tuner's meters: right even when the tune failed part way (the result has its own copy).
        let (teacherCost, studentCost) = (tuner.teacherUsage.total(), tuner.studentUsage.total())
        var json: [String: Any] = ["teacher": model, "student": id, "corrections": cases.count, "general": general.count,
                                   "prompt": env["BAKEOFF_PROMPT"] ?? "v4", "folds": min(tuner.folds, cases.count),
                                   "elapsed": elapsed, "teacherCalls": log.calls, "phases": log.phases,
                                   "cost": ["teacher": teacherCost.json, "student": studentCost.json,
                                            "total": teacherCost.cost + studentCost.cost] as [String: Any]]
        if let failure { json["error"] = failure }
        if let r = result {
            json["result"] = ["mine": r.mine, "mineBefore": r.mineBefore, "general": r.general, "generalBefore": r.generalBefore,
                              "acted": r.acted, "actedBefore": r.actedBefore, "lens": r.lens.rawValue, "verdict": r.verdict.rawValue,
                              "tokens": r.tokens, "words": r.prompt.split(whereSeparator: \.isWhitespace).count,
                              "lensScores": Dictionary(uniqueKeysWithValues: r.lensScores.map { ($0.key.rawValue, $0.value) }),
                              "learned": r.errors.values.filter { $0 <= PromptTuner.learnedError }.count,
                              "learnedBefore": r.errorsBefore.values.filter { $0 <= PromptTuner.learnedError }.count,
                              "prompt": r.prompt] as [String: Any]
        }
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: out))
        XCTAssertNil(failure, "the tune failed: \(failure ?? "")")
    }
}
