import XCTest
@testable import DictationKit

final class PolishServiceTests: XCTestCase {
    func testFailureFallsBackToTheRawTextAndSaysWhy() async {
        let service = PolishService(backend: FakePolish(error: .failed("HTTP 429")))
        let (text, error, _) = await service.polishReporting("um hello")
        XCTAssertEqual(text, "um hello", "you still get your words")
        XCTAssertEqual(error, "HTTP 429")
        do {
            _ = try await service.polished("um hello")
            XCTFail("polished() must throw so benchmarks see the failure")
        } catch {}
    }

    func testEmptyModelOutputKeepsRawTextAndTrimsWhitespace() async throws {
        let empty = try await PolishService(backend: FakePolish(output: "  \n")).polished("hello")
        XCTAssertEqual(empty, "hello")
        let trimmed = try await PolishService(backend: FakePolish(output: " Hello.\n")).polished("um hello")
        XCTAssertEqual(trimmed, "Hello.")
    }

    func testPreparePassesToTheModel() {
        let log = EventLog()
        PolishService(backend: FakePolish(log: log)).prepare()
        XCTAssertEqual(log.events, ["prepare"])
    }

    /// Kept recordings name the polish model.
    func testModelNames() {
        let onDevice: (String, Bool) -> PolishBackend = { OnDevicePolish(instructions: $0, wrap: $1) }
        XCTAssertEqual(DictationSetup.cloudFlash.polishBackend(apiKey: "k", onDevice: onDevice).name, "openrouter:deepseek/deepseek-v4.1-flash@Together,DeepInfra")
        XCTAssertEqual(DictationSetup.cloudFlash.polishBackend(apiKey: nil, onDevice: onDevice).name, "apple:on-device")
    }
}

final class OpenRouterPolishTests: XCTestCase {
    func testRequestSendsInstructionsAndTranscript() throws {
        let request = OpenRouterPolish.request(model: "anthropic/claude-haiku-5.5", apiKey: "sk-test", text: "um 帮我 build", instructions: PolishPrompt.v3)
        XCTAssertEqual(request.url, OpenRouter.chatEndpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "anthropic/claude-haiku-5.5")
        XCTAssertEqual(body["temperature"] as? Int, 0)
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
        XCTAssertEqual(messages[0]["content"], PolishPrompt.v3)
        XCTAssertEqual(messages[1]["content"], "um 帮我 build")
        XCTAssertEqual(body["reasoning"] as? [String: Bool], ["enabled": false], "no thinking for a cleanup")
        XCTAssertNil(body["provider"], "OpenRouter routes unless a provider is pinned")
    }

    func testPinnedProviderAndLowestReasoningForModelsThatMustThink() throws {
        let request = OpenRouterPolish.request(model: "openai/gpt-oss-120b", apiKey: "k", text: "t", instructions: "P", provider: "Groq")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["reasoning"] as? [String: String], ["effort": "minimal"])
        let provider = try XCTUnwrap(body["provider"] as? [String: Any])
        XCTAssertEqual(provider["order"] as? [String], ["Groq"])
        XCTAssertEqual(provider["allow_fallbacks"] as? Bool, false)
        for model in ["openai/gpt-5-mini", "openai/gpt-6.1-sol-pro", CorrectionSuggester.model.replacingOccurrences(of: "openrouter:", with: "")] {
            XCTAssertEqual(OpenRouter.reasoning(for: model) as? [String: String], ["effort": "minimal"],
                           "\(model) rejects reasoning off (\"Reasoning is mandatory\")")
        }
        let pinned = try XCTUnwrap(LatencyRunner().polisher(for: "openrouter:qwen/qwen3.8-27b@Cerebras")?.backend as? OpenRouterPolish)
        XCTAssertEqual(pinned.model, "qwen/qwen3.8-27b")
        XCTAssertEqual(pinned.provider, "Cerebras")
    }

    func testWrappedTranscriptAndCustomInstructions() throws {
        XCTAssertEqual(PolishService.userMessage("hi", wrap: false), "hi")
        XCTAssertEqual(PolishService.userMessage("hi", wrap: true), "<transcript>\nhi\n</transcript>")
        XCTAssertTrue(OnDevicePolish().wrap, "on-device polish wraps by default, like cloud polish")
        let request = OpenRouterPolish.request(model: "m", apiKey: "k", text: "t", instructions: "P")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual((body["messages"] as? [[String: String]])?.first?["content"], "P")
    }

    func testParsesReplyAndErrors() {
        let ok = Data(#"{"choices":[{"message":{"role":"assistant","content":"帮我 build。"}}]}"#.utf8)
        XCTAssertEqual(try OpenRouterPolish.parse(data: ok, status: 200).get(), "帮我 build。")
        guard case .failure(let e) = OpenRouterPolish.parse(data: Data(#"{"error":{"message":"No endpoints found"}}"#.utf8), status: 404)
        else { return XCTFail("expected failure") }
        XCTAssertEqual(e.localizedDescription, "No endpoints found")
        guard case .failure(let e2) = OpenRouterPolish.parse(data: Data("oops".utf8), status: 500)
        else { return XCTFail("expected failure") }
        XCTAssertTrue(e2.localizedDescription.contains("HTTP 500"))
    }
}

/// Cloud polish's fallback: a backup when the main model is late or fails, and a deadline after
/// which you get your raw words.
final class PolishFallbackTests: XCTestCase {
    private func fake(_ name: String, delay: TimeInterval = 0, error: PolishError? = nil, log: EventLog? = nil) -> FakePolish {
        let polish = FakePolish(delay: delay, output: name, error: error, log: log)
        polish.name = name
        return polish
    }

    func testMainOnTimeNeverAsksTheBackup() async throws {
        let log = EventLog()
        let service = PolishService(backend: fake("main", delay: 0.01), backup: fake("backup", log: log), backupAfter: 0.3)
        let answer = try await service.answer("hi")
        XCTAssertEqual(answer.text, "main")
        XCTAssertEqual(answer.by, ModelAnswer(main: "main"), "the backup wasn't asked")
        XCTAssertTrue(log.events.isEmpty, "the backup costs nothing when the main model is on time")
    }

    func testLateMainAsksTheBackupAndTheFirstAnswerWins() async throws {
        let service = PolishService(backend: fake("main", delay: 2), backup: fake("backup", delay: 0.05), backupAfter: 0.1)
        let started = Date()
        let answer = try await service.answer("hi")
        XCTAssertEqual(answer.text, "backup")
        XCTAssertEqual(answer.by, ModelAnswer(main: "main", backup: "backup", byBackup: true))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "the slow main request is cancelled, not waited for")
    }

    func testFailedMainAsksTheBackupAtOnce() async throws {
        let service = PolishService(backend: fake("main", error: .failed("host down")), backup: fake("backup"), backupAfter: 5)
        let started = Date()
        let answer = try await service.answer("hi")
        XCTAssertEqual(answer.text, "backup")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "no waiting out the delay after a failure")
    }

    func testBothFailingReportsTheFirstErrorAndKeepsYourWords() async {
        let service = PolishService(backend: fake("main", error: .failed("main down")),
                                    backup: fake("backup", delay: 0.05, error: .failed("backup down")), backupAfter: 0.1)
        let result = await service.polishReporting("my words")
        XCTAssertEqual(result.text, "my words")
        XCTAssertEqual(result.error, "main down")
        XCTAssertNil(result.by, "no model's answer was used")
    }

    func testDeadlineGivesYourWordsInsteadOfWaiting() async {
        let service = PolishService(backend: fake("main", delay: 5), backup: fake("backup", delay: 5), backupAfter: 0.05, deadline: 0.2)
        let started = Date()
        let result = await service.polishReporting("my words")
        XCTAssertEqual(result.text, "my words")
        XCTAssertEqual(result.error, "No answer within 0.2 s.")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testNoBackupOrDeadlineJustWaits() async throws {
        let answer = try await PolishService(backend: fake("main", delay: 0.2)).answer("hi")
        XCTAssertEqual(answer.text, "main", "on-device: slow, but no deadline cuts it off")
    }

    func testPrepareWarmsBoth() {
        let log = EventLog()
        PolishService(backend: FakePolish(log: log), backup: FakePolish(log: log)).prepare()
        XCTAssertEqual(log.events, ["prepare", "prepare"])
    }

    func testProviderListFallsBackInOrder() throws {
        let request = OpenRouterPolish.request(model: "m", apiKey: "k", text: "t", instructions: "P", provider: "Together,DeepInfra")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let provider = try XCTUnwrap(body["provider"] as? [String: Any])
        XCTAssertEqual(provider["order"] as? [String], ["Together", "DeepInfra"])
        XCTAssertEqual(provider["allow_fallbacks"] as? Bool, false, "only the hosts named")
    }

    func testLatencyProbeRunsASetupsPolishAsTheAppDoes() throws {
        let runner = LatencyRunner()
        runner.apiKey = "sk-test"
        let service = try XCTUnwrap(runner.polisher(for: "setup:cloud-flash"))
        XCTAssertEqual((service.backend as? OpenRouterPolish)?.provider, "Together,DeepInfra")
        XCTAssertEqual((service.backup as? OpenRouterPolish)?.provider, "DeepInfra,Together")
        XCTAssertEqual(service.backupAfter, 0.8)
        XCTAssertEqual(service.deadline, 6)
        XCTAssertNil(runner.polisher(for: "setup:nope"))
    }
}

extension PolishFallbackTests {
    func testLatencyPlanCanNameItsOwnSetups() throws {
        let file = makeTempURL(self, "setups.json")
        try #"{"setups": [{"id": "try", "title": "Try", "speech": "apple", "polish": "openrouter:m@A", "polishBackup": "openrouter:m@B", "polishBackupWait": 0.5, "prompt": "v4"}]}"#
            .write(to: file, atomically: true, encoding: .utf8)
        let plan = makeTempURL(self, "plan.json")
        try #"{"pause": 0, "timeout": 1, "trials": [], "setupsFile": "\#(file.path)"}"#.write(to: plan, atomically: true, encoding: .utf8)
        let probe = try XCTUnwrap(LatencyProbe(planPath: plan.path, outPath: makeTempURL(self, "out.jsonl").path, apiKey: "sk-test"))
        let service = try XCTUnwrap(probe.runner.polisher(for: "setup:try"))
        XCTAssertEqual((service.backup as? OpenRouterPolish)?.provider, "B")
        XCTAssertEqual(service.backupAfter, 0.5)
    }
}
