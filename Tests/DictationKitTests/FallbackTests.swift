import XCTest
@testable import DictationKit

/// Cloud Flash's slow tail (p95 28 s in the latency baseline): when it hasn't answered within
/// `fallbackDelay`, or fails, the smaller model is asked too and the first transcript wins.
/// Runs the real CloudEngine.stop() → UploadRace path with a scripted client.
final class CloudFallbackTests: XCTestCase {
    /// Per model: answer after `delay` seconds with `result`; a model without a script never answers.
    final class ScriptedClient: TranscriptionClient {
        struct Script { var delay: TimeInterval; var result: Result<TranscriptionResult, Error> }
        var scripts: [String: Script] = [:]
        private(set) var asked: [(model: String, at: TimeInterval)] = []
        let started = ProcessInfo.processInfo.systemUptime

        func transcribe(wav: URL, model: String, apiKey: String,
                        completion: @escaping (Result<TranscriptionResult, Error>) -> Void) -> URLSessionTask? {
            XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path), "the WAV is still there for \(model)")
            asked.append((model, ProcessInfo.processInfo.systemUptime - started))
            if let script = scripts[model] {
                DispatchQueue.main.asyncAfter(deadline: .now() + script.delay) { completion(script.result) }
            }
            return nil
        }
    }

    static func text(_ t: String) -> Result<TranscriptionResult, Error> {
        .success(TranscriptionResult(text: t, audioSeconds: nil, cost: nil))
    }

    private func dictate(_ client: ScriptedClient, fallback: String? = "qwen/qwen3-asr-0.6b",
                         delay: TimeInterval = 0.2) -> (engine: CloudEngine, text: String?, error: String?) {
        let engine = CloudEngine()
        engine.client = client
        engine.modelID = "qwen/qwen3-asr-1.7b"
        engine.fallbackModelID = fallback
        engine.fallbackDelay = delay
        XCTAssertTrue(engine.beginRecording())
        for _ in 0..<47 { engine.record(AudioLevelTests.buffer(amplitude: 0.2)) }  // 1 s
        let done = expectation(description: "stopped")
        var text: String?, error: String?
        engine.stop(completion: { text = $0; done.fulfill() }, failure: { error = $0; done.fulfill() })
        wait(for: [done], timeout: 3)
        return (engine, text, error)
    }

    func testFastAnswerNeverAsksTheFallback() {
        let client = ScriptedClient()
        client.scripts["qwen/qwen3-asr-1.7b"] = .init(delay: 0.05, result: Self.text("帮我 build 一下"))
        let r = dictate(client)
        XCTAssertEqual(r.text, "帮我 build 一下")
        XCTAssertEqual(r.engine.lastAnsweredBy, "qwen/qwen3-asr-1.7b")
        spinRunLoop(0.3)  // past the fallback delay
        XCTAssertEqual(client.asked.map(\.model), ["qwen/qwen3-asr-1.7b"], "no second request, no extra cost")
    }

    func testSlowAnswerIsRacedByTheFallbackAfterTheDelay() throws {
        let client = ScriptedClient()  // 1.7b never answers
        client.scripts["qwen/qwen3-asr-0.6b"] = .init(delay: 0.05, result: Self.text("帮我 build 一下"))
        let r = dictate(client, delay: 0.2)
        XCTAssertEqual(r.text, "帮我 build 一下")
        XCTAssertEqual(r.engine.lastAnsweredBy, "qwen/qwen3-asr-0.6b")
        XCTAssertEqual(client.asked.map(\.model), ["qwen/qwen3-asr-1.7b", "qwen/qwen3-asr-0.6b"])
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(client.asked.last).at, 0.2, "only after the delay")
    }

    func testOriginalStillWinsIfItAnswersFirstAfterTheFallbackStarted() {
        let client = ScriptedClient()
        client.scripts["qwen/qwen3-asr-1.7b"] = .init(delay: 0.3, result: Self.text("from 1.7b"))
        client.scripts["qwen/qwen3-asr-0.6b"] = .init(delay: 1.0, result: Self.text("from 0.6b"))
        let r = dictate(client, delay: 0.1)
        XCTAssertEqual(r.text, "from 1.7b")
        XCTAssertEqual(r.engine.lastAnsweredBy, "qwen/qwen3-asr-1.7b")
    }

    func testFailureAsksTheFallbackRightAway() throws {
        let client = ScriptedClient()
        client.scripts["qwen/qwen3-asr-1.7b"] = .init(delay: 0, result: .failure(TranscriptionError.message("Provider error")))
        client.scripts["qwen/qwen3-asr-0.6b"] = .init(delay: 0, result: Self.text("ok"))
        let r = dictate(client, delay: 5)
        XCTAssertEqual(r.text, "ok")
        XCTAssertLessThan(try XCTUnwrap(client.asked.last).at, 1, "didn't wait the 5 s delay")
    }

    func testBothFailingReportsTheFirstError() {
        let client = ScriptedClient()
        client.scripts["qwen/qwen3-asr-1.7b"] = .init(delay: 0, result: .failure(TranscriptionError.message("The cloud account is out of credits.")))
        client.scripts["qwen/qwen3-asr-0.6b"] = .init(delay: 0.05, result: .failure(TranscriptionError.message("other")))
        let r = dictate(client)
        XCTAssertNil(r.text)
        XCTAssertEqual(r.error, "The cloud account is out of credits.")
    }

    func testWithoutAFallbackAFailureIsReportedAsBefore() {
        let client = ScriptedClient()
        client.scripts["qwen/qwen3-asr-1.7b"] = .init(delay: 0, result: .failure(TranscriptionError.message("HTTP 500")))
        let r = dictate(client, fallback: nil)
        XCTAssertEqual(r.error, "HTTP 500")
        XCTAssertEqual(client.asked.count, 1)
    }

    func testFallbackAnswerIsArchivedUnderTheModelThatHeardIt() throws {
        let client = ScriptedClient()
        client.scripts["qwen/qwen3-asr-0.6b"] = .init(delay: 0, result: Self.text("hi"))
        let engine = CloudEngine()
        let archive = RecordingArchive(directory: makeTempURL(self, "Recordings"))
        engine.archive = archive
        engine.client = client
        engine.modelID = "qwen/qwen3-asr-1.7b"
        engine.fallbackModelID = "qwen/qwen3-asr-0.6b"
        engine.fallbackDelay = 0.05
        XCTAssertTrue(engine.beginRecording())
        for _ in 0..<47 { engine.record(AudioLevelTests.buffer(amplitude: 0.2)) }
        let done = expectation(description: "stopped")
        engine.stop(completion: { _ in done.fulfill() }, failure: { _ in done.fulfill() })
        wait(for: [done], timeout: 3)
        let json = try String(contentsOf: XCTUnwrap(archive.recordings.first).deletingPathExtension()
            .appendingPathExtension("json"), encoding: .utf8)
        XCTAssertTrue(json.contains("qwen3-asr-0.6b"))
    }

    func testOnlyCloudFlashHasAFallback() {
        XCTAssertEqual(TranscriptionModel.qwenASR.fallbackOpenRouterID, "qwen/qwen3-asr-0.6b")
        XCTAssertNil(TranscriptionModel.metaMuse.fallbackOpenRouterID)
        XCTAssertNil(TranscriptionModel.local.fallbackOpenRouterID)
    }
}
