import AppKit
import AVFoundation
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
        let store = HistoryStore(fileURL: makeTempURL(self), defaults: makeDefaults(self))
        store.add(text: "a", duration: 1); store.add(text: "b", duration: 1); store.add(text: "c", duration: 1)
        store.delete(store.entries[1])
        XCTAssertEqual(store.entries.map(\.text), ["c", "a"])
        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testEmptyTextIgnored() {
        let store = HistoryStore(fileURL: makeTempURL(self), defaults: makeDefaults(self))
        store.add(text: "", duration: 1)
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testRetentionOffKeepsNothing() {
        let store = HistoryStore(fileURL: makeTempURL(self), defaults: makeDefaults(self))
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
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([recent, old]).write(to: url)
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
        XCTAssertNil(entry.raw); XCTAssertNil(entry.setup); XCTAssertNil(entry.correction)
        XCTAssertEqual(entry.input, "old", "no raw: the text stands in for it")
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

    func testRetentionNeverPrunesCorrections() throws {
        let url = makeTempURL(self), defaults = makeDefaults(self)
        var old = HistoryEntry(date: Date().addingTimeInterval(-10 * 86_400), text: "old", duration: 1)
        old.correction = "old, fixed"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([old]).write(to: url)
        defaults.set(HistoryRetention.days7.rawValue, forKey: "historyRetention")
        XCTAssertEqual(HistoryStore(fileURL: url, defaults: defaults).entries.map(\.text), ["old"])
    }

    func testCorruptFileStartsEmpty() throws {
        let url = makeTempURL(self)
        try Data("not json".utf8).write(to: url)
        let store = HistoryStore(fileURL: url, defaults: makeDefaults(self))
        XCTAssertTrue(store.entries.isEmpty)
    }
}

final class SettingsTests: XCTestCase {
    func testDefaults() {
        let s = AppSettings(defaults: makeDefaults(self), secrets: InMemorySecretStore(), customSetupsFile: noCustomSetups)
        XCTAssertEqual(s.hotkey, .fn)
        XCTAssertEqual(s.mode, .hold)
        XCTAssertEqual(s.mouseButton, .off)
        XCTAssertFalse(s.polishEnabled)
        XCTAssertEqual(s.microphoneUID, "")
        XCTAssertTrue(s.interactionSounds, "sounds default on")
        XCTAssertFalse(s.muteWhileDictating)
        XCTAssertEqual(s.appearance, .system)
        XCTAssertFalse(s.showInDock)
        XCTAssertFalse(s.streamWhileSpeaking, "type-as-you-speak is off by default")
    }

    func testChangesPersistAndNotify() {
        let defaults = makeDefaults(self)
        let s = AppSettings(defaults: defaults, secrets: InMemorySecretStore(), customSetupsFile: noCustomSetups)
        var changes = 0
        s.onChange = { changes += 1 }
        s.hotkey = .rightOption
        s.mode = .toggle
        s.mouseButton = .button4
        s.polishEnabled = true
        s.microphoneUID = "mic-1"
        s.interactionSounds = false
        s.muteWhileDictating = true
        s.appearance = .dark
        s.showInDock = true
        s.streamWhileSpeaking = true
        XCTAssertEqual(changes, 10)

        let r = AppSettings(defaults: defaults, secrets: InMemorySecretStore(), customSetupsFile: noCustomSetups)
        XCTAssertEqual(r.hotkey, .rightOption)
        XCTAssertEqual(r.mode, .toggle)
        XCTAssertEqual(r.mouseButton, .button4)
        XCTAssertTrue(r.polishEnabled)
        XCTAssertEqual(r.microphoneUID, "mic-1")
        XCTAssertFalse(r.interactionSounds)
        XCTAssertTrue(r.muteWhileDictating)
        XCTAssertEqual(r.appearance, .dark)
        XCTAssertTrue(r.showInDock)
        XCTAssertTrue(r.streamWhileSpeaking)
    }

    func testHint() {
        let s = AppSettings(defaults: makeDefaults(self), secrets: InMemorySecretStore(), customSetupsFile: noCustomSetups)
        XCTAssertEqual(s.hint, "Hold Fn to dictate — release to paste")
        s.hotkey = .rightShift
        s.mode = .toggle
        XCTAssertEqual(s.hint, "Tap Right ⇧ to start — tap again to paste")
    }

    func testUnknownStoredValuesFallBack() {
        let defaults = makeDefaults(self)
        defaults.set("bogus", forKey: "hotkey")
        defaults.set("bogus", forKey: "activationMode")
        let s = AppSettings(defaults: defaults, secrets: InMemorySecretStore(), customSetupsFile: noCustomSetups)
        XCTAssertEqual(s.hotkey, .fn)
        XCTAssertEqual(s.mode, .hold)
    }
}

final class TextInjectorTests: XCTestCase {
    func testPastesTextThenRestoresOriginalClipboardWithAllTypes() {
        let pasteboard = makePasteboard(self)
        let custom = NSPasteboard.PasteboardType("com.example.custom")
        let item = NSPasteboardItem()
        item.setString("original", forType: .string)
        item.setData(Data([1, 2, 3]), forType: custom)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])

        let injector = TextInjector()
        injector.pasteboard = pasteboard
        injector.restoreDelay = 0.05
        injector.canPaste = { true }
        var seenAtPaste: String?
        injector.paste = { seenAtPaste = pasteboard.string(forType: .string) }

        injector.inject("dictated text")
        XCTAssertEqual(seenAtPaste, "dictated text")
        spinRunLoop(0.2)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
        XCTAssertEqual(pasteboard.data(forType: custom), Data([1, 2, 3]))
    }

    func testDoesNothingWithoutAccessibility() {
        let pasteboard = makePasteboard(self)
        pasteboard.clearContents()
        pasteboard.setString("untouched", forType: .string)
        let injector = TextInjector()
        injector.pasteboard = pasteboard
        injector.canPaste = { false }
        var pasted = false
        injector.paste = { pasted = true }
        injector.inject("x")
        XCTAssertFalse(pasted)
        XCTAssertEqual(pasteboard.string(forType: .string), "untouched")
    }
}

final class AudioLevelTests: XCTestCase {
    static func buffer(amplitude: Float, frames: Int = 1024) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let samples = buffer.floatChannelData![0]
        for i in 0..<frames { samples[i] = amplitude * sin(Float(i) * 2 * .pi * 440 / 48_000) }
        return buffer
    }

    func testSilenceIsZero() {
        XCTAssertEqual(SpeechEngine.level(of: Self.buffer(amplitude: 0)), 0)
    }

    func testLoudSpeechIsFull() {
        XCTAssertEqual(SpeechEngine.level(of: Self.buffer(amplitude: 0.5)), 1)
    }

    func testQuietSpeechIsLowButVisible() {
        let level = SpeechEngine.level(of: Self.buffer(amplitude: 0.01))  // ≈ -43 dBFS
        XCTAssertGreaterThan(level, 0.1)
        XCTAssertLessThan(level, 0.3)
    }

    func testLevelRisesWithVolume() {
        let levels = [0.003, 0.01, 0.03, 0.1].map { SpeechEngine.level(of: Self.buffer(amplitude: Float($0))) }
        XCTAssertEqual(levels, levels.sorted())
        XCTAssertEqual(Set(levels).count, levels.count)
    }
}

final class AppVersionTests: XCTestCase {
    func testReadsStampedInfo() {
        let v = AppVersion(info: ["CFBundleShortVersionString": "1.0.25", "CFBundleVersion": "525e456",
                                  "DictationBuildDate": "2026-10-07T06:05:00Z"])
        XCTAssertEqual(v.version, "1.0.25")
        XCTAssertEqual(v.short, "Version 1.0.25 (525e456)")
        XCTAssertNotNil(v.built)
        XCTAssertTrue(v.long.hasPrefix("Version 1.0.25 (525e456) · built "), v.long)
    }

    func testUnstampedBuildSaysDev() {
        let v = AppVersion(info: [:])
        XCTAssertEqual(v.short, "Version dev (-)")
        XCTAssertEqual(v.long, v.short)
    }
}
