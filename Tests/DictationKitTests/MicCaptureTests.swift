import AVFoundation
import XCTest
@testable import DictationKit

/// CoreAudio can stop the input right after start (seen on a USB headset ~60 ms in), leaving a flat
/// waveform until the next press. MicCapture reopens it. No real microphone here: `openInput` is faked.
final class MicCaptureTests: XCTestCase {
    private var mics: FakeMics!
    private var opened: [FakeMics.Input] { mics.opened }
    private var deliver: [AudioDeviceID: (AVAudioPCMBuffer) -> Void] { mics.feeds }

    /// `mic`: what start() finds (nil: this Mac's real devices). `backups`: the other mics.
    private func capture(failing: Bool = false, mic chosen: AudioInputDevice? = FakeMics.wired,
                         backups: [AudioInputDevice] = [FakeMics.builtIn, FakeMics.webcam]) -> MicCapture {
        let mic = MicCapture()
        mics = FakeMics(mic, chosen: chosen, backups: backups, failing: failing)
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

    /// `seconds` of you talking (160 ms syllables, 80 ms pauses): each mic hears `voice[mic]` while
    /// you speak and faint room noise (`noise`, or exact zeros for a dead mic) between.
    private func talk(_ voice: [AudioDeviceID: Float], seconds: Double, noise: [AudioDeviceID: Float] = [:]) {
        let steps = Int(seconds / HALInput.chunkSeconds)
        for step in 0..<steps {
            let speaking = (Double(step) * HALInput.chunkSeconds).truncatingRemainder(dividingBy: 0.24) < 0.16
            for (device, loudness) in voice {
                deliver[device]?(Self.buffer(amplitude: speaking ? loudness : noise[device] ?? 0.0005))
            }
        }
    }

    func testReportsLiveOnceOnTheFirstRealAudio() throws {
        let mic = capture()
        var events: [MicEvent] = []
        try mic.start(inputUID: "", onBuffer: { _ in }, onEvent: { events.append($0) }, onError: { XCTFail($0) })
        deliver[FakeMics.wired.id]?(Self.buffer(amplitude: 0))  // a headset switching modes sends zeros
        spinRunLoop(0.05)
        XCTAssertEqual(events, [])
        XCTAssertFalse(mic.isLive)
        deliver[FakeMics.wired.id]?(Self.buffer(amplitude: 0.01))
        deliver[FakeMics.wired.id]?(Self.buffer(amplitude: 0.2))
        spinRunLoop(0.05)
        XCTAssertEqual(events, [.live])
        XCTAssertTrue(mic.isLive)
        mic.stop()
    }

    func testReportsAMicThatSendsNoAudio() throws {
        let mic = capture()
        mic.noAudioAfter = 0.05
        var events: [MicEvent] = []
        try mic.start(inputUID: "", onBuffer: { _ in }, onEvent: { events.append($0) }, onError: { XCTFail($0) })
        for _ in 0..<5 { deliver[FakeMics.wired.id]?(Self.buffer(amplitude: 0)) }
        waitUntil { events == [.noAudio] }
        deliver[FakeMics.wired.id]?(Self.buffer(amplitude: 0.1))
        waitUntil { events == [.noAudio, .live] }
        mic.stop()
    }

    func testNoAudioIsntReportedForALiveMicOrAfterStop() throws {
        let mic = capture()
        mic.noAudioAfter = 0.05
        var events: [MicEvent] = []
        try mic.start(inputUID: "", onBuffer: { _ in }, onEvent: { events.append($0) }, onError: { XCTFail($0) })
        deliver[FakeMics.wired.id]?(Self.buffer(amplitude: 0.001))  // a quiet room
        spinRunLoop(0.15)
        XCTAssertEqual(events, [.live])
        try mic.start(inputUID: "", onBuffer: { _ in }, onEvent: { events.append($0) }, onError: { XCTFail($0) })
        mic.stop()
        spinRunLoop(0.15)
        XCTAssertEqual(events, [.live])
    }

    func testBackupsRecordOnlyWhenAsked() throws {
        let mic = capture()
        try mic.start(inputUID: "", onBuffer: { _ in }, onError: { XCTFail($0) })
        XCTAssertEqual(mic.openDevices, [FakeMics.wired])
        try mic.start(inputUID: "", backups: true, onBuffer: { _ in }, onError: { XCTFail($0) })
        XCTAssertEqual(mic.openDevices, [FakeMics.wired, FakeMics.builtIn, FakeMics.webcam])
        mic.stop()
        XCTAssertTrue(opened.allSatisfy { !$0.isRunning })
    }

    /// The Pixel Buds are chosen but in their case; you're talking into the webcam's mic. The
    /// dictation moves to it and the engine starts over with everything it heard, from the start.
    func testMovesToTheMicThatHearsYouClearlyBetter() throws {
        let mic = capture(mic: FakeMics.buds)
        var events: [MicEvent] = []
        var frames = 0, restarts = 0
        try mic.start(inputUID: "buds", backups: true, onBuffer: { frames += Int($0.frameLength) },
                      onEvent: { events.append($0) }, onRestart: { restarts += 1; frames = 0; return true },
                      onError: { XCTFail($0) })
        talk([FakeMics.buds.id: 0.0005, FakeMics.builtIn.id: 0.004, FakeMics.webcam.id: 0.1], seconds: 2)
        waitUntil { events.contains(.switched(to: FakeMics.webcam)) }
        XCTAssertEqual(restarts, 1)
        XCTAssertEqual(mic.device, FakeMics.webcam)
        XCTAssertEqual(mic.openDevices, [FakeMics.webcam], "the other mics close")
        XCTAssertEqual(opened.filter(\.isRunning).map(\.device), [FakeMics.webcam.id])
        let replayed = Double(frames) / MicCapture.backupFormat.sampleRate
        XCTAssertGreaterThan(replayed, 1.5, "the engine gets the webcam's audio from the start, not just from the switch")
        talk([FakeMics.webcam.id: 0.1], seconds: 0.5)
        XCTAssertEqual(Double(frames) / MicCapture.backupFormat.sampleRate, replayed + 0.5, accuracy: 0.1,
                       "then live, in the same format")
        mic.stop()
    }

    func testAMicThatSendsZerosLosesToAnyMicThatHearsYou() throws {
        let mic = capture()
        var events: [MicEvent] = []
        try mic.start(inputUID: "", backups: true, onBuffer: { _ in }, onEvent: { events.append($0) },
                      onRestart: { true }, onError: { XCTFail($0) })
        talk([FakeMics.wired.id: 0, FakeMics.builtIn.id: 0.01, FakeMics.webcam.id: 0.0006], seconds: 1.5,
             noise: [FakeMics.wired.id: 0])
        waitUntil { events.contains(.switched(to: FakeMics.builtIn)) }
        mic.stop()
    }

    /// Both mics hear you, the chosen one a little less well (6 dB): no switch, ever.
    func testKeepsTheChosenMicWhenItHearsYouAboutAsWell() throws {
        let mic = capture()
        var events: [MicEvent] = []
        try mic.start(inputUID: "", backups: true, onBuffer: { _ in }, onEvent: { events.append($0) },
                      onRestart: { true }, onError: { XCTFail($0) })
        talk([FakeMics.wired.id: 0.05, FakeMics.builtIn.id: 0.02, FakeMics.webcam.id: 0.1], seconds: 4)
        spinRunLoop(0.1)
        XCTAssertFalse(events.contains { if case .switched = $0 { return true } else { return false } }, "\(events)")
        XCTAssertEqual(mic.openDevices.count, 3)
        mic.stop()
    }

    /// Text was already handed out: carry on with the better mic from the switch, so nothing is
    /// heard twice.
    func testWithoutARestartTheBetterMicCarriesOnFromNow() throws {
        let mic = capture()
        var frames = 0
        var events: [MicEvent] = []
        try mic.start(inputUID: "", backups: true, onBuffer: { frames += Int($0.frameLength) }, onEvent: { events.append($0) },
                      onRestart: { false }, onError: { XCTFail($0) })
        talk([FakeMics.wired.id: 0.002, FakeMics.builtIn.id: 0.0006, FakeMics.webcam.id: 0.1], seconds: 2)
        waitUntil { events.contains(.switched(to: FakeMics.webcam)) }
        let rate = 48_000.0  // the chosen mic's, kept for the whole dictation
        XCTAssertEqual(Double(frames) / rate, 2, accuracy: 0.15, "one stream: the old mic until the switch, then the new")
        mic.stop()
    }

    func testStopBeforeTheSwitchLandsDropsIt() throws {
        let mic = capture()
        var events: [MicEvent] = []
        var restarted = false
        try mic.start(inputUID: "", backups: true, onBuffer: { _ in }, onEvent: { events.append($0) },
                      onRestart: { restarted = true; return true }, onError: { XCTFail($0) })
        talk([FakeMics.wired.id: 0.0006, FakeMics.builtIn.id: 0.0006, FakeMics.webcam.id: 0.1], seconds: 2)
        mic.stop()  // before the main queue runs the switch
        spinRunLoop(0.1)
        XCTAssertFalse(restarted)
        XCTAssertFalse(events.contains(.switched(to: FakeMics.webcam)))
    }

    /// The real cloud path: after a switch, the uploaded WAV is the better mic's, from the start.
    func testCloudEngineUploadsTheBetterMicFromTheStart() throws {
        let engine = CloudEngine()
        let client = FakeTranscriptionClient(text: "hello")
        engine.client = client
        engine.modelID = CloudBackupTests.main
        mics = FakeMics(engine.mic, chosen: FakeMics.buds, backups: [FakeMics.webcam])
        var events: [MicEvent] = []
        engine.start(inputUID: "buds", backups: true, onLevel: { _ in }, onMic: { events.append($0) },
                     onError: { XCTFail($0) })
        talk([FakeMics.buds.id: 0.0005, FakeMics.webcam.id: 0.1], seconds: 2)
        waitUntil { events.contains(.switched(to: FakeMics.webcam)) }
        talk([FakeMics.webcam.id: 0.1], seconds: 1)
        let done = expectation(description: "transcribed")
        engine.stop(completion: { XCTAssertEqual($0, "hello"); done.fulfill() }, failure: { XCTFail($0); done.fulfill() })
        wait(for: [done], timeout: 3)
        let bytes = try XCTUnwrap(client.uploadedData).count - 44  // 16 kHz 16-bit mono after the header
        XCTAssertEqual(Double(bytes) / 2 / WAVRecorder.sampleRate, 3, accuracy: 0.15, "all 3 s, from the webcam")
    }

    func testABackupThatStopsIsLetGo() throws {
        let mic = capture()
        try mic.start(inputUID: "", backups: true, onBuffer: { _ in }, onError: { XCTFail($0) })
        opened[1].dropOut()
        XCTAssertEqual(opened.count, 3, "not reopened")
        XCTAssertEqual(mic.openDevices, [FakeMics.wired, FakeMics.webcam])
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
        engine.start(inputUID: "", backups: false, onLevel: { _ in }, onMic: { _ in }, onError: { error = $0 })
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
