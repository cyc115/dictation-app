import AppKit
import SwiftUI
import XCTest
@testable import DictationKit

/// Visual regression: renders views with fixed data and compares to reference PNGs.
/// After an intentional UI change: RECORD_SNAPSHOTS=1 swift test --filter SnapshotTests
final class SnapshotTests: XCTestCase {
    /// Test windows draw as the window in use (an "on" switch in colour, `controlActiveState` key),
    /// in the pinned blue whatever the Mac's accent: `OffscreenWindow.hasKeyAppearance` and
    /// `pinSystemColors`. If this fails after a macOS update, AppKit no longer asks
    /// `hasKeyAppearance` for the active look and every snapshot's controls went grey.
    func testHostedWindowsDrawActive() throws {
        struct Probe: View {
            @Environment(\.controlActiveState) var state
            var body: some View {
                HStack { Toggle("On", isOn: .constant(true)).toggleStyle(.switch).labelsHidden(); Text(state == .key ? "key" : "not key") }
                    .padding(20)
            }
        }
        let hosted = host(Probe(), size: NSSize(width: 240, height: 80))
        XCTAssertTrue(hosted.allText.contains("key") && !hosted.allText.contains("not key"), hosted.allText)
        let rep = try XCTUnwrap(snapshotBitmap(of: hosted.hostingView))
        // The switch's filled track, left of its knob.
        let track = try XCTUnwrap(rep.colorAt(x: 52, y: 80)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(track.blueComponent - track.redComponent, 0.5, "an on switch is blue, not grey: \(track)")
        XCTAssertTrue(systemColorsArePinned(), "accent pinned to blue for this process: \(NSColor.controlAccentColor)")
        XCTAssertEqual(UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["AppleAccentColor"] as? Int, 4)
        XCTAssertFalse(hosted.window.isKeyWindow, "only the look changes, not focus")
    }

    func testOverlayListening() throws {
        let overlay = makeOverlay(fixedScale: true)
        overlay.showListening(micName: "MacBook Pro Microphone")
        for level in [0.1, 0.3, 0.7, 0.9, 0.6, 0.4, 0.8, 0.5, 0.2, 0.6, 0.9, 0.3, 0.1] as [Float] {
            overlay.setLevel(level)
        }
        let view = try XCTUnwrap(overlay.panel?.contentView)
        assertSnapshot(of: view, named: "overlay-listening")
    }

    /// Typical laptop/desk-mic speech (≈ −40 dBFS). This used to render as a nearly flat row.
    func testOverlayListeningQuietSpeech() throws {
        let overlay = makeOverlay(fixedScale: true)
        overlay.showListening(micName: "External Microphone")
        for i in 0..<40 { overlay.setLevel(0.25 * [1.0, 0.6, 1.2, 0.3, 0.9, 1.1, 0.2, 0.8][i % 8]) }
        assertSnapshot(of: try XCTUnwrap(overlay.panel?.contentView), named: "overlay-listening-quiet")
    }

    func testOverlayListeningLongMicName() throws {
        let overlay = makeOverlay(fixedScale: true)
        overlay.showListening(micName: "Steam Streaming Microphone")
        for level in [0.2, 0.5, 0.8, 0.6, 0.9, 0.4, 0.7, 0.3] as [Float] { overlay.setLevel(level) }
        assertSnapshot(of: try XCTUnwrap(overlay.panel?.contentView), named: "overlay-listening-long-mic")
    }

    /// A Bluetooth mic starting: dots with the sweep partway across, ✓ dimmed.
    func testOverlayWarmingUp() throws {
        let overlay = makeOverlay(fixedScale: true)
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
        let overlay = makeOverlay(fixedScale: true)
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
        let overlay = makeOverlay(fixedScale: true)
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
        let overlay = makeOverlay(fixedScale: true)
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
        let overlay = makeOverlay(fixedScale: true)
        var clock: TimeInterval = 0
        overlay.now = { clock }
        overlay.showListening(micName: "USB Mic")
        overlay.micSilent()
        clock = PillLook.silentFadeIn
        overlay.tick()
        assertSnapshot(of: try XCTUnwrap(overlay.panel?.contentView), named: "overlay-no-audio")
    }

    func testOverlayMessage() throws {
        let overlay = makeOverlay(fixedScale: true)
        overlay.show(.plain("Speech recognizer unavailable", seconds: 10))
        assertSnapshot(of: try XCTUnwrap(overlay.panel?.contentView), named: "overlay-message")
    }

    /// Command mode: blue bars and edge, "Command" for the mic name.
    func testOverlayCommand() throws {
        let overlay = makeOverlay(fixedScale: true)
        overlay.showListening(micName: "MacBook Pro Microphone", command: true)
        for level in [0.1, 0.3, 0.7, 0.9, 0.6, 0.4, 0.8, 0.5, 0.2, 0.6, 0.9, 0.3, 0.1] as [Float] { overlay.setLevel(level) }
        assertSnapshot(of: try XCTUnwrap(overlay.panel?.contentView), named: "overlay-command")
    }

    func testOverlayCommandDone() throws {
        let overlay = makeOverlay(fixedScale: true)
        overlay.show(PillMessage(title: "Volume 40%", tone: .done, seconds: 10))
        assertSnapshot(of: try XCTUnwrap(overlay.panel?.contentView), named: "overlay-command-done")
    }

    func testOverlayCommandNotFound() throws {
        let overlay = makeOverlay(fixedScale: true)
        overlay.reduceMotion = { true }  // no shake mid-snapshot
        overlay.show(PillMessage(title: "Command not found", detail: "“open the pod bay doors”", tone: .failed, seconds: 10))
        assertSnapshot(of: try XCTUnwrap(overlay.panel?.contentView), named: "overlay-command-not-found")
    }

    func testHistoryCommands() {
        let store = makeHistory(self)
        for run in [
            CommandRun(date: fixedDate(2026, 1, 5, 23, 20), said: "mute", command: "volume", choice: "mute", ok: true, result: "Muted"),
            CommandRun(date: fixedDate(2026, 1, 6, 18, 12), said: "turn the brightness way up", command: "brightness", choice: "+30",
                       result: "No display whose brightness macOS can set"),
            CommandRun(date: fixedDate(2026, 1, 6, 20, 47), said: "open the pod bay doors", result: "Command not found"),
            CommandRun(date: fixedDate(2026, 1, 6, 21, 2), said: "声音小一点", command: "volume", choice: "-10", ok: true, result: "Volume 40%"),
        ] { store.addCommand(run) }
        let hosted = host(HistoryView(store: store, shown: .commands), size: NSSize(width: 760, height: 420))
        assertSnapshot(of: hosted.hostingView, named: "history-commands")
    }

    func testCommandsTab() throws {
        let services = makeServices(self)
        let folder = services.commands.folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "\"\"\"Say the battery level.\"\"\"\n".write(to: folder.appendingPathComponent("battery.py"), atomically: true, encoding: .utf8)
        try "\"\"\"Tile the front window.\n\nChoices:\n    left: the left half\n    right: the right half\n\"\"\"\n"
            .write(to: folder.appendingPathComponent("window.py"), atomically: true, encoding: .utf8)
        services.settings.setOpenRouterKey("test-key")
        services.settings.commandModeEnabled = true
        for run in [
            CommandRun(date: fixedDate(2026, 1, 5, 23, 20), said: "battery", command: "battery", ok: true, result: "Battery 80%"),
            CommandRun(date: fixedDate(2026, 1, 6, 18, 12), said: "tile it left", command: "window", choice: "left", result: "No window to tile"),
            CommandRun(date: fixedDate(2026, 1, 6, 21, 2), said: "声音小一点", command: "volume", choice: "-10", ok: true, result: "Volume 40%"),
        ] { services.history.addCommand(run) }
        let view = CommandsView(mode: services.commands, settings: services.settings, history: services.history,
                                trash: { try FileManager.default.removeItem(at: $0) })
        let hosted = host(view, size: NSSize(width: 760, height: 1180))
        assertSnapshot(of: hosted.hostingView, named: "commands-tab")
    }

    func testVocabularyTab() {
        let url = makeTempURL(self, "vocabulary.json")
        let entries = [
            VocabularyEntry(term: "reMarkable", added: fixedDate(2026, 11, 2, 9, 0), uses: 0),
            VocabularyEntry(term: "Claude", heardAs: ["cloud", "Coloule", "Cloud Code"], source: .learned, added: fixedDate(2026, 11, 18, 9, 0), uses: 12),
            VocabularyEntry(term: "Codex", heardAs: ["code x"], enabled: false, added: fixedDate(2026, 11, 19, 9, 0)),
            VocabularyEntry(term: "GeForce Now", heardAs: ["G Four Snow", "g force now"], added: fixedDate(2026, 11, 20, 9, 0), uses: 1),
            VocabularyEntry(term: "HRV", heardAs: ["而差v"], added: fixedDate(2026, 11, 21, 9, 0), uses: 4),
        ]
        JSONFile.save(["entries": entries], to: url)
        let hosted = host(VocabularyView(store: VocabularyStore(fileURL: url)), size: NSSize(width: 760, height: 620))
        assertSnapshot(of: hosted.hostingView, named: "vocabulary-tab")
    }

    /// Seen in your edits, above Your terms: terms seen twice, an ordinary word struck through.
    func testVocabularyCandidates() {
        let url = makeTempURL(self, "vocabulary.json")
        let ids = (0..<6).map { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", $0))! }
        JSONFile.save(["entries": [VocabularyEntry(term: "reMarkable", added: fixedDate(2026, 11, 2, 9, 0), uses: 3)]], to: url)
        let store = VocabularyStore(fileURL: url)
        store.updateCandidates([
            VocabularyCandidate(term: "Claude", heard: [.init(text: "Coloule", dictations: [ids[0]]),
                                                        .init(text: "cloud", dictations: [ids[1]], ordinary: true)]),
            VocabularyCandidate(term: "HRV", heard: [.init(text: "而差v", dictations: [ids[2], ids[3]])]),
            VocabularyCandidate(term: "GeForce Now", heard: [.init(text: "G Four Snow", dictations: [ids[4]])]),
        ], learnAfter: 3)
        let hosted = host(VocabularyView(store: store), size: NSSize(width: 760, height: 560))
        assertSnapshot(of: hosted.hostingView, named: "vocabulary-candidates")
    }

    /// The README's Vocabulary animation (`scripts/readme-gifs.py render vocabulary`), one story through
    /// the app's own code with written dictations: "G Four Snow" fixed to "GeForce Now" in two
    /// dictations (Corrections), counted on its way in (`CandidateTally` → `updateCandidates`: 2 of 3),
    /// added with Add now (`learn`), and the next dictation replaced by `Vocabulary.apply` (History:
    /// right on top, the two you fixed below as the app first wrote them). Dates in the past, so
    /// History never says "Today".
    func testReadmeVocabularyStory() throws {
        let historyURL = makeTempURL(self), vocabularyURL = makeTempURL(self, "vocabulary.json")
        var entries = [
            HistoryEntry(date: fixedDate(2026, 1, 13, 20, 15), text: "Let's play on G Four Snow tonight.", duration: 2,
                         raw: "let's play on g four snow tonight", setup: "on-device"),
            HistoryEntry(date: fixedDate(2026, 1, 12, 18, 2), text: "Is G Four Snow down again?", duration: 2,
                         raw: "is g four snow down again", setup: "on-device"),
        ]
        entries[0].correction = "Let's play on GeForce Now tonight."
        entries[1].correction = "Is GeForce Now down again?"
        for i in entries.indices { entries[i].intake = FixIntake.intake(of: entries[i].text, target: entries[i].correction!) }
        JSONFile.save(entries, to: historyURL)
        JSONFile.save(["entries": [VocabularyEntry(term: "reMarkable", added: fixedDate(2026, 1, 2, 9, 0), uses: 3)]], to: vocabularyURL)
        let history = HistoryStore(fileURL: historyURL, defaults: makeDefaults(self))
        let vocabulary = VocabularyStore(fileURL: vocabularyURL)
        vocabulary.now = { fixedDate(2026, 1, 14, 9, 30) }

        assertSnapshot(of: host(CorrectionsView(store: history), size: NSSize(width: 760, height: 480)).hostingView,
                       named: "readme-vocabulary-1-fixed")

        vocabulary.updateCandidates(CandidateTally.support(in: history.entries), learnAfter: 3)
        XCTAssertEqual(vocabulary.candidates.map(\.term), ["GeForce Now"])
        XCTAssertEqual(vocabulary.candidates.first?.seen, 2)
        let seen = host(VocabularyView(store: vocabulary), size: NSSize(width: 760, height: 560))
        XCTAssertTrue(seen.allText.contains("2 of 3"), seen.allText)
        assertSnapshot(of: seen.hostingView, named: "readme-vocabulary-2-seen")

        vocabulary.learn("geforce now")
        XCTAssertEqual(vocabulary.entries.first { $0.term == "GeForce Now" }?.heardAs, ["G Four Snow"])
        let terms = host(VocabularyView(store: vocabulary), size: NSSize(width: 760, height: 560))
        assertSnapshot(of: terms.hostingView, named: "readme-vocabulary-3-terms")

        // The next dictation, as the app delivers it with AI polish off: the transcript, replaced.
        let (text, uses) = vocabulary.vocabulary(enabled: true).apply("Can we play on G Four Snow later?")
        XCTAssertEqual(text, "Can we play on GeForce Now later?")
        vocabulary.recordUses(uses)
        history.add(text: text, duration: 2, raw: "can we play on g four snow later", setup: "on-device", date: fixedDate(2026, 1, 14, 9, 41))
        assertSnapshot(of: host(HistoryView(store: history), size: NSSize(width: 760, height: 480)).hostingView,
                       named: "readme-vocabulary-4-next")
    }

    func testInsights() {
        let insights = Insights(defaults: makeDefaults(self))
        insights.record(text: Array(repeating: "w", count: 19_400).joined(separator: " "), duration: 3 * 3600 + 31 * 60)
        let hosted = host(InsightsView(insights: insights).padding(20), size: NSSize(width: 620, height: 240))
        assertSnapshot(of: hosted.hostingView, named: "insights")
    }

    func testInsightsTimeBreakdown() {
        let insights = Insights(defaults: makeDefaults(self))
        insights.record(text: Array(repeating: "w", count: 7_500).joined(separator: " "), duration: 78 * 60)
        let breakdown = TimeBreakdown(speaking: 13.9, transcribing: 1.6, polishing: 0.3, count: 100)
        let hosted = host(InsightsView(insights: insights, breakdown: breakdown).padding(20), size: NSSize(width: 620, height: 400))
        assertSnapshot(of: hosted.hostingView, named: "insights-breakdown")
    }

    func testRecentLatency() {
        let usual = TimeBreakdown(speaking: 13.9, transcribing: 1.3, polishing: 0.3, count: 100)
        let view = RecentLatencyView(entries: RecentLatencyTests.tonight, usual: usual, backupWait: 2, now: RecentLatencyTests.now)
        // In a ScrollView, as on Home: text wraps to the width there.
        let hosted = host(ScrollView { view.padding(20) }, size: NSSize(width: 720, height: 1000))
        assertSnapshot(of: hosted.hostingView, named: "recent-latency")
    }

    /// Failed requests and dictations that never became text: a small red dot on the line (details on
    /// hover; "no text" for those), a legend entry, "N failed" in Models.
    func testRecentLatencyWithErrors() {
        let entries = RecentLatencyTests.withErrors + RecentLatencyTests.tonight.filter { $0.date < RecentLatencyTests.now.addingTimeInterval(-4 * 60) }
        let view = RecentLatencyView(entries: entries, failed: RecentLatencyTests.failedDictations, backupWait: 2, now: RecentLatencyTests.now)
        let hosted = host(ScrollView { view.padding(20) }, size: NSSize(width: 720, height: 1100))
        assertSnapshot(of: hosted.hostingView, named: "recent-latency-errors")
    }

    /// A line's hover card: a slow one the backup was asked for, whose backup failed; and one with no text.
    func testRecentLatencyHoverCards() {
        let rows = RecentLatency(RecentLatencyTests.withErrors, failed: RecentLatencyTests.failedDictations, window: .last25,
                                 now: RecentLatencyTests.now).rows
        let cards = VStack(alignment: .leading, spacing: 16) {
            LineCard(row: rows[0], time: "9:16 PM").background(.background, in: RoundedRectangle(cornerRadius: 10))
            LineCard(row: rows[1], time: "9:15 PM").background(.background, in: RoundedRectangle(cornerRadius: 10))
            LineCard(row: rows[3], time: "9:14 PM").background(.background, in: RoundedRectangle(cornerRadius: 10))
        }
        let hosted = host(cards.padding(20).background(Color.gray.opacity(0.2)), size: NSSize(width: 400, height: 640))
        assertSnapshot(of: hosted.hostingView, named: "recent-latency-cards")
    }

    func testHistory() {
        let url = makeTempURL(self)
        var entries = [
            HistoryEntry(date: fixedDate(2026, 1, 6, 9, 41), text: "Ship the history page with a copy button on every row.", duration: 4),
            HistoryEntry(date: fixedDate(2026, 1, 6, 9, 15), text: "还有一个问题，中英文混用 should still look right.", duration: 3),
            HistoryEntry(date: fixedDate(2026, 1, 5, 18, 2), text: "Short one.", duration: 1),
        ]
        entries[2].correction = "Short one, corrected."
        JSONFile.save(entries, to: url)
        let store = HistoryStore(fileURL: url, defaults: makeDefaults(self))
        let hosted = host(HistoryView(store: store), size: NSSize(width: 760, height: 520))
        assertSnapshot(of: hosted.hostingView, named: "history")
    }

    func testExcludedApps() {
        let settings = makeSettings(self)
        settings.exclude(ExcludedApp(bundleID: "com.nvidia.gfnpc.mall", name: "GeForce NOW"))
        settings.exclude(ExcludedApp(bundleID: "com.example.game", name: "Some Game"))
        let view = Form { Section { ExcludedAppsList(settings: settings) } }.formStyle(.grouped)
        let hosted = host(view, size: NSSize(width: 640, height: 200))
        assertSnapshot(of: hosted.hostingView, named: "excluded-apps")
    }

    /// Settings › Shortcuts: Dictate and Command & Enter, each a keyboard key and a mouse button.
    func testShortcuts() {
        let settings = makeSettings(self)
        settings.hotkey = .rightCommand
        settings.mode = .toggle
        settings.mouseButton = .button5
        settings.commandHotkey = .rightOption
        settings.mouseEnterButton = .button4
        settings.exclude(ExcludedApp(bundleID: "com.nvidia.gfnpc.mall", name: "GeForce NOW"))
        let view = Form { ShortcutsSection(settings: settings) }.formStyle(.grouped)
        let hosted = host(view, size: NSSize(width: 760, height: 420))
        assertSnapshot(of: hosted.hostingView, named: "shortcuts")
    }

    /// Settings › Vocabulary on the On-device setup, defaults otherwise (the speech hint off), with Ask
    /// a model about my fixes left on from a cloud setup: unavailable, shown off, cloud setups only.
    func testVocabularySectionOnDevice() {
        let settings = makeSettings(self)
        settings.setup = .onDevice
        settings.judgeFixes = true
        settings.setOpenRouterKey("sk-test")
        let view = Form { VocabularySection(settings: settings, editStats: EditWatchStats(fileURL: makeTempURL(self, "edit-watch.json"))) }
            .formStyle(.grouped)
        let hosted = host(view, size: NSSize(width: 760, height: 600))
        assertSnapshot(of: hosted.hostingView, named: "settings-vocabulary-on-device")
    }

    /// Settings › Updates with a newer release found by the daily check.
    func testUpdateAvailable() {
        let updates = Updates(backend: FakeUpdater(lastChecked: fixedDate(2026, 10, 7, 1, 5)))
        updates.setAvailable("1.0.220")
        let view = Form { UpdatesSection(updates: updates, version: "1.0.213") }.formStyle(.grouped)
        let hosted = host(view, size: NSSize(width: 640, height: 200))
        assertSnapshot(of: hosted.hostingView, named: "update-available")
    }

    /// Settings › Experimental's Decider row, before Decider is installed.
    func testDeciderNotInstalled() {
        let view = Form { Section { LocalDeciderRow(check: { .notInstalled }) } }.formStyle(.grouped)
        let hosted = host(view, size: NSSize(width: 640, height: 140))
        waitUntil { hosted.allText.contains("Not installed") }
        assertSnapshot(of: hosted.hostingView, named: "decider-not-installed")
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
        JSONFile.save([flash, mac, plain], to: url)
        let store = HistoryStore(fileURL: url, defaults: makeDefaults(self))
        let hosted = host(CorrectionsView(store: store), size: NSSize(width: 760, height: 480))
        assertSnapshot(of: hosted.hostingView, named: "corrections")
    }

    /// *Waiting for you* above a captured correction you accepted.
    func testCorrectionsWaiting() {
        let url = makeTempURL(self)
        var waiting = HistoryEntry(date: fixedDate(2026, 11, 22, 9, 41), text: "Can you ask cloud to review the GeForce now settings?", duration: 3)
        waiting.capture = Capture(edited: "Can you ask Claude to review the GeForce Now settings?", mode: .readback, app: "Slack")
        var accepted = HistoryEntry(date: fixedDate(2026, 11, 21, 18, 5), text: "Send the deck to Jon tomorrow.", duration: 2, setup: "cloud-flash")
        accepted.correction = "Send the deck to John tomorrow."
        accepted.capture = Capture(edited: "Send the deck to John tomorrow.", mode: .keystrokes, app: "Mail", state: .accepted)
        JSONFile.save([waiting, accepted], to: url)
        let store = HistoryStore(fileURL: url, defaults: makeDefaults(self))
        let hosted = host(CorrectionsView(store: store), size: NSSize(width: 760, height: 520))
        assertSnapshot(of: hosted.hostingView, named: "corrections-waiting")
    }

    /// The Learn tile at rest with a kept version: its scores on the rings, Learn ready for the new correction.
    @MainActor func testLearnReady() {
        let fx = LearnFixture(self, count: 3)
        let ids = fx.history.corrections.map(\.id)
        fx.store.keep(makeLearned(errors: [ids[0]: 0.0, ids[1]: 0.09], errorsBefore: [ids[0]: 0.25, ids[1]: 0.38]))
        waitUntil { fx.settings.setup.prompt == "v8" }
        for n in 4...10 {
            fx.history.add(text: "Dictation \(n).", duration: 1, raw: "dictation \(n)", setup: "cloud-flash", prompt: "v8", date: fixedDate(2026, 10, 13, 9, n))
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
