import XCTest
@testable import DictationKit

/// Per model: answer after `delay` seconds with `result`; a model without a script never answers.
final class ScriptedTranscriptionClient: TranscriptionClient {
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

    static func text(_ t: String) -> Result<TranscriptionResult, Error> {
        .success(TranscriptionResult(text: t, audioSeconds: nil, cost: nil))
    }

    static func error(_ message: String) -> Result<TranscriptionResult, Error> {
        .failure(TranscriptionError.message(message))
    }
}

/// "Backup model when slow": Cloud Flash's slow tail (p95 28 s in the latency
/// baseline) comes in spells. Runs the real CloudEngine.stop() → UploadRace path with a scripted client.
final class CloudBackupTests: XCTestCase {
    typealias Client = ScriptedTranscriptionClient
    static let main = "qwen/qwen3-asr-1.7b"
    static let backup = "qwen/qwen3-asr-0.6b"

    private func dictate(_ client: Client, backup: AdaptiveBackup?) -> (engine: CloudEngine, text: String?, error: String?) {
        let engine = CloudEngine()
        engine.client = client
        engine.modelID = Self.main
        engine.backup = backup
        XCTAssertTrue(engine.beginRecording())
        for _ in 0..<47 { engine.record(AudioLevelTests.buffer(amplitude: 0.2)) }  // 1 s
        let done = expectation(description: "stopped")
        var text: String?, error: String?
        engine.stop(completion: { text = $0; done.fulfill() }, failure: { error = $0; done.fulfill() })
        wait(for: [done], timeout: 3)
        return (engine, text, error)
    }

    private func policy(wait: TimeInterval = 0.2) -> AdaptiveBackup {
        let policy = AdaptiveBackup()
        policy.wait = wait
        return policy
    }

    // MARK: Off (the default)

    func testOffByDefaultAndThenOnlyTheMainModelIsAsked() {
        XCTAssertNil(CloudEngine().backup)
        let client = Client()
        client.scripts[Self.main] = .init(delay: 0.4, result: Client.text("slow but only"))
        client.scripts[Self.backup] = .init(delay: 0, result: Client.text("never asked"))
        let r = dictate(client, backup: nil)
        XCTAssertEqual(r.text, "slow but only")
        XCTAssertEqual(client.asked.map(\.model), [Self.main])
    }

    func testOffAFailureIsReportedWithoutAskingTheBackup() {
        let client = Client()
        client.scripts[Self.main] = .init(delay: 0, result: Client.error("HTTP 500"))
        client.scripts[Self.backup] = .init(delay: 0, result: Client.text("never asked"))
        let r = dictate(client, backup: nil)
        XCTAssertEqual(r.error, "HTTP 500")
        XCTAssertEqual(client.asked.map(\.model), [Self.main])
    }

    // MARK: On: one dictation

    func testFastAnswerNeverAsksTheBackup() {
        let client = Client()
        client.scripts[Self.main] = .init(delay: 0.05, result: Client.text("帮我 build 一下"))
        let r = dictate(client, backup: policy())
        XCTAssertEqual(r.text, "帮我 build 一下")
        XCTAssertEqual(r.engine.lastAnsweredBy, Self.main)
        spinRunLoop(0.3)  // past the wait
        XCTAssertEqual(client.asked.map(\.model), [Self.main], "no second request, no extra cost")
    }

    func testSlowAnswerIsRacedByTheBackupAfterTheWait() throws {
        let client = Client()  // the main model never answers
        client.scripts[Self.backup] = .init(delay: 0.05, result: Client.text("帮我 build 一下"))
        let r = dictate(client, backup: policy(wait: 0.2))
        XCTAssertEqual(r.text, "帮我 build 一下")
        XCTAssertEqual(r.engine.lastAnsweredBy, Self.backup)
        XCTAssertEqual(client.asked.map(\.model), [Self.main, Self.backup])
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(client.asked.last).at, 0.2, "only after the wait")
    }

    func testMainStillWinsIfItAnswersFirstAfterTheBackupStarted() {
        let client = Client()
        client.scripts[Self.main] = .init(delay: 0.3, result: Client.text("from 1.7b"))
        client.scripts[Self.backup] = .init(delay: 1.0, result: Client.text("from 0.6b"))
        let r = dictate(client, backup: policy(wait: 0.1))
        XCTAssertEqual(r.text, "from 1.7b")
        XCTAssertEqual(r.engine.lastAnsweredBy, Self.main)
    }

    func testFailureAsksTheBackupRightAway() throws {
        let client = Client()
        client.scripts[Self.main] = .init(delay: 0, result: Client.error("Provider error"))
        client.scripts[Self.backup] = .init(delay: 0, result: Client.text("ok"))
        let r = dictate(client, backup: policy(wait: 5))
        XCTAssertEqual(r.text, "ok")
        XCTAssertLessThan(try XCTUnwrap(client.asked.last).at, 1, "didn't wait out the 5 s")
    }

    func testBothFailingReportsTheFirstError() {
        let client = Client()
        client.scripts[Self.main] = .init(delay: 0, result: Client.error("The cloud account is out of credits."))
        client.scripts[Self.backup] = .init(delay: 0.05, result: Client.error("other"))
        let r = dictate(client, backup: policy())
        XCTAssertNil(r.text)
        XCTAssertEqual(r.error, "The cloud account is out of credits.")
    }

    func testBackupAnswerIsArchivedUnderTheModelThatHeardIt() throws {
        let client = Client()
        client.scripts[Self.backup] = .init(delay: 0, result: Client.text("hi"))
        let engine = CloudEngine()
        let archive = RecordingArchive(directory: makeTempURL(self, "Recordings"))
        engine.archive = archive
        engine.client = client
        engine.modelID = Self.main
        engine.backup = policy(wait: 0.05)
        XCTAssertTrue(engine.beginRecording())
        for _ in 0..<47 { engine.record(AudioLevelTests.buffer(amplitude: 0.2)) }
        let done = expectation(description: "stopped")
        engine.stop(completion: { _ in done.fulfill() }, failure: { _ in done.fulfill() })
        wait(for: [done], timeout: 3)
        let json = try String(contentsOf: XCTUnwrap(archive.recordings.first).deletingPathExtension()
            .appendingPathExtension("json"), encoding: .utf8)
        XCTAssertTrue(json.contains("qwen3-asr-0.6b"))
    }

    // MARK: On: across dictations

    func testAfterASlowAnswerTheNextDictationAsksBothAtOnce() throws {
        let shared = policy(wait: 0.2)
        let slow = Client()
        slow.scripts[Self.backup] = .init(delay: 0.05, result: Client.text("first"))
        _ = dictate(slow, backup: shared)
        XCTAssertTrue(shared.inSlowSpell(Self.main))

        let next = Client()
        next.scripts[Self.main] = .init(delay: 0.1, result: Client.text("second"))
        next.scripts[Self.backup] = .init(delay: 0.5, result: Client.text("late"))
        let r = dictate(next, backup: shared)
        XCTAssertEqual(next.asked.map(\.model), [Self.main, Self.backup])
        XCTAssertLessThan(next.asked[1].at - next.asked[0].at, 0.05, "no wait during a slow spell")
        XCTAssertEqual(r.text, "second")
        XCTAssertFalse(shared.inSlowSpell(Self.main), "the main model answered on time: spell over")
    }

    func testCloudModelsHaveAFasterBackup() {
        XCTAssertEqual(TranscriptionModel.qwenASR.backupOpenRouterID, Self.backup)
        XCTAssertEqual(TranscriptionModel.metaMuse.backupOpenRouterID, Self.main, "Cloud Big falls back to Cloud Flash")
        XCTAssertNil(TranscriptionModel.local.backupOpenRouterID)
    }

    func testSlowCloudBigIsRacedByCloudFlash() throws {
        let big = try XCTUnwrap(TranscriptionModel.metaMuse.openRouterID)
        let client = Client()  // Cloud Big never answers
        client.scripts[Self.main] = .init(delay: 0.05, result: Client.text("帮我 build 一下"))
        let engine = CloudEngine()
        engine.client = client
        engine.modelID = big
        engine.backup = policy(wait: 0.2)
        XCTAssertTrue(engine.beginRecording())
        for _ in 0..<47 { engine.record(AudioLevelTests.buffer(amplitude: 0.2)) }
        let done = expectation(description: "stopped")
        var text: String?
        engine.stop(completion: { text = $0; done.fulfill() }, failure: { _ in done.fulfill() })
        wait(for: [done], timeout: 3)
        XCTAssertEqual(text, "帮我 build 一下")
        XCTAssertEqual(engine.lastAnsweredBy, Self.main)
        XCTAssertEqual(client.asked.map(\.model), [big, Self.main], "only Cloud Flash, not its own backup")
    }
}

/// AdaptiveBackup's rules on their own, with a fake clock.
final class AdaptiveBackupTests: XCTestCase {
    private var now: TimeInterval = 1000
    private lazy var policy = AdaptiveBackup(clock: { [unowned self] in now })
    private let main = CloudBackupTests.main
    private let big = TranscriptionModel.metaMuse.openRouterID!

    private func report(_ answeredBy: String?, after seconds: TimeInterval, mainFailed: Bool = false) -> UploadRace.Report {
        UploadRace.Report(outcome: answeredBy.map { .text("x", model: $0) } ?? .failed("e"),
                          seconds: seconds, mainFailed: mainFailed)
    }

    func testDefaultsAreEachModelsWaitAndFiveMinutes() {
        XCTAssertEqual(AdaptiveBackup().wait(for: main), 2, "Cloud Flash")
        XCTAssertEqual(AdaptiveBackup().wait(for: big), 4, "Cloud Big usually takes about 2 s")
        XCTAssertEqual(AdaptiveBackup().spell, 300)
    }

    func testModelsWithoutABackupGetNoPlan() {
        XCTAssertNil(policy.plan(for: "unknown/model"))
    }

    func testCloudBigWaitsFourSecondsForCloudFlash() {
        XCTAssertEqual(policy.plan(for: big), UploadRace.Backup(model: main, delay: 4))
        policy.learn(big, from: report(big, after: 3))  // slower than Cloud Flash's wait, but normal for Cloud Big
        XCTAssertFalse(policy.inSlowSpell(big))
        policy.learn(big, from: report(main, after: 4.5))
        XCTAssertEqual(policy.plan(for: big)?.delay, 0)
        XCTAssertFalse(policy.inSlowSpell(main), "spells are per model")
    }

    func testNormallyWaitsBeforeAskingTheBackup() {
        XCTAssertEqual(policy.plan(for: main), UploadRace.Backup(model: CloudBackupTests.backup, delay: 2))
        policy.learn(main, from: report(main, after: 0.8))
        XCTAssertEqual(policy.plan(for: main)?.delay, 2)
    }

    func testLateMainAnswerStartsASpellThatExpires() {
        policy.learn(main, from: report(main, after: 2.5))  // main won, but after the wait
        XCTAssertEqual(policy.plan(for: main)?.delay, 0)
        now += 299
        XCTAssertEqual(policy.plan(for: main)?.delay, 0)
        now += 2
        XCTAssertEqual(policy.plan(for: main)?.delay, 2, "back to normal after 5 minutes")
    }

    func testBackupWinningAfterTheWaitAndFailuresCountAsLate() {
        policy.learn(main, from: report(CloudBackupTests.backup, after: 2.6))
        XCTAssertTrue(policy.inSlowSpell(main))
        let other = AdaptiveBackup(clock: { 0 })
        other.learn(main, from: report(CloudBackupTests.backup, after: 0.4, mainFailed: true))
        XCTAssertTrue(other.inSlowSpell(main), "a failed main model counts as late however fast")
    }

    func testEachLateAnswerExtendsTheSpell() {
        policy.learn(main, from: report(CloudBackupTests.backup, after: 3))
        now += 200
        policy.learn(main, from: report(CloudBackupTests.backup, after: 2.2))
        now += 200
        XCTAssertTrue(policy.inSlowSpell(main), "5 minutes from the latest late answer")
    }

    func testDuringASpellAQuickBackupAnswerTellsNothingAboutTheMainModel() {
        policy.learn(main, from: report(main, after: 4))
        let before = policy.inSlowSpell(main)
        now += 100
        policy.learn(main, from: report(CloudBackupTests.backup, after: 0.5))
        XCTAssertTrue(before && policy.inSlowSpell(main))
        now += 201
        XCTAssertFalse(policy.inSlowSpell(main), "not extended by the backup's quick answer")
    }

    func testOnTimeMainAnswerEndsTheSpellEarly() {
        policy.learn(main, from: report(main, after: 4))
        policy.learn(main, from: report(main, after: 0.6))
        XCTAssertFalse(policy.inSlowSpell(main))
        XCTAssertEqual(policy.plan(for: main)?.delay, 2)
    }
}
