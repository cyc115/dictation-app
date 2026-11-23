import AVFoundation
import XCTest
@testable import DictationKit

/// The history bench's harness (bench/suite.py history). In every ./test.sh it runs the fixture's job
/// (bench/history_fixture/job.json) with a stubbed network and a fake speech model, so it can't rot; for
/// real only when bench/suite.py history runs it (HISTORY_BENCH_JOB, HISTORY_BENCH_OUT, HISTORY_BENCH_KEY).
@MainActor
final class HistoryBenchTests: XCTestCase {
    private let fixture = benchFolder.appendingPathComponent("history_fixture")

    private func rows(_ url: URL) throws -> [[String: Any]] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    /// Answers each polish request with its transcript as it was sent, at $0.001 a call.
    private func stubPolish() -> URLSession {
        let session = StubURLProtocol.session()
        StubURLProtocol.respond = { request in
            let body = StubURLProtocol.body(request) ?? [:]
            let user = ((body["messages"] as? [[String: Any]])?.last?["content"] as? String) ?? ""
            let text = user.replacingOccurrences(of: "<transcript>\n", with: "").replacingOccurrences(of: "\n</transcript>", with: "")
            let reply: [String: Any] = ["choices": [["message": ["role": "assistant", "content": text]]],
                                        "usage": ["prompt_tokens": 100, "completion_tokens": 20, "cost": 0.001]]
            return .success((200, String(decoding: try! JSONSerialization.data(withJSONObject: reply), as: UTF8.self)))
        }
        return session
    }

    private func fakeSpeech(downloaded: Bool = true, text: String = "can you send me the nodes from today's meeting") -> (LocalSpeechModel, FakeSpeechRuntime) {
        let runtime = FakeSpeechRuntime()
        runtime.text = text
        if downloaded { runtime.directory = URL(fileURLWithPath: "/tmp/fake-model") }
        let model = LocalSpeechModel(repo: "test/qwen", runtime: runtime)
        model.onBattery = { false }
        return (model, runtime)
    }

    private func bench(_ job: HistoryBenchJob, out: URL) throws -> HistoryBench {
        let bench = try HistoryBench(job: job, folder: fixture, out: out, test: self)
        bench.key = "sk-test"
        bench.session = stubPolish()
        return bench
    }

    private func id(_ n: Int) -> String { "DDDDDDDD-0000-4000-8000-00000000000\(n)" }

    // MARK: The contract with the bench

    /// The bench splits words and trims their edges as WordDiff and FixIntake do (the same fixture both sides read).
    func testWordsAndEdgesAreTheBenchs() throws {
        struct Words: Decodable { let text: String; let words: [String] }
        struct Edge: Decodable { let word: String; let trimmed: String }
        struct File: Decodable { let words: [Words]; let edges: [Edge] }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: fixture.appendingPathComponent("words.json")))
        for c in file.words { XCTAssertEqual(WordDiff.words(c.text).map { String(c.text[$0]) }, c.words) }
        for c in file.edges { XCTAssertEqual(c.word.trimmingCharacters(in: FixIntake.edges), c.trimmed) }
    }

    /// The fixture's word changes are what FixIntake makes of its fixes, so its scoring means what the app's would.
    func testTheFixturesChangesAreFixIntakes() throws {
        let history = try JSONFile.decoder.decode([HistoryEntry].self, from: Data(contentsOf: fixture.appendingPathComponent("history.json")))
        for entry in history {
            guard let intake = entry.currentIntake else { continue }
            XCTAssertEqual(FixIntake.changes(from: entry.text, to: intake.of).map { [$0.old, $0.new] }, intake.changes.map { [$0.old, $0.new] },
                           entry.id.uuidString)
        }
    }

    func testCharacterEditsRebuildTheFix() {
        for (old, new) in [("I use cloud code.", "I use Claude Code."), ("我们用克劳的写代码", "我们用 Claude 写代码"), ("abc", ""), ("", "abc")] {
            var box = Array(old)
            for edit in HistoryBench.edits(from: old, to: new).reversed() { box.replaceSubrange(edit.range, with: edit.text) }
            XCTAssertEqual(String(box), new)
        }
    }

    // MARK: The harness on the fixture

    func testRunsTheFixtureJob() async throws {
        let job = try HistoryBench.load(fixture.appendingPathComponent("job.json"))
        let out = makeTempURL(self, "rows.jsonl")
        let bench = try bench(job, out: out)
        let (model, runtime) = fakeSpeech()
        // Again's context (it has "notes") comes back as the context itself, the echo the guard catches.
        runtime.answer = { context in context.contains("notes") ? context : nil }
        bench.speechModel = model
        try await bench.run()
        let rows = try rows(out)
        func part(_ n: Int) -> [[String: Any]] { rows.filter { $0["part"] as? Int == n } }

        let setup = try XCTUnwrap(part(0).first { $0["kind"] as? String == "setup" })
        XCTAssertEqual(setup["setup"] as? String, "cloud-flash")
        XCTAssertEqual(setup["basePrompt"] as? String, "v7", "the setup's own prompt")
        XCTAssertEqual(setup["learnedPrompt"] as? String, "v8", "its active learned prompt (the fixture's learned-prompts.json)")
        XCTAssertEqual(part(0).filter { $0["kind"] as? String == "dictation" && $0["error"] == nil }.count, 5)

        // Part 1: the real request per arm; the stub echoes the transcript, so only replacement fixes a word.
        let polish = part(1)
        XCTAssertEqual(polish.count, job.polish.count)
        func output(_ arm: String, _ n: Int, prompt: String = "base") -> String {
            polish.first { $0["arm"] as? String == arm && $0["id"] as? String == id(n) && $0["round"] as? Int == 1 && $0["prompt"] as? String == prompt }?["output"] as? String ?? ""
        }
        XCTAssertEqual(Set(polish.compactMap { $0["prompt"] as? String }), ["learned", "base", "v4"])
        XCTAssertEqual(Set(polish.filter { $0["prompt"] as? String == "v4" }.compactMap { $0["promptVersion"] as? String }), ["v4"])
        XCTAssertEqual(output("again", 1, prompt: "learned"), output("again", 1))
        XCTAssertTrue(output("off", 1).contains("nodes"))
        XCTAssertTrue(output("terms-only", 1).contains("nodes"), "terms told to polish, nothing replaced")
        XCTAssertTrue(output("again", 1).contains("notes"))
        XCTAssertTrue(output("held-out", 1).contains("nodes"), "the entry only this dictation taught is held out")
        XCTAssertTrue(output("again", 4).contains("Hammerspoon"))
        XCTAssertFalse(output("held-out", 4).contains("Hammerspoon"))
        XCTAssertTrue(output("again", 2).contains("Claude"))
        XCTAssertFalse(output("held-out", 2).contains("Claude"), "its variant came from this dictation alone")
        XCTAssertTrue(output("again", 9).contains("Neovim"))
        XCTAssertFalse(output("held-out", 9).contains("Neovim"), "a learned entry whose candidate says nothing: History names its source")
        let systems = StubURLProtocol.sent.compactMap { (StubURLProtocol.body($0)?["messages"] as? [[String: Any]])?.first?["content"] as? String }
        XCTAssertEqual(systems.count, job.polish.count)
        XCTAssertEqual(systems.filter { $0.contains(Vocabulary.promptHeader) }.count, job.polish.filter { $0.arm != "off" }.count,
                       "the terms block in every arm but off")
        XCTAssertEqual(systems.filter { $0.hasPrefix("You clean up dictated text for the history bench fixture.") }.count,
                       job.polish.filter { $0.prompt == "learned" }.count, "the learned prompt for the learned trials")
        // Each prompt up to its closing paragraph (the terms block goes in before it): v4 and v7 share their opening.
        func body(_ prompt: String) -> String { prompt.range(of: "\n\n", options: .backwards).map { String(prompt[..<$0.lowerBound]) } ?? prompt }
        XCTAssertEqual(systems.filter { $0.hasPrefix(body(DictationSetup.cloudFlash.promptText)) }.count,
                       job.polish.filter { $0.prompt == "base" }.count, "Cloud Flash's own prompt for the base trials")
        XCTAssertEqual(systems.filter { $0.hasPrefix(body(try! PolishPrompt.text(for: "v4"))) }.count,
                       job.polish.filter { $0.prompt == "v4" }.count, "the built-in v4 for the v4 trials")
        XCTAssertEqual(StubURLProtocol.sent.first?.value(forHTTPHeaderField: "X-Title"), "DictationApp", "names its app")
        XCTAssertEqual(polish.compactMap { $0["cost"] as? Double }.reduce(0, +), 0.001 * Double(job.polish.count), accuracy: 1e-9)

        // Part 2: the speech hint as a dictation builds it.
        XCTAssertEqual(part(2).count, job.speech.count)
        XCTAssertEqual(runtime.contexts.count, job.speech.count + 1, "again's echo is transcribed once more")
        XCTAssertEqual(runtime.contexts.filter { $0.contains("notes") }.count, 1, "again only: held out drops it, off has none")
        XCTAssertEqual(runtime.contexts.filter(\.isEmpty).count, 2, "off, and again's second pass")
        let againSpeech = try XCTUnwrap(part(2).first { $0["arm"] as? String == "again" })
        XCTAssertEqual(againSpeech["echoed"] as? Bool, true)
        XCTAssertEqual(againSpeech["transcript"] as? String, "can you send me the nodes from today's meeting", "the second pass, delivered")
        XCTAssertEqual(againSpeech["replaced"] as? String, "can you send me the notes from today's meeting")
        XCTAssertEqual(part(2).filter { $0["echoed"] as? Bool == false }.count, job.speech.count - 1)

        // Part 3: reach, and the flags.
        let hits = part(3).filter { $0["kind"] as? String == "hit" }
        XCTAssertEqual(Set(hits.compactMap { $0["id"] as? String }).count, hits.count)
        XCTAssertTrue(hits.contains { $0["id"] as? String == "EEEEEEEE-0000-4000-8000-000000000003" }, "an unfixed dictation with an ordinary word")
        let entries = part(3).filter { $0["kind"] as? String == "entry" }
        XCTAssertEqual(entries.count, 6, "enabled entries")
        func flags(_ term: String) -> [String: Any] { (entries.first { $0["term"] as? String == term }?["variants"] as? [[String: Any]])?.first ?? [:] }
        XCTAssertEqual(flags("notes")["ordinary"] as? Bool, true)
        XCTAssertEqual(flags("reMarkable")["caseOnly"] as? Bool, true)
        XCTAssertEqual(flags("Hammerspoon")["ordinary"] as? Bool, false)

        // Part 4: a time per dictation with a raw transcript.
        XCTAssertEqual((part(4).first?["seconds"] as? [Double])?.count, 9)

        // Part 5: the rules count a change of mind; the judge doesn't.
        func terms(_ method: String) -> Set<String> {
            Set(((part(5).first { $0["method"] as? String == method }?["candidates"] as? [[String: Any]]) ?? []).compactMap { $0["term"] as? String })
        }
        XCTAssertTrue(terms("rules").contains("this morning"))
        XCTAssertFalse(terms("judge").contains("this morning"))
        XCTAssertTrue(terms("judge").contains("Claude"))

        // Part 6: every fix rebuilt by both trackers; Chinese flagged as needing an input method.
        let replays = part(6)
        XCTAssertEqual(replays.count, 10)
        XCTAssertEqual(replays.filter { $0["exact"] as? Bool == true }.count, 10)
        XCTAssertEqual(Set(replays.filter { $0["needsInputMethod"] as? Bool == true }.compactMap { $0["id"] as? String }), [id(2)])

        let done = try XCTUnwrap(rows.last)
        XCTAssertEqual(done["kind"] as? String, "done")
        XCTAssertEqual(done["stopped"] as? Bool, false)
    }

    /// Once the answers' cost reaches the cap, nothing more is sent; the rows so far are kept.
    func testStopsSendingAtTheCostCap() async throws {
        var job = try HistoryBench.load(fixture.appendingPathComponent("job.json"))
        job.maxCost = 0.0025
        job.parts = [1]
        let out = makeTempURL(self, "rows.jsonl")
        try await bench(job, out: out).run()
        let rows = try rows(out)
        XCTAssertEqual(StubURLProtocol.sent.count, 3)
        XCTAssertEqual(rows.filter { $0["part"] as? Int == 1 && $0["arm"] != nil }.count, 3)
        XCTAssertEqual(rows.filter { $0["kind"] as? String == "stopped" }.count, 1)
        XCTAssertEqual(rows.last?["stopped"] as? Bool, true)
    }

    /// A setup with no learned prompt active: the learned trials aren't run (the bench asks for base only then).
    func testWithoutALearnedPromptOnlyBaseRuns() async throws {
        var job = try HistoryBench.load(fixture.appendingPathComponent("job.json"))
        job.learnedPrompts = nil
        job.parts = [1]
        let out = makeTempURL(self, "rows.jsonl")
        try await bench(job, out: out).run()
        let rows = try rows(out)
        XCTAssertEqual(StubURLProtocol.sent.count, job.polish.filter { $0.prompt != "learned" }.count, "base and v4 still run")
        XCTAssertEqual(rows.filter { $0["kind"] as? String == "skipped" && $0["prompt"] as? String == "learned" }.count, 1)
        XCTAssertTrue(rows.first { $0["kind"] as? String == "setup" }?["learnedPrompt"] is NSNull)
    }

    /// No key: part 1 sends nothing (and never falls back to polishing on this Mac).
    func testWithoutAKeyPart1IsSkipped() async throws {
        var job = try HistoryBench.load(fixture.appendingPathComponent("job.json"))
        job.parts = [1]
        let out = makeTempURL(self, "rows.jsonl")
        let bench = try bench(job, out: out)
        bench.key = nil
        try await bench.run()
        XCTAssertTrue(StubURLProtocol.sent.isEmpty)
        XCTAssertEqual(try rows(out).filter { $0["kind"] as? String == "skipped" }.count, 1)
    }

    /// A model that isn't downloaded is never downloaded: part 2 says it's skipped.
    func testSkipsSpeechWhenTheModelIsntDownloaded() async throws {
        var job = try HistoryBench.load(fixture.appendingPathComponent("job.json"))
        job.parts = [2]
        let out = makeTempURL(self, "rows.jsonl")
        let bench = try bench(job, out: out)
        let (model, runtime) = fakeSpeech(downloaded: false)
        bench.speechModel = model
        try await bench.run()
        XCTAssertEqual(try rows(out).first { $0["part"] as? Int == 2 }?["kind"] as? String, "skipped")
        XCTAssertTrue(runtime.log.isEmpty, "no download, no load")
    }

    // MARK: For real

    /// bench/suite.py history run: the job it wrote, on a snapshot of your History, with the bench's key.
    func testRunsTheJobItIsGiven() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let jobPath = env["HISTORY_BENCH_JOB"], let outPath = env["HISTORY_BENCH_OUT"] else {
            throw XCTSkip("bench/suite.py history run runs it (HISTORY_BENCH_JOB, HISTORY_BENCH_OUT)")
        }
        let jobURL = URL(fileURLWithPath: jobPath)
        let job = try HistoryBench.load(jobURL)
        let bench = try HistoryBench(job: job, folder: jobURL.deletingLastPathComponent(), out: URL(fileURLWithPath: outPath), test: self)
        XCTAssertNotEqual(bench.url(job.history).standardizedFileURL, HistoryStore.defaultFileURL.standardizedFileURL, "a snapshot, never the live file")
        bench.key = env["HISTORY_BENCH_KEY"]
        bench.speechModel = LocalSpeechModel(repo: DictationSetup.onDevice.localModelID!)
        bench.verbose = true
        try await bench.run()
    }
}

/// The app's seams the history bench runs through, each the code a dictation uses.
final class HistoryBenchSeamTests: XCTestCase {
    private let terms = Vocabulary([VocabularyEntry(term: "Claude", heardAs: ["cloud"], added: Date())])

    /// Replaced before polish (so a failed polish still has the terms) and again after it.
    func testRefineReplacesAroundPolish() async {
        let polished = await DictationController.refine("ask cloud", terms: terms, polisher: PolishService(backend: FakePolish(output: "Ask cloud.")))
        XCTAssertEqual(polished.text, "Ask Claude.")
        XCTAssertEqual(polished.uses.values.reduce(0, +), 2, "once before, once after")
        XCTAssertNil(polished.error)
        let failed = await DictationController.refine("ask cloud", terms: terms,
                                                      polisher: PolishService(backend: FakePolish(error: .failed("down"))))
        XCTAssertEqual(failed.text, "ask Claude")
        XCTAssertEqual(failed.error, "down")
        let told = await DictationController.refine("ask cloud", terms: .none, polisher: PolishService(backend: FakePolish(output: "Ask cloud.")))
        XCTAssertEqual(told.text, "Ask cloud.", "no terms: nothing replaced (the bench's terms-only arm)")
    }

    func testSpeechHintIsYourTermsOnlyWhenOnAndOnDevice() {
        XCTAssertEqual(DictationController.speechHint(terms, setup: .onDevice, enabled: true), SpeechContext(words: ["Claude"]))
        XCTAssertEqual(DictationController.speechHint(terms, setup: .onDevice, enabled: false), .none)
        XCTAssertEqual(DictationController.speechHint(terms, setup: .cloudFlash, enabled: true), .none, "cloud speech takes no prompt")
        XCTAssertEqual(DictationController.speechHint(.none, setup: .onDevice, enabled: true), .none)
    }

    /// The cloud polish backend is called through the session it's given.
    func testPolishBackendTakesASession() async throws {
        let session = StubURLProtocol.session()
        StubURLProtocol.respond = { _ in .success((200, #"{"choices":[{"message":{"content":"Hi."}}]}"#)) }
        let backend = DictationSetup.cloudFlash.polishBackend(apiKey: "k", vocabulary: terms, onDevice: { _, _ in FakePolish() }, session: session)
        let answer = try await backend.polish("hi")
        XCTAssertEqual(answer, "Hi.")
        XCTAssertEqual(StubURLProtocol.sent.count, 1)
    }

    /// A heard standing in 3 dictations you didn't fix is ordinary, unless it stands there as the term itself.
    func testOrdinaryIsTheCandidateGuard() {
        let entries = ["the cloud", "a cloud", "cloud nine", "my remarkable", "Remarkable!", "remarkable"].map {
            HistoryEntry(date: Date(), text: $0, duration: 1)
        }
        XCTAssertEqual(CandidateTally.ordinary([(heard: "cloud", term: "Claude"), (heard: "remarkable", term: "reMarkable"),
                                                (heard: "nodes", term: "notes")], in: entries), [true, true, false])
        XCTAssertEqual(CandidateTally.ordinary([(heard: "cloud", term: "Claude")], in: Array(entries.prefix(2))), [false])
    }
}
