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
}

/// Hits the real API. Opt-in: LIVE_OPENROUTER=1 OPENROUTER_KEY=… swift test --filter LiveOpenRouterTests
final class LiveOpenRouterTests: XCTestCase {
    func testMuseTranscribesMixedClip() throws { try transcribesMixedClip(.metaMuse) }
    func testQwenTranscribesMixedClip() throws { try transcribesMixedClip(.qwenASR) }

    private func transcribesMixedClip(_ model: TranscriptionModel) throws {
        let env = ProcessInfo.processInfo.environment
        guard env["LIVE_OPENROUTER"] == "1", let key = env["OPENROUTER_KEY"] else {
            throw XCTSkip("set LIVE_OPENROUTER=1 and OPENROUTER_KEY to run")
        }
        let wav = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../bench/audio/mixed-01.wav").standardized
        let done = expectation(description: "transcribed")
        var text = ""
        _ = OpenRouterClient().transcribe(wav: wav, model: model.openRouterID!, apiKey: key) { result in
            switch result {
            case .success(let r): text = r.text
            case .failure(let e): XCTFail(e.localizedDescription)
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 60)
        for word in ["build", "push", "repository"] {
            XCTAssertTrue(text.lowercased().contains(word), "missing \(word) in \(text)")
        }
    }
}
