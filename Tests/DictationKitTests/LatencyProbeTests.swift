import XCTest
@testable import DictationKit

/// The turnaround benchmark's in-app side: real CloudEngine stop → upload path and
/// PolishService, with fakes standing in for the network.
final class LatencyRunnerTests: XCTestCase {
    static let clip = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../bench/audio/mixed-01.wav").standardized.path

    private func run(_ runner: LatencyRunner, _ trial: LatencyTrial) -> LatencySample? {
        let done = expectation(description: trial.id)
        var sample: LatencySample?
        runner.run(trial) { sample = $0; done.fulfill() }
        wait(for: [done], timeout: 5)
        return sample
    }

    func testTimesTranscriptionThenEachPolishBackend() throws {
        let runner = LatencyRunner()
        runner.transcriptionClient = FakeTranscriptionClient(text: "帮我 build 一个", delay: 0.2)
        runner.polishers = ["apple": FakePolish(delay: 0.1), "openrouter:fast": FakePolish(delay: 0.02)]
        let trial = LatencyTrial(id: "t1", file: Self.clip, stt: "openrouter:qwen/qwen3-asr-1.7b",
                                 polish: ["apple", "openrouter:fast"])
        let sample = try XCTUnwrap(run(runner, trial))

        XCTAssertNil(sample.error)
        XCTAssertEqual(sample.raw, "帮我 build 一个")
        let transcribe = try XCTUnwrap(sample.transcribe)
        XCTAssertGreaterThanOrEqual(transcribe, 0.2, "includes the upload round trip")
        XCTAssertLessThan(transcribe, 1.5)
        XCTAssertEqual(sample.polish.map(\.model), ["apple", "openrouter:fast"], "in the planned order")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(sample.polish[0].seconds), 0.1)
        XCTAssertEqual(sample.polish[0].text, "帮我 build 一个。")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(sample.polish[1].seconds), 0.02)
    }

    func testPolishFailureIsReportedNotHiddenBehindTheRawText() throws {
        let runner = LatencyRunner()
        runner.transcriptionClient = FakeTranscriptionClient(text: "帮我 build 一个", delay: 0)
        runner.polishers = ["apple": FakePolish(delay: 0, error: .unavailable("model unavailable"))]
        let sample = try XCTUnwrap(run(runner, LatencyTrial(id: "t", file: Self.clip, stt: "openrouter:m", polish: ["apple"])))
        XCTAssertNotNil(sample.transcribe)
        XCTAssertNil(sample.polish[0].seconds, "a failed polish must not count as a fast one")
        XCTAssertEqual(sample.polish[0].error, "model unavailable")
    }

    func testEmptyTranscriptIsAnErrorAndSkipsPolish() throws {
        let runner = LatencyRunner()
        let client = FakeTranscriptionClient(text: "")
        runner.transcriptionClient = client
        runner.polishers = ["apple": FakePolish()]
        let sample = try XCTUnwrap(run(runner, LatencyTrial(id: "t", file: Self.clip, stt: "openrouter:m", polish: ["apple"])))
        XCTAssertEqual(sample.error, "empty transcript")
        XCTAssertNil(sample.polish[0].seconds)
    }

    func testUnknownModelsAndMissingFilesFailFast() throws {
        let runner = LatencyRunner()
        runner.transcriptionClient = FakeTranscriptionClient(text: "帮我 build 一个", delay: 0)
        var sample = try XCTUnwrap(run(runner, LatencyTrial(id: "a", file: Self.clip, stt: "whisper:x", polish: [])))
        XCTAssertEqual(sample.error, "unknown speech model whisper:x")
        sample = try XCTUnwrap(run(runner, LatencyTrial(id: "b", file: "/nonexistent.wav", stt: "openrouter:m", polish: [])))
        XCTAssertTrue(sample.error?.contains("could not read") == true)
        sample = try XCTUnwrap(run(runner, LatencyTrial(id: "c", file: Self.clip, stt: "openrouter:m", polish: ["gpt:x"])))
        XCTAssertEqual(sample.polish.first?.error, "unknown polish model gpt:x")
    }

    func testBackupSuffixTurnsOnTheBackupAsTheSettingDoes() throws {
        let runner = LatencyRunner()
        runner.backupWait = 0.1
        let client = FakeTranscriptionClient()  // the main model never answers
        client.scripts["qwen/qwen3-asr-0.6b"] = FakeTranscriptionClient.Script(delay: 0, result: FakeTranscriptionClient.text("backup"))
        runner.transcriptionClient = client
        let sample = try XCTUnwrap(run(runner, LatencyTrial(id: "on", file: Self.clip,
                                                            stt: "openrouter:qwen/qwen3-asr-1.7b+backup", polish: [])))
        XCTAssertEqual(sample.raw, "backup")
        XCTAssertEqual(sample.answeredBy, "openrouter:qwen/qwen3-asr-0.6b")
        XCTAssertEqual(client.asked.map(\.model), ["qwen/qwen3-asr-1.7b", "qwen/qwen3-asr-0.6b"])
    }

    func testWithoutTheSuffixOnlyTheMainModelIsAsked() throws {
        let runner = LatencyRunner()
        runner.backupWait = 0.1
        let client = FakeTranscriptionClient()
        client.scripts["qwen/qwen3-asr-1.7b"] = FakeTranscriptionClient.Script(delay: 0.3, result: FakeTranscriptionClient.text("main"))
        runner.transcriptionClient = client
        let sample = try XCTUnwrap(run(runner, LatencyTrial(id: "off", file: Self.clip,
                                                            stt: "openrouter:qwen/qwen3-asr-1.7b", polish: [])))
        XCTAssertEqual(sample.answeredBy, "openrouter:qwen/qwen3-asr-1.7b")
        XCTAssertEqual(client.asked.map(\.model), ["qwen/qwen3-asr-1.7b"])
    }

    func testRealBackendsForSpecs() throws {
        let runner = LatencyRunner()
        runner.apiKey = "k"
        XCTAssertNotNil(runner.polisher(for: "apple")?.backend as? OnDevicePolish)
        let cloud = runner.polisher(for: "openrouter:anthropic/claude-haiku-5.5")?.backend as? OpenRouterPolish
        XCTAssertEqual(cloud?.model, "anthropic/claude-haiku-5.5")
        XCTAssertEqual(cloud?.apiKey, "k")
        XCTAssertNil(runner.polisher(for: "none"))
    }

    func testTextTrialSkipsTranscriptionAndPolishesTheText() throws {
        let runner = LatencyRunner()
        runner.speakingTime = 0
        runner.polishers = ["apple": FakePolish(delay: 0.01)]
        let trial = LatencyTrial(id: "t", file: "", stt: "text", polish: ["apple"], text: "嗯帮我 merge 一下")
        let sample = try XCTUnwrap(run(runner, trial))
        XCTAssertNil(sample.error)
        XCTAssertEqual(sample.raw, "嗯帮我 merge 一下")
        XCTAssertEqual(sample.transcribe, 0)
        XCTAssertEqual(sample.polish.first?.text, "嗯帮我 merge 一下。")
    }

    func testPromptOverridesReachEveryBackend() throws {
        let runner = LatencyRunner()
        runner.instructions = "Only clean up."
        runner.wrap = false
        let apple = try XCTUnwrap(runner.polisher(for: "apple")?.backend as? OnDevicePolish)
        XCTAssertEqual(apple.instructions, "Only clean up.")
        XCTAssertFalse(apple.wrap)
        let cloud = try XCTUnwrap(runner.polisher(for: "openrouter:m")?.backend as? OpenRouterPolish)
        XCTAssertEqual(cloud.instructions, "Only clean up.")
        XCTAssertFalse(cloud.wrap)
        let defaults = LatencyRunner()
        let cloudDefault = try XCTUnwrap(defaults.polisher(for: "openrouter:m")?.backend as? OpenRouterPolish)
        XCTAssertEqual(cloudDefault.instructions, DictationSetup.cloudFlash.promptText, "the setup's prompt unless overridden")
        XCTAssertTrue(cloudDefault.wrap, "tags unless turned off")
        XCTAssertTrue(try XCTUnwrap(defaults.polisher(for: "apple")?.backend as? OnDevicePolish).wrap)
    }

    /// The benchmark times polish the way the app now runs it: the model is prepared when
    /// dictation starts, before the transcript exists.
    func testBenchmarkPreparesPolishWhenDictationStarts() {
        let log = EventLog()
        let runner = LatencyRunner()
        let client = FakeTranscriptionClient(text: "hello", delay: 0.05)
        client.log = log
        runner.transcriptionClient = client
        runner.polishers = ["apple": FakePolish(log: log)]
        let done = expectation(description: "trial")
        runner.run(LatencyTrial(id: "t", file: LatencyRunnerTests.clip, stt: "openrouter:m", polish: ["apple"])) { _ in
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(log.events, ["prepare", "upload", "polish"])
    }
}

final class LatencyProbeTests: XCTestCase {
    func testPlanDecodesPolishOnlyTrialsAndPromptOverrides() throws {
        let json = """
            {"pause": 0, "timeout": 5, "instructions": "P", "wrap": true,
             "trials": [{"id": "a", "file": "", "stt": "text", "polish": ["apple"], "text": "hi"},
                        {"id": "b", "file": "x.wav", "stt": "openrouter:m", "polish": []}]}
            """
        let plan = try JSONDecoder().decode(LatencyPlan.self, from: Data(json.utf8))
        XCTAssertEqual(plan.instructions, "P")
        XCTAssertEqual(plan.wrap, true)
        XCTAssertEqual(plan.trials.map(\.text), ["hi", nil])
        let old = try JSONDecoder().decode(LatencyPlan.self, from: Data(#"{"pause": 0, "timeout": 5, "trials": []}"#.utf8))
        XCTAssertNil(old.instructions, "plans from the latency suite don't set them")
        XCTAssertNil(old.wrap, "unset means wrapped, like the app")
    }

    /// The plan format bench/suite.py writes; a hung trial times out and the run continues.
    func testRunsPlanWritesOneLinePerTrialAndTimesOutHungTrials() throws {
        let plan = makeTempURL(self, "plan.json")
        let out = makeTempURL(self, "out.jsonl")
        let clip = LatencyRunnerTests.clip
        try """
            {"pause": 0, "timeout": 0.5, "trials": [
              {"id": "hung", "file": "\(clip)", "stt": "openrouter:hang", "polish": []},
              {"id": "ok", "file": "\(clip)", "stt": "openrouter:m", "polish": ["apple"]}
            ]}
            """.write(to: plan, atomically: true, encoding: .utf8)
        let probe = try XCTUnwrap(LatencyProbe(planPath: plan.path, outPath: out.path, apiKey: "k"))
        let client = FakeTranscriptionClient(text: "帮我 build 一个", delay: 0.05)
        client.scripts["hang"] = .never
        probe.runner.transcriptionClient = client
        probe.runner.polishers = ["apple": FakePolish(delay: 0.01)]
        let finished = expectation(description: "finished")
        probe.onFinish = { finished.fulfill() }
        probe.run()
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path),
                      "created at launch, so suite.py can tell this build understood the plan")
        wait(for: [finished], timeout: 5)

        let lines = try String(contentsOf: out, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let rows = try lines.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        XCTAssertEqual(rows[0]["id"] as? String, "hung")
        XCTAssertEqual(rows[0]["error"] as? String, "timed out after 0.5 s")
        XCTAssertEqual(rows[1]["id"] as? String, "ok")
        XCTAssertNotNil(rows[1]["transcribe"] as? Double)
        let polish = try XCTUnwrap((rows[1]["polish"] as? [[String: Any]])?.first)
        XCTAssertEqual(polish["model"] as? String, "apple")
        XCTAssertNotNil(polish["seconds"] as? Double)
    }

    func testRejectsUnreadablePlan() {
        let plan = makeTempURL(self, "plan.json")
        try? "not json".write(to: plan, atomically: true, encoding: .utf8)
        XCTAssertNil(LatencyProbe(planPath: plan.path, outPath: makeTempURL(self, "o").path, apiKey: ""))
    }
}

