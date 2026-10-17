import AVFoundation
import XCTest
@testable import DictationKit

/// CoreAudio can stop the input right after start (seen on a USB headset ~60 ms in), leaving a flat
/// waveform until the next press. MicCapture reopens it. No real microphone here: `openInput` is faked.
final class MicCaptureTests: XCTestCase {
    final class FakeInput: MicInput {
        let device: AudioDeviceID
        let stopped: () -> Void
        var isRunning = true
        init(device: AudioDeviceID, stopped: @escaping () -> Void) { self.device = device; self.stopped = stopped }
        func stop() { isRunning = false }
        /// CoreAudio stopping it.
        func dropOut() { isRunning = false; stopped() }
    }

    private var opened: [FakeInput] = []
    /// What each opened input delivers to (index matches `opened`).
    private var deliver: [(AVAudioPCMBuffer) -> Void] = []

    static let wired = AudioInputDevice(id: 11, uid: "wired", name: "USB Mic")
    static let buds = AudioInputDevice(id: 12, uid: "buds", name: "Mike’s Pixel Buds Pro", isBluetooth: true)
    static let builtIn = AudioInputDevice(id: 13, uid: "builtin", name: "MacBook Pro Microphone")

    /// `mic`: what start() finds (nil: this Mac's real devices).
    private func capture(failing: Bool = false, mic chosen: AudioInputDevice? = MicCaptureTests.wired) -> MicCapture {
        let mic = MicCapture()
        if let chosen { mic.resolveInput = { _ in chosen } }
        mic.fallbackInput = { _ in Self.builtIn }
        mic.openInput = { [unowned self] device, deliver, stopped in
            if failing { throw TranscriptionError.message("no mic") }
            let input = FakeInput(device: device, stopped: stopped)
            opened.append(input)
            self.deliver.append(deliver)
            return input
        }
        return mic
    }

    private static func buffer(rate: Double = 48_000, amplitude: Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let frames = AVAudioFrameCount(rate * HALInput.chunkSeconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = amplitude * sin(Float(i) * 0.05) }
        return buffer
    }

    func testReportsLiveOnceOnTheFirstRealAudio() throws {
        let mic = capture()
        var events: [MicEvent] = []
        try mic.start(inputUID: "", onBuffer: { _ in }, onEvent: { events.append($0) }, onError: { XCTFail($0) })
        deliver[0](Self.buffer(amplitude: 0))  // a headset switching modes sends zeros
        spinRunLoop(0.05)
        XCTAssertEqual(events, [])
        XCTAssertFalse(mic.isLive)
        deliver[0](Self.buffer(amplitude: 0.01))
        deliver[0](Self.buffer(amplitude: 0.2))
        spinRunLoop(0.05)
        XCTAssertEqual(events, [.live])
        XCTAssertTrue(mic.isLive)
        mic.stop()
    }

    /// A Bluetooth mic that never sends audio: the dictation moves to the built-in mic.
    func testSilentBluetoothMicFallsBackToTheBuiltInMic() throws {
        let mic = capture(mic: Self.buds)
        mic.fallbackAfter = 0.05
        var events: [MicEvent] = []
        try mic.start(inputUID: "buds", onBuffer: { _ in }, onEvent: { events.append($0) }, onError: { XCTFail($0) })
        deliver[0](Self.buffer(rate: 16_000, amplitude: 0))
        waitUntil { events.count == 1 }
        XCTAssertEqual(events, [.switched(to: "MacBook Pro Microphone")])
        XCTAssertEqual(opened.map(\.device), [Self.buds.id, Self.builtIn.id])
        XCTAssertFalse(opened[0].isRunning, "the silent mic is closed")
        XCTAssertEqual(mic.device, Self.builtIn)
        opened[1].dropOut()
        XCTAssertEqual(opened.last?.device, Self.builtIn.id, "a restart reopens the mic it moved to")
        mic.stop()
    }

    func testLiveBluetoothMicIsKept() throws {
        let mic = capture(mic: Self.buds)
        try mic.start(inputUID: "buds", onBuffer: { _ in }, onError: { XCTFail($0) })
        deliver[0](Self.buffer(amplitude: 0.1))
        mic.fallBackIfSilent()
        XCTAssertEqual(opened.count, 1)
        mic.stop()
    }

    func testWiredMicNeverFallsBack() throws {
        let mic = capture(mic: Self.wired)
        mic.fallbackAfter = 0.01
        try mic.start(inputUID: "", onBuffer: { _ in }, onError: { XCTFail($0) })
        spinRunLoop(0.1)
        XCTAssertEqual(opened.count, 1, "only Bluetooth mics are given up on")
        mic.stop()
    }

    func testStopCancelsTheFallback() throws {
        let mic = capture(mic: Self.buds)
        mic.fallbackAfter = 0.05
        try mic.start(inputUID: "buds", onBuffer: { _ in }, onError: { XCTFail($0) })
        mic.stop()
        spinRunLoop(0.15)
        XCTAssertEqual(opened.count, 1)
    }

    func testNoFallbackWhenThereIsNoBetterMic() throws {
        let mic = capture(mic: Self.buds)
        mic.fallbackInput = { _ in nil }  // e.g. lid closed and no other mic
        try mic.start(inputUID: "buds", onBuffer: { _ in }, onError: { XCTFail($0) })
        mic.fallBackIfSilent()
        XCTAssertEqual(opened.count, 1)
        XCTAssertTrue(opened[0].isRunning)
        mic.stop()
    }

    /// After a switch to a mic at another rate, the engine still gets the dictation's first format.
    func testAudioKeepsOneFormatAcrossASwitch() throws {
        let mic = capture(mic: Self.buds)
        var formats: [Double] = []
        var frames: [AVAudioFrameCount] = []
        try mic.start(inputUID: "buds", onBuffer: { formats.append($0.format.sampleRate); frames.append($0.frameLength) },
                      onError: { XCTFail($0) })
        deliver[0](Self.buffer(rate: 16_000, amplitude: 0))
        mic.fallBackIfSilent()
        for _ in 0..<3 { deliver[1](Self.buffer(rate: 48_000, amplitude: 0.2)) }
        XCTAssertEqual(formats, [16_000, 16_000, 16_000, 16_000])
        XCTAssertGreaterThan(frames.dropFirst().reduce(0, +), 2 * frames[0], "converted, not dropped")
        mic.stop()
    }

    func testReopensWhenCoreAudioStopsTheInput() throws {
        let mic = capture()
        try mic.start(inputUID: "", onBuffer: { _ in }, onError: { XCTFail($0) })
        XCTAssertEqual(opened.count, 1)
        opened[0].dropOut()
        XCTAssertEqual(opened.count, 2)
        XCTAssertEqual(mic.restarts, 1)
        XCTAssertTrue(mic.input === opened[1])
        mic.stop()
        XCTAssertFalse(opened[1].isRunning)
    }

    func testGivesUpAfterMaxRestarts() throws {
        let mic = capture()
        var errors: [String] = []
        try mic.start(inputUID: "", onBuffer: { _ in }, onError: { errors.append($0) })
        for _ in 0...MicCapture.maxRestarts { opened.last!.dropOut() }
        XCTAssertEqual(opened.count, 1 + MicCapture.maxRestarts)
        XCTAssertEqual(errors, ["The microphone stopped. Try again."], "says the mic stopped instead of showing a silent flat line")
        XCTAssertNil(mic.input)
    }

    func testIgnoresStopsAfterStopAndFromOldInputs() throws {
        let mic = capture()
        try mic.start(inputUID: "", onBuffer: { _ in }, onError: { XCTFail($0) })
        let first = opened[0]
        try mic.start(inputUID: "", onBuffer: { _ in }, onError: { XCTFail($0) })
        first.dropOut()  // a late notice from a finished dictation
        XCTAssertEqual(opened.count, 2)
        mic.stop()
        opened[1].dropOut()
        XCTAssertEqual(opened.count, 2)
        XCTAssertNil(mic.input)
    }

    func testNewDictationResetsRestartCount() throws {
        let mic = capture()
        try mic.start(inputUID: "", onBuffer: { _ in }, onError: { XCTFail($0) })
        opened[0].dropOut()
        try mic.start(inputUID: "", onBuffer: { _ in }, onError: { XCTFail($0) })
        XCTAssertEqual(mic.restarts, 0)
        mic.stop()
    }

    func testFailedStartThrowsAndLeavesNothingOpen() {
        let mic = capture(failing: true)
        XCTAssertThrowsError(try mic.start(inputUID: "", onBuffer: { _ in }, onError: { _ in }))
        XCTAssertNil(mic.input)
    }

    /// The bug: with Bluetooth headphones as the output, picking the MacBook's mic recorded the
    /// headphones' mic instead. The chosen mic's device is what gets opened.
    func testOpensTheChosenMicElseTheDefault() throws {
        let devices = AudioDevices.inputDevices()
        guard let chosen = devices.first(where: { $0.id != AudioDevices.defaultInputDevice() }) ?? devices.first else {
            throw XCTSkip("no microphones on this Mac")
        }
        let mic = capture(mic: nil)
        try mic.start(inputUID: chosen.uid, onBuffer: { _ in }, onError: { XCTFail($0) })
        XCTAssertEqual(opened.last?.device, chosen.id)
        try mic.start(inputUID: "not-connected", onBuffer: { _ in }, onError: { XCTFail($0) })
        XCTAssertEqual(opened.last?.device, AudioDevices.defaultInputDevice())
        mic.stop()
    }

    func testCloudEngineReportsAMicThatWontOpen() {
        let engine = CloudEngine()
        engine.mic.openInput = { _, _, _ in throw TranscriptionError.message("no mic") }
        var error: String?
        engine.start(inputUID: "", onLevel: { _ in }, onMic: { _ in }, onUtterance: nil, onError: { error = $0 })
        XCTAssertEqual(error, "could not open microphone: no mic")
        engine.cancel()
    }
}

final class AudioChunkerTests: XCTestCase {
    /// Whatever size CoreAudio's I/O cycles are, chunks come out ~21 ms long, in order, with nothing lost.
    func testCutsAnyCycleSizeIntoEqualChunks() {
        for rate in [48_000.0, 44_100, 16_000] {
            var chunker = AudioChunker(format: AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!)
            var out: [Float] = []
            var sizes: Set<AVAudioFrameCount> = []
            var next: Float = 0
            for cycle in [512, 160, 4096, 1, 333] {
                let samples = (0..<cycle).map { _ -> Float in next += 1; return next }
                samples.withUnsafeBufferPointer { p in
                    chunker.append(p.baseAddress!, cycle) { chunk in
                        sizes.insert(chunk.frameLength)
                        out += UnsafeBufferPointer(start: chunk.floatChannelData![0], count: Int(chunk.frameLength))
                    }
                }
            }
            XCTAssertEqual(sizes, [chunker.chunkFrames], "\(rate)")
            XCTAssertEqual(Double(chunker.chunkFrames) / rate, HALInput.chunkSeconds, accuracy: 0.0001)
            XCTAssertEqual(out, (1...out.count).map(Float.init), "\(rate): in order, nothing dropped")
            XCTAssertGreaterThan(out.count, 5000 - Int(chunker.chunkFrames))
        }
    }
}

/// A real microphone through HALInput: it opens the device it's given (output untouched) and
/// delivers ~21 ms chunks of mono audio. Skipped where there's no microphone or no access to it.
final class HALInputTests: XCTestCase {
    func testRecordsFromTheGivenMicInChunks() throws {
        guard let device = AudioDevices.defaultInputDevice() else { throw XCTSkip("no microphone") }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw XCTSkip("no microphone access") }
        let got = expectation(description: "audio")
        got.assertForOverFulfill = false
        var chunks: [AVAudioPCMBuffer] = []
        let lock = NSLock()
        let input = try HALInput(device: device, deliver: { buffer in
            lock.lock(); chunks.append(buffer); let n = chunks.count; lock.unlock()
            if n >= 5 { got.fulfill() }
        }, stopped: {})
        wait(for: [got], timeout: 5)
        XCTAssertTrue(input.isRunning)
        input.stop()
        XCTAssertFalse(input.isRunning)
        lock.lock(); defer { lock.unlock() }
        let first = try XCTUnwrap(chunks.first)
        XCTAssertEqual(first.format.channelCount, 1)
        XCTAssertEqual(Double(first.frameLength) / first.format.sampleRate, HALInput.chunkSeconds, accuracy: 0.001)
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
        XCTAssertEqual(MicCapture.level(of: Self.buffer(amplitude: 0)), 0)
    }

    func testLoudSpeechIsFull() {
        XCTAssertEqual(MicCapture.level(of: Self.buffer(amplitude: 0.5)), 1)
    }

    func testQuietSpeechIsLowButVisible() {
        let level = MicCapture.level(of: Self.buffer(amplitude: 0.01))  // ≈ -43 dBFS
        XCTAssertGreaterThan(level, 0.1)
        XCTAssertLessThan(level, 0.3)
    }

    func testLevelRisesWithVolume() {
        let levels = [0.003, 0.01, 0.03, 0.1].map { MicCapture.level(of: Self.buffer(amplitude: Float($0))) }
        XCTAssertEqual(levels, levels.sorted())
        XCTAssertEqual(Set(levels).count, levels.count)
    }
}
