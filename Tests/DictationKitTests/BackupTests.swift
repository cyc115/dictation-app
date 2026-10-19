import XCTest
@testable import DictationKit

/// "Backup model when slow": Cloud Flash's slow tail (p95 28 s in the latency
/// baseline) comes in spells. Runs the real CloudEngine.stop() → UploadRace path with a scripted client.
final class CloudBackupTests: XCTestCase {
    typealias Client = FakeTranscriptionClient
    static let main = "qwen/qwen3-asr-1.7b"
    static let backup = "qwen/qwen3-asr-0.6b"

    private func dictate(_ client: Client, backup: AdaptiveBackup?, backupWait: TimeInterval = 0.2) -> (engine: CloudEngine, text: String?, error: String?) {
        let engine = CloudEngine()
        engine.client = client
        engine.modelID = Self.main
        if let backup {
            engine.backup = backup
            engine.backupModelID = DictationSetup.cloudFlash.backup
        }
        engine.backupWait = backupWait
        XCTAssertTrue(engine.beginRecording())
        for _ in 0..<47 { engine.record(AudioLevelTests.buffer(amplitude: 0.2)) }  // 1 s
        let done = expectation(description: "stopped")
        var text: String?, error: String?
        engine.stop(completion: { text = $0; done.fulfill() }, failure: { error = $0; done.fulfill() })
        wait(for: [done], timeout: 3)
        return (engine, text, error)
    }

    // MARK: Off (the default)

    func testOffByDefaultAndThenOnlyTheMainModelIsAsked() {
        XCTAssertNil(CloudEngine().backupModelID)
        let client = Client()
        client.scripts[Self.main] = Client.Script(delay: 0.4, result: Client.text("slow but only"))
        client.scripts[Self.backup] = Client.Script(delay: 0, result: Client.text("never asked"))
        let r = dictate(client, backup: nil)
        XCTAssertEqual(r.text, "slow but only")
        XCTAssertEqual(client.asked.map(\.model), [Self.main])
    }

    func testOffAFailureIsReportedWithoutAskingTheBackup() {
        let client = Client()
        client.scripts[Self.main] = Client.Script(delay: 0, result: Client.error("HTTP 500"))
        client.scripts[Self.backup] = Client.Script(delay: 0, result: Client.text("never asked"))
        let r = dictate(client, backup: nil)
        XCTAssertEqual(r.error, "HTTP 500")
        XCTAssertEqual(client.asked.map(\.model), [Self.main])
    }

    // MARK: On: one dictation

    func testFastAnswerNeverAsksTheBackup() {
        let client = Client()
        client.scripts[Self.main] = Client.Script(delay: 0.05, result: Client.text("帮我 build 一下"))
        let r = dictate(client, backup: AdaptiveBackup())
        XCTAssertEqual(r.text, "帮我 build 一下")
        XCTAssertEqual(r.engine.lastAnsweredBy, Self.main)
        XCTAssertEqual(r.engine.lastAnswer, ModelAnswer(main: Self.main), "History: the backup wasn't asked")
        spinRunLoop(0.3)  // past the wait
        XCTAssertEqual(client.asked.map(\.model), [Self.main], "no second request, no extra cost")
    }

    func testSlowAnswerIsRacedByTheBackupAfterTheWait() throws {
        let client = Client()  // the main model never answers
        client.scripts[Self.backup] = Client.Script(delay: 0.05, result: Client.text("帮我 build 一下"))
        let r = dictate(client, backup: AdaptiveBackup(), backupWait: 0.2)
        XCTAssertEqual(r.text, "帮我 build 一下")
        XCTAssertEqual(r.engine.lastAnsweredBy, Self.backup)
        XCTAssertEqual(r.engine.lastAnswer, ModelAnswer(main: Self.main, backup: Self.backup, byBackup: true))
        XCTAssertEqual(client.asked.map(\.model), [Self.main, Self.backup])
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(client.asked.last).at, 0.2, "only after the wait")
    }

    func testMainStillWinsIfItAnswersFirstAfterTheBackupStarted() {
        let client = Client()
        client.scripts[Self.main] = Client.Script(delay: 0.3, result: Client.text("from 1.7b"))
        client.scripts[Self.backup] = Client.Script(delay: 1.0, result: Client.text("from 0.6b"))
        let r = dictate(client, backup: AdaptiveBackup(), backupWait: 0.1)
        XCTAssertEqual(r.text, "from 1.7b")
        XCTAssertEqual(r.engine.lastAnsweredBy, Self.main)
        XCTAssertEqual(r.engine.lastAnswer, ModelAnswer(main: Self.main, backup: Self.backup, byBackup: false),
                       "asked, but the main model won")
    }

    func testFailureAsksTheBackupRightAway() throws {
        let client = Client()
        client.scripts[Self.main] = Client.Script(delay: 0, result: Client.error("Provider error"))
        client.scripts[Self.backup] = Client.Script(delay: 0, result: Client.text("ok"))
        let r = dictate(client, backup: AdaptiveBackup(), backupWait: 5)
        XCTAssertEqual(r.text, "ok")
        XCTAssertLessThan(try XCTUnwrap(client.asked.last).at, 1, "didn't wait out the 5 s")
    }

    func testBothFailingReportsTheFirstError() {
        let client = Client()
        client.scripts[Self.main] = Client.Script(delay: 0, result: Client.error("The cloud account is out of credits."))
        client.scripts[Self.backup] = Client.Script(delay: 0.05, result: Client.error("other"))
        let r = dictate(client, backup: AdaptiveBackup())
        XCTAssertNil(r.text)
        XCTAssertEqual(r.error, "The cloud account is out of credits.")
    }

    func testBackupAnswerIsArchivedUnderTheModelThatHeardIt() throws {
        let client = Client()
        client.scripts[Self.backup] = Client.Script(delay: 0, result: Client.text("hi"))
        let engine = CloudEngine()
        let archive = RecordingArchive(directory: makeTempURL(self, "Recordings"))
        engine.archive = archive
        engine.client = client
        engine.modelID = Self.main
        engine.backupWait = 0.05
        engine.backupModelID = Self.backup
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
        let shared = AdaptiveBackup()
        let slow = Client()
        slow.scripts[Self.backup] = Client.Script(delay: 0.05, result: Client.text("first"))
        _ = dictate(slow, backup: shared)
        XCTAssertTrue(shared.inSlowSpell(Self.main))

        let next = Client()
        next.scripts[Self.main] = Client.Script(delay: 0.1, result: Client.text("second"))
        next.scripts[Self.backup] = Client.Script(delay: 0.5, result: Client.text("late"))
        let r = dictate(next, backup: shared)
        XCTAssertEqual(next.asked.map(\.model), [Self.main, Self.backup])
        XCTAssertLessThan(next.asked[1].at - next.asked[0].at, 0.05, "no wait during a slow spell")
        XCTAssertEqual(r.text, "second")
        XCTAssertFalse(shared.inSlowSpell(Self.main), "the main model answered on time: spell over")
    }

    /// The bug that sent 43% of real dictations to the backup: in a spell the faster backup always
    /// won, so the main model never got to show it was on time again.
    func testInASpellTheMainModelAnsweringWithinTheWaitEndsItEvenWhenTheBackupWins() {
        let shared = AdaptiveBackup()
        shared.learn(Self.main, onTime: false)
        let client = Client()
        client.scripts[Self.main] = Client.Script(delay: 0.12, result: Client.text("from 1.7b"))
        client.scripts[Self.backup] = Client.Script(delay: 0.02, result: Client.text("from 0.6b"))
        let r = dictate(client, backup: shared, backupWait: 0.3)
        XCTAssertEqual(r.text, "from 0.6b", "the first answer is still used")
        XCTAssertTrue(shared.inSlowSpell(Self.main), "not judged yet: the main model is still answering")
        spinRunLoop(0.2)
        XCTAssertFalse(shared.inSlowSpell(Self.main), "the main model answered within its wait: spell over")
    }

    func testInASpellTheMainModelMissingTheWaitKeepsIt() {
        let shared = AdaptiveBackup()
        shared.learn(Self.main, onTime: false)
        let client = Client()  // the main model never answers
        client.scripts[Self.backup] = Client.Script(delay: 0.02, result: Client.text("from 0.6b"))
        _ = dictate(client, backup: shared, backupWait: 0.1)
        spinRunLoop(0.2)
        XCTAssertTrue(shared.inSlowSpell(Self.main))
    }

    func testASlowBackupAnswerDoesNotCountAgainstAnOnTimeMainModel() {
        let shared = AdaptiveBackup()
        let client = Client()
        client.scripts[Self.main] = Client.Script(delay: 0, result: Client.error("HTTP 500"))
        client.scripts[Self.backup] = Client.Script(delay: 0.05, result: Client.text("ok"))
        _ = dictate(client, backup: shared, backupWait: 1)
        XCTAssertTrue(shared.inSlowSpell(Self.main), "a failed main model counts as late however fast")
        let next = Client()
        next.scripts[Self.main] = Client.Script(delay: 0.05, result: Client.text("on time"))
        next.scripts[Self.backup] = Client.Script(delay: 0.5, result: Client.text("slow backup"))
        XCTAssertEqual(dictate(next, backup: shared, backupWait: 0.3).text, "on time")
        XCTAssertFalse(shared.inSlowSpell(Self.main))
    }

    func testUseSetsUpEachCloudSetupWithItsFasterBackup() {
        let engine = CloudEngine()
        engine.use(.cloudBig, apiKey: "k", backupWhenSlow: true)
        XCTAssertEqual(engine.modelID, DictationSetup.cloudBig.openRouterID)
        XCTAssertEqual(engine.backupModelID, Self.main, "Cloud Big falls back to Cloud Flash")
        XCTAssertEqual(engine.backupWait, 4)
        XCTAssertEqual(engine.apiKey, "k")
        engine.use(.cloudFlash, apiKey: "k", backupWhenSlow: true)
        XCTAssertEqual(engine.modelID, Self.main)
        XCTAssertEqual(engine.backupModelID, Self.backup)
        XCTAssertEqual(engine.backupWait, 2)
        engine.use(.cloudFlash, apiKey: "k", backupWhenSlow: false)
        XCTAssertNil(engine.backupModelID, "setting off: only the main model")
        XCTAssertNil(DictationSetup.onDevice.backup)
    }

    func testSlowCloudBigIsRacedByCloudFlash() throws {
        let big = try XCTUnwrap(DictationSetup.cloudBig.openRouterID)
        let client = Client()  // Cloud Big never answers
        client.scripts[Self.main] = Client.Script(delay: 0.05, result: Client.text("帮我 build 一下"))
        let engine = CloudEngine()
        engine.client = client
        engine.use(.cloudBig, apiKey: "k", backupWhenSlow: true)
        engine.backupWait = 0.2
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
    private let big = DictationSetup.cloudBig.openRouterID!

    /// As CloudEngine asks: with the backup and wait of the built-in setup using `model`.
    private func plan(_ model: String) -> UploadRace.Backup? {
        guard let setup = DictationSetup.builtIn(speechModel: model), let backup = setup.backup else { return nil }
        return policy.plan(for: model, backup: backup, wait: setup.backupWait)
    }

    private func learn(_ model: String, onTime: Bool) { policy.learn(model, onTime: onTime) }

    func testSpellsLastFiveMinutesAndModelsWithoutABackupGetNoPlan() {
        XCTAssertEqual(AdaptiveBackup().spell, 300)
        XCTAssertNil(plan("unknown/model"))
    }

    func testCloudBigWaitsFourSecondsForCloudFlash() {
        XCTAssertEqual(plan(big), UploadRace.Backup(model: main, delay: 4))
        learn(big, onTime: false)
        XCTAssertEqual(plan(big)?.delay, 0)
        XCTAssertFalse(policy.inSlowSpell(main), "spells are per model")
    }

    func testNormallyWaitsBeforeAskingTheBackup() {
        XCTAssertEqual(plan(main), UploadRace.Backup(model: CloudBackupTests.backup, delay: 2))
        learn(main, onTime: true)
        XCTAssertEqual(plan(main)?.delay, 2)
    }

    func testLateMainAnswerStartsASpellThatExpires() {
        learn(main, onTime: false)
        XCTAssertEqual(plan(main)?.delay, 0)
        now += 299
        XCTAssertEqual(plan(main)?.delay, 0)
        now += 2
        XCTAssertEqual(plan(main)?.delay, 2, "back to normal after 5 minutes")
    }

    func testEachLateAnswerExtendsTheSpell() {
        learn(main, onTime: false)
        now += 200
        learn(main, onTime: false)
        now += 200
        XCTAssertTrue(policy.inSlowSpell(main), "5 minutes from the latest late answer")
    }

    func testOnTimeMainAnswerEndsTheSpellEarly() {
        learn(main, onTime: false)
        learn(main, onTime: true)
        XCTAssertFalse(policy.inSlowSpell(main))
        XCTAssertEqual(plan(main)?.delay, 2)
    }
}
