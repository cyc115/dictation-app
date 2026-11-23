import XCTest
@testable import DictationKit

/// The lines a cloud call leaves in the system log. Nov 22: Grok STT, the backup, answered every ask
/// with a 404 for three weeks and nothing said so; these are the lines that would have.
final class CloudLogTests: XCTestCase {
    /// Collects what would go to the system log.
    final class Lines {
        var all: [(level: CloudLog.Level, text: String)] = []
        lazy var log = CloudLog { [unowned self] level, text in self.all.append((level, text)) }
        func at(_ level: CloudLog.Level) -> [String] { all.filter { $0.level == level }.map(\.text) }
    }

    func testAFailedTranscriptionRequestLogsItsModelStatusAndError() throws {
        let lines = Lines()
        StubURLProtocol.respond = { _ in .success((404, #"{"error":{"message":"No endpoints found for x-ai/grok-stt-1.0.","code":404}}"#)) }
        let client = OpenRouterClient(session: StubURLProtocol.session(), log: lines.log)
        let wav = makeTempURL(self, "a.wav")
        try Data([0]).write(to: wav)
        var result: Result<String, Error>?
        client.transcribe(wav: wav, model: SpeechRoute(id: "x-ai/grok-stt-1.0"), apiKey: "k") { result = $0 }
        waitUntil { result != nil }
        let error = try XCTUnwrap(lines.at(.error).first)
        XCTAssertTrue(error.hasPrefix("x-ai/grok-stt-1.0: HTTP 404 in "), error)
        XCTAssertTrue(error.hasSuffix(": No endpoints found for x-ai/grok-stt-1.0."), error)
    }

    func testAnAnswerIsInfoWithItsStatus() throws {
        let lines = Lines()
        StubURLProtocol.respond = { _ in .success((200, #"{"text":"secret words"}"#)) }
        let client = OpenRouterClient(session: StubURLProtocol.session(), log: lines.log)
        let wav = makeTempURL(self, "a.wav")
        try Data([0]).write(to: wav)
        var result: Result<String, Error>?
        client.transcribe(wav: wav, model: SpeechRoute(id: "m", hosts: "Host"), apiKey: "k") { result = $0 }
        waitUntil { result != nil }
        XCTAssertEqual(lines.at(.error), [])
        XCTAssertTrue(try XCTUnwrap(lines.at(.info).first).hasPrefix("m@Host: HTTP 200 in "))
        XCTAssertFalse(lines.all.contains { $0.text.contains("secret") }, "never the dictated words")
    }

    /// The race's side: why the backup was asked, and that the main model's late answer was used.
    func testABackupThatFailsWhileTheMainModelIsLateIsLogged() {
        let lines = Lines()
        let client = FakeTranscriptionClient()
        client.scripts["main"] = .init(delay: 0.3, result: FakeTranscriptionClient.text("late"))
        client.scripts["backup"] = .init(delay: 0, result: FakeTranscriptionClient.error("No endpoints found for backup."))
        let wav = makeTempURL(self, "a.wav")
        FileManager.default.createFile(atPath: wav.path, contents: Data([0]))
        var report: UploadRace.Report?
        UploadRace(wav: wav, apiKey: "k", client: client, main: SpeechRoute(id: "main"), backup: .init(model: SpeechRoute(id: "backup"), delay: 0.05),
                   log: lines.log) { report = $0 }.start()
        waitUntil { report != nil }
        XCTAssertEqual(lines.at(.notice).first, "asking backup backup: main hasn't answered in 0.05 s")
        XCTAssertTrue(lines.at(.notice).last?.hasPrefix("transcript from main in 0.") == true, "\(lines.all)")
        XCTAssertTrue(lines.at(.notice).last?.hasSuffix("; backup backup was slower or failed") == true)
        // Kept on the dictation too: Insights shows it as a red dot.
        XCTAssertEqual(report?.failures, [.init(model: "backup", message: "No endpoints found for backup.")])
    }

    func testAnAllFailedTranscriptionIsAnError() {
        let lines = Lines()
        let client = FakeTranscriptionClient(answer: .init(delay: 0, result: FakeTranscriptionClient.error("down")))
        let wav = makeTempURL(self, "a.wav")
        FileManager.default.createFile(atPath: wav.path, contents: Data([0]))
        var report: UploadRace.Report?
        UploadRace(wav: wav, apiKey: "k", client: client, main: SpeechRoute(id: "main"), backup: .init(model: SpeechRoute(id: "backup"), delay: 5),
                   log: lines.log) { report = $0 }.start()
        waitUntil { report != nil }
        XCTAssertEqual(lines.at(.notice), ["asking backup backup: main failed: down"])
        XCTAssertTrue(lines.at(.error).first?.hasSuffix(", every model asked: down") == true, "\(lines.all)")
    }

    func testPolishLogsAFailedBackupEvenWhenTheMainModelAnswers() async throws {
        let lines = Lines()
        let main = FakePolish(delay: 0.2, output: "ok")
        main.name = "main"
        let backup = FakePolish(error: .failed("No endpoints found"))
        backup.name = "backup"
        let service = PolishService(backend: main, backup: backup, backupAfter: 0.05, deadline: 2, log: lines.log)
        let answer = try await service.answer("x")
        XCTAssertEqual(answer.text, "ok")
        XCTAssertTrue(lines.at(.error).first?.hasPrefix("backup failed after ") == true, "\(lines.all)")
        XCTAssertTrue(lines.at(.error).first?.hasSuffix(": No endpoints found") == true)
        XCTAssertTrue(lines.at(.notice).first?.hasSuffix("; backup backup was slower or failed") == true, "\(lines.all)")
        XCTAssertEqual(answer.by.failures, [.init(model: "backup", message: "No endpoints found")])
        XCTAssertNil(answer.by.failed)
    }

    func testPolishGivingUpIsAnError() async {
        let lines = Lines()
        let service = PolishService(backend: FakePolish(delay: 1), deadline: 0.05, log: lines.log)
        let result = await service.polishReporting("raw")
        XCTAssertEqual(result.text, "raw")
        XCTAssertTrue(lines.at(.error).first?.hasPrefix("polish gave up after ") == true, "\(lines.all)")
        // Saved on the dictation, so History shows the polish that gave up.
        XCTAssertEqual(result.by?.failed, true)
        XCTAssertEqual(result.by?.failures, [.init(model: "FakePolish", message: "No answer within 0.05 s.")])
    }

    /// Every model failed: `lastAnswer` still says which and why, for History's failed dictations.
    func testCloudEngineFailingEveryModelKeepsTheFailures() {
        let client = FakeTranscriptionClient()
        client.scripts["main"] = .init(delay: 0, result: FakeTranscriptionClient.error("HTTP 500"))
        client.scripts["backup"] = .init(delay: 0, result: FakeTranscriptionClient.error("404"))
        let engine = CloudEngine()
        engine.client = client
        engine.model = SpeechRoute(id: "main")
        engine.backupModel = SpeechRoute(id: "backup")
        XCTAssertTrue(engine.beginRecording())
        feedSpeech(engine)
        XCTAssertEqual(stopAndWait(engine, timeout: 3).error, "HTTP 500")
        XCTAssertEqual(engine.lastAnswer, ModelAnswer(main: "main", backup: "backup",
                                                      failures: [.init(model: "main", message: "HTTP 500"), .init(model: "backup", message: "404")],
                                                      failed: true))
        // The next dictation fails on silence, before any model: no leftover answer from this one.
        XCTAssertTrue(engine.beginRecording())
        engine.mic.stop()
        _ = stopAndWait(engine, timeout: 2)
        XCTAssertNotEqual(engine.lastAnswer, ModelAnswer(main: "main", backup: "backup",
                                                         failures: [.init(model: "main", message: "HTTP 500"), .init(model: "backup", message: "404")],
                                                         failed: true))
    }

    /// The real engine path: CloudEngine.stop() hands the failures to `lastAnswer`, which History saves.
    func testCloudEngineKeepsTheFailuresOnItsAnswer() {
        let client = FakeTranscriptionClient()
        client.scripts["main"] = .init(delay: 0.2, result: FakeTranscriptionClient.text("ok"))
        client.scripts["backup"] = .init(delay: 0, result: FakeTranscriptionClient.error("404"))
        let engine = CloudEngine()
        engine.client = client
        engine.model = SpeechRoute(id: "main")
        engine.backupModel = SpeechRoute(id: "backup")
        engine.backupWait = 0.05
        XCTAssertTrue(engine.beginRecording())
        feedSpeech(engine)
        XCTAssertEqual(stopAndWait(engine, timeout: 3).text, "ok")
        XCTAssertEqual(engine.lastAnswer?.failures, [.init(model: "backup", message: "404")])
        XCTAssertEqual(engine.lastAnswer?.byBackup, false)
    }
}
