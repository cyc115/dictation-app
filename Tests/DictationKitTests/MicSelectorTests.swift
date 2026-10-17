import AVFoundation
import XCTest
@testable import DictationKit

/// Which mic hears you best, from dB per buffer: speech rises over each mic's own noise.
final class MicSelectorTests: XCTestCase {
    /// `seconds` of syllables (160 ms on, 80 ms off): each mic at `speech` dBFS while you talk and
    /// `noise` dBFS between.
    private func talk(_ selector: inout MicSelector, _ mics: [(speech: Float, noise: Float)], seconds: Double) {
        for step in 0..<Int(seconds / HALInput.chunkSeconds) {
            let speaking = (Double(step) * HALInput.chunkSeconds).truncatingRemainder(dividingBy: 0.24) < 0.16
            for (index, mic) in mics.enumerated() { selector.add(speaking ? mic.speech : mic.noise, mic: index) }
        }
    }

    func testAMicThatHearsYouClearlyBetterWins() {
        var selector = MicSelector(mics: 2)
        talk(&selector, [(-48, -60), (-22, -62)], seconds: 1.5)  // laptop across the desk vs a headset
        XCTAssertEqual(selector.better(than: 0), 1)
    }

    func testGainDoesntMatterOnlyHowFarSpeechRisesOverNoise() {
        var selector = MicSelector(mics: 2)
        // Mic 1 is louder overall (hot gain) but its noise is loud too: no clearer.
        talk(&selector, [(-40, -70), (-15, -45)], seconds: 3)
        XCTAssertNil(selector.better(than: 0))
    }

    func testAboutAsGoodNeverWins() {
        var selector = MicSelector(mics: 2)
        talk(&selector, [(-30, -62), (-24, -62)], seconds: 5)  // 6 dB better: not enough
        XCTAssertNil(selector.better(than: 0))
    }

    func testABackupNeedsAFewWords() {
        var selector = MicSelector(mics: 2)
        talk(&selector, [(MicSelector.silence, MicSelector.silence), (-20, -60)], seconds: 0.5)
        XCTAssertNil(selector.better(than: 0), "half a second isn't enough to be sure")
        talk(&selector, [(MicSelector.silence, MicSelector.silence), (-20, -60)], seconds: 0.8)
        XCTAssertEqual(selector.better(than: 0), 1)
    }

    func testRoomNoiseAloneNeverWins() {
        var selector = MicSelector(mics: 3)
        talk(&selector, [(MicSelector.silence, MicSelector.silence), (-58, -60), (-50, -51)], seconds: 4)
        XCTAssertNil(selector.better(than: 0), "nobody's talking: stay put")
    }

    func testTheClearestOfSeveralWins() {
        var selector = MicSelector(mics: 3)
        talk(&selector, [(-55, -60), (-35, -62), (-20, -64)], seconds: 1.5)
        XCTAssertEqual(selector.better(than: 0), 2)
    }

    /// A Bluetooth mic sends zeros, then its noise: that jump isn't speech.
    func testAMicWakingUpFromZerosIsntSpeech() {
        var meter = MicSelector.Meter()
        for _ in 0..<40 { meter.add(MicSelector.silence) }
        for _ in 0..<40 { meter.add(-60) }
        XCTAssertEqual(meter.speech, 0)
    }

    func testDecibels() {
        XCTAssertEqual(MicSelector.decibels(of: AudioLevelTests.buffer(amplitude: 0)), MicSelector.silence)
        XCTAssertEqual(MicSelector.decibels(of: AudioLevelTests.buffer(amplitude: 0.1)), -23, accuracy: 0.5)  // sine RMS = A/√2
    }
}
