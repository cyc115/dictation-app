import AVFoundation
import XCTest
@testable import DictationKit

/// CoreAudio can stop the engine right after start (seen on a USB headset: "iounit configuration
/// changed > stopping the engine" 63 ms in), leaving a flat waveform until the next press.
/// MicCapture restarts it. The engine is never really started here: `startEngine` is faked.
final class MicCaptureTests: XCTestCase {
    private var starts = 0

    private func capture(failing: Bool = false) -> MicCapture {
        let mic = MicCapture()
        mic.startEngine = { [unowned self] _ in
            starts += 1
            if failing { throw TranscriptionError.message("no mic") }
        }
        return mic
    }

    private func postConfigurationChange(_ engine: AVAudioEngine?) {
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))  // the observer runs on the main queue
    }

    func testRestartsWhenCoreAudioStopsTheEngine() throws {
        let mic = capture()
        try mic.start(inputUID: "", onBuffer: { _ in }, onError: { XCTFail($0) })
        XCTAssertEqual(starts, 1)
        postConfigurationChange(mic.engine)  // the fake never runs, so the engine reads as stopped
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(mic.restarts, 1)
        mic.stop()
    }

    func testGivesUpAfterMaxRestarts() throws {
        let mic = capture()
        var errors: [String] = []
        try mic.start(inputUID: "", onBuffer: { _ in }, onError: { errors.append($0) })
        for _ in 0...MicCapture.maxRestarts { postConfigurationChange(mic.engine) }
        XCTAssertEqual(starts, 1 + MicCapture.maxRestarts)
        XCTAssertEqual(errors.count, 1, "says the mic stopped instead of showing a silent flat line")
        mic.stop()
    }

    func testIgnoresChangesAfterStopAndFromOtherEngines() throws {
        let mic = capture()
        try mic.start(inputUID: "", onBuffer: { _ in }, onError: { XCTFail($0) })
        let old = mic.engine
        postConfigurationChange(AVAudioEngine())  // some other engine
        XCTAssertEqual(starts, 1)
        mic.stop()
        postConfigurationChange(old)  // a late notice from a finished dictation
        XCTAssertEqual(starts, 1)
        XCTAssertNil(mic.engine)
    }

    func testNewDictationResetsRestartCount() throws {
        let mic = capture()
        try mic.start(inputUID: "", onBuffer: { _ in }, onError: { XCTFail($0) })
        postConfigurationChange(mic.engine)
        try mic.start(inputUID: "", onBuffer: { _ in }, onError: { XCTFail($0) })
        XCTAssertEqual(mic.restarts, 0)
        mic.stop()
    }

    func testFailedStartThrowsAndLeavesNothingOpen() {
        let mic = capture(failing: true)
        XCTAssertThrowsError(try mic.start(inputUID: "", onBuffer: { _ in }, onError: { _ in }))
        XCTAssertNil(mic.engine)
    }

    func testCloudEngineReportsAMicThatWontOpen() {
        let engine = CloudEngine()
        engine.mic.startEngine = { _ in throw TranscriptionError.message("no mic") }
        var error: String?
        engine.start(inputUID: "", onLevel: { _ in }, onUtterance: nil, onError: { error = $0 })
        XCTAssertEqual(error, "could not open microphone: no mic")
        engine.cancel()
    }
}
