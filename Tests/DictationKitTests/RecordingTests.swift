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

    private func cloudDictation(archive: RecordingArchive?, client: CapturingClient) {
        let engine = CloudEngine()
        engine.client = client
        engine.modelID = "qwen/qwen3-asr-1.7b"
        engine.archive = archive
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

    func testKeepRecordingsIsOffByDefaultAndPersists() {
        let defaults = makeDefaults(self)
        XCTAssertFalse(AppSettings(defaults: defaults, secrets: InMemorySecretStore()).keepRecordings)
        AppSettings(defaults: defaults, secrets: InMemorySecretStore()).keepRecordings = true
        XCTAssertTrue(AppSettings(defaults: defaults, secrets: InMemorySecretStore()).keepRecordings)
    }
}
