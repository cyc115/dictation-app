import Foundation
import XCTest
@testable import DictationKit

/// The judge in the idle pass (`VocabularyIntake` + `FixJudge`), with a fake judge, a fake clock, the
/// pass's work run inline and its requests held until the test runs them.
final class JudgePassTests: XCTestCase {
    private var services: AppServices!
    private var history: HistoryStore { services.history }
    private var intake: VocabularyIntake { services.intake }
    private var settings: AppSettings { services.settings }
    private let judge = FakeJudge()
    private var timers: [(delay: TimeInterval, fire: () -> Void)] = []
    private var busy = false
    private var clock = Date(timeIntervalSince1970: 2_000_000_000)
    /// Requests sent, not yet answered.
    private var requests: [() async -> Void] = []
    /// What a request hands back to the main thread, run once it has finished.
    private var landed: [() -> Void] = []
    private let lock = NSLock()
    /// Hold the pass's work back (to land an answer while a pass runs).
    private var holdPass = false
    private var heldPasses: [() -> Void] = []

    override func setUp() {
        super.setUp()
        services = makeServices(self)
        settings.judgeFixes = true
        intake.judgeBackend = { [unowned self] in judge }
        intake.isBusy = { [unowned self] in busy }
        intake.after = { [unowned self] delay, fire in timers.append((delay, fire)) }
        intake.now = { [unowned self] in clock }
        intake.toMain = { [unowned self] work in
            if Thread.isMainThread { work() } else { lock.withLock { landed.append(work) } }
        }
        intake.send = { [unowned self] work in
            requests.append(work)
        }
        intake.background = { [unowned self] work in if holdPass { heldPasses.append(work) } else { work() } }
    }

    /// Answers every request sent so far (and any the answers send).
    private func answer(all: Bool = true) {
        repeat {
            let now = requests
            requests = []
            for request in now {
                let done = expectation(description: "request")
                Task.detached { await request(); done.fulfill() }
                wait(for: [done], timeout: 5)
                let back = lock.withLock { defer { landed = [] }; return landed }
                back.forEach { $0() }
            }
        } while all && !requests.isEmpty
    }

    /// Corrected dictations, oldest first.
    @discardableResult
    private func correct(_ fixes: [(String, String)]) -> [UUID] {
        fixes.map { text, correction in
            let id = history.add(text: text, duration: 1)!
            history.setCorrection(correction, for: id)
            return id
        }
    }

    private func five() -> [(String, String)] {
        (1...5).map { ("ask cloud about item \($0)", "ask Claude about item \($0)") }
    }

    func testNothingWithTheSettingOff() {
        settings.judgeFixes = false
        correct(five())
        intake.tabShown()
        XCTAssertEqual(intake.batches, 0)
        XCTAssertEqual(services.vocabulary.entries.map(\.term), ["Claude"], "the rules, as before")
        XCTAssertTrue(timers.isEmpty)
    }

    /// No judge for the setup (no key, or the On-device setup): the rules count, nothing is sent.
    func testNothingWithoutAJudge() {
        intake.judgeBackend = { nil }
        correct(five())
        intake.tabShown()
        XCTAssertEqual(intake.batches, 0)
        XCTAssertEqual(services.vocabulary.entries.map(\.term), ["Claude"])
    }

    /// The On-device setup, with a key and the setting on: the app's own choice of judge is none, so
    /// nothing is sent and the rules count.
    func testTheOnDeviceSetupSendsNothing() {
        settings.setOpenRouterKey("sk-test")
        settings.setup = .onDevice
        intake.judgeBackend = { [unowned self] in FixJudge.backend(settings: settings) }
        correct(five())
        intake.tabShown()
        XCTAssertEqual(intake.batches, 0)
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(services.vocabulary.entries.map(\.term), ["Claude"])
    }

    /// A batch in flight when you switch to a setup that polishes on this Mac: its answer is still used
    /// (the fixes were sent while the setup was a cloud one), and nothing more is sent.
    func testSwitchingToALocalSetupSendsNoMore() {
        settings.setOpenRouterKey("sk-test")
        settings.setup = .cloudFlash
        intake.judgeBackend = { [unowned self] in FixJudge.backend(settings: settings) != nil ? judge : nil }
        let ids = correct((1...11).map { ("ask cloud about item \($0)", "ask Claude about item \($0)") })
        intake.tabShown()
        XCTAssertEqual(intake.batches, 1)
        XCTAssertTrue(services.vocabulary.entries.isEmpty, "changes wait for the verdicts")
        settings.setup = .onDevice
        answer()
        XCTAssertEqual(judge.asked.map(\.count), [10])
        let judged = history.entries.filter { $0.intake?.changes.first?.verdict == .misheard }
        XCTAssertEqual(judged.count, 10, "the answer is used")
        XCTAssertEqual(intake.batches, 1, "the 11th isn't sent from the local setup")
        XCTAssertTrue(FixJudge.pending(history.entries).map(\.id).allSatisfy(ids.contains))
        XCTAssertEqual(FixJudge.pending(history.entries).count, 1)
    }

    func testABatchGoesOnceFiveFixesWait() {
        correct(Array(five().prefix(4)))
        intake.runIfIdle()
        XCTAssertEqual(intake.batches, 0, "4 waiting, none for 10 minutes")
        XCTAssertTrue(services.vocabulary.candidates.isEmpty, "unjudged changes wait for verdicts")
        XCTAssertEqual(timers.map(\.delay), [600], "woken when the oldest has waited 10 minutes")
        correct([five()[4]])
        intake.runIfIdle()
        XCTAssertEqual(intake.batches, 1)
        XCTAssertEqual(requests.count, 1)
        answer()
        XCTAssertEqual(judge.asked.map(\.count), [5])
        XCTAssertEqual(Set(judge.asked[0].map(\.wrote)), Set(five().map(\.0)))
    }

    func testTheOldestWaitingTenMinutesSendsABatch() {
        correct(Array(five().prefix(2)))
        intake.runIfIdle()
        XCTAssertEqual(intake.batches, 0)
        clock += 300
        correct([five()[2]])
        intake.runIfIdle()
        XCTAssertEqual(timers.last?.delay, 300, "still from the oldest")
        clock += 300
        timers.last?.fire()
        XCTAssertEqual(intake.batches, 1)
        answer()
        XCTAssertEqual(judge.asked.first?.count, 3)
        XCTAssertEqual(judge.asked.first?.first?.wrote, five()[0].0, "longest waiting first")
    }

    func testShowingTheTabSendsAtOnce() {
        correct([five()[0]])
        intake.tabShown()
        XCTAssertEqual(intake.batches, 1)
        answer()
        XCTAssertEqual(history.entries[0].intake?.changes.first?.verdict, .misheard)
    }

    func testNeverWhileADictationIsInProgress() {
        correct(five())
        busy = true
        intake.tabShown()
        intake.runIfIdle()
        XCTAssertEqual(intake.batches, 0)
        busy = false
        intake.tabShown()
        XCTAssertEqual(intake.batches, 1)
        busy = true  // a dictation started while the judge was asked
        answer()
        XCTAssertNil(history.entries[0].intake?.changes.first?.verdict, "nothing written during a dictation")
        busy = false
        intake.runIfIdle()
        XCTAssertEqual(history.entries[0].intake?.changes.first?.verdict, .misheard, "the paid answer is kept for the next pass")
        XCTAssertEqual(intake.batches, 1, "not asked again")
    }

    /// Up to 10 fixes a request, one request at a time; each answer runs
    /// the pass again, which sends the next batch while 5 or more wait.
    func testBatchesOfTenOneAtATime() {
        correct((1...23).map { ("ask cloud about \($0)", "ask Claude about \($0)") })
        intake.tabShown()
        intake.tabShown()
        XCTAssertEqual(requests.count, 1, "one in flight")
        answer()
        XCTAssertEqual(judge.asked.map(\.count), [10, 10, 3], "the last 3 too: the tab was shown")
        XCTAssertTrue(FixJudge.pending(history.entries).isEmpty)

        correct(Array(five().prefix(2)))
        intake.runIfIdle()
        XCTAssertTrue(requests.isEmpty, "fewer than 5 wait for their 10 minutes")
    }

    /// Verdicts count at once: a misheard term is learned without waiting for another dictation; a
    /// judged fix isn't asked about again.
    func testVerdictsCountAtOnceAndAreNotAskedAgain() {
        judge.verdict = ["Thursday": .changedMind]
        correct([("I use cloud", "I use Claude"), ("ask Coloule now", "ask Claude now"), ("Klod said no", "Claude said no"),
                 ("see you Tuesday", "see you Thursday"), ("meet Tuesday", "meet Thursday")])
        intake.runIfIdle()
        answer()
        XCTAssertEqual(services.vocabulary.entries.map(\.term), ["Claude"])
        XCTAssertFalse(services.vocabulary.candidates.contains { $0.term == "Thursday" }, "a change of mind never counts")
        intake.runIfIdle()
        intake.tabShown()
        XCTAssertEqual(intake.batches, 1)
    }

    /// An answer that leaves a fix out: it's asked again (after a wait, or with the tab), at most 3
    /// times; then the rules count it.
    func testAMalformedAnswerIsRetriedThenLeft() {
        judge.answer = { items in JudgeAnswer(verdicts: items.map { _ in nil }, usage: OpenRouter.Usage(calls: 1, cost: 0.001)) }
        correct(five())
        intake.runIfIdle()
        answer()
        XCTAssertEqual(intake.batches, 1, "no second request straight away")
        XCTAssertEqual(history.entries[0].intake?.tries, 1)
        XCTAssertEqual(timers.last?.delay, 600, "backs off 10 minutes")
        intake.runIfIdle()
        XCTAssertEqual(intake.batches, 1)
        clock += 600
        timers.last?.fire()
        answer()
        intake.tabShown()
        answer()
        XCTAssertEqual(intake.batches, 3)
        XCTAssertEqual(history.entries[0].intake?.tries, FixJudge.maxTries)
        intake.tabShown()
        XCTAssertEqual(intake.batches, 3, "given up: it never costs again")
        XCTAssertEqual(services.vocabulary.entries.map(\.term), ["Claude"], "the rules count it")
        XCTAssertEqual(intake.judgeUsage.total().calls, 3, "what each request cost is added up")
    }

    /// A partial answer judges what it covers; the rest waits.
    func testAPartialAnswerJudgesWhatItCovers() {
        judge.answer = { items in JudgeAnswer(verdicts: items.indices.map { $0 == 0 ? [.misheard] : nil }, usage: nil) }
        correct(five())
        intake.runIfIdle()
        answer(all: false)
        XCTAssertEqual(history.entries.filter { $0.intake?.changes.first?.verdict == .misheard }.count, 1)
        XCTAssertEqual(history.entries.filter { $0.intake?.tries == 1 }.count, 4)
    }

    /// A failed request (offline, a busy host) costs no try and waits 10 minutes.
    func testAFailedRequestCostsNoTry() {
        judge.answer = { _ in throw URLError(.notConnectedToInternet) }
        correct(five())
        intake.runIfIdle()
        answer()
        XCTAssertNil(history.entries[0].intake?.tries)
        XCTAssertEqual(timers.last?.delay, 600)
        XCTAssertEqual(intake.batches, 1)
        judge.answer = nil
        clock += 600
        timers.last?.fire()
        answer()
        XCTAssertEqual(history.entries[0].intake?.changes.first?.verdict, .misheard)
    }

    /// A refused request (a bad model id, no credit) would fail the same
    /// way again: it counts a try, so one fix that always fails can't hold the others up forever.
    func testARefusedRequestCountsATry() {
        judge.answer = { _ in throw JudgeFailure(json: ["error": ["message": "No such model"]], status: 400) }
        correct(five())
        for _ in 0..<FixJudge.maxTries {
            intake.tabShown()
            answer()
        }
        XCTAssertEqual(history.entries[0].intake?.tries, FixJudge.maxTries)
        intake.tabShown()
        XCTAssertEqual(intake.batches, FixJudge.maxTries, "then it's asked no more")
        XCTAssertEqual(services.vocabulary.entries.map(\.term), ["Claude"], "and the rules count it")
        XCTAssertFalse(FixJudge.countsATry(JudgeFailure(json: nil, status: 429)))
        XCTAssertFalse(FixJudge.countsATry(JudgeFailure(json: nil, status: 503)))
        XCTAssertFalse(FixJudge.countsATry(URLError(.timedOut)))
    }

    /// Turned off while the judge was asked: its answer isn't used, nor one held for the next pass.
    func testAnAnswerAfterTheSettingIsTurnedOffIsDropped() {
        correct([five()[0]])
        intake.tabShown()
        settings.judgeFixes = false
        answer()
        XCTAssertNil(history.entries[0].intake?.changes.first?.verdict)

        settings.judgeFixes = true
        intake.tabShown()
        busy = true
        answer()
        busy = false
        settings.judgeFixes = false
        intake.runIfIdle()
        XCTAssertNil(history.entries[0].intake?.changes.first?.verdict, "held, then dropped")
    }

    /// An answer that lands while a pass is running: that pass runs again once it's done, keeping a
    /// tab shown.
    func testAnAnswerDuringAPassRunsItAgain() {
        correct(five())
        intake.runIfIdle()
        let before = intake.passes
        holdPass = true
        intake.tabShown()
        answer()
        XCTAssertEqual(history.entries[0].intake?.changes.first?.verdict, .misheard, "saved at once")
        holdPass = false
        heldPasses.forEach { $0() }
        heldPasses = []
        XCTAssertEqual(intake.passes, before + 2, "the pass, then again with the verdicts")
    }

    /// The 10-minute wake-up during a dictation does nothing; the pass after the dictation sends it.
    func testTheWakeUpWaitsForADictationToEnd() {
        correct([five()[0]])
        intake.runIfIdle()
        clock += 600
        busy = true
        timers.last?.fire()
        XCTAssertEqual(intake.batches, 0)
        busy = false
        intake.scheduleAfterIdle()
        timers.last?.fire()
        XCTAssertEqual(intake.batches, 1)
    }

    /// By default every captured edit waits for Accept: a clear one read back from the text box, all
    /// misheard, gets its verdicts and counts toward vocabulary, but stays `waiting` and trains nothing.
    func testAClearCaptureWaitsForAcceptByDefault() throws {
        XCTAssertFalse(settings.trainOnUnreviewedCaptures, "off by default")
        let id = try XCTUnwrap(history.add(text: "ask open router", duration: 1))
        history.setCapture(Capture(edited: "ask OpenRouter", mode: .readback, app: "Slack"), for: id)
        intake.tabShown()
        answer()
        XCTAssertEqual(judge.asked.count, 1)
        XCTAssertEqual(history.entries[0].capture?.state, .waiting)
        XCTAssertNil(history.entries[0].correction)
        XCTAssertTrue(history.corrections.isEmpty, "trains nothing")
        XCTAssertEqual(history.entries[0].intake?.changes.map(\.verdict), [.misheard], "judged")
        XCTAssertEqual(intake.batches, 1, "not asked again")
    }

    /// With `trainOnUnreviewedCaptures` on, a clear capture read back from the text box trains Learn
    /// unreviewed (`auto`); it isn't kept past "Keep history".
    func testAClearCaptureBecomesAutoAndIsPruned() throws {
        settings.trainOnUnreviewedCaptures = true
        let id = try XCTUnwrap(history.add(text: "ask open router", duration: 1, date: Date().addingTimeInterval(-10 * 86_400)))
        history.setCapture(Capture(edited: "ask OpenRouter", mode: .readback, app: "Slack"), for: id)
        intake.tabShown()
        answer()
        XCTAssertEqual(history.entries[0].capture?.state, .auto)
        XCTAssertEqual(history.corrections.map(\.id), [id], "trains Learn")
        XCTAssertEqual(LearnController.tuneFixes(history.corrections).map(\.id), [id])
        history.retention = .days7
        XCTAssertTrue(history.entries.isEmpty, "an auto one isn't kept past Keep history")
    }

    func testDismissingAnAutoCaptureStopsItTraining() throws {
        settings.trainOnUnreviewedCaptures = true
        let id = try XCTUnwrap(history.add(text: "ask open router", duration: 1))
        history.setCapture(Capture(edited: "ask OpenRouter", mode: .readback, app: "Slack"), for: id)
        intake.tabShown()
        answer()
        XCTAssertEqual(history.entries[0].capture?.state, .auto)
        history.dismiss(id)
        XCTAssertNil(history.entries[0].correction)
        XCTAssertNil(history.entries[0].fixTarget)
    }

    /// A captured edit with nothing worth keeping is dismissed: it feeds nothing.
    func testACaptureWithNothingKeptIsDismissed() throws {
        judge.verdict = ["Thursday": .changedMind]
        let id = try XCTUnwrap(history.add(text: "see you Tuesday", duration: 1))
        history.setCapture(Capture(edited: "see you Thursday", mode: .readback, app: "Slack"), for: id)
        intake.tabShown()
        answer()
        XCTAssertEqual(history.entries[0].capture?.state, .dismissed)
        XCTAssertTrue(history.waiting.isEmpty)
        intake.runIfIdle()
        XCTAssertNil(history.entries[0].intake)
    }

    /// Your edit while the judge was asked wins: the answer is for a fix that's gone.
    func testAFixEditedMeanwhileIsJudgedAgain() throws {
        let id = correct([five()[0]])[0]
        intake.tabShown()
        history.setCorrection("ask Claude Code about item 1", for: id)
        answer(all: false)
        XCTAssertNil(history.entries[0].intake?.changes.first?.verdict)
        intake.tabShown()
        answer()
        XCTAssertEqual(history.entries[0].intake?.of, "ask Claude Code about item 1")
        XCTAssertNotNil(history.entries[0].intake?.changes.first?.verdict)
    }

    /// The terms the judge is told are your vocabulary's.
    func testTheJudgeIsToldYourTerms() {
        var told: [String] = []
        final class Spy: FixJudgeBackend {
            var terms: (([String]) -> Void)?
            func judge(_ items: [JudgeItem], terms: [String]) async throws -> JudgeAnswer {
                self.terms?(terms)
                return JudgeAnswer(verdicts: items.map { _ in nil }, usage: nil)
            }
        }
        let spy = Spy()
        spy.terms = { told = $0 }
        intake.judgeBackend = { spy }
        services.vocabulary.add(term: "DeepSeek", heardAs: ["deep sea"])
        correct([five()[0]])
        intake.tabShown()
        answer()
        XCTAssertEqual(told, ["DeepSeek"])
    }
}
