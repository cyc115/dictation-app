import AppKit
import XCTest
@testable import DictationKit

/// Budgets for the code that runs while you dictate or open the app.
/// Each prints "[perf] …" timings; budgets are ~10x the measured time on an M-series Mac,
/// so they catch real regressions (e.g. an accidental O(n²)) without flaking.
final class PerformanceTests: XCTestCase {
    /// Runs on the audio thread ~47×/s (1024 frames at 48 kHz = 21 ms per buffer).
    func testMicLevelPerBuffer() {
        let buffer = AudioLevelTests.buffer(amplitude: 0.2)
        assertFaster(than: 0.000_5, iterations: 2_000, "mic level per 1024-frame buffer") {
            _ = SpeechEngine.level(of: buffer)
        }
    }

    /// With "Keep recordings" on, the mic tap also converts each buffer to 16 kHz and writes it
    /// (on-device and cloud alike); a buffer arrives every 21 ms.
    /// Worst case: a silent buffer is scanned in full on every tap until a sample is non-zero.
    func testSilenceCheckPerBuffer() {
        let silent = AudioLevelTests.buffer(amplitude: 0)
        assertFaster(than: 0.000_2, iterations: 2_000, "mic silence check per 1024-frame buffer") {
            _ = MicCapture.hasSignal(silent)
        }
    }

    func testRecordingPerBuffer() throws {
        let recorder = try WAVRecorder(url: makeTempURL(self, "rec.wav"))
        let buffer = AudioLevelTests.buffer(amplitude: 0.2)
        assertFaster(than: 0.002, iterations: 500, "WAV recorder append per 1024-frame buffer") {
            recorder.append(buffer)
        }
        recorder.finish()
    }

    /// Redrawn on every buffer while listening; must fit well inside a 16 ms frame.
    func testWaveformRedraw() {
        let waveform = WaveformView(frame: NSRect(x: 0, y: 0, width: 72, height: 20))
        let rep = waveform.bitmapImageRepForCachingDisplay(in: waveform.bounds)!
        var level: Float = 0
        assertFaster(than: 0.002, iterations: 500, "waveform push + redraw") {
            level = level > 1 ? 0 : level + 0.07
            waveform.push(level)
            waveform.cacheDisplay(in: waveform.bounds, to: rep)
        }
    }

    /// From hotkey press to the pill on screen.
    func testOverlayShowLatency() {
        let overlay = OverlayWindow()
        addTeardownBlock { overlay.hide() }
        assertFaster(than: 0.01, iterations: 50, "overlay showListening") {
            overlay.showListening()
        }
    }

    /// Runs once per dictation; 10k words is far longer than any single dictation.
    func testWordCountLongMixedText() {
        let text = Array(repeating: "Today 我们 shipped the new 设置 page and it works", count: 1_000).joined(separator: " ")
        assertFaster(than: 0.05, "word count of ~10k mixed words") {
            XCTAssertGreaterThan(Insights.wordCount(text), 8_000)
        }
    }

    /// Saved after every dictation and loaded at launch.
    func testHistoryWithFiveThousandEntries() throws {
        let url = makeTempURL(self), defaults = makeDefaults(self)
        let sentence = "This is a fairly typical dictation of about twenty words, the kind people send in chat all day."
        let entries = (0..<5_000).map {
            HistoryEntry(date: Date().addingTimeInterval(Double(-$0 * 60)), text: sentence, duration: 6)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entries).write(to: url)

        assertFaster(than: 0.25, "load 5k-entry history") {
            XCTAssertEqual(HistoryStore(fileURL: url, defaults: defaults).entries.count, 5_000)
        }
        let store = HistoryStore(fileURL: url, defaults: defaults)
        assertFaster(than: 0.25, iterations: 5, "add one entry to 5k history (includes save)") {
            store.add(text: sentence, duration: 6)
        }
        // Runs on every keystroke in Corrections, so it must not stall typing.
        let id = store.entries[2_500].id
        var n = 0
        assertFaster(than: 0.004, iterations: 20, "edit a correction in 5k history") {
            n += 1
            store.setCorrection("fixed \(n)", for: id)
        }
    }

    /// Also report XCTest's own metrics (visible in the test log; no pass/fail outside Xcode).
    func testMicLevelMetrics() {
        let buffer = AudioLevelTests.buffer(amplitude: 0.2)
        measure(metrics: [XCTClockMetric(), XCTCPUMetric()]) {
            for _ in 0..<1_000 { _ = SpeechEngine.level(of: buffer) }
        }
    }
}
