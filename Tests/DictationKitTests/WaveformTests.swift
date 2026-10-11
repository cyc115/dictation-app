import AppKit
import XCTest
@testable import DictationKit

/// The bars should move a lot for normal (often quiet) speech, but stay flat in silence.
/// Mic level is 0…1 for −50…−10 dBFS (MicCapture.level): 0.25 ≈ −40 dB, typical for a
/// laptop or desk mic at normal speaking distance.
final class WaveformTests: XCTestCase {
    private func push(_ w: WaveformView, _ levels: [Float]) { levels.forEach(w.push) }

    /// A speech-like level pattern (syllables and short gaps) around `base`.
    private func speech(_ base: Float, count: Int) -> [Float] {
        (0..<count).map { i in max(0, base * [1.0, 0.6, 1.2, 0.3, 0.9, 1.1, 0.2, 0.8][i % 8]) }
    }

    func testQuietSpeechStillMakesTallBars() {
        let w = WaveformView()
        push(w, speech(0.25, count: 40))
        XCTAssertGreaterThan(w.levels.max() ?? 0, 0.75, "quiet mic speech should reach most of the height")
    }

    func testSilenceStaysFlat() {
        let w = WaveformView()
        push(w, Array(repeating: 0, count: 40))
        XCTAssertEqual(w.levels.max(), 0)
        push(w, Array(repeating: 0.05, count: 40))  // room noise ≈ −48 dB
        XCTAssertLessThan(w.levels.max() ?? 1, 0.35, "background hiss must not look like talking")
    }

    func testBarsVaryWhileTalking() {
        let w = WaveformView()
        push(w, speech(0.3, count: 40))
        let mean = w.levels.reduce(0, +) / CGFloat(w.levels.count)
        let spread = sqrt(w.levels.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / CGFloat(w.levels.count))
        XCTAssertGreaterThan(spread, 0.08, "a flat row of equal bars looks dead")
    }

    func testAdaptsAfterLoudBurst() {
        let w = WaveformView()
        push(w, Array(repeating: 0.9, count: 20))   // someone laughs / coughs loudly
        push(w, speech(0.3, count: 150))            // ~3 s of normal speech after
        XCTAssertGreaterThan(w.levels.max() ?? 0, 0.6, "gain recovers so normal speech isn't tiny")
    }

    func testResetClearsGain() {
        let w = WaveformView()
        push(w, Array(repeating: 1, count: 30))
        w.reset()
        push(w, speech(0.25, count: 40))
        XCTAssertGreaterThan(w.levels.max() ?? 0, 0.75, "a new dictation doesn't inherit the old gain")
    }

    func testLevelsStayInRange() {
        let w = WaveformView()
        push(w, (0..<200).map { _ in Float.random(in: 0...1) })
        XCTAssertTrue(w.levels.allSatisfy { (0...1).contains($0) })
    }
}
