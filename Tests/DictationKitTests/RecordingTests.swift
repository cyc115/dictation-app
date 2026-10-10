import AVFoundation
import XCTest
@testable import DictationKit

/// "Keep recordings": finished dictations are kept with what was heard; everything else is deleted.
final class RecordingArchiveTests: XCTestCase {
    private func archive() -> RecordingArchive {
        RecordingArchive(directory: makeTempURL(self, "Recordings"))
    }

    private func wav(seconds: Double) throws -> URL {
        let url = makeTempURL(self, "\(UUID().uuidString).wav")
        let recorder = try WAVRecorder(url: url)
        for _ in 0..<Int(seconds * 48_000 / 1024) { recorder.append(AudioLevelTests.buffer(amplitude: 0.2)) }
        recorder.finish()
        return url
    }

    private func info(_ url: URL) throws -> RecordingInfo {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RecordingInfo.self, from: Data(contentsOf: url.deletingPathExtension().appendingPathExtension("json")))
    }

    func testKeepMovesTheWAVAndWritesWhatWasHeard() throws {
        let archive = archive()
        let source = try wav(seconds: 1)
        let date = fixedDate(2026, 10, 8, 22, 57)
        let kept = try XCTUnwrap(archive.keep(wav: source, info: RecordingInfo(
            date: date, model: "apple:en-US", transcript: "hello there", seconds: 1)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "moved, not copied")
        XCTAssertEqual(kept.deletingLastPathComponent().lastPathComponent, "Recordings")
        XCTAssertTrue(kept.lastPathComponent.hasPrefix("20261008-225700-"))
        let saved = try info(kept)
        XCTAssertEqual(saved.transcript, "hello there")
        XCTAssertEqual(saved.model, "apple:en-US")
        XCTAssertEqual(saved.date, date)
        XCTAssertEqual(archive.recordings.map(\.lastPathComponent), [kept.lastPathComponent])
    }

    func testSameMomentDoesNotOverwrite() throws {
        let archive = archive()
        let info = RecordingInfo(date: fixedDate(2026, 10, 8, 9, 0), model: "m", transcript: "", seconds: 1)
        let first = try XCTUnwrap(archive.keep(wav: try wav(seconds: 0.5), info: info))
        let second = try XCTUnwrap(archive.keep(wav: try wav(seconds: 0.5), info: info))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(archive.recordings.count, 2)
    }
}

final class KeepRecordingsEngineTests: XCTestCase {
    /// Answers with `result` and remembers which file it was given.
    final class CapturingClient: TranscriptionClient {
        var result: Result<TranscriptionResult, Error> = .success(TranscriptionResult(text: "帮我 build 一下", audioSeconds: nil, cost: nil))
        var uploaded: URL?
        func transcribe(wav: URL, model: String, apiKey: String,
                        completion: @escaping (Result<TranscriptionResult, Error>) -> Void) -> URLSessionTask? {
            uploaded = wav
            let result = self.result
            DispatchQueue.main.async { completion(result) }
            return nil
        }
    }

    private func cloudDictation(archive: RecordingArchive?, client: CapturingClient, note: RecordingNote? = nil) {
        let engine = CloudEngine()
        engine.client = client
        engine.modelID = "qwen/qwen3-asr-1.7b"
        engine.archive = archive
        engine.note = note
        XCTAssertTrue(engine.beginRecording())
        for _ in 0..<47 { engine.record(AudioLevelTests.buffer(amplitude: 0.2)) }  // 1 s
        let done = expectation(description: "stopped")
        engine.stop(completion: { _ in done.fulfill() }, failure: { _ in done.fulfill() })
        wait(for: [done], timeout: 2)
    }

    func testCloudDictationIsKeptWithItsTranscript() throws {
        let archive = RecordingArchive(directory: makeTempURL(self, "Recordings"))
        let client = CapturingClient()
        cloudDictation(archive: archive, client: client)
        let kept = try XCTUnwrap(archive.recordings.first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(client.uploaded).path))
        let json = try String(contentsOf: kept.deletingPathExtension().appendingPathExtension("json"), encoding: .utf8)
        XCTAssertTrue(json.contains("帮我 build 一下"))
        XCTAssertTrue(json.contains("openrouter:qwen\\/qwen3-asr-1.7b") || json.contains("openrouter:qwen/qwen3-asr-1.7b"))
        XCTAssertEqual(try AVAudioFile(forReading: kept).fileFormat.sampleRate, 16_000)
    }

    func testFailedCloudDictationIsKeptWithTheError() throws {
        let archive = RecordingArchive(directory: makeTempURL(self, "Recordings"))
        let client = CapturingClient()
        client.result = .failure(TranscriptionError.message("Provider could not process the audio input"))
        cloudDictation(archive: archive, client: client)
        let kept = try XCTUnwrap(archive.recordings.first)
        let json = try String(contentsOf: kept.deletingPathExtension().appendingPathExtension("json"), encoding: .utf8)
        XCTAssertTrue(json.contains("Provider could not process"))
    }

    func testCloudRecordingIsDeletedWhenNotKeeping() throws {
        let client = CapturingClient()
        cloudDictation(archive: nil, client: client)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(client.uploaded).path))
    }

    func testOnDeviceDictationIsKeptOnlyWhenFinished() throws {
        let archive = RecordingArchive(directory: makeTempURL(self, "Recordings"))
        let engine = SpeechEngine()
        XCTAssertNil(engine.startRecording(), "nothing is written while Keep recordings is off")

        engine.archive = archive
        engine.localeIdentifier = "zh-CN"
        var recorder = try XCTUnwrap(engine.startRecording())
        for _ in 0..<47 { recorder.append(AudioLevelTests.buffer(amplitude: 0.2)) }  // what the mic tap does
        engine.finishRecording(transcript: "你好")
        XCTAssertEqual(archive.recordings.count, 1)
        let json = try String(contentsOf: archive.recordings[0].deletingPathExtension().appendingPathExtension("json"), encoding: .utf8)
        XCTAssertTrue(json.contains("apple:zh-CN") && json.contains("你好"))

        recorder = try XCTUnwrap(engine.startRecording())
        for _ in 0..<47 { recorder.append(AudioLevelTests.buffer(amplitude: 0.2)) }
        engine.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: recorder.url.path), "cancelled dictations are thrown away")

        recorder = try XCTUnwrap(engine.startRecording())
        recorder.append(AudioLevelTests.buffer(amplitude: 0.2))  // a tap of the key
        engine.finishRecording(transcript: "")
        XCTAssertEqual(archive.recordings.count, 1, "too short to keep")
    }

    private func info(_ wav: URL) throws -> RecordingInfo {
        try RecordingArchive.decoder.decode(RecordingInfo.self, from: Data(contentsOf: wav.deletingPathExtension().appendingPathExtension("json")))
    }

    func testCloudDictationKeepsRawAndPolishedTranscript() throws {
        let archive = RecordingArchive(directory: makeTempURL(self, "Recordings"))
        let note = RecordingNote(polishEnabled: true, polishModel: "openrouter:openai/gpt-oss-120b@Groq")
        cloudDictation(archive: archive, client: CapturingClient(), note: note)
        let kept = try XCTUnwrap(archive.recordings.first)
        var saved = try info(kept)
        XCTAssertEqual(saved.transcript, "帮我 build 一下")
        XCTAssertEqual(saved.polishEnabled, true)
        XCTAssertEqual(saved.polishModel, "openrouter:openai/gpt-oss-120b@Groq")
        XCTAssertNil(saved.polished, "polish hasn't finished yet")

        note.transcribed(seconds: 1.2)  // cloud: noted after the engine kept it
        XCTAssertEqual(try info(kept).transcribeSeconds, 1.2)
        note.polished("帮我 build 一下。", seconds: 0.4, error: nil)  // polish finishes after the recording is kept
        saved = try info(kept)
        XCTAssertEqual(saved.transcript, "帮我 build 一下", "the raw transcript stays")
        XCTAssertEqual(saved.polished, "帮我 build 一下。")
        XCTAssertEqual(saved.polishSeconds, 0.4)
        XCTAssertEqual(saved.transcribeSeconds, 1.2, "polish doesn't wipe the transcribe time")
        XCTAssertNil(saved.polishError)
        XCTAssertEqual(saved.model, "openrouter:qwen/qwen3-asr-1.7b")
    }

    func testPolishFinishingBeforeTheRecordingIsKeptIsStillSaved() throws {
        let archive = RecordingArchive(directory: makeTempURL(self, "Recordings"))
        let note = RecordingNote(polishEnabled: true, polishModel: "apple:on-device")
        note.transcribed(seconds: 0.35)  // on-device: noted before the engine keeps it
        note.polished("hello", seconds: 1, error: "Apple Intelligence isn't available on this Mac.")
        let engine = SpeechEngine()
        engine.archive = archive
        engine.note = note
        let recorder = try XCTUnwrap(engine.startRecording())
        engine.note = RecordingNote(polishEnabled: false, polishModel: nil)  // the next dictation starts first
        for _ in 0..<47 { recorder.append(AudioLevelTests.buffer(amplitude: 0.2)) }
        engine.finishRecording(transcript: "hello")
        let saved = try info(try XCTUnwrap(archive.recordings.first))
        XCTAssertEqual(saved.polishEnabled, true, "uses the note from when this recording started")
        XCTAssertEqual(saved.polished, "hello")
        XCTAssertEqual(saved.polishError, "Apple Intelligence isn't available on this Mac.")
        XCTAssertEqual(saved.transcribeSeconds, 0.35)
        XCTAssertEqual(saved.polishSeconds, 1)
    }

    func testPolishOffIsRecorded() throws {
        let archive = RecordingArchive(directory: makeTempURL(self, "Recordings"))
        cloudDictation(archive: archive, client: CapturingClient(),
                       note: RecordingNote(polishEnabled: false, polishModel: "apple:on-device"))
        let saved = try info(try XCTUnwrap(archive.recordings.first))
        XCTAssertEqual(saved.polishEnabled, false)
        XCTAssertNil(saved.polishModel, "no model when polish didn't run")
        XCTAssertNil(saved.polished)
    }

    func testOldRecordingsWithoutPolishStillDecode() throws {
        let json = #"{"date":"2026-10-08T22:57:00Z","model":"apple:en-US","seconds":1,"transcript":"hi"}"#
        let saved = try RecordingArchive.decoder.decode(RecordingInfo.self, from: Data(json.utf8))
        XCTAssertEqual(saved.transcript, "hi")
        XCTAssertNil(saved.polishEnabled)
    }

    func testKeepRecordingsIsOffByDefaultAndPersists() {
        let defaults = makeDefaults(self)
        XCTAssertFalse(AppSettings(defaults: defaults, secrets: InMemorySecretStore()).keepRecordings)
        AppSettings(defaults: defaults, secrets: InMemorySecretStore()).keepRecordings = true
        XCTAssertTrue(AppSettings(defaults: defaults, secrets: InMemorySecretStore()).keepRecordings)
    }
}

/// What kept recordings say about polish: which model, and why it fell back to the raw text.
final class PolishReportTests: XCTestCase {
    struct FailingPolish: PolishBackend {
        func polish(_ text: String) async throws -> String { throw PolishError.failed("HTTP 429") }
    }

    func testReportsWhyPolishFellBack() async {
        let (text, error) = await PolishService(backend: FailingPolish()).polishReporting("um hello")
        XCTAssertEqual(text, "um hello", "you still get your words")
        XCTAssertEqual(error, "HTTP 429")
    }

    func testModelNames() {
        XCTAssertEqual(PolishModel.cloud.backend(apiKey: "k", onDevice: OnDevicePolish()).name, "openrouter:openai/gpt-oss-120b@Groq")
        XCTAssertEqual(PolishModel.cloud.backend(apiKey: nil, onDevice: OnDevicePolish()).name, "apple:on-device")
    }
}
