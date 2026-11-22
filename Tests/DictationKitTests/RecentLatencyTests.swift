import SwiftUI
import XCTest
@testable import DictationKit

/// Settings → Show detailed analytics: recent dictations' waits and which models gave them.
final class RecentLatencyTests: XCTestCase {
    static let flash = "qwen/qwen3-asr-1.7b", small = "qwen/qwen3-asr-0.6b"
    static let together = "openrouter:deepseek/deepseek-v4.1-flash@Together,DeepInfra"
    static let deepInfra = "openrouter:deepseek/deepseek-v4.1-flash@DeepInfra,Together"
    static let now = fixedDate(2026, 10, 18, 21, 17)

    /// A timed dictation `minutesAgo` before `now`. `speech` / `polish`: "main", "asked" (the backup
    /// was asked, the main model won), "backup" (the backup won) or nil (not recorded).
    static func entry(_ minutesAgo: Double, spoke: Double = 10, _ transcribe: Double, _ polish: Double?,
                      speech: String? = "main", polished: String? = "main") -> HistoryEntry {
        func answer(_ kind: String?, main: String, backup: String) -> ModelAnswer? {
            kind.map { ModelAnswer(main: main, backup: $0 == "main" ? nil : backup, byBackup: $0 == "backup") }
        }
        return HistoryEntry(date: now.addingTimeInterval(-minutesAgo * 60), text: "t", duration: spoke,
                            transcribeSeconds: transcribe, polishSeconds: polish,
                            transcribedBy: answer(speech, main: flash, backup: small),
                            polishedBy: polish == nil ? nil : answer(polished, main: together, backup: deepInfra))
    }

    /// Oct 18's real timings: a slow spell from 9:00 PM, normal at 4:50 PM. Backups as recorded from now on.
    static var tonight: [HistoryEntry] {
        [entry(0.3, spoke: 139, 4.0, 2.17, speech: "backup", polished: "backup"),
         entry(3.0, spoke: 20, 29.6, 0.25, speech: "asked"),
         entry(3.8, spoke: 8, 0.98, 0.21),
         entry(5.1, spoke: 4, 2.66, 0.28, speech: "asked"),
         entry(14.1, spoke: 3, 5.17, 4.19, speech: "backup", polished: "asked"),
         entry(14.4, spoke: 16, 4.74, 4.19, speech: "asked", polished: "asked"),
         entry(14.8, spoke: 13, 0.82, 4.19, polished: "asked"),
         entry(15.0, spoke: 55, 5.46, 4.15, speech: "backup", polished: "backup"),
         entry(16.0, spoke: 14, 11.1, 6.27, speech: "asked", polished: "asked"),
         entry(18.7, spoke: 12, 1.75, 0.27),
         entry(20.3, spoke: 4, 2.51, 0.28, speech: "asked"),
         entry(260, spoke: 15, 0.91, 0.24), entry(261, spoke: 6, 0.54, 0.24), entry(262, spoke: 9, 0.82, 0.28)]
    }

    // MARK: Logic

    func testWindowsPickTimedDictationsNewestFirst() {
        let entries = Self.tonight + [HistoryEntry(date: Self.now, text: "untimed", duration: 3)]
        XCTAssertEqual(RecentLatency(entries, window: .tenMinutes, now: Self.now).rows.count, 4)
        XCTAssertEqual(RecentLatency(entries, window: .thirtyMinutes, now: Self.now).rows.count, 11)
        let last25 = RecentLatency(entries, window: .last25, now: Self.now)
        XCTAssertEqual(last25.rows.count, 14, "all timed ones, however old; the untimed one never")
        XCTAssertEqual(last25.rows.first?.transcribing, 4.0)
        let many = Array(repeating: Self.entry(1, 1, 0.2), count: 40)
        XCTAssertEqual(RecentLatency(many, window: .last25, now: Self.now).rows.count, 25)
    }

    func testWaitsAreStopToTextAndTypicalIsTheMedian() throws {
        let latency = RecentLatency(Self.tonight, window: .thirtyMinutes, now: Self.now)
        XCTAssertEqual(try XCTUnwrap(latency.rows.first).wait, 6.17, accuracy: 1e-9, "speaking isn't part of the wait")
        XCTAssertEqual(try XCTUnwrap(latency.typicalWait), 6.17, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(latency.slowestWait), 29.85, accuracy: 1e-9)
        XCTAssertEqual(latency.typicalTranscribing, 4.0)
        XCTAssertEqual(latency.typicalPolishing, 2.17)
        XCTAssertEqual(latency.count(slowerThan: 3), 7, "2.94 s isn't over 3")
        let unpolished = RecentLatency([Self.entry(1, 1.5, nil)], window: .tenMinutes, now: Self.now)
        XCTAssertEqual(unpolished.rows.first?.wait, 1.5)
        XCTAssertNil(unpolished.typicalPolishing)
    }

    func testModelsSplitMainFromBackupAndCountWhoAnswered() throws {
        let models = RecentLatency(Self.tonight, window: .thirtyMinutes, now: Self.now).models
        XCTAssertEqual(models.map { "\($0.phase.rawValue) \($0.model) \($0.isBackup ? "backup" : "main")" },
                       ["Speech \(Self.flash) main", "Speech \(Self.small) backup",
                        "Polish \(Self.together) main", "Polish \(Self.deepInfra) backup"])
        let speech = models[0], speechBackup = models[1], polishBackup = models[3]
        XCTAssertEqual(speech.asked, 11)
        XCTAssertEqual(speech.answered, 8)
        XCTAssertEqual(speech.slowest, 29.6, "only the answers it gave")
        XCTAssertEqual(speechBackup.asked, 8)
        XCTAssertEqual(speechBackup.answered, 3)
        XCTAssertEqual(speechBackup.typical, 5.17)
        XCTAssertEqual(polishBackup.asked, 6)
        XCTAssertEqual(polishBackup.answered, 2)
        XCTAssertEqual(speech.answeredLabel, "8 of 11 (73%)")
        XCTAssertEqual(speechBackup.answeredLabel, "Asked 8, first 3")
    }

    func testDictationsWithoutModelsStillShowTheirWaits() {
        let latency = RecentLatency([Self.entry(1, 0.6, 1.1, speech: nil, polished: nil)], window: .tenMinutes, now: Self.now)
        XCTAssertEqual(latency.rows.count, 1, "on-device speech, and history from before models were saved")
        XCTAssertTrue(latency.models.isEmpty)
    }

    func testSeverityThresholds() {
        XCTAssertEqual(RecentLatency.Severity(3), .normal, "over 3 s is slow")
        XCTAssertEqual(RecentLatency.Severity(3.1), .slow)
        XCTAssertEqual(RecentLatency.Severity(8), .slow)
        XCTAssertEqual(RecentLatency.Severity(8.1), .verySlow)
    }

    func testComparisonWithUsual() {
        XCTAssertEqual(RecentLatency.comparison(4.0, usual: 1.3), "3.1× slower than usual")
        XCTAssertEqual(RecentLatency.comparison(1.6, usual: 1.3), "normal", "under 1.5×")
        XCTAssertEqual(RecentLatency.comparison(0.2, usual: 0.3), "normal")
    }

    func testLabels() {
        XCTAssertEqual(ModelAnswer.displayName(Self.flash), "qwen3-asr-1.7b")
        XCTAssertEqual(ModelAnswer.displayName(Self.together), "deepseek-v4.1-flash · Together, DeepInfra")
        XCTAssertEqual(ModelAnswer.displayName("apple:on-device"), "Apple on-device")
        let rows = RecentLatency(Self.tonight, window: .thirtyMinutes, now: Self.now).rows
        XCTAssertEqual(rows.map(\.backupLabel).prefix(5), ["speech, polish", "", "", "", "speech"])
        XCTAssertEqual(ModelAnswer(main: "a", backup: "b", byBackup: true).model, "b")
        XCTAssertEqual(ModelAnswer(main: "a", backup: "b").model, "a")
    }

    func testOldHistoryWithoutModelsStillLoads() throws {
        let url = makeTempURL(self)
        try Data(#"[{"id":"0F0E697A-D711-4F8E-9AEE-5B17055EFFE8","date":"2026-10-18T02:00:00Z","text":"hi","duration":2,"transcribeSeconds":1}]"#.utf8)
            .write(to: url)
        let store = HistoryStore(fileURL: url, defaults: makeDefaults(self))
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertNil(store.entries.first?.transcribedBy)
        store.add(text: "new", duration: 1, transcribeSeconds: 0.5, transcribedBy: ModelAnswer(main: "m", backup: "b", byBackup: true))
        let reloaded = HistoryStore(fileURL: url, defaults: makeDefaults(self))
        XCTAssertEqual(reloaded.entries.first?.transcribedBy, ModelAnswer(main: "m", backup: "b", byBackup: true), "saved")
    }

    // MARK: UI

    func testOffByDefaultAndTheSwitchShowsItOnHome() {
        let settings = makeSettings(self)
        XCTAssertFalse(settings.showDetailedAnalytics)
        let selection = TabSelection()
        selection.tab = .settings
        let history = makeHistory(self)
        Self.tonight.reversed().forEach { e in
            history.add(text: e.text, duration: e.duration, transcribeSeconds: e.transcribeSeconds, polishSeconds: e.polishSeconds,
                        transcribedBy: e.transcribedBy, polishedBy: e.polishedBy, date: Date().addingTimeInterval(e.date.timeIntervalSince(Self.now)))
        }
        let hosted = host(MainView(selection: selection, services: makeServices(self, settings: settings, history: history)),
                          size: NSSize(width: 860, height: 2800))
        selection.tab = .home
        hosted.settle()
        XCTAssertNotNil(hosted.element(id: "insights.breakdown"))
        XCTAssertNil(hosted.element(id: "recent"), "hidden until turned on")

        selection.tab = .settings
        hosted.settle()
        guard let toggle = hosted.element(id: "setting.Show detailed analytics") else { return XCTFail("no switch") }
        XCTAssertTrue(hosted.click(toggle))
        XCTAssertTrue(settings.showDetailedAnalytics)
        selection.tab = .home
        hosted.settle()
        XCTAssertNotNil(hosted.element(id: "recent"))
        XCTAssertEqual(hosted.elements(id: "recent.row").count, 11, "the last 30 minutes")
        XCTAssertEqual(hosted.elements(id: "recent.model").count, 4)

        settings.showDetailedAnalytics = false
        hosted.settle()
        XCTAssertNil(hosted.element(id: "recent"))
    }

    func testWindowPickerChangesTheRows() throws {
        let hosted = host(RecentLatencyView(entries: Self.tonight, now: Self.now), size: NSSize(width: 680, height: 1400))
        XCTAssertEqual(hosted.elements(id: "recent.row").count, 11)
        // A click on the "10 min" segment: NSSegmentedControl selects it, then sends its action.
        let picker = try XCTUnwrap(hosted.elements { $0.object is NSSegmentedControl }.first?.object as? NSSegmentedControl)
        XCTAssertEqual(picker.label(forSegment: 0), "10 min")
        picker.selectedSegment = 0
        XCTAssertTrue(picker.sendAction(picker.action, to: picker.target))
        hosted.settle()
        XCTAssertEqual(hosted.elements(id: "recent.row").count, 4)
        XCTAssertTrue(hosted.allText.contains("4 dictations in the last 10 min"), hosted.allText)
    }

    func testEmptyWindowSaysSo() {
        let hosted = host(RecentLatencyView(entries: [Self.entry(60, 1, 0.2)], now: Self.now, window: .tenMinutes),
                          size: NSSize(width: 680, height: 300))
        XCTAssertNotNil(hosted.element(id: "recent.empty"))
        XCTAssertNil(hosted.element(id: "recent.typical"))
    }

    // MARK: Errors

    /// Nov 22: the speech backup 404'd while Qwen ran on; polish's backup failed once and polish gave up once.
    static var withErrors: [HistoryEntry] {
        var dead = entry(1, 43.9, 0.2, speech: "asked")
        dead.transcribedBy?.failures = [.init(model: small, message: "No endpoints found for qwen/qwen3-asr-0.6b.")]
        var gaveUp = entry(2, 0.5, 6.0)
        gaveUp.polishedBy = ModelAnswer(main: together, backup: deepInfra,
                                        failures: [.init(model: together, message: "No answer within 6 s.")], failed: true)
        return [dead, gaveUp, entry(3, 0.6, 0.2)]
    }

    func testFailedRequestsBecomeTheLinesErrorDetail() throws {
        let latency = RecentLatency(Self.withErrors, window: .last25, now: Self.now)
        XCTAssertEqual(latency.rows[0].errors, "Speech · qwen3-asr-0.6b: No endpoints found for qwen/qwen3-asr-0.6b.")
        XCTAssertEqual(latency.rows[1].errors, "Polish · deepseek-v4.1-flash · Together, DeepInfra: No answer within 6 s.\n"
            + "Polish gave up: your words were pasted unpolished.")
        XCTAssertNil(latency.rows[2].errors, "a clean dictation has no dot")
        let backup = try XCTUnwrap(latency.models.first { $0.model == Self.small && $0.isBackup })
        XCTAssertEqual(backup.failedLabel, "1 failed")
        XCTAssertEqual(backup.answeredLabel, "Asked 1, first 0")
        let polish = try XCTUnwrap(latency.models.first { $0.model == Self.together && !$0.isBackup })
        XCTAssertEqual(polish.answered, 2, "polish that gave up isn't an answer")
        XCTAssertEqual(polish.failedLabel, "1 failed")
        XCTAssertNil(latency.models.first { $0.model == Self.flash }?.failedLabel)
    }

    /// Two dictations that never became text: every model failed at 9:15:30; the mic was silent at 9:10.
    static var failedDictations: [FailedDictation] {
        [FailedDictation(date: now.addingTimeInterval(-1.5 * 60), duration: 6, seconds: 2.4, setup: "cloud-flash",
                         error: "Transcription failed (HTTP 500).",
                         transcribedBy: ModelAnswer(main: flash, backup: small, failures: [
                            .init(model: flash, message: "Transcription failed (HTTP 500)."),
                            .init(model: small, message: "No endpoints found for qwen/qwen3-asr-0.6b.")], failed: true)),
         FailedDictation(date: now.addingTimeInterval(-7 * 60), duration: 3, seconds: 0, error: "The microphone sent only silence.")]
    }

    func testFailedDictationsAreLinesWithNoText() throws {
        let latency = RecentLatency(Self.withErrors, failed: Self.failedDictations, window: .last25, now: Self.now)
        XCTAssertEqual(latency.rows.map(\.backupLabel), ["", "no text", "", "", "no text"], "newest first, merged")
        XCTAssertEqual(latency.rows[1].errors, "Speech · qwen3-asr-1.7b: Transcription failed (HTTP 500).\n"
            + "Speech · qwen3-asr-0.6b: No endpoints found for qwen/qwen3-asr-0.6b.\nNothing was typed.")
        XCTAssertEqual(latency.rows[4].errors, "The microphone sent only silence.\nNothing was typed.", "no model asked: what you were told")
        let withoutFailures = RecentLatency(Self.withErrors, window: .last25, now: Self.now)
        XCTAssertEqual(latency.typicalWait, withoutFailures.typicalWait, "stop to text: a failure has no text")
        XCTAssertEqual(latency.count(slowerThan: 3), withoutFailures.count(slowerThan: 3))
        XCTAssertEqual(latency.texted.count, 3)
        let main = try XCTUnwrap(latency.models.first { $0.model == Self.flash && !$0.isBackup })
        XCTAssertEqual(main.asked, 4)
        XCTAssertEqual(main.answered, 3, "a failed dictation isn't an answer")
        XCTAssertEqual(main.failedLabel, "1 failed")
        XCTAssertEqual(latency.models.first { $0.model == Self.small && $0.isBackup }?.failedLabel, "2 failed")
        // 10 minutes back from 5 minutes on: the three dictations and the 9:15 failure, not the silent one at 9:10.
        XCTAssertEqual(RecentLatency(Self.withErrors, failed: Self.failedDictations, window: .tenMinutes,
                                     now: Self.now.addingTimeInterval(5 * 60)).rows.map(\.noText), [false, true, false, false],
                       "windows apply to them too")
    }

    func testFailedDictationsAreKeptApartFromHistory() throws {
        let url = makeTempURL(self)
        let defaults = makeDefaults(self)
        let store = HistoryStore(fileURL: url, defaults: defaults), failure = Self.failedDictations[0]
        store.addFailed(failure)
        XCTAssertEqual(store.entries, [])
        XCTAssertEqual(HistoryStore(fileURL: url, defaults: defaults).failed, [failure], "saved in its own file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.failedURL.path))
        for i in 0..<(HistoryStore.failedLimit + 5) {
            store.addFailed(FailedDictation(date: Date(), duration: 1, seconds: 0, error: "e\(i)"))
        }
        XCTAssertEqual(store.failed.count, HistoryStore.failedLimit)
        XCTAssertEqual(store.failed.first?.error, "e\(HistoryStore.failedLimit + 4)", "newest kept")
        store.clear()
        XCTAssertEqual(store.failed, [])
        store.retention = .off
        store.addFailed(Self.failedDictations[0])
        XCTAssertEqual(store.failed, [], "History off keeps nothing")
    }

    func testOldFailedDictationsArePrunedWithHistory() {
        let url = makeTempURL(self)
        let defaults = makeDefaults(self)
        let store = HistoryStore(fileURL: url, defaults: defaults)
        store.addFailed(FailedDictation(date: Date().addingTimeInterval(-40 * 86_400), duration: 1, seconds: 0, error: "old"))
        store.addFailed(FailedDictation(date: Date(), duration: 1, seconds: 0, error: "new"))
        store.retention = .days30
        XCTAssertEqual(store.failed.map(\.error), ["new"])
    }

    func testAnErrorIsADotWithItsDetailOnHover() throws {
        let hosted = host(RecentLatencyView(entries: Self.withErrors, now: Self.now), size: NSSize(width: 680, height: 900))
        let rows = hosted.elements(id: "recent.row")
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows[0].text.contains("error"), rows[0].text)
        XCTAssertEqual(rows[0].help, "Speech · qwen3-asr-0.6b: No endpoints found for qwen/qwen3-asr-0.6b.")
        XCTAssertFalse(rows[2].text.contains("error"), rows[2].text)
        XCTAssertTrue(rows[2].help?.isEmpty ?? true)
        XCTAssertTrue(hosted.allText.contains("Error: hover the line for details"))
        XCTAssertTrue(hosted.allText.contains("1 failed"))
    }

    func testNoErrorsNoErrorLegend() {
        let hosted = host(RecentLatencyView(entries: Self.tonight, now: Self.now), size: NSSize(width: 680, height: 1400))
        XCTAssertFalse(hosted.allText.contains("Error: hover"), "nothing to explain")
        XCTAssertFalse(hosted.allText.contains("failed"))
    }

    func testFailuresSurviveSavingAndOldEntriesLoad() throws {
        let url = makeTempURL(self)
        let store = HistoryStore(fileURL: url, defaults: makeDefaults(self))
        let answer = ModelAnswer(main: "m", backup: "b", failures: [.init(model: "b", message: "404")], failed: true)
        store.add(text: "x", duration: 1, transcribeSeconds: 0.5, polishSeconds: 6, polishedBy: answer)
        XCTAssertEqual(HistoryStore(fileURL: url, defaults: makeDefaults(self)).entries.first?.polishedBy, answer)
        let old = try JSONDecoder().decode(ModelAnswer.self, from: Data(#"{"main":"m","byBackup":false}"#.utf8))
        XCTAssertNil(old.failures)
        XCTAssertNil(old.failed)
    }

    func testStatsAndComparisonsOnScreen() {
        let usual = TimeBreakdown(speaking: 13.9, transcribing: 1.3, polishing: 0.3, count: 100)
        let hosted = host(RecentLatencyView(entries: Self.tonight, usual: usual, now: Self.now), size: NSSize(width: 680, height: 1400))
        func text(_ id: String) -> String { hosted.element(id: id)?.text ?? "<missing \(id)>" }
        XCTAssertTrue(text("recent.typical").contains("6.2"), text("recent.typical"))
        XCTAssertTrue(text("recent.slowest").contains("29.9"), text("recent.slowest"))
        XCTAssertTrue(text("recent.slow").contains("7") && text("recent.slow").contains("of 11"), text("recent.slow"))
        XCTAssertTrue(text("recent.compare.Transcribing").contains("3.1× slower than usual"), text("recent.compare.Transcribing"))
        XCTAssertTrue(text("recent.compare.Polishing").contains("7.2× slower than usual"), text("recent.compare.Polishing"))
    }
}
