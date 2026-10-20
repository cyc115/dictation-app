import AppKit
import SwiftUI
import XCTest
@testable import DictationKit

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

    /// Command mode: blue bars and edge, "Command" for the mic name.
    func testOverlayCommand() throws {
        let overlay = snapshotOverlay()
        addTeardownBlock { overlay.hide() }
        overlay.showListening(micName: "MacBook Pro Microphone", command: true)
        for level in [0.1, 0.3, 0.7, 0.9, 0.6, 0.4, 0.8, 0.5, 0.2, 0.6, 0.9, 0.3, 0.1] as [Float] { overlay.setLevel(level) }
        assertSnapshot(of: try XCTUnwrap(overlay.panel?.contentView), named: "overlay-command")
    }

    func testOverlayCommandDone() throws {
        let overlay = snapshotOverlay()
        addTeardownBlock { overlay.hide() }
        overlay.showResult("Volume 40%", ok: true, hideAfter: 10)
        assertSnapshot(of: try XCTUnwrap(overlay.panel?.contentView), named: "overlay-command-done")
    }

    func testOverlayCommandNotFound() throws {
        let overlay = snapshotOverlay()
        addTeardownBlock { overlay.hide() }
        overlay.reduceMotion = { true }  // no shake mid-snapshot
        overlay.showResult("Command not found", detail: "“open the pod bay doors”", ok: false, hideAfter: 10)
        assertSnapshot(of: try XCTUnwrap(overlay.panel?.contentView), named: "overlay-command-not-found")
    }

    func testHistoryCommands() {
        let store = HistoryStore(fileURL: makeTempURL(self), defaults: makeDefaults(self))
        for run in [
            CommandRun(date: fixedDate(2026, 1, 5, 23, 20), said: "mute", command: "volume", choice: "mute", ok: true, result: "Muted"),
            CommandRun(date: fixedDate(2026, 1, 6, 18, 12), said: "turn the brightness way up", command: "brightness", choice: "+30",
                       result: "No display whose brightness macOS can set"),
            CommandRun(date: fixedDate(2026, 1, 6, 20, 47), said: "open the pod bay doors", result: "Command not found"),
            CommandRun(date: fixedDate(2026, 1, 6, 21, 2), said: "声音小一点", command: "volume", choice: "-10", ok: true, result: "Volume 40%"),
        ] { store.addCommand(run) }
        let hosted = HostedView(HistoryView(store: store, shown: .commands), size: NSSize(width: 760, height: 420))
        addTeardownBlock { hosted.close() }
        assertSnapshot(of: hosted.hostingView, named: "history-commands")
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

    func testRecentLatency() {
        let usual = TimeBreakdown(speaking: 13.9, transcribing: 1.3, polishing: 0.3, count: 100)
        let view = RecentLatencyView(entries: RecentLatencyTests.tonight, usual: usual, backupWait: 2, now: RecentLatencyTests.now)
        // In a ScrollView, as on Home: text wraps to the width there.
        let hosted = HostedView(ScrollView { view.padding(20) }, size: NSSize(width: 720, height: 1000))
        addTeardownBlock { hosted.close() }
        assertSnapshot(of: hosted.hostingView, named: "recent-latency")
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
        JSONFile.save([flash, mac, plain], to: url)
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
