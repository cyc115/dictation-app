import SwiftUI
import XCTest
@testable import DictationKit

/// Settings on Cloud Flash with a key, a history of `count` corrections, a throwaway learned-prompt
/// store, and a tuner with a fake teacher and student (`FakeStudent`: the "both" lens fixes
/// everything, the current prompt gets one word wrong).
@MainActor
struct LearnFixture {
    let settings: AppSettings
    let history: HistoryStore
    let store: LearnedPromptStore
    let teacher = PromptTunerTests.FakeTeacher()
    let log = EventLog()
    let controller: LearnController
    var inputs: [String] { history.corrections.map(\.input) }

    init(_ test: XCTestCase, count: Int = 10, key: Bool = true, setup: DictationSetup = .cloudFlash,
         generalFails: [Lens: Set<String>] = [:], right: [Lens: Set<String>]? = nil, studentError: PolishError? = nil,
         studentDelay: TimeInterval = 0) {
        store = LearnedPromptStore(fileURL: makeTempURL(test, "learned-prompts.json"))
        settings = makeSettings(test, learned: store)
        if key { settings.setOpenRouterKey("sk-or-v1-test") }
        settings.setup = settings.setups.first { $0.id == setup.id }!
        // Fixed dates (not Date()), so snapshots don't change with the clock.
        let url = makeTempURL(test)
        var entries: [HistoryEntry] = []
        for n in stride(from: max(count, 1), through: 1, by: -1) where count > 0 {
            var entry = HistoryEntry(date: fixedDate(2026, 10, 13, 8, n), text: "Can you install Cloud Code \(n)?", duration: 2,
                                     raw: "can you install cloud code \(n)", setup: "cloud-flash", prompt: "v7")
            entry.correction = "Can you install Claude Code \(n)?"
            entries.append(entry)
        }
        JSONFile.save(entries, to: url)
        history = HistoryStore(fileURL: url, defaults: makeDefaults(test))
        let general = [GeneralCase(id: "g1", raw: "general one", expected: "general one"),
                       GeneralCase(id: "g2", raw: "general two", expected: "general two")]
        let wanted = Dictionary(uniqueKeysWithValues: history.corrections.map { ($0.input, $0.correction!) })
        let right = right ?? [.both: Set(wanted.keys)]
        let teacher = teacher, log = log
        // The current prompt with one rule added, so the diff is one hunk, as a real tune's would be.
        teacher.answer = { lens, user in
            let current = user.components(separatedBy: "<current>\n")[1].components(separatedBy: "\n</current>")[0]
            let edited = current.replacingOccurrences(of: "- Convert Traditional Chinese characters to Simplified.",
                                                      with: "- Convert Traditional Chinese characters to Simplified.\n- Terms you use: Claude (never Cloud), Codex. LENS:\(lens.rawValue)")
            return "<prompt>\n\(edited)\n</prompt>"
        }
        controller = LearnController(settings: settings, history: history, store: store, general: general) { _, _ in
            PromptTuner(student: { FakeStudent(instructions: $0, right: right, wanted: wanted, generalFails: generalFails, log: log, error: studentError, delay: studentDelay) },
                        teacher: teacher.call, general: general, repeats: 1)
        }
        controller.now = { fixedDate(2026, 10, 13, 9, 0) }
    }

    /// The tile measures the current prompt as it appears; this waits for that to finish.
    func host(_ test: XCTestCase, height: CGFloat = 900) -> HostedView<CorrectionsView> {
        let hosted = HostedView(CorrectionsView(store: history, learn: controller), size: NSSize(width: 760, height: height))
        test.addTeardownBlock { hosted.close() }
        waitUntil(timeout: 5) { !controller.measuring }
        hosted.settle()
        return hosted
    }
}

@MainActor
final class LearnUITests: XCTestCase {
    func testGatedUntilTenCorrectionsWithACloudSetupAndAKey() {
        let few = LearnFixture(self, count: 7)
        XCTAssertEqual(few.controller.gate, .needMore(have: 7))
        let hosted = few.host(self)
        XCTAssertNil(hosted.element(id: "learn.button"))
        XCTAssertTrue(hosted.allText.contains("7 of 10"), hosted.allText)
        XCTAssertEqual(hosted.element(id: "learn.score.mine")?.value, "not measured yet", "no score before the first tune")
        XCTAssertTrue(hosted.allText.contains("Not measured yet"))

        XCTAssertEqual(LearnFixture(self, key: false).controller.gate, .noKey)
        XCTAssertEqual(LearnFixture(self, setup: .onDevice).controller.gate, .cloudOnly)
        let ready = LearnFixture(self)
        XCTAssertEqual(ready.controller.gate, .ready(count: 10))
        let readyHosted = ready.host(self)
        XCTAssertEqual(readyHosted.element(id: "learn.button")?.label, "Learn")
        XCTAssertNil(readyHosted.element(id: "corrections.fit"), "no fit before any tune")
    }

    func testTheTileMeasuresTheCurrentPromptWhenItHasNothingToShow() {
        let fx = LearnFixture(self, studentDelay: 0.3)
        XCTAssertNil(fx.store.measurement(setup: "cloud-flash", prompt: "v7"))
        let hosted = HostedView(CorrectionsView(store: fx.history, learn: fx.controller), size: NSSize(width: 760, height: 600))
        addTeardownBlock { hosted.close() }
        hosted.settle()
        XCTAssertEqual(fx.controller.gate, .measuring)
        XCTAssertEqual(hosted.element(id: "learn.button")?.label, "Measuring…")
        XCTAssertEqual(hosted.element(id: "learn.status")?.value, "Measuring prompt v7 on your 10 corrections and the general test set")
        waitUntil(timeout: 5) { !fx.controller.measuring }
        hosted.settle()
        let m = fx.store.measurement(setup: "cloud-flash", prompt: "v7")
        XCTAssertEqual(m?.mine ?? 0, 83.3, accuracy: 0.1)
        XCTAssertEqual(m?.general, 100)
        XCTAssertEqual(m?.corrections, 10)
        XCTAssertEqual(hosted.element(id: "learn.score.mine")?.value, "83%")
        XCTAssertEqual(hosted.element(id: "learn.score.general")?.value, "100%")
        XCTAssertNil(hosted.element(id: "learn.status"), "nothing to say once measured")
        XCTAssertEqual(fx.controller.gate, .ready(count: 10))
        XCTAssertEqual(fx.teacher.inputs.count, 0, "no teacher for a measurement")
        let polishes = fx.log.events.filter { $0.hasPrefix("polish:") }.count
        XCTAssertEqual(polishes, 10 + 2, "corrections once, and the general set")

        let again = fx.host(self)
        XCTAssertEqual(fx.log.events.filter { $0.hasPrefix("polish:") }.count, polishes, "measured once, remembered")
        XCTAssertEqual(again.element(id: "learn.score.mine")?.value, "83%")

        let few = LearnFixture(self, count: 7)
        _ = few.host(self)
        XCTAssertNil(few.store.measurement(setup: "cloud-flash", prompt: "v7"), "below the minimum: not measured")
        XCTAssertEqual(few.controller.gate, .needMore(have: 7))
    }

    func testLearnRunsTheTuneAndShowsCandidatesDiffScoresAndFits() throws {
        let fx = LearnFixture(self)
        let hosted = fx.host(self)
        XCTAssertTrue(hosted.click(try XCTUnwrap(hosted.element(id: "learn.button"))))
        XCTAssertEqual(fx.controller.sweep, 1)
        waitUntil(timeout: 5) { fx.controller.gate == .done }
        hosted.settle()

        let result = try XCTUnwrap(fx.controller.result)
        XCTAssertEqual(result.lens, .both)
        XCTAssertEqual(hosted.elements { $0.identifier?.hasPrefix("learn.candidate.") ?? false }.count, 3)
        XCTAssertEqual(hosted.element(id: "learn.candidate.both")?.value, "100%")
        XCTAssertTrue(hosted.allText.contains("best"))
        XCTAssertNotNil(hosted.element(id: "learn.diff"))
        XCTAssertTrue(hosted.allText.contains("Terms you use: Claude (never Cloud), Codex. LENS:both"), "the new prompt's added line")
        XCTAssertFalse(hosted.allText.contains("Output only the cleaned transcript."), "only the hunk, not the whole prompt")
        XCTAssertEqual(hosted.element(id: "learn.score.mine")?.value, "100%")
        XCTAssertEqual(hosted.element(id: "learn.score.mine")?.label, "100, %, +17, Your corrections · Cloud Flash", "from 83 (one word in six wrong)")
        XCTAssertEqual(hosted.element(id: "learn.score.general")?.label, "100, %, held, General test set · guard")
        XCTAssertEqual(hosted.element(id: "learn.status")?.value, "v8: 10 of 10 corrections now within 15% of what you wanted (v7: 0). General set held at 100%.")
        XCTAssertEqual(hosted.elements(id: "corrections.fit").count, hosted.elements(id: "corrections.card").count, "every card on screen")
        XCTAssertEqual(hosted.element(id: "corrections.fit")?.value, "v7 17% off, →, v8 0% off, learned")
        XCTAssertTrue(hosted.allText.contains("Prompt v8"))
        XCTAssertTrue(hosted.allText.contains("learned from 10 corrections · Oct 13"))
        XCTAssertNil(hosted.element(id: "learn.verdict"))
        XCTAssertEqual(hosted.element(id: "learn.button")?.label, "Learned")
    }

    func testKeepMakesTheSetupPolishWithTheNewVersion() throws {
        let fx = LearnFixture(self)
        let hosted = fx.host(self)
        fx.controller.learn()
        waitUntil(timeout: 5) { fx.controller.gate == .done }
        hosted.settle()
        XCTAssertTrue(hosted.click(try XCTUnwrap(hosted.element(id: "learn.keep"))))
        XCTAssertEqual(fx.store.active(for: "cloud-flash")?.version, "v8")
        waitUntil { fx.settings.setup.prompt == "v8" }
        XCTAssertTrue(fx.settings.setup.promptText.hasPrefix(PolishPrompt.v4.prefix(40)) && fx.settings.setup.promptText.contains("Codex. LENS:both"), "the kept text")
        XCTAssertNil(fx.controller.result)
        XCTAssertEqual(fx.controller.gate, .allLearned(count: 10), "nothing left to learn")
        hosted.settle()
        XCTAssertEqual(hosted.element(id: "learn.status")?.value, "Cloud Flash now polishes with prompt v8. Older versions are in Settings › Model.")
        XCTAssertEqual(hosted.element(id: "learn.score.mine")?.value, "100%", "the kept version's scores stay on the rings")
        XCTAssertEqual(hosted.elements(id: "corrections.fit").count, hosted.elements(id: "corrections.card").count, "fits now come from the kept version")
        XCTAssertEqual(fx.controller.fit(for: fx.history.corrections[0].id)?.to, "v8")
        XCTAssertEqual(fx.controller.fit(for: fx.history.corrections[0].id)?.from, "v7")

        fx.history.add(text: "New one", duration: 1, raw: "new one", setup: "cloud-flash", prompt: "v8")
        fx.history.setCorrection("A new one", for: fx.history.entries[0].id)
        XCTAssertEqual(fx.controller.gate, .ready(count: 11), "a new correction: learn again")
        XCTAssertEqual(fx.controller.nextVersion, "v9")
        XCTAssertNil(fx.controller.fit(for: fx.history.entries[0].id), "not scored yet")
    }

    func testDiscardAndAFailedVerdictKeepNothing() throws {
        let fx = LearnFixture(self)
        let hosted = fx.host(self)
        fx.controller.learn()
        waitUntil(timeout: 5) { fx.controller.gate == .done }
        hosted.settle()
        XCTAssertTrue(hosted.click(try XCTUnwrap(hosted.element(id: "learn.discard"))))
        XCTAssertNil(fx.controller.result)
        XCTAssertNil(fx.store.active(for: "cloud-flash"))
        XCTAssertEqual(fx.controller.gate, .ready(count: 10))
        XCTAssertNil(hosted.element(id: "corrections.fit"))

        let dropped = LearnFixture(self, generalFails: [.both: ["general one"]])
        let droppedHosted = dropped.host(self)
        dropped.controller.learn()
        waitUntil(timeout: 5) { dropped.controller.gate == .done }
        droppedHosted.settle()
        XCTAssertEqual(dropped.controller.result?.verdict, .generalDropped)
        XCTAssertEqual(droppedHosted.element(id: "learn.verdict")?.value, "Not kept: the general set dropped more than 2 points.")
        XCTAssertEqual(droppedHosted.element(id: "learn.keep")?.object.value(forKey: "accessibilityEnabled") as? Bool, false)
        XCTAssertEqual(droppedHosted.element(id: "learn.score.general")?.label, "50, %, -50, General test set · guard")
        dropped.controller.keep()
        XCTAssertNil(dropped.store.active(for: "cloud-flash"), "keep() refuses a failed verdict")
    }

    func testAFailureIsShownAndLearnCanRunAgain() {
        let fx = LearnFixture(self, studentError: .failed("No credits."))
        let hosted = fx.host(self)
        fx.controller.learn()
        waitUntil(timeout: 5) { fx.controller.error != nil }
        hosted.settle()
        XCTAssertEqual(hosted.element(id: "learn.status")?.value, "Polishing failed: No credits.")
        XCTAssertEqual(fx.controller.gate, .ready(count: 10))
        XCTAssertEqual(hosted.element(id: "learn.button")?.label, "Learn")
    }

    func testSettingsOffersThePromptVersions() {
        let fx = LearnFixture(self)
        let hosted = HostedView(SettingsView(services: makeServices(self, settings: fx.settings, history: fx.history)),
                                size: NSSize(width: 640, height: 2300))
        addTeardownBlock { hosted.close() }
        let row = "setting.Polish prompt"
        XCTAssertFalse(fx.settings.polishEnabled)
        XCTAssertEqual(hosted.element(id: row)?.object.value(forKey: "accessibilityEnabled") as? Bool, false, "no polish, no prompt to choose")
        XCTAssertTrue(hosted.allText.contains("Turn on AI polish to choose the prompt it polishes with."))
        fx.settings.polishEnabled = true
        hosted.settle()
        XCTAssertEqual(hosted.element(id: row)?.object.value(forKey: "accessibilityEnabled") as? Bool, false, "nothing learned yet")
        XCTAssertTrue(hosted.allText.contains("Learn one from your corrections in the Corrections tab."))
        XCTAssertTrue(hosted.allText.contains("v7 · built in"), "no score until measured")

        let id = fx.history.corrections[0].id
        fx.store.keep(makeLearned(errors: [id: 0.0], errorsBefore: [id: 0.2]))
        waitUntil { fx.settings.setup.prompt == "v8" }
        hosted.settle()
        XCTAssertEqual(hosted.element(id: row)?.object.value(forKey: "accessibilityEnabled") as? Bool, true)
        XCTAssertTrue(hosted.allText.contains("v8 · learned from 15 corrections: 65% → 74% on them, general set 71%."), hosted.allText)
        XCTAssertTrue(hosted.allText.contains("v8 · 74% · from v7 · Oct 13"), hosted.allText)

        fx.store.activate(nil, for: "cloud-flash")
        waitUntil { fx.settings.setup.prompt == "v7" }
        hosted.settle()
        XCTAssertTrue(hosted.allText.contains("The built-in prompt."))
        XCTAssertFalse(hosted.allText.contains("Learn one from your corrections"), "a version exists, it's just not chosen")
        XCTAssertTrue(hosted.allText.contains("v7 · 65% · built in"), "the built-in's score is v8's baseline: \(hosted.allText)")

        fx.store.record(PromptMeasurement(setup: "cloud-flash", prompt: "v7", date: fixedDate(2026, 10, 14, 9, 0), mine: 68.2, general: 70, corrections: 11))
        hosted.settle()
        XCTAssertTrue(hosted.allText.contains("v7 · 68% · built in"), "a fresh measurement wins over the old baseline")
    }
}
