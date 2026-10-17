import AppKit
import SwiftUI
import XCTest
@testable import DictationKit

/// Drives the real views through the accessibility tree, the same way assistive tech
/// (and a user) would, and checks the app state they change.
final class SettingsUITests: XCTestCase {
    private func host(_ settings: AppSettings, history: HistoryStore? = nil) -> HostedView<SettingsView> {
        let history = history ?? HistoryStore(fileURL: makeTempURL(self), defaults: makeDefaults(self))
        let hosted = HostedView(SettingsView(settings: settings, history: history), size: NSSize(width: 640, height: 1900))
        addTeardownBlock { hosted.close() }
        return hosted
    }

    func testEverySettingIsReachable() {
        let hosted = host(makeSettings(self))
        for title in ["Appearance", "Launch app at login", "Show app in Dock", "Microphone",
                      "Interaction sounds", "Mute when dictating", "Hotkey", "Activation",
                      "Mouse button", "Type as you speak", "AI polish", "Model", "Language", "Keep history", "Keep recordings",
                      "Backup model when slow", "Pause in these apps",
                      "Mouse button for Enter", "Enter button"] {
            XCTAssertNotNil(hosted.element(id: "setting." + title), "missing control: \(title)")
        }
    }

    func testTogglesChangeAndPersistSettings() {
        let defaults = makeDefaults(self)
        let settings = makeSettings(self, defaults: defaults)
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
        let reloaded = makeSettings(self, defaults: defaults)
        XCTAssertFalse(reloaded.interactionSounds)
        XCTAssertTrue(reloaded.muteWhileDictating)
        XCTAssertTrue(reloaded.showInDock)
        XCTAssertTrue(reloaded.streamWhileSpeaking)
        XCTAssertTrue(reloaded.polishEnabled)
        XCTAssertTrue(reloaded.keepRecordings)
    }

    func testRecordingsFolderOnlyShownWhileKeepingRecordings() {
        let settings = makeSettings(self)
        let hosted = host(settings)
        XCTAssertNil(hosted.element(id: "setting.Recordings folder"))
        guard let toggle = hosted.element(id: "setting.Keep recordings") else { return XCTFail("no toggle") }
        XCTAssertTrue(hosted.click(toggle))
        hosted.settle()
        XCTAssertNotNil(hosted.element(id: "setting.Recordings folder"))
    }

    func testKeepHistoryLivesInSettings() {
        let defaults = makeDefaults(self)
        let history = HistoryStore(fileURL: makeTempURL(self), defaults: defaults)
        let hosted = host(makeSettings(self), history: history)
        XCTAssertNotNil(hosted.element(id: "setting.Keep history"))
        history.retention = .days30
        hosted.settle()
        XCTAssertEqual(HistoryStore(fileURL: makeTempURL(self), defaults: defaults).retention, .days30, "remembered")
    }

    func testBackupModelForCloudModelsOnByDefaultAndPersists() {
        let defaults = makeDefaults(self)
        let settings = makeSettings(self, defaults: defaults)
        XCTAssertTrue(settings.backupWhenSlow, "on by default")
        let hosted = host(settings)
        let id = "setting.Backup model when slow"
        XCTAssertEqual(hosted.element(id: id)?.object.value(forKey: "accessibilityEnabled") as? Bool, false,
                       "On-device has no backup")

        settings.setOpenRouterKey("sk-or-v1-test")
        settings.setup = .cloudFlash
        hosted.settle()
        XCTAssertTrue(settings.effectiveBackup)
        guard let toggle = hosted.element(id: id) else { return XCTFail("no toggle") }
        XCTAssertTrue(hosted.click(toggle))
        XCTAssertFalse(settings.backupWhenSlow)
        XCTAssertFalse(makeSettings(self, defaults: defaults).backupWhenSlow,
                       "turning it off is remembered")
        XCTAssertTrue(hosted.click(toggle))

        settings.setup = .cloudBig
        hosted.settle()
        XCTAssertTrue(settings.effectiveBackup, "Cloud Big falls back to Cloud Flash")
        XCTAssertEqual(hosted.element(id: id)?.object.value(forKey: "accessibilityEnabled") as? Bool, true)

        settings.setup = .onDevice
        hosted.settle()
        XCTAssertFalse(settings.effectiveBackup)
        XCTAssertEqual(hosted.element(id: id)?.value, "0", "unavailable toggle shows off")
        XCTAssertTrue(settings.backupWhenSlow, "the saved choice is kept")
    }

    func testPolishRunsWhereTheSpeechModelRuns() {
        let settings = makeSettings(self)
        settings.polishEnabled = true
        let hosted = host(settings)
        XCTAssertTrue(settings.setup.polishesOnDevice, "On-device speech: nothing leaves the Mac")
        XCTAssertTrue(hosted.allText.contains("nothing leaves it"))
        settings.setOpenRouterKey("sk-or-v1-test")
        for model in [DictationSetup.cloudFlash, .cloudBig] {
            settings.setup = model
            hosted.settle()
            XCTAssertFalse(settings.setup.polishesOnDevice, model.title)
            XCTAssertTrue(hosted.allText.contains("with a cloud model"), model.title)
        }
        XCTAssertNil(hosted.element(id: "setting.Polish model"), "no separate choice: it follows the speech model")
    }

    func testCloudModelDisablesUnsupportedSettingsButKeepsThem() {
        let settings = makeSettings(self)
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
        settings.setup = .cloudBig
        hosted.settle()
        XCTAssertEqual(enabled("Type as you speak"), false)
        XCTAssertEqual(enabled("Language"), false)
        XCTAssertNotNil(hosted.element(id: "setting.Cloud API key"))
        XCTAssertTrue(settings.streamWhileSpeaking, "state is remembered while disabled")
        XCTAssertEqual(settings.localLanguage, .mandarin)

        settings.setup = .cloudFlash
        hosted.settle()
        XCTAssertEqual(enabled("Type as you speak"), false)
        XCTAssertNotNil(hosted.element(id: "setting.Cloud API key"), "same key for every cloud model")
        XCTAssertTrue(hosted.allText.contains("Unavailable"), "unavailable rows are labeled")
        let toggle = hosted.element(id: "setting.Type as you speak")
        XCTAssertEqual(toggle?.value, "0", "unavailable toggle shows off, not the saved on-state")
        XCTAssertTrue(settings.streamWhileSpeaking)
        settings.setup = .onDevice
        hosted.settle()
        XCTAssertEqual(hosted.element(id: "setting.Type as you speak")?.value, "1", "saved choice comes back")
    }

    func testNoVendorOrModelNamesInSettings() {
        let settings = makeSettings(self)
        settings.setOpenRouterKey("sk-or-v1-test")
        let hosted = host(settings)
        for model in DictationSetup.builtIns {
            settings.setup = model
            hosted.settle()
            let text = hosted.allText.lowercased()
            for banned in ["openrouter", "muse", "qwen", "meta", "alibaba", "sk-or"] {
                XCTAssertFalse(text.contains(banned), "\(model.title): settings mention \(banned)")
            }
        }
    }

    func testEnterButtonGreyedOutWhileMouseEnterIsOff() {
        let settings = makeSettings(self)
        let hosted = host(settings)
        func enabled() -> Bool? {
            hosted.element(id: "setting.Enter button")?.object.value(forKey: "accessibilityEnabled") as? Bool
        }
        XCTAssertEqual(enabled(), true)
        XCTAssertTrue(hosted.element(id: "setting.Mouse button for Enter").map { hosted.click($0) } ?? false)
        XCTAssertFalse(settings.mouseEnterEnabled)
        XCTAssertEqual(enabled(), false)
    }

    func testExcludedAppsListedAndRemovable() {
        let settings = makeSettings(self)
        settings.exclude(ExcludedApp(bundleID: "com.example.game", name: "Some Game"))
        let hosted = host(settings)
        XCTAssertTrue(hosted.allText.contains("Some Game"))
        let remove = try? XCTUnwrap(hosted.element(id: "excluded.remove.com.example.game"))
        XCTAssertTrue(remove.map { hosted.click($0) } ?? false)
        XCTAssertEqual(settings.excludedApps, [])
        XCTAssertFalse(hosted.allText.contains("Some Game"))
    }

    func testFnTipOnlyShownForFn() {
        let settings = makeSettings(self)
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
        XCTAssertEqual(hosted.element(id: "history.empty").flatMap { $0.label ?? $0.value }?.hasPrefix("No dictations yet"), true)
    }

    func testEmptyStateSaysWhereToTurnHistoryBackOn() {
        let store = HistoryStore(fileURL: makeTempURL(self), defaults: makeDefaults(self))
        store.retention = .off
        let hosted = HostedView(HistoryView(store: store), size: NSSize(width: 760, height: 400))
        addTeardownBlock { hosted.close() }
        XCTAssertEqual(hosted.element(id: "history.empty").flatMap { $0.label ?? $0.value }?.contains("Settings"), true)
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

final class CorrectionsUITests: XCTestCase {
    func testPencilMakesACorrectionAndOpensIt() {
        let store = HistoryStore(fileURL: makeTempURL(self), defaults: makeDefaults(self))
        store.add(text: "Can you install Cloud Code?", duration: 2)
        var opened: UUID?
        let hosted = HostedView(HistoryView(store: store, onCorrect: { opened = $0 }), size: NSSize(width: 760, height: 400))
        addTeardownBlock { hosted.close() }
        let pencil = hosted.element(id: "history.correct")
        XCTAssertEqual(pencil?.label, "Correct this dictation")
        XCTAssertTrue(pencil.map(hosted.click) ?? false)
        XCTAssertEqual(opened, store.entries[0].id)
        XCTAssertEqual(store.corrections.first?.correction, "Can you install Cloud Code?", "starts as what the app wrote")
        XCTAssertEqual(hosted.element(id: "history.correct")?.label, "Open correction")

        hosted.click(hosted.element(id: "history.correct")!)
        XCTAssertEqual(store.corrections.count, 1, "opening it again doesn't make another")
    }

    func testCardsShowBothSidesAndTypingSaves() throws {
        let store = HistoryStore(fileURL: makeTempURL(self), defaults: makeDefaults(self))
        store.add(text: "Can you install Cloud Code?", duration: 2, raw: "can you install cloud code", setup: "cloud-flash", prompt: "v3")
        store.add(text: "Not corrected.", duration: 1)
        let id = store.entries[1].id
        store.setCorrection("Can you install Claude Code?", for: id)
        let hosted = HostedView(CorrectionsView(store: store, editing: id), size: NSSize(width: 760, height: 480))
        addTeardownBlock { hosted.close() }

        XCTAssertEqual(hosted.elements(id: "corrections.card").count, 1, "only corrected dictations")
        XCTAssertTrue(hosted.allText.contains("Cloud Flash · prompt v3"), hosted.allText)
        XCTAssertTrue(hosted.allText.contains("Before polish"))
        let editor = try XCTUnwrap(hosted.element(id: "corrections.wanted"))
        hosted.click(editor)
        let field = try XCTUnwrap(hosted.window.firstResponder as? NSTextView, "the editor has the cursor")
        field.moveToEndOfDocument(nil)
        field.insertText(" Thanks.", replacementRange: field.selectedRange())
        hosted.settle()
        XCTAssertEqual(store.corrections.first?.correction, "Can you install Claude Code? Thanks.")

        hosted.click(try XCTUnwrap(hosted.element(id: "corrections.delete")))
        hosted.window.makeFirstResponder(nil)
        hosted.settle()
        XCTAssertTrue(store.corrections.isEmpty)
        XCTAssertNotNil(hosted.element(id: "corrections.empty"))
    }

    func testChangedWordsAreFound() {
        func changed(_ old: String, _ new: String) -> [String] { WordDiff.changed(from: old, to: new).map { String(old[$0]) } }
        XCTAssertEqual(changed("Can you install Cloud Code?", "Can you install Claude Code?"), ["Cloud"])
        XCTAssertEqual(changed("No, I. So I want the app.", "I want the app."), ["No,", "I.", "So"])
        XCTAssertEqual(changed("那你让我看干什么？", "那你想让我看什么？"), ["干"])
        XCTAssertEqual(changed("Same text.", "Same text."), [])
    }

    func testPencilPrefillsACloudPolishOfWhatYouSaid() {
        let store = HistoryStore(fileURL: makeTempURL(self), defaults: makeDefaults(self))
        store.add(text: "Can you install Cloud Code?", duration: 2, raw: "can you install cloud code", setup: "cloud-flash", prompt: "v3")
        let log = EventLog()
        let polish = FakePolish(delay: 0.5, output: "Can you install Claude Code?", log: log)
        let suggester = CorrectionSuggester { polish }
        let hosted = HostedView(HistoryView(store: store, suggester: suggester), size: NSSize(width: 760, height: 400))
        addTeardownBlock { hosted.close() }
        hosted.click(hosted.element(id: "history.correct")!)
        XCTAssertEqual(store.entries[0].correction, "Can you install Cloud Code?", "the app's text until the model answers")
        XCTAssertEqual(suggester.pending, [store.entries[0].id])
        waitUntil { suggester.pending.isEmpty }
        XCTAssertEqual(store.entries[0].correction, "Can you install Claude Code?")
        XCTAssertEqual(store.entries[0].text, "Can you install Cloud Code?", "left side is still what the app wrote")

        hosted.click(hosted.element(id: "history.correct")!)
        spinRunLoop(0.1)
        XCTAssertEqual(log.events.filter { $0 == "polish" }.count, 1, "opening an existing correction doesn't ask again")
    }

    func testSuggestionUsesTheChosenSetupsPrompt() throws {
        let model = try XCTUnwrap(CorrectionSuggester.backend(apiKey: "k", setup: .cloudBig) as? OpenRouterPolish)
        XCTAssertEqual(model.model, "openai/gpt-6.1-sol-pro")
        XCTAssertEqual(model.instructions, DictationSetup.cloudBig.promptText)
        XCTAssertEqual(model.wrap, DictationSetup.cloudBig.wrap)
        XCTAssertNil(CorrectionSuggester.backend(apiKey: "", setup: .cloudFlash), "no key, no suggestion")
    }

    func testSuggestionDoesNotOverwriteWhatYouTyped() {
        let store = HistoryStore(fileURL: makeTempURL(self), defaults: makeDefaults(self))
        store.add(text: "Cloud Code", duration: 1)
        let suggester = CorrectionSuggester { FakePolish(delay: 0.2, output: "Claude Code") }
        store.setCorrection("Cloud Code", for: store.entries[0].id)
        suggester.suggest(for: store.entries[0], in: store)
        store.setCorrection("Claude Code, the CLI", for: store.entries[0].id)
        waitUntil { suggester.pending.isEmpty }
        XCTAssertEqual(store.entries[0].correction, "Claude Code, the CLI")
    }

    func testSuggestionFailureKeepsTheAppsTextAndSaysWhy() {
        let store = HistoryStore(fileURL: makeTempURL(self), defaults: makeDefaults(self))
        store.add(text: "Cloud Code", duration: 1)
        let suggester = CorrectionSuggester { FakePolish(error: .failed("No credits.")) }
        store.setCorrection("Cloud Code", for: store.entries[0].id)
        suggester.suggest(for: store.entries[0], in: store)
        waitUntil { suggester.pending.isEmpty }
        XCTAssertEqual(store.entries[0].correction, "Cloud Code")
        XCTAssertEqual(suggester.failed[store.entries[0].id], "No credits.")

        let noKey = CorrectionSuggester { nil }
        noKey.suggest(for: store.entries[0], in: store)
        XCTAssertTrue(noKey.pending.isEmpty, "no API key: nothing asked")
    }

    func testClearAllSaysCorrectionsGoToo() {
        XCTAssertEqual(HistoryView.clearTitle(corrections: 0), "Delete all dictation history?")
        XCTAssertEqual(HistoryView.clearTitle(corrections: 1), "Delete all dictation history, including 1 correction?")
        XCTAssertEqual(HistoryView.clearTitle(corrections: 3), "Delete all dictation history, including 3 corrections?")
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
        XCTAssertEqual(overlay.pillFrame.height, OverlayWindow.height)
        XCTAssertEqual(overlay.pillFrame.width, OverlayWindow.listeningWidth)
        let screen = try XCTUnwrap(panel.screen ?? NSScreen.main)
        XCTAssertEqual(overlay.pillFrame.midX, screen.visibleFrame.midX, accuracy: 1, "centered")
        XCTAssertLessThan(overlay.pillFrame.minY - screen.visibleFrame.minY, 60, "near the bottom")
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
        XCTAssertNotNil(overlay.panel)
        XCTAssertEqual(overlay.mode, .message)
        XCTAssertGreaterThan(overlay.pillFrame.width, OverlayWindow.listeningWidth)
        XCTAssertLessThanOrEqual(overlay.pillFrame.width, 460)
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
        XCTAssertEqual(overlay.pillFrame.height, OverlayWindow.height, "caption doesn't grow the pill")

        overlay.showListening(micName: nil)
        XCTAssertTrue(overlay.micLabel.isHidden)
        overlay.showListening(micName: "Studio Display Microphone")
        overlay.showMessage("Error", hideAfter: 10)
        XCTAssertTrue(overlay.micLabel.isHidden, "only shown while listening")
    }

    /// A Bluetooth mic: the pill says it's starting, with ✓ dimmed, until the first real audio.
    func testSlowMicShowsStartingUntilLive() throws {
        let overlay = OverlayWindow()
        addTeardownBlock { overlay.hide() }
        var clock: TimeInterval = 100
        overlay.now = { clock }
        overlay.reduceMotion = { false }
        overlay.showListening(micName: "Mike’s Pixel Buds Pro", warmingUp: true)
        XCTAssertTrue(overlay.isWarmingUp)
        XCTAssertEqual(overlay.micLabel.stringValue.hasSuffix("Starting Mike’s Pixel Buds Pro…"), true, overlay.micLabel.stringValue)
        XCTAssertEqual(overlay.micLabel.accessibilityLabel(), "Microphone starting: Mike’s Pixel Buds Pro")
        XCTAssertEqual(overlay.confirmButton.emphasis, 0.3, accuracy: 0.001)
        let width = overlay.pillFrame.width

        clock += 0.9
        overlay.micLive()
        XCTAssertFalse(overlay.isWarmingUp)
        XCTAssertTrue(overlay.micLabel.stringValue.hasSuffix("Mike’s Pixel Buds Pro"))
        XCTAssertFalse(overlay.micLabel.stringValue.contains("Starting"))
        XCTAssertEqual(overlay.pillFrame.width, width, "one width from start to live")
        clock += 0.1
        overlay.tick()
        XCTAssertLessThan(overlay.confirmButton.emphasis, 1, "✓ still brightening")
        XCTAssertEqual(overlay.panel?.hasShadow, false, "the green glow stands in for the shadow")

        clock += PillLook.glowDuration
        overlay.tick()
        XCTAssertEqual(overlay.confirmButton.emphasis, 1)
        XCTAssertEqual(overlay.micLabel.alphaValue, 1)
        XCTAssertEqual(overlay.panel?.hasShadow, true, "plain listening pill again")
        overlay.setLevel(0.9)
        XCTAssertGreaterThan(overlay.waveform.levels.last ?? 0, 0.5, "bars follow the mic")
    }

    /// Stop: the listening pill narrows into the processing one instead of jumping to it.
    func testStopNarrowsIntoTheProcessingPill() throws {
        let overlay = OverlayWindow()
        addTeardownBlock { overlay.hide() }
        var clock: TimeInterval = 0
        overlay.now = { clock }
        overlay.showListening(micName: "MacBook Pro Microphone")
        for level in [0.4, 0.8, 0.6] as [Float] { overlay.setLevel(level) }
        let wide = overlay.pillFrame
        overlay.showProcessing()
        XCTAssertEqual(overlay.mode, .processing)
        XCTAssertTrue(overlay.isNarrowing)

        clock = 0.23
        overlay.tick()
        let pill = try XCTUnwrap(overlay.panel?.contentView?.subviews.first)
        XCTAssertLessThan(pill.frame.width, wide.width)
        XCTAssertGreaterThan(pill.frame.width, OverlayWindow.processingWidth)
        XCTAssertEqual(pill.frame.midX, overlay.panel!.contentView!.bounds.midX, accuracy: 0.5, "narrows toward its center")
        XCTAssertEqual(overlay.confirmButton.alphaValue, 0, accuracy: 0.01)

        clock = PillLook.narrowDuration
        overlay.tick()
        XCTAssertFalse(overlay.isNarrowing)
        XCTAssertEqual(overlay.pillFrame.width, OverlayWindow.processingWidth)
        XCTAssertEqual(overlay.pillFrame.midX, wide.midX, accuracy: 1, "ends where it narrowed to")
        XCTAssertTrue(overlay.confirmButton.isHidden)
    }

    func testProcessingFromHiddenAppearsAtOnce() {
        let overlay = OverlayWindow()
        addTeardownBlock { overlay.hide() }
        overlay.showProcessing()
        XCTAssertFalse(overlay.isNarrowing)
        XCTAssertEqual(overlay.pillFrame.width, OverlayWindow.processingWidth)
    }

    func testMessageDuringNarrowingWins() {
        let overlay = OverlayWindow()
        addTeardownBlock { overlay.hide() }
        overlay.showListening(micName: "MacBook Pro Microphone")
        overlay.showProcessing()
        overlay.showMessage("Couldn't reach the cloud model", hideAfter: 10)
        XCTAssertFalse(overlay.isNarrowing)
        XCTAssertEqual(overlay.mode, .message)
        XCTAssertFalse(overlay.label.isHidden)
    }

    func testFastMicSkipsTheWait() {
        let overlay = OverlayWindow()
        addTeardownBlock { overlay.hide() }
        overlay.showListening(micName: "MacBook Pro Microphone")
        XCTAssertFalse(overlay.isWarmingUp)
        overlay.micLive()  // every mic reports live; only a waiting pill reacts
        XCTAssertEqual(overlay.panel?.hasShadow, true)
        XCTAssertEqual(overlay.confirmButton.emphasis, 1)
    }

    /// Intelligent mic selection moved to a better mic: its name, a yellow flash, the wait over.
    func testSwitchedMicFlashesYellowWithItsName() throws {
        let overlay = OverlayWindow()
        addTeardownBlock { overlay.hide() }
        var clock: TimeInterval = 0
        overlay.now = { clock }
        overlay.showListening(micName: "Mike’s Pixel Buds Pro", warmingUp: true)
        overlay.micSilent()
        clock = 1.2
        overlay.micSwitched(to: "Logitech BRIO")
        XCTAssertFalse(overlay.isWarmingUp)
        XCTAssertFalse(overlay.isShowingNoAudio, "the switch ends the red glow")
        XCTAssertTrue(overlay.micLabel.stringValue.hasSuffix("Logitech BRIO"), overlay.micLabel.stringValue)
        let pill = try XCTUnwrap(overlay.panel?.contentView?.subviews.first)
        clock = 1.3
        overlay.tick()
        let yellow = try XCTUnwrap(pill.shadow?.shadowColor?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(yellow.redComponent, 0.9)
        XCTAssertGreaterThan(yellow.greenComponent, 0.7)
        XCTAssertLessThan(yellow.blueComponent, 0.1)
        clock = 1.2 + PillLook.glowDuration
        overlay.tick()
        XCTAssertNil(pill.shadow, "then the plain pill")
    }

    /// No audio 3 s in: a red glow fades in, and stays until audio arrives.
    func testNoAudioGlowsRedUntilLive() throws {
        let overlay = OverlayWindow()
        addTeardownBlock { overlay.hide() }
        var clock: TimeInterval = 0
        overlay.now = { clock }
        overlay.showListening(micName: "USB Mic")
        overlay.micSilent()
        let pill = try XCTUnwrap(overlay.panel?.contentView?.subviews.first)
        clock = 0.3
        overlay.tick()
        let early = try XCTUnwrap(pill.shadow?.shadowColor?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(early.redComponent, 0.9)
        XCTAssertLessThan(early.greenComponent, 0.3)
        clock = 10
        overlay.tick()
        let late = try XCTUnwrap(pill.shadow?.shadowColor)
        XCTAssertGreaterThan(late.alphaComponent, early.alphaComponent, "fades in")
        XCTAssertEqual(overlay.panel?.hasShadow, false)
        overlay.micLive()
        XCTAssertFalse(overlay.isShowingNoAudio)
        XCTAssertNil(pill.shadow)
        XCTAssertEqual(overlay.panel?.hasShadow, true)
    }

    func testOtherModesEndTheWait() {
        let overlay = OverlayWindow()
        addTeardownBlock { overlay.hide() }
        overlay.showListening(micName: "Mike’s Pixel Buds Pro", warmingUp: true)
        overlay.showMessage("The microphone sent only silence.", hideAfter: 10)
        XCTAssertFalse(overlay.isWarmingUp)
        XCTAssertEqual(overlay.confirmButton.emphasis, 1)
        overlay.showListening(micName: "Mike’s Pixel Buds Pro", warmingUp: true)
        overlay.hide()
        XCTAssertFalse(overlay.isWarmingUp)
    }

    func testFullMicNameFitsWithoutTruncation() throws {
        let overlay = OverlayWindow()
        addTeardownBlock { overlay.hide() }
        for name in ["MacBook Pro Microphone", "iPhone (53) Microphone", "HD Pro Webcam C920", "Steam Streaming Microphone"] {
            overlay.showListening(micName: name)
            let needed = overlay.micLabel.attributedStringValue.size().width
            XCTAssertTrue(overlay.micLabel.stringValue.hasSuffix(name), "full name shown: \(overlay.micLabel.stringValue)")
            XCTAssertGreaterThanOrEqual(overlay.micLabel.frame.width, needed, "\(name) is truncated")
            XCTAssertEqual(overlay.pillFrame.width, overlay.micLabel.frame.maxX + overlay.micLabel.frame.minX, accuracy: 1,
                           "caption is centered in the pill")
        }
        overlay.showListening(micName: "Mic")
        XCTAssertEqual(overlay.pillFrame.width, OverlayWindow.listeningWidth, "short names keep the compact pill")
        overlay.showListening(micName: String(repeating: "Very Long Device Name ", count: 6))
        XCTAssertEqual(overlay.pillFrame.width, OverlayWindow.maxListeningWidth, "absurd names are capped")
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
    /// The pill in a window with a fixed scale (`OffscreenPanel`), not one on whichever display the
    /// mouse is on.
    private func snapshotOverlay() -> OverlayWindow {
        let overlay = OverlayWindow()
        overlay.makePanel = { OffscreenPanel(contentRect: $0, styleMask: [.borderless, .nonactivatingPanel],
                                             backing: .buffered, defer: false) }
        return overlay
    }

    func testOverlayListening() throws {
        let overlay = snapshotOverlay()
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
        let overlay = snapshotOverlay()
        addTeardownBlock { overlay.hide() }
        overlay.showListening(micName: "External Microphone")
        for i in 0..<40 { overlay.setLevel(0.25 * [1.0, 0.6, 1.2, 0.3, 0.9, 1.1, 0.2, 0.8][i % 8]) }
        assertSnapshot(of: try XCTUnwrap(overlay.panel?.contentView), named: "overlay-listening-quiet")
    }

    func testOverlayListeningLongMicName() throws {
        let overlay = snapshotOverlay()
        addTeardownBlock { overlay.hide() }
        overlay.showListening(micName: "Steam Streaming Microphone")
        for level in [0.2, 0.5, 0.8, 0.6, 0.9, 0.4, 0.7, 0.3] as [Float] { overlay.setLevel(level) }
        assertSnapshot(of: try XCTUnwrap(overlay.panel?.contentView), named: "overlay-listening-long-mic")
    }

    /// A Bluetooth mic starting: dots with the sweep partway across, ✓ dimmed.
    func testOverlayWarmingUp() throws {
        let overlay = snapshotOverlay()
        addTeardownBlock { overlay.hide() }
        var clock: TimeInterval = 0
        overlay.now = { clock }
        overlay.reduceMotion = { false }
        overlay.showListening(micName: "Mike’s Pixel Buds Pro", warmingUp: true)
        clock = 0.52
        overlay.tick()
        assertSnapshot(of: try XCTUnwrap(overlay.panel?.contentView), named: "overlay-warming-up")
    }

    /// The moment it goes live: green edge, bounce, bars rippling out from the center.
    func testOverlayMicReady() throws {
        let overlay = snapshotOverlay()
        addTeardownBlock { overlay.hide() }
        var clock: TimeInterval = 0
        overlay.now = { clock }
        overlay.reduceMotion = { false }
        overlay.showListening(micName: "Mike’s Pixel Buds Pro", warmingUp: true)
        clock = 0.95
        overlay.micLive()
        clock = 1.08
        overlay.tick()
        assertSnapshot(of: try XCTUnwrap(overlay.panel?.contentView), named: "overlay-mic-ready")
    }

    /// Partway from listening to processing: ✕/✓ and caption gone, the pill half narrowed.
    func testOverlayNarrowing() throws {
        let overlay = snapshotOverlay()
        addTeardownBlock { overlay.hide() }
        var clock: TimeInterval = 0
        overlay.now = { clock }
        overlay.showListening(micName: "MacBook Pro Microphone")
        for level in [0.1, 0.3, 0.7, 0.9, 0.6, 0.4, 0.8, 0.5, 0.2, 0.6, 0.9, 0.3, 0.1] as [Float] { overlay.setLevel(level) }
        overlay.showProcessing()
        for _ in 0..<4 { overlay.waveform.tick() }
        clock = 0.23
        overlay.tick()
        assertSnapshot(of: try XCTUnwrap(overlay.panel?.contentView), named: "overlay-narrowing")
    }

    /// Moved to a better mic: the ready flash in yellow.
    func testOverlayMicSwitched() throws {
        let overlay = snapshotOverlay()
        addTeardownBlock { overlay.hide() }
        var clock: TimeInterval = 0
        overlay.now = { clock }
        overlay.reduceMotion = { false }
        overlay.showListening(micName: "Mike’s Pixel Buds Pro")
        for level in [0.1, 0.3, 0.7, 0.9, 0.6, 0.4, 0.8, 0.5, 0.2, 0.6, 0.9, 0.3, 0.1] as [Float] { overlay.setLevel(level) }
        overlay.micSwitched(to: "Logitech BRIO")
        clock = 0.4
        overlay.tick()
        assertSnapshot(of: try XCTUnwrap(overlay.panel?.contentView), named: "overlay-mic-switched")
    }

    /// No audio coming in: the red glow, fully faded in.
    func testOverlayNoAudio() throws {
        let overlay = snapshotOverlay()
        addTeardownBlock { overlay.hide() }
        var clock: TimeInterval = 0
        overlay.now = { clock }
        overlay.showListening(micName: "USB Mic")
        overlay.micSilent()
        clock = PillLook.silentFadeIn
        overlay.tick()
        assertSnapshot(of: try XCTUnwrap(overlay.panel?.contentView), named: "overlay-no-audio")
    }

    func testOverlayMessage() throws {
        let overlay = snapshotOverlay()
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

    func testInsightsTimeBreakdown() {
        let insights = Insights(defaults: makeDefaults(self))
        insights.record(text: Array(repeating: "w", count: 7_500).joined(separator: " "), duration: 78 * 60)
        let breakdown = TimeBreakdown(speaking: 13.9, transcribing: 1.6, polishing: 0.3, count: 100)
        let hosted = HostedView(InsightsView(insights: insights, breakdown: breakdown).padding(20), size: NSSize(width: 620, height: 400))
        addTeardownBlock { hosted.close() }
        assertSnapshot(of: hosted.hostingView, named: "insights-breakdown")
    }

    func testHistory() {
        let url = makeTempURL(self)
        var entries = [
            HistoryEntry(date: fixedDate(2026, 1, 6, 9, 41), text: "Ship the history page with a copy button on every row.", duration: 4),
            HistoryEntry(date: fixedDate(2026, 1, 6, 9, 15), text: "还有一个问题，中英文混用 should still look right.", duration: 3),
            HistoryEntry(date: fixedDate(2026, 1, 5, 18, 2), text: "Short one.", duration: 1),
        ]
        entries[2].correction = "Short one, corrected."
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(entries).write(to: url)
        let store = HistoryStore(fileURL: url, defaults: makeDefaults(self))
        let hosted = HostedView(HistoryView(store: store), size: NSSize(width: 760, height: 520))
        addTeardownBlock { hosted.close() }
        assertSnapshot(of: hosted.hostingView, named: "history")
    }

    func testExcludedApps() {
        let settings = makeSettings(self)
        settings.exclude(ExcludedApp(bundleID: "com.nvidia.gfnpc.mall", name: "GeForce NOW"))
        settings.exclude(ExcludedApp(bundleID: "com.example.game", name: "Some Game"))
        let view = Form { Section { ExcludedAppsList(settings: settings) } }.formStyle(.grouped)
        let hosted = HostedView(view, size: NSSize(width: 640, height: 200))
        addTeardownBlock { hosted.close() }
        assertSnapshot(of: hosted.hostingView, named: "excluded-apps")
    }

    func testCorrections() {
        let url = makeTempURL(self)
        var flash = HistoryEntry(date: fixedDate(2026, 10, 8, 22, 18), text: "Can you install Cloud Code so I can develop the app when I ask?",
                                 duration: 4, raw: "can you install cloud code so i can develop the app when i ask uh", setup: "cloud-flash", prompt: "v3")
        flash.correction = "Can you install Claude Code so I can develop the app when I ask?"
        var mac = HistoryEntry(date: fixedDate(2026, 10, 7, 2, 1), text: "All right. Let's push off some changes. 那你让我看干什么？",
                               duration: 2, setup: "on-device")
        mac.correction = "All right. Let's push these changes. 那你想让我看什么？"
        let plain = HistoryEntry(date: fixedDate(2026, 10, 7, 1, 0), text: "Not corrected.", duration: 1)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode([flash, mac, plain]).write(to: url)
        let store = HistoryStore(fileURL: url, defaults: makeDefaults(self))
        let hosted = HostedView(CorrectionsView(store: store), size: NSSize(width: 760, height: 480))
        addTeardownBlock { hosted.close() }
        assertSnapshot(of: hosted.hostingView, named: "corrections")
    }

    /// The Learn tile at rest with a kept version: its scores on the rings, Learn ready for the new correction.
    @MainActor func testLearnReady() {
        let fx = LearnFixture(self, count: 3)
        let ids = fx.history.corrections.map(\.id)
        fx.store.keep(makeLearned(errors: [ids[0]: 0.0, ids[1]: 0.09], errorsBefore: [ids[0]: 0.25, ids[1]: 0.38]))
        waitUntil { fx.settings.setup.prompt == "v5" }
        for n in 4...10 {
            fx.history.add(text: "Dictation \(n).", duration: 1, raw: "dictation \(n)", setup: "cloud-flash", prompt: "v5", date: fixedDate(2026, 10, 13, 9, n))
            fx.history.setCorrection("Dictation number \(n).", for: fx.history.entries[0].id)
        }
        let hosted = fx.host(self, height: 620)
        assertSnapshot(of: hosted.hostingView, named: "learn-ready")
    }

    /// Before the first tune (what a new user sees): no scores yet, Learn ready.
    @MainActor func testLearnFirstRun() {
        let fx = LearnFixture(self)
        let hosted = fx.host(self, height: 420)
        spinRunLoop(1.6)  // the rings and figures count up once the measurement is in
        hosted.settle()
        assertSnapshot(of: hosted.hostingView, named: "learn-first-run")
    }

    /// After a tune: the candidates, the diff, the new scores, the fits and Keep.
    @MainActor func testLearnDone() {
        let fx = LearnFixture(self, right: [.rules: ["can you install cloud code 1", "can you install cloud code 2"],
                                            .both: Set((1...10).map { "can you install cloud code \($0)" })])
        let hosted = fx.host(self, height: 980)
        fx.controller.learn()
        waitUntil(timeout: 5) { fx.controller.gate == .done }
        spinRunLoop(1.6)  // the rings and figures count up
        hosted.settle()
        assertSnapshot(of: hosted.hostingView, named: "learn-done")
    }
}

/// The sidebar picks tabs by each row's `.tag`. A modifier after the tag (the Corrections badge)
/// hid it from the List: no row was ever highlighted and clicking the sidebar did nothing.
/// (Synthetic clicks don't reach List rows here, so this checks the highlight the tags drive.)
final class SidebarTests: XCTestCase {
    func testTheCurrentTabsRowIsSelected() {
        for tab in MainTab.allCases {
            let selection = TabSelection()
            selection.tab = tab
            let history = HistoryStore(fileURL: makeTempURL(self), defaults: makeDefaults(self))
            let hosted = HostedView(MainView(selection: selection, history: history), size: NSSize(width: 860, height: 620))
            let sidebar = hosted.elements { $0.object is NSTableView }.first?.object as? NSTableView
            XCTAssertEqual(sidebar?.numberOfRows, MainTab.allCases.count)
            XCTAssertEqual(sidebar?.selectedRow, MainTab.allCases.firstIndex(of: tab), "\(tab.title) row highlighted")
        }
    }
}

/// Each page is built on its first visit and kept, hidden, behind the selected one (MainView):
/// rebuilding Settings took ~100 ms of every tab switch.
final class KeptPagesTests: XCTestCase {
    private func host(_ tab: MainTab, settings: AppSettings? = nil) -> (HostedView<MainView>, TabSelection) {
        let selection = TabSelection()
        selection.tab = tab
        let history = HistoryStore(fileURL: makeTempURL(self), defaults: makeDefaults(self))
        let hosted = HostedView(MainView(selection: selection, history: history, settings: settings ?? makeSettings(self)),
                                size: NSSize(width: 860, height: 620))
        addTeardownBlock { hosted.close() }
        return (hosted, selection)
    }

    private func switches(in view: NSView) -> Set<ObjectIdentifier> {
        view.subviews.reduce(into: Set(view is NSSwitch ? [ObjectIdentifier(view)] : [])) { $0.formUnion(switches(in: $1)) }
    }

    func testSettingsIsKeptAcrossTabSwitches() {
        let (hosted, selection) = host(.settings)
        let controls = switches(in: hosted.hostingView)
        XCTAssertFalse(controls.isEmpty)
        XCTAssertNotNil(hosted.element(id: "setting.Hotkey"))

        selection.tab = .history
        hosted.settle()
        XCTAssertNil(hosted.element(id: "setting.Hotkey"), "a hidden page is out of the accessibility tree")
        XCTAssertNotNil(hosted.element(id: "history.empty") ?? hosted.elements { $0.label == "History" }.first)

        selection.tab = .settings
        hosted.settle()
        XCTAssertNotNil(hosted.element(id: "setting.Hotkey"))
        XCTAssertEqual(switches(in: hosted.hostingView), controls, "the same switches, not rebuilt")
    }

    /// History and Corrections each searched from the toolbar; kept alive together they put two
    /// search fields there, and AppKit threw (crashed) inserting the second. Needs the app's real
    /// window: HostedView's has no toolbar.
    func testOneToolbarSearchFieldAcrossKeptPages() {
        let selection = TabSelection()
        selection.tab = .history
        let history = HistoryStore(fileURL: makeTempURL(self), defaults: makeDefaults(self))
        let window = MainWindowController.makeWindow(rootView: MainView(selection: selection, history: history, settings: makeSettings(self), learn: nil))
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        addTeardownBlock { window.close() }
        func searchFields() -> [NSSearchField] {
            spinRunLoop(0.2)
            return (window.toolbar?.items ?? []).compactMap { $0.view as? NSSearchField }
                + (window.toolbar?.items ?? []).compactMap { ($0 as? NSSearchToolbarItem)?.searchField }
        }
        for (tab, prompt) in [(MainTab.history, "Search history"), (.corrections, "Search corrections"),
                              (.history, "Search history"), (.settings, nil), (.corrections, "Search corrections")] {
            selection.tab = tab
            let fields = searchFields()
            XCTAssertEqual(fields.count, prompt == nil ? 0 : 1, "\(tab.title)")
            if let prompt { XCTAssertEqual(fields.first?.placeholderString, prompt) }
        }
    }

    /// The query typed in MainView's toolbar field filters the page in front.
    func testSearchFiltersHistoryAndCorrections() {
        let store = HistoryStore(fileURL: makeTempURL(self), defaults: makeDefaults(self))
        store.add(text: "Book the flight.", duration: 1)
        store.add(text: "Call the dentist.", duration: 1)
        store.entries.forEach { store.setCorrection($0.text + "!", for: $0.id) }
        let history = HostedView(HistoryView(store: store, search: "dentist"), size: NSSize(width: 760, height: 400))
        addTeardownBlock { history.close() }
        XCTAssertEqual(history.elements(id: "history.row").count, 1)
        let corrections = HostedView(CorrectionsView(store: store, search: "flight"), size: NSSize(width: 760, height: 480))
        addTeardownBlock { corrections.close() }
        XCTAssertEqual(corrections.elements(id: "corrections.card").count, 1)
    }

    func testSettingsRereadsCustomSetupsEachTimeItIsShown() throws {
        let file = makeTempURL(self, "setups.json")
        let settings = AppSettings(defaults: makeDefaults(self), secrets: InMemorySecretStore(), customSetupsFile: file,
                                   learned: noLearnedPrompts(self))
        let (hosted, selection) = host(.settings, settings: settings)
        selection.tab = .history
        hosted.settle()
        try #"{"setups": [{"id": "try", "title": "Try", "speech": "apple", "polish": "apple", "prompt": "v1"}]}"#
            .write(to: file, atomically: true, encoding: .utf8)
        XCTAssertFalse(settings.setups.contains { $0.id == "try" })

        selection.tab = .settings
        hosted.settle()
        XCTAssertTrue(settings.setups.contains { $0.id == "try" }, "edits show up when Settings opens again")
    }
}

/// Puts a page in a kept tab whose shown state the test flips, as MainView does.
private final class KeptTab: ObservableObject {
    let page = KeptPage()
    @Published var editing: UUID?
}

private struct KeptCorrections: View {
    @ObservedObject var tab: KeptTab
    let store: HistoryStore

    var body: some View {
        CorrectionsView(store: store, editing: tab.editing).environment(\.keptPage, tab.page)
    }
}

final class KeptCorrectionsTests: XCTestCase {
    /// History's pencil opens Corrections on the new correction even when Corrections is already
    /// built (kept hidden), and a hidden Corrections lets go of the keyboard.
    func testOpeningAKeptCorrectionsFocusesTheEditedOne() throws {
        let store = HistoryStore(fileURL: makeTempURL(self), defaults: makeDefaults(self))
        store.add(text: "First.", duration: 1)
        store.add(text: "Second.", duration: 1)
        store.setCorrection("First!", for: store.entries[1].id)
        let tab = KeptTab()
        tab.page.shown = true
        let hosted = HostedView(KeptCorrections(tab: tab, store: store), size: NSSize(width: 760, height: 480))
        addTeardownBlock { hosted.close() }

        tab.page.shown = false
        hosted.settle()
        let id = store.entries[0].id
        store.setCorrection("Second!", for: id)
        tab.editing = id
        tab.page.shown = true
        hosted.settle()
        let field = try XCTUnwrap(hosted.window.firstResponder as? NSTextView, "the new correction has the cursor")
        XCTAssertEqual(field.string, "Second!")

        tab.page.shown = false
        hosted.settle()
        XCTAssertFalse(hosted.window.firstResponder === field, "hidden, it doesn't keep the keyboard")
    }
}

final class MainWindowTests: XCTestCase {
    func testTitleBarIsTransparentAndUntitledSoNoBandShowsOverTheContent() {
        let window = MainWindowController.makeWindow(rootView: Text("content"))
        defer { window.close() }
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertEqual(window.title, "DictationApp", "still named for the Window menu and Mission Control")
    }
}
