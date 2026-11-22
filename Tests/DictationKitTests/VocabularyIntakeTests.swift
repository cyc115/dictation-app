import AppKit
import XCTest
@testable import DictationKit

/// The idle pass (`VocabularyIntake`), with a fake clock, the work run inline and a fake "busy".
final class VocabularyIntakeTests: XCTestCase {
    private struct Fixture {
        let services: AppServices
        var history: HistoryStore { services.history }
        var vocabulary: VocabularyStore { services.vocabulary }
        var intake: VocabularyIntake { services.intake }
    }

    /// Timers asked for, in order: their delay and what they run.
    private var timers: [(delay: TimeInterval, fire: () -> Void)] = []
    private var busy = false
    /// The pass's work, held back until the test lets it finish (nil: runs at once).
    private var heldWork: [() -> Void]?

    private func makeFixture() -> Fixture {
        let services = makeServices(self)
        let intake = services.intake
        intake.isBusy = { [unowned self] in busy }
        intake.after = { [unowned self] delay, fire in timers.append((delay, fire)) }
        intake.background = { [unowned self] work in if heldWork != nil { heldWork!.append(work) } else { work() } }
        intake.toMain = { $0() }
        return Fixture(services: services)
    }

    /// Dictations, oldest first, each corrected when a correction is given.
    private func dictate(_ fixture: Fixture, _ dictations: [(String, String?)]) {
        for (text, correction) in dictations {
            fixture.history.add(text: text, duration: 1)
            if let correction { fixture.history.setCorrection(correction, for: fixture.history.entries[0].id) }
        }
    }

    private let claude: [(String, String?)] = [("I use cloud.", "I use Claude."), ("ask Coloule now", "ask Claude now"),
                                               ("Klod said no", "Claude said no")]

    func testRunsThirtySecondsAfterTheLastDictation() {
        let fx = makeFixture()
        dictate(fx, claude)
        fx.intake.scheduleAfterIdle()
        fx.intake.scheduleAfterIdle()  // another dictation ended meanwhile
        XCTAssertEqual(timers.map(\.delay), [30, 30])
        timers[0].fire()
        XCTAssertEqual(fx.intake.passes, 0, "an older timer does nothing")
        timers[1].fire()
        XCTAssertEqual(fx.intake.passes, 1)
    }

    /// The first pass is the backfill: every correction you already have.
    func testTheFirstPassLearnsFromExistingCorrections() throws {
        let fx = makeFixture()
        dictate(fx, claude + [("fine", nil)])
        XCTAssertTrue(fx.history.entries.allSatisfy { $0.intake == nil })
        fx.intake.runIfIdle()
        XCTAssertEqual(fx.history.corrections.compactMap(\.intake).count, 3)
        XCTAssertNil(fx.history.entries[0].intake, "no correction, no intake")
        let entry = try XCTUnwrap(fx.vocabulary.entries.first)
        XCTAssertEqual(entry.term, "Claude")
        XCTAssertEqual(entry.source, .learned)
        XCTAssertEqual(Set(entry.heardAs), ["cloud", "Coloule", "Klod"])
    }

    func testNeverWhileADictationIsInProgress() {
        let fx = makeFixture()
        dictate(fx, claude)
        busy = true
        fx.intake.scheduleAfterIdle()
        timers[0].fire()
        fx.intake.tabShown()
        XCTAssertEqual(fx.intake.passes, 0)
        XCTAssertTrue(fx.vocabulary.candidates.isEmpty)

        busy = false
        heldWork = []
        fx.intake.tabShown()
        fx.intake.tabShown()
        XCTAssertEqual(heldWork?.count, 1, "one pass at a time")
        busy = true  // a dictation started while it worked
        heldWork?.forEach { $0() }
        XCTAssertEqual(fx.intake.passes, 0, "its result is dropped; the next pass redoes it")
        XCTAssertTrue(fx.history.entries.allSatisfy { $0.intake == nil })
        busy = false
        heldWork = nil
        fx.intake.tabShown()
        XCTAssertEqual(fx.intake.passes, 1)
    }

    /// A correction edited while the pass worked: its result is dropped (it could learn a term from a
    /// fix that's gone), and it tries again later.
    func testACorrectionChangedMeanwhileDropsTheResult() {
        let fx = makeFixture()
        dictate(fx, claude)
        heldWork = []
        fx.intake.tabShown()
        fx.history.setCorrection("", for: fx.history.entries[0].id)
        heldWork?.forEach { $0() }
        XCTAssertEqual(fx.intake.passes, 0)
        XCTAssertTrue(fx.vocabulary.entries.isEmpty, "not learned from the deleted fix")
        XCTAssertEqual(timers.map(\.delay), [30], "tries again")
        heldWork = nil
        timers[0].fire()
        XCTAssertEqual(fx.intake.passes, 1)
        XCTAssertEqual(fx.vocabulary.candidates.first?.seen, 2)
    }

    /// Only an entry whose correction changed is worked out again, so phase 4's verdicts stay.
    func testOnlyAChangedCorrectionIsWorkedOutAgain() throws {
        let fx = makeFixture()
        dictate(fx, claude)
        fx.intake.runIfIdle()
        let id = fx.history.entries[0].id
        var judged = try XCTUnwrap(fx.history.entries[0].intake)
        judged.changes[0].verdict = .style
        fx.history.setIntakes([id: judged])
        fx.intake.runIfIdle()
        XCTAssertEqual(fx.history.entries[0].intake?.changes.first?.verdict, .style, "kept")
        fx.history.setCorrection("Claude said yes", for: id)
        fx.intake.runIfIdle()
        XCTAssertEqual(fx.history.entries[0].intake?.of, "Claude said yes")
        XCTAssertNil(fx.history.entries[0].intake?.changes.first?.verdict)
    }

    func testDeletingACorrectionLowersTheCount() {
        let fx = makeFixture()
        dictate(fx, Array(claude.prefix(2)))
        fx.intake.runIfIdle()
        XCTAssertEqual(fx.vocabulary.candidates.first?.seen, 2)
        let id = fx.history.entries[0].id
        fx.history.setCorrection("", for: id)
        fx.intake.runIfIdle()
        XCTAssertEqual(fx.vocabulary.candidates.first?.seen, 1)
        XCTAssertNil(fx.history.entries[0].intake)
        fx.history.delete(fx.history.entries[1])
        fx.intake.runIfIdle()
        XCTAssertTrue(fx.vocabulary.candidates.isEmpty)
    }

    func testWithUseVocabularyOffNothingIsAdded() {
        let fx = makeFixture()
        fx.services.settings.vocabularyEnabled = false
        dictate(fx, claude)
        fx.intake.runIfIdle()
        XCTAssertTrue(fx.vocabulary.entries.isEmpty)
        XCTAssertEqual(fx.vocabulary.candidates.first?.seen, 3, "candidates are still collected")
        fx.services.settings.vocabularyEnabled = true
        fx.intake.runIfIdle()
        XCTAssertEqual(fx.vocabulary.entries.map(\.term), ["Claude"])
    }

    /// The Vocabulary and Corrections tabs run a pass when shown; other tabs don't.
    func testShowingVocabularyOrCorrectionsRunsAPass() {
        let fx = makeFixture()
        let selection = TabSelection()
        let hosted = host(MainView(selection: selection, services: fx.services), size: NSSize(width: 860, height: 620))
        XCTAssertEqual(fx.intake.passes, 0, "Home")
        selection.tab = .vocabulary
        hosted.settle()
        XCTAssertEqual(fx.intake.passes, 1)
        selection.tab = .history
        hosted.settle()
        selection.tab = .corrections
        hosted.settle()
        XCTAssertEqual(fx.intake.passes, 2)
        selection.tab = .vocabulary
        hosted.settle()
        XCTAssertEqual(fx.intake.passes, 3, "each time it's shown")
    }
    /// A captured edit waiting for your Accept counts toward vocabulary like a correction (every guard
    /// the same); one you dismissed counts for nothing; Accept doesn't make it count twice.
    func testCapturedEditsCountUnlessDismissed() throws {
        let fx = makeFixture()
        dictate(fx, Array(claude.prefix(2)))
        let captured = fx.history.add(text: "Klod said no", duration: 1)!
        fx.history.setCapture(Capture(edited: "Claude said no", mode: .readback, app: "Slack"), for: captured)
        fx.intake.runIfIdle()
        XCTAssertEqual(fx.history.entries[0].intake?.of, "Claude said no")
        XCTAssertEqual(fx.vocabulary.entries.map(\.term), ["Claude"], "the third dictation was a captured edit")
        XCTAssertEqual(fx.history.corrections.count, 2, "still waiting: not a correction, so Learn doesn't see it")

        fx.history.accept(captured)
        fx.intake.runIfIdle()
        XCTAssertEqual(fx.vocabulary.candidates.first?.seen, 3, "the same fix: counted once")
    }

    func testADismissedCaptureCountsForNothing() {
        let fx = makeFixture()
        dictate(fx, Array(claude.prefix(2)))
        let captured = fx.history.add(text: "Klod said no", duration: 1)!
        fx.history.setCapture(Capture(edited: "Claude said no", mode: .keystrokes, app: "Notes"), for: captured)
        fx.history.dismiss(captured)
        fx.intake.runIfIdle()
        XCTAssertNil(fx.history.entries[0].intake)
        XCTAssertTrue(fx.vocabulary.entries.isEmpty)
        XCTAssertEqual(fx.vocabulary.candidates.first?.seen, 2)
    }

    /// A dictation with a captured edit isn't one you left alone: its words don't make a heard an
    /// ordinary word.
    func testACapturedDictationIsNotAnUncorrectedOne() {
        let fx = makeFixture()
        dictate(fx, [("my cloud bill", nil), ("the cloud is down", nil)])
        for text in ["cloud is great", "ask cloud", "cloud said no"] {
            let id = fx.history.add(text: text, duration: 1)!
            fx.history.setCapture(Capture(edited: text.replacingOccurrences(of: "cloud", with: "Claude"), mode: .readback, app: "Slack"), for: id)
        }
        fx.intake.runIfIdle()
        let heard = fx.vocabulary.candidates.first?.heard.first
        XCTAssertEqual(heard?.ordinary, false, "only 2 dictations left alone have it")
        XCTAssertEqual(fx.vocabulary.entries.first?.heardAs, ["cloud"])
    }
}
