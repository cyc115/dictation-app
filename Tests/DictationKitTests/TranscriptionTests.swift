import AVFoundation
import XCTest
@testable import DictationKit

final class TranscriptionModelTests: XCTestCase {
    func testCapabilities() {
        XCTAssertFalse(TranscriptionModel.local.isCloud)
        XCTAssertTrue(TranscriptionModel.local.supportsStreaming)
        XCTAssertTrue(TranscriptionModel.local.supportsLanguageChoice)
        XCTAssertEqual(TranscriptionModel.metaMuse.openRouterID, "meta/muse-voice-transcribe-1.0")
        XCTAssertFalse(TranscriptionModel.metaMuse.supportsStreaming)
        XCTAssertFalse(TranscriptionModel.metaMuse.supportsLanguageChoice)
        XCTAssertEqual(TranscriptionModel.qwenASR.openRouterID, "qwen/qwen3-asr-1.7b")
        for model in TranscriptionModel.allCases where model.isCloud {
            XCTAssertFalse(model.supportsStreaming, "\(model) is batch")
            XCTAssertFalse(model.supportsLanguageChoice, "\(model) detects the language")
            XCTAssertNotNil(model.provider, "\(model) needs a provider for the privacy note")
            XCTAssertNotNil(model.costPerAudioHour, "\(model) needs a price")
        }
        XCTAssertNil(TranscriptionModel.local.provider)
    }

    func testQwenPersists() {
        let defaults = makeDefaults(self)
        AppSettings(defaults: defaults, secrets: InMemorySecretStore()).transcriptionModel = .qwenASR
        XCTAssertEqual(AppSettings(defaults: defaults, secrets: InMemorySecretStore()).transcriptionModel, .qwenASR)
    }
}

final class ModelSettingsTests: XCTestCase {
    func testDefaultsAndPersistence() {
        let defaults = makeDefaults(self)
        let s = AppSettings(defaults: defaults, secrets: InMemorySecretStore())
        XCTAssertEqual(s.transcriptionModel, .local)
        XCTAssertEqual(s.localLanguage, .english)
        s.transcriptionModel = .metaMuse
        s.localLanguage = .mandarin
        let r = AppSettings(defaults: defaults, secrets: InMemorySecretStore())
        XCTAssertEqual(r.transcriptionModel, .metaMuse)
        XCTAssertEqual(r.localLanguage, .mandarin)
    }

    func testStreamingDisabledForCloudButRemembered() {
        let s = AppSettings(defaults: makeDefaults(self), secrets: InMemorySecretStore())
        s.streamWhileSpeaking = true
        XCTAssertTrue(s.effectiveStreaming)
        s.transcriptionModel = .metaMuse
        XCTAssertFalse(s.effectiveStreaming, "batch model can't stream")
        XCTAssertTrue(s.streamWhileSpeaking, "the saved preference survives")
        s.transcriptionModel = .local
        XCTAssertTrue(s.effectiveStreaming, "and comes back with the local model")
    }

    func testAPIKeyGoesToSecretStoreNotDefaults() {
        let defaults = makeDefaults(self)
        let secrets = InMemorySecretStore()
        let s = AppSettings(defaults: defaults, secrets: secrets)
        XCTAssertFalse(s.hasOpenRouterKey)
        s.setOpenRouterKey("  sk-or-v1-test  ")
        XCTAssertTrue(s.hasOpenRouterKey)
        XCTAssertEqual(secrets.get(AppSettings.openRouterAccount), "sk-or-v1-test")
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { "\($0)".contains("sk-or") })
        s.setOpenRouterKey("")
        XCTAssertFalse(s.hasOpenRouterKey)
    }
}

final class OpenRouterClientTests: XCTestCase {
    func testParsesTranscript() throws {
        let data = Data(#"{"text":"帮我build一个","usage":{"seconds":3.7,"cost":0.000185}}"#.utf8)
        let r = try OpenRouterClient.parse(data: data, status: 200).get()
        XCTAssertEqual(r, TranscriptionResult(text: "帮我build一个", audioSeconds: 3.7, cost: 0.000185))
    }

    func testFriendlyErrors() {
        func message(_ status: Int, _ body: String) -> String {
            guard case .failure(let e) = OpenRouterClient.parse(data: Data(body.utf8), status: status) else { return "success?" }
            return e.localizedDescription
        }
        XCTAssertTrue(message(401, #"{"error":{"message":"User not found."}}"#).contains("API key"))
        XCTAssertTrue(message(402, "{}").contains("credits"))
        XCTAssertTrue(message(403, #"{"error":{"message":"requires 18+ age confirmation"}}"#).contains("18+"))
        XCTAssertTrue(message(500, "oops").contains("HTTP 500"))
    }

    func testCleanupFixesDoubledPunctuation() {
        XCTAssertEqual(OpenRouterClient.cleanup("from today's meeting??"), "from today's meeting?")
        XCTAssertEqual(OpenRouterClient.cleanup("from today's meeting?."), "from today's meeting?")
        XCTAssertEqual(OpenRouterClient.cleanup(" 好的。。 "), "好的。")
        XCTAssertEqual(OpenRouterClient.cleanup("Version 1.0.14 works."), "Version 1.0.14 works.")
    }

    func testMultipartBody() {
        let (body, boundary) = OpenRouterClient.multipart(model: "meta/muse-voice-transcribe-1.0", audio: Data([1, 2, 3]), filename: "a.wav")
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("--\(boundary)\r\n"))
        XCTAssertTrue(text.contains("name=\"model\"\r\n\r\nmeta/muse-voice-transcribe-1.0\r\n"))
        XCTAssertTrue(text.contains("filename=\"a.wav\"\r\nContent-Type: audio/wav\r\n\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n--\(boundary)--\r\n"))
    }
}

final class WAVRecorderTests: XCTestCase {
    func testConvertsMicBuffersTo16kMonoWAV() throws {
        let url = makeTempURL(self, "rec.wav")
        let recorder = try WAVRecorder(url: url)
        // 1 second of 48 kHz stereo, like a typical mic.
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        for _ in 0..<47 {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
            buffer.frameLength = 1024
            recorder.append(buffer)
        }
        XCTAssertEqual(recorder.duration, 47 * 1024 / 48_000, accuracy: 0.05)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF", "Meta requires a RIFF/WAVE container")
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
    }

    /// Regression: the app uploaded the WAV while it was still open, so its header declared
    /// 0 bytes of audio. Meta tolerated that; Qwen rejected it as "malformed audio".
    func testFinishWritesCompleteHeaderWhileRecorderIsStillAlive() throws {
        let url = makeTempURL(self, "rec.wav")
        let recorder = try WAVRecorder(url: url)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        for _ in 0..<30 {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
            buffer.frameLength = 1024
            recorder.append(buffer)
        }
        recorder.finish()
        let data = try Data(contentsOf: url)  // read while `recorder` is still referenced, like the upload
        func u32(_ at: Int) -> Int { Int(data[at]) | Int(data[at + 1]) << 8 | Int(data[at + 2]) << 16 | Int(data[at + 3]) << 24 }
        XCTAssertEqual(u32(4), data.count - 8, "RIFF size must match the file")
        let dataChunk = try XCTUnwrap(data.range(of: Data("data".utf8))).lowerBound
        XCTAssertEqual(u32(dataChunk + 4), Int(recorder.framesWritten) * 2, "data size must match the samples")
        recorder.append(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!)  // ignored after finish
        XCTAssertEqual(try Data(contentsOf: url).count, data.count)
    }
}

/// Runs the real CloudEngine stop → upload path with a fake client that inspects the WAV at
/// the moment of upload. Regression for "Provider could not process the audio input": the
/// file was uploaded unfinished (header declaring 0 bytes), which Qwen rejects.
final class CloudEngineTests: XCTestCase {
    final class FakeClient: TranscriptionClient {
        var uploaded: Data?
        var model: String?
        var result: Result<TranscriptionResult, Error> = .success(TranscriptionResult(text: "ok", audioSeconds: nil, cost: nil))
        func transcribe(wav: URL, model: String, apiKey: String,
                        completion: @escaping (Result<TranscriptionResult, Error>) -> Void) -> URLSessionTask? {
            uploaded = try? Data(contentsOf: wav)  // read exactly when a real upload would
            self.model = model
            DispatchQueue.main.async { completion(self.result) }
            return nil
        }
    }

    private func feedSpeech(_ engine: CloudEngine, seconds: Double) {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        for _ in 0..<Int(seconds * 48_000 / 1024) {
            engine.record(AudioLevelTests.buffer(amplitude: 0.2))  // 48 kHz mono, 1024 frames
            _ = format
        }
    }

    private func u32(_ d: Data, _ at: Int) -> Int {
        Int(d[at]) | Int(d[at + 1]) << 8 | Int(d[at + 2]) << 16 | Int(d[at + 3]) << 24
    }

    func testUploadedWAVIsCompleteAndWellFormed() throws {
        let engine = CloudEngine()
        let fake = FakeClient()
        engine.client = fake
        engine.modelID = "qwen/qwen3-asr-1.7b"
        XCTAssertTrue(engine.beginRecording())
        feedSpeech(engine, seconds: 1)
        let done = expectation(description: "stopped")
        var text: String?
        engine.stop(completion: { text = $0; done.fulfill() }, failure: { XCTFail($0); done.fulfill() })
        wait(for: [done], timeout: 2)

        XCTAssertEqual(text, "ok")
        XCTAssertEqual(fake.model, "qwen/qwen3-asr-1.7b")
        let wav = try XCTUnwrap(fake.uploaded)
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(u32(wav, 4), wav.count - 8, "RIFF size must match the uploaded file")
        let dataChunk = try XCTUnwrap(wav.range(of: Data("data".utf8))).lowerBound
        let declared = u32(wav, dataChunk + 4)
        XCTAssertGreaterThan(declared, 0, "header must not declare an empty recording")
        XCTAssertEqual(declared, wav.count - dataChunk - 8, "data size must cover all the audio")
        XCTAssertEqual(Double(declared) / 2 / 16_000, 1.0, accuracy: 0.05, "16 kHz 16-bit mono")
    }

    func testTooShortRecordingSkipsUpload() {
        let engine = CloudEngine()
        let fake = FakeClient()
        engine.client = fake
        XCTAssertTrue(engine.beginRecording())
        feedSpeech(engine, seconds: 0.1)
        let done = expectation(description: "stopped")
        engine.stop(completion: { XCTAssertEqual($0, ""); done.fulfill() }, failure: { _ in done.fulfill() })
        wait(for: [done], timeout: 2)
        XCTAssertNil(fake.uploaded, "a tap of the key shouldn't cost an API call")
    }

    func testUploadErrorReachesFailure() {
        let engine = CloudEngine()
        let fake = FakeClient()
        fake.result = .failure(TranscriptionError.message("Provider could not process the audio input"))
        engine.client = fake
        XCTAssertTrue(engine.beginRecording())
        feedSpeech(engine, seconds: 1)
        let done = expectation(description: "stopped")
        engine.stop(completion: { _ in XCTFail("should fail"); done.fulfill() },
                    failure: { XCTAssertTrue($0.contains("Provider")); done.fulfill() })
        wait(for: [done], timeout: 2)
    }

    /// Same path against the real API. Opt-in: LIVE_OPENROUTER=1 OPENROUTER_KEY=…
    func testLiveUploadThroughCloudEngine() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["LIVE_OPENROUTER"] == "1", let key = env["OPENROUTER_KEY"] else {
            throw XCTSkip("set LIVE_OPENROUTER=1 and OPENROUTER_KEY to run")
        }
        let src = try AVAudioFile(forReading: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../bench/audio/mixed-01.wav").standardized)
        let input = AVAudioPCMBuffer(pcmFormat: src.processingFormat, frameCapacity: AVAudioFrameCount(src.length))!
        try src.read(into: input)
        for model in TranscriptionModel.allCases where model.isCloud {
            let engine = CloudEngine()
            engine.modelID = model.openRouterID!
            engine.apiKey = key
            XCTAssertTrue(engine.beginRecording())
            engine.record(input)  // 16 kHz clip; WAVRecorder converts whatever the mic format is
            let done = expectation(description: "\(model)")
            var text = ""
            engine.stop(completion: { text = $0; done.fulfill() },
                        failure: { XCTFail("\(model): \($0)"); done.fulfill() })
            wait(for: [done], timeout: 60)
            XCTAssertTrue(text.lowercased().contains("repository"), "\(model): \(text)")
        }
    }
}
