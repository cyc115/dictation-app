import AppKit
import SwiftUI
import XCTest
@testable import DictationKit

/// Drives the real views through the accessibility tree, the same way assistive tech
/// (and a user) would, and checks the app state they change.
final class SettingsUITests: XCTestCase {
    private func host(_ settings: AppSettings) -> HostedView<SettingsView> {
        let hosted = HostedView(SettingsView(settings: settings), size: NSSize(width: 640, height: 1700))
        addTeardownBlock { hosted.close() }
        return hosted
    }

    func testEverySettingIsReachable() {
        let hosted = host(AppSettings(defaults: makeDefaults(self), secrets: InMemorySecretStore()))
        for title in ["Appearance", "Launch app at login", "Show app in Dock", "Microphone",
                      "Interaction sounds", "Mute when dictating", "Hotkey", "Activation",
                      "Mouse button", "Type as you speak", "AI polish", "Model", "Language", "Keep recordings"] {
            XCTAssertNotNil(hosted.element(id: "setting." + title), "missing control: \(title)")
        }
    }

    func testTogglesChangeAndPersistSettings() {
        let defaults = makeDefaults(self)
        let settings = AppSettings(defaults: defaults, secrets: InMemorySecretStore())
        let hosted = host(settings)
        for (title, read) in [("Interaction sounds", { settings.interactionSounds }),
                              ("Mute when dictating", { settings.muteWhileDictating }),
                              ("Show app in Dock", { settings.showInDock }),
                              ("Type as you speak", { settings.streamWhileSpeaking }),
                              ("AI polish", { settings.polishEnabled }),
                              ("Keep recordings", { settings.keepRecordings })] as [(String, () -> Bool)] {
            let before = read()
            guard let toggle = hosted.element(id: "setting." + title) else { XCTFail("no \(title)"); continue }
            XCTAssertTrue(hosted.click(toggle), "\(title) not clickable")
            XCTAssertEqual(read(), !before, "\(title) did not flip")
        }
        let reloaded = AppSettings(defaults: defaults, secrets: InMemorySecretStore())
        XCTAssertFalse(reloaded.interactionSounds)
        XCTAssertTrue(reloaded.muteWhileDictating)
        XCTAssertTrue(reloaded.showInDock)
        XCTAssertTrue(reloaded.streamWhileSpeaking)
        XCTAssertTrue(reloaded.polishEnabled)
        XCTAssertTrue(reloaded.keepRecordings)
    }

    func testRecordingsFolderOnlyShownWhileKeepingRecordings() {
        let settings = AppSettings(defaults: makeDefaults(self), secrets: InMemorySecretStore())
        let hosted = host(settings)
        XCTAssertNil(hosted.element(id: "setting.Recordings folder"))
        guard let toggle = hosted.element(id: "setting.Keep recordings") else { return XCTFail("no toggle") }
        XCTAssertTrue(hosted.click(toggle))
        hosted.settle()
        XCTAssertNotNil(hosted.element(id: "setting.Recordings folder"))
    }

    func testCloudModelDisablesUnsupportedSettingsButKeepsThem() {
        let settings = AppSettings(defaults: makeDefaults(self), secrets: InMemorySecretStore())
        settings.streamWhileSpeaking = true
        settings.localLanguage = .mandarin
        let hosted = host(settings)
        func enabled(_ title: String) -> Bool? {
            guard let node = hosted.element(id: "setting." + title) else { return nil }
            return node.object.value(forKey: "accessibilityEnabled") as? Bool
        }
        XCTAssertEqual(enabled("Type as you speak"), true)
        XCTAssertEqual(enabled("Language"), true)
        XCTAssertNil(hosted.element(id: "setting.Cloud API key"), "key row only for cloud models")

        settings.setOpenRouterKey("sk-or-v1-test")
        settings.transcriptionModel = .metaMuse
        hosted.settle()
        XCTAssertEqual(enabled("Type as you speak"), false)
        XCTAssertEqual(enabled("Language"), false)
        XCTAssertNotNil(hosted.element(id: "setting.Cloud API key"))
        XCTAssertTrue(settings.streamWhileSpeaking, "state is remembered while disabled")
        XCTAssertEqual(settings.localLanguage, .mandarin)

        settings.transcriptionModel = .qwenASR
        hosted.settle()
        XCTAssertEqual(enabled("Type as you speak"), false)
        XCTAssertNotNil(hosted.element(id: "setting.Cloud API key"), "same key for every cloud model")
        XCTAssertTrue(hosted.allText.contains("Unavailable"), "unavailable rows are labeled")
        let toggle = hosted.element(id: "setting.Type as you speak")
        XCTAssertEqual(toggle?.value, "0", "unavailable toggle shows off, not the saved on-state")
        XCTAssertTrue(settings.streamWhileSpeaking)
        settings.transcriptionModel = .local
        hosted.settle()
        XCTAssertEqual(hosted.element(id: "setting.Type as you speak")?.value, "1", "saved choice comes back")
    }

    func testNoVendorOrModelNamesInSettings() {
        let settings = AppSettings(defaults: makeDefaults(self), secrets: InMemorySecretStore())
        settings.setOpenRouterKey("sk-or-v1-test")
        let hosted = host(settings)
        for model in TranscriptionModel.allCases {
            settings.transcriptionModel = model
            hosted.settle()
            let text = hosted.allText.lowercased()
            for banned in ["openrouter", "muse", "qwen", "meta", "alibaba", "sk-or"] {
                XCTAssertFalse(text.contains(banned), "\(model.title): settings mention \(banned)")
            }
        }
    }

    func testFnTipOnlyShownForFn() {
        let settings = AppSettings(defaults: makeDefaults(self), secrets: InMemorySecretStore())
        let hosted = host(settings)
        func tipShown() -> Bool { hosted.allText.contains("Press 🌐 key to") }
        XCTAssertTrue(tipShown())
        settings.hotkey = .rightCommand
        hosted.settle()
        XCTAssertFalse(tipShown())
    }
}

final class HistoryUITests: XCTestCase {
    private func makeStore() -> HistoryStore {
        let store = HistoryStore(fileURL: makeTempURL(self), defaults: makeDefaults(self))
        store.add(text: "Hello from the history page.", duration: 2)
        store.add(text: "还有一个问题，中英文混用 works too.", duration: 3)
        return store
    }

    func testRowsListedAndCopyWritesTranscript() {
        let pasteboard = makePasteboard(self)
        HistoryRow.pasteboard = pasteboard
        addTeardownBlock { HistoryRow.pasteboard = .general }

        let store = makeStore()
        let hosted = HostedView(HistoryView(store: store), size: NSSize(width: 760, height: 560))
        addTeardownBlock { hosted.close() }

        let copyButtons = hosted.elements(id: "history.copy")
        XCTAssertEqual(copyButtons.count, 2, "one copy button per entry")
        XCTAssertTrue(copyButtons.first.map(hosted.click) ?? false)
        let copied = pasteboard.string(forType: .string)
        XCTAssertTrue(store.entries.map(\.text).contains(copied ?? ""), "copied: \(copied ?? "nil")")
    }

    func testEmptyStateWhenNoHistory() {
        let store = HistoryStore(fileURL: makeTempURL(self), defaults: makeDefaults(self))
        let hosted = HostedView(HistoryView(store: store), size: NSSize(width: 760, height: 400))
        addTeardownBlock { hosted.close() }
        XCTAssertTrue(hosted.elements(id: "history.copy").isEmpty)
    }

    func testNewDictationAppearsLive() {
        let store = makeStore()
        let hosted = HostedView(HistoryView(store: store), size: NSSize(width: 760, height: 560))
        addTeardownBlock { hosted.close() }
        store.add(text: "Just dictated.", duration: 1)
        hosted.settle()
        XCTAssertEqual(hosted.elements(id: "history.copy").count, 3)
    }
}

final class InsightsUITests: XCTestCase {
    func testCardsShowFormattedTotals() {
        let insights = Insights(defaults: makeDefaults(self))
        // 19,400 words over 3h31m.
        insights.record(text: Array(repeating: "w", count: 19_400).joined(separator: " "), duration: 3 * 3600 + 31 * 60)
        let hosted = HostedView(InsightsView(insights: insights), size: NSSize(width: 600, height: 260))
        addTeardownBlock { hosted.close() }

        func text(_ caption: String) -> String {
            guard let card = hosted.element(id: "insights." + caption) else { return "<missing>" }
            return "\(card.label ?? "") \(card.value ?? "")"
        }
        XCTAssertTrue(text("Words dictated").contains("19.4K"), text("Words dictated"))
        XCTAssertTrue(text("Total dictation time").contains("3") && text("Total dictation time").contains("31"),
                      text("Total dictation time"))
        XCTAssertTrue(text("Average dictation speed").contains("\(insights.wordsPerMinute)"),
                      text("Average dictation speed"))
        XCTAssertTrue(text("Time saved").contains("hr"), text("Time saved"))
    }
}

final class OverlayUITests: XCTestCase {
    func testListeningPillAtBottomCenterWithButtons() throws {
        let overlay = OverlayWindow()
        var confirmed = 0, cancelled = 0
        overlay.onConfirm = { confirmed += 1 }
        overlay.onCancel = { cancelled += 1 }
        addTeardownBlock { overlay.hide() }

        overlay.showListening()
        spinRunLoop(0.2)
        let panel = try XCTUnwrap(overlay.panel)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(overlay.mode, .listening)
        XCTAssertEqual(panel.frame.height, OverlayWindow.height)
        XCTAssertEqual(panel.frame.width, OverlayWindow.listeningWidth)
        let screen = try XCTUnwrap(panel.screen ?? NSScreen.main)
        XCTAssertEqual(panel.frame.midX, screen.visibleFrame.midX, accuracy: 1, "centered")
        XCTAssertLessThan(panel.frame.minY - screen.visibleFrame.minY, 60, "near the bottom")
        XCTAssertFalse(panel.canBecomeKey, "must not steal focus from the app being typed into")

        let buttons = (panel.contentView?.subviews.first?.subviews ?? []).filter { $0.accessibilityRole() == .button }
        let confirm = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier() == "overlay.checkmark" })
        let cancel = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier() == "overlay.xmark" })
        XCTAssertTrue(confirm.accessibilityPerformPress())
        XCTAssertTrue(cancel.accessibilityPerformPress())
        XCTAssertEqual(confirmed, 1)
        XCTAssertEqual(cancelled, 1)
    }

    func testWaveformFollowsLevelOnlyWhileListening() {
        let overlay = OverlayWindow()
        addTeardownBlock { overlay.hide() }
        overlay.showListening()
        XCTAssertEqual(overlay.waveform.levels.max(), 0)
        overlay.setLevel(0.9)
        let afterSpeech = overlay.waveform.levels
        XCTAssertGreaterThan(afterSpeech.last ?? 0, 0.5)
        overlay.showMessage("Error")
        overlay.setLevel(0.5)
        XCTAssertEqual(overlay.waveform.levels, afterSpeech, "ignored outside listening")
    }

    func testMessageModeWidensAndHidesButtons() throws {
        let overlay = OverlayWindow()
        addTeardownBlock { overlay.hide() }
        overlay.showMessage("On-device recognition unavailable — check Dictation languages", hideAfter: 10)
        let panel = try XCTUnwrap(overlay.panel)
        XCTAssertEqual(overlay.mode, .message)
        XCTAssertGreaterThan(panel.frame.width, OverlayWindow.listeningWidth)
        XCTAssertLessThanOrEqual(panel.frame.width, 460)
        overlay.hideUnlessMessage()
        XCTAssertEqual(overlay.mode, .message, "messages survive hideUnlessMessage")
    }

    func testMicNameShownUnderWaveform() throws {
        let overlay = OverlayWindow()
        addTeardownBlock { overlay.hide() }
        overlay.showListening(micName: "MacBook Pro Microphone")
        XCTAssertFalse(overlay.micLabel.isHidden)
        XCTAssertTrue(overlay.micLabel.stringValue.hasSuffix("MacBook Pro Microphone"), overlay.micLabel.stringValue)
        XCTAssertLessThan(overlay.micLabel.frame.maxY, overlay.waveform.frame.minY + 1, "caption sits below the bars")
        XCTAssertEqual(overlay.panel?.frame.height, OverlayWindow.height, "caption doesn't grow the pill")

        overlay.showListening(micName: nil)
        XCTAssertTrue(overlay.micLabel.isHidden)
        overlay.showListening(micName: "Studio Display Microphone")
        overlay.showMessage("Error", hideAfter: 10)
        XCTAssertTrue(overlay.micLabel.isHidden, "only shown while listening")
    }

    func testFullMicNameFitsWithoutTruncation() throws {
        let overlay = OverlayWindow()
        addTeardownBlock { overlay.hide() }
        for name in ["MacBook Pro Microphone", "iPhone (53) Microphone", "HD Pro Webcam C920", "Steam Streaming Microphone"] {
            overlay.showListening(micName: name)
            let needed = overlay.micLabel.attributedStringValue.size().width
            XCTAssertTrue(overlay.micLabel.stringValue.hasSuffix(name), "full name shown: \(overlay.micLabel.stringValue)")
            XCTAssertGreaterThanOrEqual(overlay.micLabel.frame.width, needed, "\(name) is truncated")
            let panel = try XCTUnwrap(overlay.panel)
            XCTAssertEqual(panel.frame.width, overlay.micLabel.frame.maxX + overlay.micLabel.frame.minX, accuracy: 1,
                           "caption is centered in the pill")
        }
        overlay.showListening(micName: "Mic")
        XCTAssertEqual(overlay.panel?.frame.width, OverlayWindow.listeningWidth, "short names keep the compact pill")
        overlay.showListening(micName: String(repeating: "Very Long Device Name ", count: 6))
        XCTAssertEqual(overlay.panel?.frame.width, OverlayWindow.maxListeningWidth, "absurd names are capped")
    }

    func testHideFadesOut() throws {
        let overlay = OverlayWindow()
        overlay.showListening()
        overlay.hide()
        XCTAssertEqual(overlay.mode, .hidden)
        spinRunLoop(0.4)
        XCTAssertFalse(try XCTUnwrap(overlay.panel).isVisible)
    }

    func testMessageAutoHides() {
        let overlay = OverlayWindow()
        overlay.showMessage("Polishing failed", hideAfter: 0.1)
        spinRunLoop(0.5)
        XCTAssertEqual(overlay.mode, .hidden)
    }
}

/// Visual regression: renders views with fixed data and compares to reference PNGs.
/// After an intentional UI change: RECORD_SNAPSHOTS=1 swift test --filter SnapshotTests
final class SnapshotTests: XCTestCase {
    func testOverlayListening() throws {
        let overlay = OverlayWindow()
        addTeardownBlock { overlay.hide() }
        overlay.showListening(micName: "MacBook Pro Microphone")
        for level in [0.1, 0.3, 0.7, 0.9, 0.6, 0.4, 0.8, 0.5, 0.2, 0.6, 0.9, 0.3, 0.1] as [Float] {
            overlay.setLevel(level)
        }
        let view = try XCTUnwrap(overlay.panel?.contentView)
        assertSnapshot(of: view, named: "overlay-listening")
    }

    /// Typical laptop/desk-mic speech (≈ −40 dBFS). This used to render as a nearly flat row.
    func testOverlayListeningQuietSpeech() throws {
        let overlay = OverlayWindow()
        addTeardownBlock { overlay.hide() }
        overlay.showListening(micName: "External Microphone")
        for i in 0..<40 { overlay.setLevel(0.25 * [1.0, 0.6, 1.2, 0.3, 0.9, 1.1, 0.2, 0.8][i % 8]) }
        assertSnapshot(of: try XCTUnwrap(overlay.panel?.contentView), named: "overlay-listening-quiet")
    }

    func testOverlayListeningLongMicName() throws {
        let overlay = OverlayWindow()
        addTeardownBlock { overlay.hide() }
        overlay.showListening(micName: "Steam Streaming Microphone")
        for level in [0.2, 0.5, 0.8, 0.6, 0.9, 0.4, 0.7, 0.3] as [Float] { overlay.setLevel(level) }
        assertSnapshot(of: try XCTUnwrap(overlay.panel?.contentView), named: "overlay-listening-long-mic")
    }

    func testOverlayMessage() throws {
        let overlay = OverlayWindow()
        addTeardownBlock { overlay.hide() }
        overlay.showMessage("Speech recognizer unavailable", hideAfter: 10)
        assertSnapshot(of: try XCTUnwrap(overlay.panel?.contentView), named: "overlay-message")
    }

    func testInsights() {
        let insights = Insights(defaults: makeDefaults(self))
        insights.record(text: Array(repeating: "w", count: 19_400).joined(separator: " "), duration: 3 * 3600 + 31 * 60)
        let hosted = HostedView(InsightsView(insights: insights).padding(20), size: NSSize(width: 620, height: 240))
        addTeardownBlock { hosted.close() }
        assertSnapshot(of: hosted.hostingView, named: "insights")
    }

    func testHistory() {
        let url = makeTempURL(self)
        let entries = [
            HistoryEntry(date: fixedDate(2026, 1, 6, 9, 41), text: "Ship the history page with a copy button on every row.", duration: 4),
            HistoryEntry(date: fixedDate(2026, 1, 6, 9, 15), text: "还有一个问题，中英文混用 should still look right.", duration: 3),
            HistoryEntry(date: fixedDate(2026, 1, 5, 18, 2), text: "Short one.", duration: 1),
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(entries).write(to: url)
        let store = HistoryStore(fileURL: url, defaults: makeDefaults(self))
        let hosted = HostedView(HistoryView(store: store), size: NSSize(width: 760, height: 520))
        addTeardownBlock { hosted.close() }
        assertSnapshot(of: hosted.hostingView, named: "history")
    }
}
