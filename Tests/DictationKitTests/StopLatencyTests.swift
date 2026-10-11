import XCTest
@testable import DictationKit

/// The two waits after you press stop that the latency baseline flagged
/// (bench/results/latency/BASELINE-pre-optimization.md).
final class OnDeviceStopTests: XCTestCase {
    /// Before: every dictation whose final result never came waited the full 2 s.
    func testFinishesOnceTheRecognizerHasGoneQuiet() {
        // Paused before pressing stop: nothing more is coming, finish after the minimum wait.
        XCTAssertEqual(SpeechEngine.remainingWait(sinceStop: 0, sinceLastResult: 1.5)!, 0.2, accuracy: 1e-9)
        XCTAssertNil(SpeechEngine.remainingWait(sinceStop: 0.2, sinceLastResult: 1.7))
        // Still talking at stop: wait until words stop arriving for settleDelay.
        XCTAssertEqual(SpeechEngine.remainingWait(sinceStop: 0.2, sinceLastResult: 0.05)!, 0.3, accuracy: 1e-9)
        XCTAssertNil(SpeechEngine.remainingWait(sinceStop: 0.5, sinceLastResult: 0.35))
    }

    func testNeverWaitsPastTheTimeout() {
        // Words keep trickling in: give up at 2 s, as before.
        XCTAssertEqual(SpeechEngine.remainingWait(sinceStop: 1.9, sinceLastResult: 0)!, 0.1, accuracy: 1e-9)
        XCTAssertNil(SpeechEngine.remainingWait(sinceStop: 2.0, sinceLastResult: 0))
    }

    func testTypicalStopIsWellUnderTheOldTwoSeconds() {
        // A result 0.1 s before stop and none after: done 0.25 s after stop.
        var waited = 0.0
        while let wait = SpeechEngine.remainingWait(sinceStop: waited, sinceLastResult: waited + 0.1) { waited += wait }
        XCTAssertEqual(waited, 0.25, accuracy: 1e-9)
    }
}
