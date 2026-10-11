import XCTest
@testable import DictationKit

final class PolishServiceTests: XCTestCase {
    func testFailureFallsBackToTheRawTextAndSaysWhy() async {
        let service = PolishService(backend: FakePolish(error: .failed("HTTP 429")))
        let (text, error) = await service.polishReporting("um hello")
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
        XCTAssertEqual(DictationSetup.cloudFlash.polishBackend(apiKey: "k", onDevice: onDevice).name, "openrouter:openai/gpt-oss-120b@Groq")
        XCTAssertEqual(DictationSetup.cloudFlash.polishBackend(apiKey: nil, onDevice: onDevice).name, "apple:on-device")
    }
}

final class OpenRouterPolishTests: XCTestCase {
    func testRequestSendsInstructionsAndTranscript() throws {
        let request = OpenRouterPolish.request(model: "anthropic/claude-haiku-5.5", apiKey: "sk-test", text: "um 帮我 build", instructions: PolishPrompt.v3)
        XCTAssertEqual(request.url, OpenRouterPolish.endpoint)
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
        let pinned = try XCTUnwrap(LatencyRunner().polisher(for: "openrouter:qwen/qwen3.8-27b@Cerebras") as? OpenRouterPolish)
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
