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
        XCTAssertEqual(RecentLatencyView.answered(speech), "8 of 11 (73%)")
        XCTAssertEqual(RecentLatencyView.answered(speechBackup), "Asked 8, first 3")
    }

    func testDictationsWithoutModelsStillShowTheirWaits() {
        let latency = RecentLatency([Self.entry(1, 0.6, 1.1, speech: nil, polished: nil)], window: .tenMinutes, now: Self.now)
        XCTAssertEqual(latency.rows.count, 1, "on-device speech, and history from before models were saved")
        XCTAssertTrue(latency.models.isEmpty)
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
        XCTAssertEqual(rows.map(RecentLatencyView.backupLabel).prefix(5), ["speech, polish", "", "", "", "speech"])
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
        let history = HistoryStore(fileURL: makeTempURL(self), defaults: makeDefaults(self))
        Self.tonight.reversed().forEach { e in
            history.add(text: e.text, duration: e.duration, transcribeSeconds: e.transcribeSeconds, polishSeconds: e.polishSeconds,
                        transcribedBy: e.transcribedBy, polishedBy: e.polishedBy, date: Date().addingTimeInterval(e.date.timeIntervalSince(Self.now)))
        }
        let hosted = HostedView(MainView(selection: selection, services: makeServices(self, settings: settings, history: history)),
                                size: NSSize(width: 860, height: 2400))
        addTeardownBlock { hosted.close() }
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
        let hosted = HostedView(RecentLatencyView(entries: Self.tonight, now: Self.now), size: NSSize(width: 680, height: 1400))
        addTeardownBlock { hosted.close() }
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
        let hosted = HostedView(RecentLatencyView(entries: [Self.entry(60, 1, 0.2)], now: Self.now, window: .tenMinutes),
                                size: NSSize(width: 680, height: 300))
        addTeardownBlock { hosted.close() }
        XCTAssertNotNil(hosted.element(id: "recent.empty"))
        XCTAssertNil(hosted.element(id: "recent.typical"))
    }

    func testStatsAndComparisonsOnScreen() {
        let usual = TimeBreakdown(speaking: 13.9, transcribing: 1.3, polishing: 0.3, count: 100)
        let hosted = HostedView(RecentLatencyView(entries: Self.tonight, usual: usual, now: Self.now), size: NSSize(width: 680, height: 1400))
        addTeardownBlock { hosted.close() }
        func text(_ id: String) -> String {
            guard let node = hosted.element(id: id) else { return "<missing \(id)>" }
            return "\(node.label ?? "") \(node.value ?? "")"
        }
        XCTAssertTrue(text("recent.typical").contains("6.2"), text("recent.typical"))
        XCTAssertTrue(text("recent.slowest").contains("29.9"), text("recent.slowest"))
        XCTAssertTrue(text("recent.slow").contains("7") && text("recent.slow").contains("of 11"), text("recent.slow"))
        XCTAssertTrue(text("recent.compare.Transcribing").contains("3.1× slower than usual"), text("recent.compare.Transcribing"))
        XCTAssertTrue(text("recent.compare.Polishing").contains("7.2× slower than usual"), text("recent.compare.Polishing"))
    }
}
