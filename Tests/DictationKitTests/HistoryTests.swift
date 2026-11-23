import AppKit
import AVFoundation
import Combine
import XCTest
@testable import DictationKit

final class InsightsTests: XCTestCase {
    func testWordCountEnglishChineseAndMixed() {
        XCTAssertEqual(Insights.wordCount(""), 0)
        XCTAssertEqual(Insights.wordCount("Hello, world! It's fine."), 4)
        XCTAssertGreaterThan(Insights.wordCount("我今天很高兴"), 1, "Chinese is segmented into words, not one blob")
        let mixed = Insights.wordCount("我想用 Swift 写一个 app")
        XCTAssertGreaterThanOrEqual(mixed, 4)
    }

    func testRecordAccumulatesAndPersists() {
        let defaults = makeDefaults(self)
        let insights = Insights(defaults: defaults)
        insights.record(text: "one two three four", duration: 2)
        insights.record(text: "five six", duration: 1)
        XCTAssertEqual(insights.words, 6)
        XCTAssertEqual(insights.seconds, 3, accuracy: 0.001)
        let reloaded = Insights(defaults: defaults)
        XCTAssertEqual(reloaded.words, 6)
        XCTAssertEqual(reloaded.seconds, 3, accuracy: 0.001)
    }

    func testEmptyTextIsNotRecorded() {
        let insights = Insights(defaults: makeDefaults(self))
        insights.record(text: "   ", duration: 5)
        XCTAssertEqual(insights.words, 0)
        XCTAssertEqual(insights.seconds, 0)
    }

    func testDerivedStats() {
        let insights = Insights(defaults: makeDefaults(self))
        XCTAssertEqual(insights.wordsPerMinute, 0, "no division by zero")
        // 120 words in 60s → 120 WPM. Typing at 40 WPM takes 180s → 120s saved.
        insights.record(text: Array(repeating: "word", count: 120).joined(separator: " "), duration: 60)
        XCTAssertEqual(insights.wordsPerMinute, 120)
        XCTAssertEqual(insights.secondsSaved, 120, accuracy: 0.001)
    }

    func testTimeSavedNeverNegative() {
        let insights = Insights(defaults: makeDefaults(self))
        insights.record(text: "slow", duration: 600)
        XCTAssertEqual(insights.secondsSaved, 0)
    }
}

final class HistoryStoreTests: XCTestCase {
    func testAddPersistsNewestFirst() {
        let url = makeTempURL(self), defaults = makeDefaults(self)
        let store = HistoryStore(fileURL: url, defaults: defaults)
        store.add(text: "first", duration: 1)
        store.add(text: "second", duration: 2)
        XCTAssertEqual(store.entries.map(\.text), ["second", "first"])
        let reloaded = HistoryStore(fileURL: url, defaults: defaults)
        XCTAssertEqual(reloaded.entries.map(\.text), ["second", "first"])
        XCTAssertEqual(reloaded.entries.last?.duration, 1)
    }

    func testDeleteAndClear() {
        let store = makeHistory(self)
        store.add(text: "a", duration: 1); store.add(text: "b", duration: 1); store.add(text: "c", duration: 1)
        store.delete(store.entries[1])
        XCTAssertEqual(store.entries.map(\.text), ["c", "a"])
        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testEmptyTextIgnored() {
        let store = makeHistory(self)
        store.add(text: "", duration: 1)
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testRetentionOffKeepsNothing() {
        let store = makeHistory(self)
        store.add(text: "kept", duration: 1)
        store.retention = .off
        XCTAssertTrue(store.entries.isEmpty, "switching to Don't keep clears history")
        store.add(text: "dropped", duration: 1)
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testRetentionPrunesOldEntriesOnLoad() throws {
        let url = makeTempURL(self), defaults = makeDefaults(self)
        let old = HistoryEntry(date: Date().addingTimeInterval(-10 * 86_400), text: "old", duration: 1)
        let recent = HistoryEntry(date: Date().addingTimeInterval(-3600), text: "recent", duration: 1)
        try JSONFile.write([recent, old], to: url)
        defaults.set(HistoryRetention.days7.rawValue, forKey: "historyRetention")
        let store = HistoryStore(fileURL: url, defaults: defaults)
        XCTAssertEqual(store.entries.map(\.text), ["recent"])
    }

    func testRawSetupAndPromptAreKept() {
        let url = makeTempURL(self), defaults = makeDefaults(self)
        let store = HistoryStore(fileURL: url, defaults: defaults)
        store.add(text: "Send it tomorrow.", duration: 1, raw: "um send it tomorrow", setup: "cloud-flash", prompt: "v3")
        store.add(text: "unpolished", duration: 1, raw: "unpolished", setup: "on-device")
        let reloaded = HistoryStore(fileURL: url, defaults: defaults).entries
        XCTAssertEqual(reloaded[1].raw, "um send it tomorrow")
        XCTAssertEqual(reloaded[1].setup, "cloud-flash")
        XCTAssertEqual(reloaded[1].prompt, "v3")
        XCTAssertNil(reloaded[0].raw, "same as the text: not stored twice")
        XCTAssertEqual(reloaded[0].input, "unpolished")
        XCTAssertNil(reloaded[0].prompt)
    }

    func testOldEntriesDecodeWithoutTheNewFields() throws {
        let url = makeTempURL(self)
        try Data(#"[{"id":"7F1D7C55-0000-4000-8000-000000000001","date":"2026-10-07T07:00:00Z","text":"old","duration":1}]"#.utf8).write(to: url)
        let entry = try XCTUnwrap(HistoryStore(fileURL: url, defaults: makeDefaults(self)).entries.first)
        XCTAssertEqual(entry.text, "old")
        XCTAssertNil(entry.raw); XCTAssertNil(entry.setup); XCTAssertNil(entry.correction); XCTAssertNil(entry.intake)
        XCTAssertEqual(entry.input, "old", "no raw: the text stands in for it")
    }

    /// Every page that shows History redraws when it publishes; a correction being typed publishes
    /// with its save, once typing pauses, not on every keystroke.
    func testTypingACorrectionPublishesOnceTypingPauses() {
        let store = makeHistory(self)
        store.add(text: "Cloud Code", duration: 1)
        let id = store.entries[0].id
        var published = 0
        let watching = store.objectWillChange.sink { _ in published += 1 }
        defer { watching.cancel() }
        store.setCorrection("Cloud Code", for: id)
        XCTAssertEqual(published, 1, "a new correction shows everywhere at once")
        store.setCorrection("Claude Cod", for: id)
        store.setCorrection("Claude Code", for: id)
        XCTAssertEqual(published, 1, "typing doesn't publish…")
        XCTAssertEqual(store.corrections.first?.correction, "Claude Code", "…but reads back at once")
        waitUntil(timeout: 1) { published == 2 }  // with the save
        store.setCorrection("", for: id)
        XCTAssertEqual(published, 3, "removing it shows everywhere at once")
    }

    func testCorrectionsAreSavedEditedAndRemovedWhenEmptied() {
        let url = makeTempURL(self), defaults = makeDefaults(self)
        let store = HistoryStore(fileURL: url, defaults: defaults)
        store.add(text: "Cloud Code", duration: 1); store.add(text: "fine", duration: 1)
        let id = store.entries[1].id
        store.setCorrection("Claude Code", for: id)
        XCTAssertEqual(store.corrections.map(\.id), [id])
        XCTAssertEqual(HistoryStore(fileURL: url, defaults: defaults).corrections.first?.correction, "Claude Code", "saved")
        store.setCorrection("Claude Code, please", for: id)
        XCTAssertEqual(store.corrections.first?.correction, "Claude Code, please")
        XCTAssertEqual(HistoryStore(fileURL: url, defaults: defaults).corrections.first?.correction, "Claude Code",
                       "an edit is written once typing pauses")
        spinRunLoop(0.6)
        XCTAssertEqual(HistoryStore(fileURL: url, defaults: defaults).corrections.first?.correction, "Claude Code, please")
        store.setCorrection("Claude Code, now", for: id)
        store.flush()
        XCTAssertEqual(HistoryStore(fileURL: url, defaults: defaults).corrections.first?.correction, "Claude Code, now",
                       "flushed at quit")
        store.setCorrection("  \n", for: id)
        XCTAssertTrue(store.corrections.isEmpty, "emptied: no correction")
        XCTAssertNil(HistoryStore(fileURL: url, defaults: defaults).entries[1].correction)
    }

    /// The pass that works out intake (`VocabularyIntake`) sets many at once: one publish, one save;
    /// one worked out from a correction that has changed since is stale and not kept.
    func testIntakesAreSetTogetherAndOnlyForTheirTarget() throws {
        let url = makeTempURL(self), defaults = makeDefaults(self)
        let store = HistoryStore(fileURL: url, defaults: defaults)
        store.add(text: "I use cloud.", duration: 1); store.add(text: "Cloud Code", duration: 1); store.add(text: "fine", duration: 1)
        let (fine, code, cloud) = (store.entries[0].id, store.entries[1].id, store.entries[2].id)
        store.setCorrection("I use Claude.", for: cloud)
        store.setCorrection("Claude Code", for: code)
        var published = 0
        let watching = store.objectWillChange.sink { _ in published += 1 }
        defer { watching.cancel() }
        store.setIntakes([cloud: FixIntake.intake(of: "I use cloud.", target: "I use Claude."),
                          code: FixIntake.intake(of: "Cloud Code", target: "Claude Cod"),  // typed on since
                          fine: nil])
        XCTAssertEqual(published, 1)
        let saved = HistoryStore(fileURL: url, defaults: defaults).entries
        XCTAssertEqual(saved.first { $0.id == cloud }?.intake?.changes, [WordChange(old: "cloud", new: "Claude")])
        XCTAssertNil(saved.first { $0.id == code }?.intake, "stale: worked out again at the next pass")

        store.setIntakes([fine: nil])
        XCTAssertEqual(published, 1, "nothing changed: no publish")
        store.setCorrection("", for: cloud)
        store.setIntakes([cloud: nil])
        XCTAssertNil(store.entries.first { $0.id == cloud }?.intake, "the correction is gone, and its intake with it")
    }

    func testRetentionNeverPrunesCorrections() throws {
        let url = makeTempURL(self), defaults = makeDefaults(self)
        var old = HistoryEntry(date: Date().addingTimeInterval(-10 * 86_400), text: "old", duration: 1)
        old.correction = "old, fixed"
        try JSONFile.write([old], to: url)
        defaults.set(HistoryRetention.days7.rawValue, forKey: "historyRetention")
        XCTAssertEqual(HistoryStore(fileURL: url, defaults: defaults).entries.map(\.text), ["old"])
    }

    func testCorruptFileStartsEmpty() throws {
        let url = makeTempURL(self)
        try Data("not json".utf8).write(to: url)
        let store = HistoryStore(fileURL: url, defaults: makeDefaults(self))
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testAddSaysWhichEntryItMade() {
        let store = makeHistory(self)
        let id = store.add(text: "hello", duration: 1)
        XCTAssertEqual(id, store.entries[0].id)
        XCTAssertNil(store.add(text: "", duration: 1), "nothing kept, no id")
        store.retention = .off
        XCTAssertNil(store.add(text: "hello", duration: 1))
    }
}

/// Captured fixes (*Learn from my edits*) on their History entries: waiting until you Accept them,
/// and only then training Learn.
final class CapturedFixTests: XCTestCase {
    private func captured(_ store: HistoryStore, _ text: String = "I use cloud code.", edited: String = "I use Claude Code.") -> UUID {
        let id = store.add(text: text, duration: 1)!
        store.setCapture(Capture(edited: edited, mode: .readback, app: "Slack"), for: id)
        return id
    }

    func testACaptureWaitsAndDoesNotTrainLearn() throws {
        let url = makeTempURL(self), defaults = makeDefaults(self)
        let store = HistoryStore(fileURL: url, defaults: defaults)
        let id = captured(store)
        XCTAssertEqual(store.waiting.map(\.id), [id])
        XCTAssertTrue(store.corrections.isEmpty, "waiting: no correction, so Learn doesn't see it")
        XCTAssertEqual(store.entries[0].fixTarget, "I use Claude Code.", "vocabulary counts it")
        let saved = try XCTUnwrap(HistoryStore(fileURL: url, defaults: defaults).entries.first?.capture)
        XCTAssertEqual(saved, Capture(edited: "I use Claude Code.", mode: .readback, app: "Slack", state: .waiting))
    }

    func testAcceptMakesItACorrection() {
        let store = makeHistory(self)
        let id = captured(store)
        store.accept(id)
        XCTAssertEqual(store.corrections.first?.correction, "I use Claude Code.")
        XCTAssertEqual(store.entries[0].capture?.state, .accepted)
        XCTAssertTrue(store.waiting.isEmpty)
    }

    func testDismissCountsForNothing() {
        let store = makeHistory(self)
        let id = captured(store)
        store.dismiss(id)
        XCTAssertEqual(store.entries[0].capture?.state, .dismissed)
        XCTAssertNil(store.entries[0].fixTarget, "not for vocabulary either")
        XCTAssertTrue(store.waiting.isEmpty)
        XCTAssertTrue(store.corrections.isEmpty)
        store.accept(id)
        XCTAssertTrue(store.corrections.isEmpty, "a dismissed capture can't be accepted later")
    }

    func testDismissingAnAutoFixClearsItsCorrection() {
        let url = makeTempURL(self)
        var entry = HistoryEntry(date: Date(), text: "cloud", duration: 1)  // as the judge leaves it
        entry.correction = "Claude"
        entry.capture = Capture(edited: "Claude", mode: .readback, app: "Slack", state: .auto)
        try? JSONFile.write([entry], to: url)
        let store = HistoryStore(fileURL: url, defaults: makeDefaults(self))
        let id = entry.id
        XCTAssertEqual(store.corrections.map(\.id), [id], "auto trains Learn")
        store.dismiss(id)
        XCTAssertNil(store.entries[0].correction)
        XCTAssertEqual(store.entries[0].capture?.state, .dismissed)
    }

    func testTypingACorrectionOnACaptureMakesItYours() {
        let store = makeHistory(self)
        let id = captured(store)
        store.setCorrection("I use Claude Code, the CLI.", for: id)
        XCTAssertEqual(store.entries[0].capture?.state, .accepted)
        XCTAssertEqual(store.entries[0].fixTarget, "I use Claude Code, the CLI.", "yours wins over the edit")
        store.setCorrection("", for: id)
        XCTAssertEqual(store.entries[0].capture?.state, .dismissed, "taking yours away: its edit doesn't feed vocabulary unseen")
        XCTAssertNil(store.entries[0].fixTarget)
    }

    /// A correction you type on a capture you dismissed is yours: it stays dismissed (no "captured").
    func testACorrectionOnADismissedCaptureIsYours() {
        let store = makeHistory(self)
        let id = captured(store)
        store.dismiss(id)
        store.setCorrection("I use cloud code.", for: id)  // the pencil starts from what the app wrote
        XCTAssertEqual(store.entries[0].capture?.state, .dismissed)
        XCTAssertEqual(store.entries[0].capture?.trains, false)
        XCTAssertEqual(store.corrections.count, 1)
    }

    func testOneCapturePerDictationAndNeverOverACorrection() {
        let store = makeHistory(self)
        let id = captured(store)
        store.setCapture(Capture(edited: "other", mode: .keystrokes, app: "Notes"), for: id)
        XCTAssertEqual(store.entries[0].capture?.edited, "I use Claude Code.")
        let corrected = store.add(text: "cloud", duration: 1)!
        store.setCorrection("Claude", for: corrected)
        store.setCapture(Capture(edited: "clod", mode: .readback, app: "Slack"), for: corrected)
        XCTAssertNil(store.entries[0].capture)
    }

    /// Kept past "Keep history" only as a correction you made or accepted; waiting, dismissed and
    /// `auto` ones go with their dictation.
    func testRetentionKeepsOnlyCorrectionsThatAreYours() throws {
        let url = makeTempURL(self), defaults = makeDefaults(self)
        let old = Date().addingTimeInterval(-10 * 86_400)
        func entry(_ text: String, correction: String? = nil, _ state: Capture.State?) -> HistoryEntry {
            var e = HistoryEntry(date: old, text: text, duration: 1)
            e.correction = correction
            e.capture = state.map { Capture(edited: text + "!", mode: .readback, app: "Slack", state: $0) }
            return e
        }
        try JSONFile.write([entry("manual", correction: "manual!", nil), entry("accepted", correction: "accepted!", .accepted),
                            entry("auto", correction: "auto!", .auto), entry("waiting", .waiting), entry("dismissed", .dismissed)], to: url)
        defaults.set(HistoryRetention.days7.rawValue, forKey: "historyRetention")
        XCTAssertEqual(HistoryStore(fileURL: url, defaults: defaults).entries.map(\.text), ["manual", "accepted"])
    }

    /// A newer build's state reads as dismissed (counts for nothing); an entry without a capture, or a
    /// file from before captures, loads as before.
    func testUnknownStatesFromANewerBuildCountForNothing() throws {
        let url = makeTempURL(self)
        try Data(#"""
        [{"id":"7F1D7C55-0000-4000-8000-000000000001","date":"2026-10-07T07:00:00Z","text":"cloud","duration":1,
          "capture":{"edited":"Claude","mode":"telepathy","app":"Slack","state":"judgedTwice"}},
         {"id":"7F1D7C55-0000-4000-8000-000000000002","date":"2026-10-07T07:00:00Z","text":"old","duration":1,
          "capture":{"mode":"readback"}}]
        """#.utf8).write(to: url)
        let entries = HistoryStore(fileURL: url, defaults: makeDefaults(self)).entries
        XCTAssertEqual(entries.count, 2, "history still loads")
        XCTAssertEqual(entries[0].capture, Capture(edited: "Claude", mode: .keystrokes, app: "Slack", state: .dismissed))
        XCTAssertNil(entries[0].fixTarget)
        XCTAssertEqual(entries[1].capture?.state, .dismissed, "no text: nothing to learn")
    }
}

