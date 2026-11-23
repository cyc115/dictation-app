import Foundation
import XCTest
@testable import DictationKit

/// A judge that answers at once from `verdict` (by the change's new words; misheard when not given),
/// keeping every batch it was asked.
final class FakeJudge: FixJudgeBackend {
    var asked: [[JudgeItem]] = []
    var verdict: [String: WordChange.Verdict] = [:]
    /// Replaces the answer (a malformed one, a failure).
    var answer: (([JudgeItem]) throws -> JudgeAnswer)?

    func judge(_ items: [JudgeItem], terms: [String]) async throws -> JudgeAnswer {
        asked.append(items)
        if let answer { return try answer(items) }
        return JudgeAnswer(verdicts: items.map { $0.changes.map { verdict[$0.new] ?? .misheard } },
                           usage: OpenRouter.Usage(calls: 1, prompt: 100, completion: 10, cost: 0.001))
    }
}

/// The judge's logic (`FixJudge`): which fixes wait, the message, reading answers, what verdicts do.
final class FixJudgeTests: XCTestCase {
    private func entry(_ text: String, correction: String? = nil, capture: Capture? = nil) -> HistoryEntry {
        entryWithIntake(text, correction: correction, capture: capture)
    }

    // MARK: Putting changes back

    func testKeepingPutsBackOnlyTheChangesNotKept() {
        let text = "Ask cloud to book Tuesday and then cloud said fine", target = "Ask Claude to book Thursday and then Claude said fine"
        XCTAssertEqual(FixIntake.changes(from: text, to: target).map(\.new), ["Claude", "Thursday", "Claude"])
        XCTAssertEqual(FixIntake.keeping([true, false, true], text: text, target: target), "Ask Claude to book Tuesday and then Claude said fine")
        XCTAssertEqual(FixIntake.keeping([false, true, false], text: text, target: target), "Ask cloud to book Thursday and then cloud said fine",
                       "by position: the same word twice")
        XCTAssertEqual(FixIntake.keeping([true, true, true], text: text, target: target), target)
    }

    /// Chinese, and a kept change right beside one put back.
    func testKeepingInChineseAndBesideAnother() {
        let text = "让克劳德周二review这个PR", target = "让Claude周四review这个PR"
        XCTAssertEqual(FixIntake.keeping([true, false], text: text, target: target), "让Claude周二review这个PR")
        XCTAssertEqual(FixIntake.keeping([false, true], text: text, target: target), "让克劳德周四review这个PR")
        let near = "send cloud mail to Bob", fixed = "send Claude mail to Rob"
        XCTAssertEqual(FixIntake.keeping([false, true], text: near, target: fixed), "send cloud mail to Rob")
    }

    /// The judge's tries are saved with the fix, and history.json without them still loads.
    func testTriesAreSavedAndOldFilesLoad() throws {
        let intake = Intake(of: "I use Claude", changes: [WordChange(old: "cloud", new: "Claude")], tries: 2)
        let data = try JSONEncoder().encode(intake)
        XCTAssertEqual(try JSONDecoder().decode(Intake.self, from: data), intake)
        let old = try JSONDecoder().decode(Intake.self, from: Data(#"{"of": "x", "changes": [{"old": "a", "new": "b", "verdict": "sarcasm"}]}"#.utf8))
        XCTAssertNil(old.tries)
        XCTAssertNil(old.changes[0].verdict, "a verdict a newer build wrote reads as none")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(Intake(of: "x", changes: [])), as: UTF8.self).contains("tries"))
    }

    /// What isn't a word change (a period, a filler taken out) stays as you made it.
    func testKeepingLeavesWhatIsNotAChange() {
        let text = "um I use cloud on tuesday", target = "I use Claude on Thursday."
        XCTAssertEqual(FixIntake.changes(from: text, to: target).map(\.old), ["cloud", "tuesday"])
        XCTAssertEqual(FixIntake.keeping([true, false], text: text, target: target), "I use Claude on tuesday")
        XCTAssertFalse(FixIntake.wordsOnlyAdded(from: text, to: target), "only removed")
        XCTAssertTrue(FixIntake.wordsOnlyAdded(from: "send it", to: "send it to Bob now"))
        XCTAssertFalse(FixIntake.wordsOnlyAdded(from: "send it", to: "send it."), "punctuation isn't words")
    }

    // MARK: Message and answers (bench/judge_message_fixture.json)

    private struct Fixture: Decodable {
        struct Message: Decodable {
            struct Item: Decodable { let wrote: String; let wanted: String; let changes: [[String]] }
            let terms: [String]; let items: [Item]; let prefix: String; let rest: String
        }
        struct Answer: Decodable { let about: String; let changes: [Int]; let text: String; let verdicts: [[String]?] }
        let messages: [Message]
        let answers: [Answer]
    }

    private func fixture() throws -> Fixture {
        try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: benchFolder.appendingPathComponent("judge_message_fixture.json")))
    }

    /// The app and the bench send the judge the same message.
    func testTheMessageIsTheBenchs() throws {
        for m in try fixture().messages {
            let items = m.items.map { JudgeItem(id: UUID(), wrote: $0.wrote, target: $0.wanted, changes: $0.changes.map { WordChange(old: $0[0], new: $0[1]) }) }
            let (prefix, rest) = FixJudge.message(items, terms: m.terms)
            XCTAssertEqual(prefix, m.prefix)
            XCTAssertEqual(rest, m.rest)
        }
    }

    /// …and read its answers the same way: an item is covered only by its number with one known
    /// verdict per change.
    func testAnswersAreReadAsTheBenchReadsThem() throws {
        for a in try fixture().answers {
            let items = a.changes.map { n in JudgeItem(id: UUID(), wrote: "w", target: "t", changes: Array(repeating: WordChange(old: "a", new: "b"), count: n)) }
            let expected = a.verdicts.map { $0?.map { FixJudge.verdict($0)! } }
            XCTAssertEqual(FixJudge.parse(a.text, items: items), expected, a.about)
        }
        XCTAssertEqual(FixJudge.parse("not json", items: [JudgeItem(id: UUID(), wrote: "", target: "", changes: [])]).count, 1)
        XCTAssertTrue(FixJudge.parse("{}", items: []).isEmpty)
    }

    /// bench/edit_cases.json's changes are exactly what the app works out from each fix, so the bench
    /// asks the judge what the app would ask it.
    func testTheBenchCasesAreTheAppsChanges() throws {
        struct Cases: Decodable {
            struct Case: Decodable {
                struct Change: Decodable { let old: String; let new: String; let verdict: String }
                let id: String; let wrote: String; let target: String; let changes: [Change]
            }
            let cases: [Case]
        }
        let cases = try JSONDecoder().decode(Cases.self, from: Data(contentsOf: benchFolder.appendingPathComponent("edit_cases.json"))).cases
        XCTAssertGreaterThanOrEqual(cases.count, 40)
        for c in cases {
            XCTAssertEqual(FixIntake.changes(from: c.wrote, to: c.target).map { [$0.old, $0.new] }, c.changes.map { [$0.old, $0.new] }, c.id)
            XCTAssertTrue(c.changes.allSatisfy { FixJudge.verdict($0.verdict) != nil }, c.id)
        }
    }

    /// The instructions are the file the bench sends, loaded from the app's resources.
    func testTheInstructionsAreTheSharedFile() throws {
        let file = try String(contentsOf: sourcesFolder.appendingPathComponent("Vocabulary/JudgeFixes.txt"), encoding: .utf8)
        XCTAssertEqual(FixJudge.instructions, file.trimmingCharacters(in: .whitespacesAndNewlines))
        for verdict in ["misheard", "style", "changedMind", "unclear"] { XCTAssertTrue(FixJudge.instructions.contains(verdict)) }
    }

    // MARK: Which fixes wait

    func testPendingFixesAreTheUnjudgedCurrentOnes() {
        let fresh = entry("I use cloud", correction: "I use Claude")
        var judged = entry("ask cloud", correction: "ask Claude")
        judged.intake!.changes[0].verdict = .misheard
        var stale = entry("Klod said no", correction: "Claude said no")
        stale.correction = "Claude said yes"
        var givenUp = entry("cloud is up", correction: "Claude is up")
        givenUp.intake!.tries = FixJudge.maxTries
        let none = entry("fine")
        let pending = FixJudge.pending([fresh, judged, stale, givenUp, none])
        XCTAssertEqual(pending.map(\.id), [fresh.id])
        XCTAssertEqual(pending[0], JudgeItem(id: fresh.id, wrote: "I use cloud", target: "I use Claude", changes: [WordChange(old: "cloud", new: "Claude")]))
    }

    // MARK: What verdicts do

    func testACorrectionIsLabelledNeverRewritten() {
        for train in [false, true] {
            let e = entry("see you tuesday with cloud", correction: "see you Thursday with Claude")
            let judged = FixJudge.judged(e, verdicts: [.changedMind, .misheard], trainUnreviewed: train)
            XCTAssertEqual(judged.correction, "see you Thursday with Claude")
            XCTAssertEqual(judged.intake?.changes.map(\.verdict), [.changedMind, .misheard])
            XCTAssertEqual(judged.intake?.of, "see you Thursday with Claude")

            var accepted = entry("ask cloud", capture: Capture(edited: "ask Claude", mode: .readback, app: "Slack"))
            accepted.correction = "ask Claude"
            accepted.capture?.state = .accepted
            let labelled = FixJudge.judged(accepted, verdicts: [.changedMind], trainUnreviewed: train)
            XCTAssertEqual(labelled.capture?.state, .accepted, "yours once accepted")
            XCTAssertEqual(labelled.correction, "ask Claude")
        }
    }

    /// By default (`trainOnUnreviewedCaptures` off) even a clear read-back capture, every change
    /// misheard, waits for Accept: it gets its verdicts and nothing trains Learn.
    func testAClearReadBackCaptureWaitsForAcceptByDefault() {
        let e = entry("open router and deep sea", capture: Capture(edited: "OpenRouter and DeepSeek", mode: .readback, app: "Slack"))
        let judged = FixJudge.judged(e, verdicts: [.misheard, .misheard], trainUnreviewed: false)
        XCTAssertEqual(judged.capture?.state, .waiting)
        XCTAssertNil(judged.correction, "doesn't train Learn")
        XCTAssertEqual(judged.capture?.trains, false)
        XCTAssertEqual(judged.fixTarget, "OpenRouter and DeepSeek", "still counts toward vocabulary")
        XCTAssertEqual(judged.intake, Intake(of: "OpenRouter and DeepSeek", changes: [
            WordChange(old: "open router", new: "OpenRouter", verdict: .misheard),
            WordChange(old: "deep sea", new: "DeepSeek", verdict: .misheard)]))
    }

    /// With `trainOnUnreviewedCaptures` on, a clear read-back capture trains Learn unreviewed (`auto`).
    func testAClearReadBackCaptureTrainsUnreviewedWhenAllowed() {
        let e = entry("open router and deep sea", capture: Capture(edited: "OpenRouter and DeepSeek", mode: .readback, app: "Slack"))
        let judged = FixJudge.judged(e, verdicts: [.misheard, .misheard], trainUnreviewed: true)
        XCTAssertEqual(judged.capture?.state, .auto)
        XCTAssertEqual(judged.correction, "OpenRouter and DeepSeek", "trains Learn")
        XCTAssertEqual(judged.capture?.trains, true)
        XCTAssertEqual(judged.intake, Intake(of: "OpenRouter and DeepSeek", changes: [
            WordChange(old: "open router", new: "OpenRouter", verdict: .misheard),
            WordChange(old: "deep sea", new: "DeepSeek", verdict: .misheard)]))
    }

    func testAKeystrokeCaptureAlwaysWaits() {
        for train in [false, true] {
            let e = entry("I use cloud", capture: Capture(edited: "I use Claude", mode: .keystrokes, app: "Notes"))
            let judged = FixJudge.judged(e, verdicts: [.misheard], trainUnreviewed: train)
            XCTAssertEqual(judged.capture?.state, .waiting)
            XCTAssertNil(judged.correction)
            XCTAssertEqual(judged.intake?.changes.first?.verdict, .misheard)
        }
    }

    /// A change of mind is put back and the rest kept, whether or not it may train unreviewed; only
    /// with `trainOnUnreviewedCaptures` does it then train.
    func testAChangeOfMindIsPutBack() {
        for train in [false, true] {
            let e = entry("ask cloud about tuesday", capture: Capture(edited: "ask Claude about Thursday", mode: .readback, app: "Slack"))
            let judged = FixJudge.judged(e, verdicts: [.misheard, .changedMind], trainUnreviewed: train)
            XCTAssertEqual(judged.capture?.edited, "ask Claude about tuesday")
            XCTAssertEqual(judged.capture?.state, train ? .auto : .waiting)
            XCTAssertEqual(judged.correction, train ? "ask Claude about tuesday" : nil)
            XCTAssertEqual(judged.intake, Intake(of: "ask Claude about tuesday", changes: [WordChange(old: "cloud", new: "Claude", verdict: .misheard)]))
        }
    }

    func testNothingKeptDismissesTheCapture() {
        for train in [false, true] {
            for verdicts in [[WordChange.Verdict.changedMind], [.unclear]] {
                let e = entry("see you tuesday", capture: Capture(edited: "see you Thursday", mode: .readback, app: "Slack"))
                let judged = FixJudge.judged(e, verdicts: verdicts, trainUnreviewed: train)
                XCTAssertEqual(judged.capture?.state, .dismissed, "\(verdicts)")
                XCTAssertNil(judged.correction)
                XCTAssertNil(judged.fixTarget)
                XCTAssertNil(judged.intake)
            }
        }
    }

    /// Unclear, or words only added (a change of mind no verdict covers): it waits for you, with only
    /// its misheard and style changes, even when clear captures may train unreviewed.
    func testUnclearOrWordsOnlyAddedWait() {
        let unclear = entry("ask GPT and cloud", capture: Capture(edited: "ask Claude and Claude", mode: .readback, app: "Slack"))
        let judged = FixJudge.judged(unclear, verdicts: [.unclear, .misheard], trainUnreviewed: true)
        XCTAssertEqual(judged.capture?.state, .waiting)
        XCTAssertEqual(judged.capture?.edited, "ask GPT and Claude")
        XCTAssertNil(judged.correction)

        let added = entry("send cloud the file", capture: Capture(edited: "send Claude the file now", mode: .readback, app: "Slack"))
        XCTAssertEqual(FixJudge.judged(added, verdicts: [.misheard], trainUnreviewed: true).capture?.state, .waiting)
    }

    /// A kept target that's the dictation's own text, or empty, is never `auto`.
    func testNeverAutoWithoutAKeptChange() {
        let e = entry("I use cloud", capture: Capture(edited: "I use Claude", mode: .readback, app: "Slack"))
        let judged = FixJudge.judged(e, verdicts: [.changedMind], trainUnreviewed: true)
        XCTAssertNotEqual(judged.capture?.state, .auto)
        XCTAssertNil(judged.correction)
    }

    // MARK: Saving an answer

    func testAnAnswerIsSavedOnlyOnTheFixItJudged() throws {
        let history = makeHistory(self)
        let id = try XCTUnwrap(history.add(text: "I use cloud", duration: 1))
        history.setCorrection("I use Claude", for: id)
        history.setIntakes([id: FixIntake.intake(of: "I use cloud", target: "I use Claude")])
        let item = try XCTUnwrap(FixJudge.pending(history.entries).first)

        history.setCorrection("I use Claude Code", for: id)  // edited meanwhile
        history.applyVerdicts([FixJudge.Judged(item: item, verdicts: [.misheard])], trainUnreviewed: false)
        XCTAssertNil(history.entries[0].intake?.changes.first?.verdict, "not on a fix that's gone")

        history.setCorrection("I use Claude", for: id)
        history.applyVerdicts([FixJudge.Judged(item: item, verdicts: nil)], trainUnreviewed: false)
        XCTAssertEqual(history.entries[0].intake?.tries, 1, "left out: one more try")
        history.applyVerdicts([FixJudge.Judged(item: item, verdicts: [.style])], trainUnreviewed: false)
        XCTAssertEqual(history.entries[0].intake?.changes.first?.verdict, .style)
        XCTAssertEqual(HistoryStore(fileURL: history.fileURL, defaults: makeDefaults(self)).entries[0].intake?.changes.first?.verdict, .style, "saved")
    }

    // MARK: Counting with the judge

    func testWithTheJudgeUnjudgedChangesWaitAndOnlyMisheardCounts() {
        var waiting = entry("I use cloud", correction: "I use Claude")
        XCTAssertEqual(CandidateTally.support(in: [waiting]).first?.term, "Claude", "rules, judge off")
        XCTAssertTrue(CandidateTally.support(in: [waiting], judging: true).isEmpty, "waits for a verdict")
        waiting.intake!.tries = FixJudge.maxTries
        XCTAssertEqual(CandidateTally.support(in: [waiting], judging: true).first?.term, "Claude", "given up on: the rules")

        var style = entry("I use cloud", correction: "I use Claude")
        style.intake!.changes[0].verdict = .style
        XCTAssertTrue(CandidateTally.support(in: [style]).isEmpty)
        var misheard = entry("we talked to open router today", correction: "we talked to OpenRouter today")
        misheard.intake!.changes = misheard.intake!.changes.map { WordChange(old: $0.old, new: $0.new, verdict: .misheard) }
        XCTAssertEqual(CandidateTally.support(in: [misheard], judging: true).first?.heard.first?.misheard, true, "misheard counts while judging")
        var long = entry("we talked to the folks at open router team today", correction: "we talked to OpenRouter today")
        long.intake!.changes = long.intake!.changes.map { WordChange(old: $0.old, new: $0.new, verdict: .misheard) }
        XCTAssertTrue(CandidateTally.support(in: [long], judging: true).isEmpty, "misheard, but over 4 words: the shape still rules it out")
    }

    // MARK: Backends

    /// The judge's own default model (not Learn's teacher's, though the same model today), and where it runs.
    func testTheJudgesDefaultModelAndSetups() {
        XCTAssertEqual(FixJudge.defaultModel, "anthropic/claude-sonnet-5.5")
        XCTAssertEqual(makeSettings(self).judgeModel, FixJudge.defaultModel)
        XCTAssertEqual(FixJudge.modelID("  "), FixJudge.defaultModel)
        XCTAssertTrue(FixJudge.runs(on: .cloudFlash))
        XCTAssertFalse(FixJudge.runs(on: .onDevice))
    }

    /// The judge needs a cloud setup: on one that polishes on this Mac it never runs (nothing is sent;
    /// the rules count), even with a key and the setting on. A `judgeUsesCloud` left by an unreleased
    /// build is ignored.
    func testTheJudgeNeedsACloudSetup() throws {
        let defaults = makeDefaults(self)
        defaults.set(true, forKey: "judgeUsesCloud")
        let settings = makeSettings(self, defaults: defaults)
        settings.judgeFixes = true
        settings.setOpenRouterKey("sk-test")
        settings.setup = .onDevice
        XCTAssertNil(FixJudge.backend(settings: settings), "On-device: no judge, even with a key")

        settings.setup = .cloudFlash
        XCTAssertEqual((FixJudge.backend(settings: settings) as? OpenRouterJudge)?.model, FixJudge.defaultModel)
        settings.judgeModel = " google/gemini-3.8-flash "
        XCTAssertEqual((FixJudge.backend(settings: settings) as? OpenRouterJudge)?.model, "google/gemini-3.8-flash")
        settings.setOpenRouterKey(nil)
        XCTAssertNil(FixJudge.backend(settings: settings), "no key")
        settings.setOpenRouterKey("sk-test")

        // Mixed setups: the judge follows the polish model, not the speech model.
        let cloudSpeechApplePolish = try setup(#"{"id": "a", "title": "A", "speech": "openrouter:qwen/qwen3-asr-1.7b", "polish": "apple", "prompt": "v3"}"#)
        settings.setup = cloudSpeechApplePolish
        XCTAssertTrue(cloudSpeechApplePolish.usesCloud)
        XCTAssertNil(FixJudge.backend(settings: settings))
        let localSpeechCloudPolish = try setup(#"{"id": "b", "title": "B", "speech": "apple", "polish": "openrouter:deepseek/deepseek-v4.1-flash", "prompt": "v7"}"#)
        settings.setup = localSpeechCloudPolish
        XCTAssertTrue(FixJudge.backend(settings: settings) is OpenRouterJudge)
    }

    private func setup(_ json: String) throws -> DictationSetup {
        try JSONDecoder().decode(DictationSetup.self, from: Data(json.utf8))
    }

    /// The request names the app, puts the stable instructions first and the terms before the fixes
    /// (cacheable where the model needs a breakpoint).
    func testTheCloudRequest() throws {
        let items = [JudgeItem(id: UUID(), wrote: "I use cloud", target: "I use Claude", changes: [WordChange(old: "cloud", new: "Claude")])]
        let anthropic = OpenRouterJudge(model: "anthropic/claude-sonnet-5.5", apiKey: "k").request(items, terms: ["Claude"])
        for (field, value) in OpenRouter.appHeaders { XCTAssertEqual(anthropic.value(forHTTPHeaderField: field), value) }
        let body = try XCTUnwrap(anthropic.httpBody.flatMap(OpenRouter.json))
        XCTAssertEqual(body["model"] as? String, "anthropic/claude-sonnet-5.5")
        XCTAssertEqual(body["temperature"] as? Int, 0)
        XCTAssertEqual(body["reasoning"] as? [String: Bool], ["enabled": false])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages[0]["content"] as? String, FixJudge.instructions)
        let parts = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(parts[0]["text"] as? String, "Vocabulary terms: Claude\n\n")
        XCTAssertNotNil(parts[0]["cache_control"])
        XCTAssertEqual(parts[1]["text"] as? String, FixJudge.message(items, terms: ["Claude"]).rest)

        let other = OpenRouterJudge(model: "google/gemini-3.8-flash", apiKey: "k").request(items, terms: [])
        let plain = try XCTUnwrap(other.httpBody.flatMap(OpenRouter.json)?["messages"] as? [[String: Any]])
        XCTAssertEqual(plain[1]["content"] as? String, "Vocabulary terms: (none)\n\n" + FixJudge.message(items, terms: []).rest)
    }

    /// An answer is read, its cost kept; a model that can't turn thinking off is asked again at the
    /// lowest effort; a failed call throws (no try counted).
    func testTheCloudJudgeAnswers() async throws {
        let items = [JudgeItem(id: UUID(), wrote: "I use cloud", target: "I use Claude", changes: [WordChange(old: "cloud", new: "Claude")])]
        let ok = #"{"choices": [{"message": {"content": "{\"fixes\": [{\"fix\": 1, \"verdicts\": [\"misheard\"]}]}"}}], "usage": {"prompt_tokens": 500, "completion_tokens": 20, "cost": 0.0012}}"#
        StubURLProtocol.respond = { request in
            (StubURLProtocol.body(request)?["reasoning"] as? [String: Bool]) == ["enabled": false]
                ? .success((400, #"{"error": {"message": "Reasoning is mandatory for this endpoint and cannot be disabled."}}"#))
                : .success((200, ok))
        }
        let judge = OpenRouterJudge(model: "openai/gpt-7", apiKey: "k", session: StubURLProtocol.session())
        let answer = try await judge.judge(items, terms: [])
        XCTAssertEqual(answer.verdicts, [[.misheard]])
        XCTAssertEqual(answer.usage?.cost, 0.0012)
        XCTAssertEqual(StubURLProtocol.sent.count, 2)

        StubURLProtocol.respond = { _ in .success((402, #"{"error": {"message": "Insufficient credits"}}"#)) }
        do {
            _ = try await OpenRouterJudge(model: "m", apiKey: "k", session: StubURLProtocol.session()).judge(items, terms: [])
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Insufficient credits")
            XCTAssertTrue(FixJudge.countsATry(error), "refused: it would fail the same way again")
        }
    }

    // MARK: Live

    /// One real batch through the cloud judge's own request path. Opt-in: ./test.sh --live (~$0.002).
    func testLiveJudgeBatch() async throws {
        let key = try liveOpenRouterKey()
        func item(_ text: String, _ target: String) -> JudgeItem {
            JudgeItem(id: UUID(), wrote: text, target: target, changes: FixIntake.changes(from: text, to: target))
        }
        let items = [item("Ask open router for the price.", "Ask OpenRouter for the price."),
                     item("Let's meet on Tuesday at noon.", "Let's meet on Thursday at noon."),
                     item("我们用deep sea的模型", "我们用DeepSeek的模型")]
        XCTAssertEqual(items.map(\.changes.count), [1, 1, 1])
        let answer = try await OpenRouterJudge(model: FixJudge.defaultModel, apiKey: key).judge(items, terms: ["OpenRouter", "DeepSeek"])
        print("[live] judge verdicts \(answer.verdicts), cost $\(answer.usage?.cost ?? 0)")
        XCTAssertEqual(answer.verdicts.compactMap { $0 }.count, 3, "every fix covered")
        XCTAssertEqual(answer.verdicts[0], [.misheard])
        XCTAssertEqual(answer.verdicts[1], [.changedMind])
        XCTAssertEqual(answer.verdicts[2], [.misheard])
        XCTAssertNotNil(answer.usage)
    }
}
