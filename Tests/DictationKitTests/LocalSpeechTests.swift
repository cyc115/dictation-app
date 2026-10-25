import AVFoundation
import HuggingFace
import XCTest
@testable import DictationKit

@MainActor
final class LocalSpeechTests: XCTestCase {
    private func model(downloaded: Bool = true) -> (LocalSpeechModel, FakeSpeechRuntime) {
        let runtime = FakeSpeechRuntime()
        if downloaded { runtime.directory = URL(fileURLWithPath: "/tmp/fake-model") }
        let model = LocalSpeechModel(repo: "test/qwen", runtime: runtime)
        model.onBattery = { false }
        return (model, runtime)
    }

    /// A 16 kHz WAV of `seconds`, recorded the way the app records (WAVRecorder).
    private func wav(seconds: Double = 2) throws -> URL {
        let url = makeTempURL(self, "clip.wav")
        let recorder = try WAVRecorder(url: url)
        for _ in 0..<Int(seconds * 47) { recorder.append(AudioLevelTests.buffer(amplitude: 0.2)) }
        recorder.finish()
        return url
    }

    // MARK: Memory

    func testKeptOnPowerUnloadedAfter30IdleMinutesOnBattery() {
        let keep = KeepLoaded()
        XCTAssertFalse(keep.shouldUnload(idle: 24 * 3600, onBattery: false), "on power: always ready")
        XCTAssertFalse(keep.shouldUnload(idle: 29 * 60, onBattery: true))
        XCTAssertTrue(keep.shouldUnload(idle: 30 * 60, onBattery: true))
    }

    func testIdleModelLeavesMemoryOnlyOnBattery() async throws {
        let (model, runtime) = model()
        var clock = Date(timeIntervalSince1970: 0)
        model.now = { clock }
        try await model.prepare().value
        XCTAssertEqual(model.state, .ready)
        clock += 3 * 3600
        model.unloadIfIdle()
        XCTAssertEqual(model.state, .ready, "on power it stays, however long it's idle")

        var battery = true
        model.onBattery = { battery }
        clock += 60
        await model.unloadIfIdle()?.value
        XCTAssertEqual(model.state, .onDisk)
        XCTAssertEqual(runtime.log.last, "unload")

        _ = try await model.transcribe(wav: wav())
        XCTAssertEqual(model.state, .ready, "loads again for the next dictation")
        XCTAssertEqual(runtime.log.suffix(2), ["load", "transcribe"])
        clock += 29 * 60
        model.unloadIfIdle()
        XCTAssertEqual(model.state, .ready, "used 29 minutes ago: kept")
        battery = false
        clock += 60 * 60
        model.unloadIfIdle()
        XCTAssertEqual(model.state, .ready, "plugged in again: kept")
    }

    // MARK: Download and load

    func testFirstUseDownloadsThenLoads() async throws {
        let (model, runtime) = model(downloaded: false)
        XCTAssertEqual(model.state, .notDownloaded)
        XCTAssertFalse(model.isDownloaded)
        runtime.holdDownload = true
        let preparing = model.prepare()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.state, .downloading(0.5))
        XCTAssertTrue(model.prepare() == preparing, "a second call joins the first")
        runtime.finishDownload()
        try await preparing.value
        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(runtime.log, ["download", "load"], "downloaded once")
        XCTAssertTrue(model.isDownloaded)
    }

    func testDictatingWhileItDownloadsSaysSoInsteadOfWaiting() async throws {
        let (model, runtime) = model(downloaded: false)
        runtime.holdDownload = true
        do {
            _ = try await model.transcribe(wav: wav())
            XCTFail("no text while downloading")
        } catch {
            XCTAssertEqual(error as? LocalSpeechError, .stillDownloading(0), "and the download starts")
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.state, .downloading(0.5))
        do {
            _ = try await model.transcribe(wav: wav())
        } catch {
            XCTAssertEqual(error.localizedDescription, "The on-device model is still downloading (50%). Dictate again once it's done.")
        }
        runtime.finishDownload()
        try await model.prepare().value
        let text = try await model.transcribe(wav: wav())
        XCTAssertEqual(text, "帮我 build 一下")
        XCTAssertEqual(runtime.log.filter { $0 == "download" }.count, 1)
    }

    func testFailedDownloadCanBeRetried() async throws {
        let (model, runtime) = model(downloaded: false)
        runtime.error = URLError(.notConnectedToInternet)
        do { try await model.prepare().value; XCTFail() } catch {}
        guard case .failed = model.state else { return XCTFail("\(model.state)") }
        runtime.error = nil
        try await model.prepare().value
        XCTAssertEqual(model.state, .ready)
    }

    func testOutputIsCappedByTheClipsLength() async throws {
        let (model, runtime) = model()
        _ = try await model.transcribe(wav: wav(seconds: 2))
        XCTAssertEqual(runtime.maxTokens.first, LocalSpeechModel.maxTokens(seconds: 2))
        XCTAssertEqual(LocalSpeechModel.maxTokens(seconds: 10), 214, "≈ 3× fast speech")
        XCTAssertEqual(LocalSpeechModel.maxTokens(seconds: 0.5), 71, "room for the shortest")
    }

    func testReadsTheAppsOwnRecordings() throws {
        let samples = try LocalSpeechModel.samples(wav(seconds: 1))
        XCTAssertEqual(Double(samples.count) / 16_000, 1, accuracy: 0.05)
        XCTAssertGreaterThan(samples.map(abs).max() ?? 0, 0.1)
    }

    // MARK: Engine

    /// The real LocalEngine.stop() path, as CloudBackupTests runs CloudEngine's.
    func testEngineTranscribesTheRecordingAndKeepsIt() throws {
        let (model, runtime) = model()
        let archive = RecordingArchive(directory: makeTempURL(self, "Recordings"))
        let engine = LocalEngine(model: model)
        engine.archive = archive
        XCTAssertTrue(engine.beginRecording())
        for _ in 0..<47 { engine.record(AudioLevelTests.buffer(amplitude: 0.2)) }  // 1 s
        let done = expectation(description: "stopped")
        var text: String?
        engine.stop(completion: { text = $0; done.fulfill() }, failure: { XCTFail($0); done.fulfill() })
        wait(for: [done], timeout: 3)
        XCTAssertEqual(text, "帮我 build 一下")
        XCTAssertEqual(engine.lastAnswer, ModelAnswer(main: "local:test/qwen"), "History names the model")
        XCTAssertEqual(runtime.log, ["load", "transcribe"])
        XCTAssertEqual(runtime.contexts, [""], "plain dictation: no context")
        waitUntil { archive.infos.count == 1 }
        XCTAssertEqual(archive.infos.first?.model, "local:test/qwen")
        XCTAssertEqual(archive.infos.first?.transcript, "帮我 build 一下")
    }

    /// A command's words reach the model as its context prompt.
    func testEnginePassesTheContextToTheModel() throws {
        let (model, runtime) = model()
        let engine = LocalEngine(model: model)
        engine.context = SpeechContext(words: ["press Enter", "brightness"])
        XCTAssertTrue(engine.beginRecording())
        for _ in 0..<47 { engine.record(AudioLevelTests.buffer(amplitude: 0.2)) }
        let done = expectation(description: "stopped")
        engine.stop(completion: { _ in done.fulfill() }, failure: { XCTFail($0); done.fulfill() })
        wait(for: [done], timeout: 3)
        XCTAssertEqual(runtime.contexts, [engine.context.prompt])
        XCTAssertEqual(engine.context.prompt, "press Enter, brightness")
    }

    func testEngineReportsAFailure() throws {
        let (model, runtime) = model()
        runtime.error = LocalSpeechError.notLoaded
        let engine = LocalEngine(model: model)
        XCTAssertTrue(engine.beginRecording())
        for _ in 0..<47 { engine.record(AudioLevelTests.buffer(amplitude: 0.2)) }
        let done = expectation(description: "stopped")
        var message: String?
        engine.stop(completion: { _ in XCTFail("no text"); done.fulfill() }, failure: { message = $0; done.fulfill() })
        wait(for: [done], timeout: 3)
        XCTAssertEqual(message, "The on-device model isn't loaded.")
        XCTAssertNil(engine.lastAnswer)
    }

    /// The real model on this Mac's GPU, through the app's own LocalEngine.stop(), on the bench's
    /// clips. Opt-in (`./test.sh --local`): the first run downloads the model (2.5 GB) into the same
    /// place the app keeps it.
    func testLiveLocalModelHearsEnglishChineseAndBoth() throws {
        guard ProcessInfo.processInfo.environment["LIVE_LOCAL_MODEL"] == "1" else {
            throw XCTSkip("set LIVE_LOCAL_MODEL=1 (./test.sh --local) to run")
        }
        let model = LocalSpeechModel(repo: DictationSetup.onDevice.localModelID!)
        let loaded = expectation(description: "downloaded and loaded")
        Task {
            do { try await model.prepare().value } catch { XCTFail("\(error)") }
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 1800)
        XCTAssertEqual(model.state, .ready)
        let bench = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../bench/audio")
        // A command's context (what command mode gives it) mustn't change what it hears in a dictation.
        let commandWords = CommandMode(folder: makeTempURL(self), history: HistoryStore(fileURL: makeTempURL(self), defaults: makeDefaults(self)))
            .speechContext()
        var clips = [("mixed-01", ["帮我", "build", "push", "repository"]), ("english-01", ["notes", "meeting"]), ("chinese-01", ["天气", "公园"])]
            .flatMap { clip, heard in [(bench.appendingPathComponent(clip + ".wav"), heard, SpeechContext.none),
                                       (bench.appendingPathComponent(clip + ".wav"), heard, commandWords)] }
        // Short commands (macOS's voice, so clean speech: this checks the context reaches the real model).
        for (name, said, heard) in [("enter", "Press Enter.", "enter"), ("brightness", "Reduce brightness.", "brightness")] {
            let wav = makeTempURL(self, name + ".wav")
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-o", wav.path, "--data-format=LEI16@16000", said]
            try say.run()
            say.waitUntilExit()
            clips.append((wav, [heard], commandWords))
        }
        for (wav, heard, context) in clips {
            let clip = wav.deletingPathExtension().lastPathComponent + (context == .none ? "" : " (command words)")
            let engine = LocalEngine(model: model)
            engine.context = context
            XCTAssertTrue(engine.beginRecording())
            XCTAssertTrue(LatencyRunner.read(wav, into: engine.record))
            let done = expectation(description: clip)
            var text = ""
            let started = Date()
            engine.stop(completion: { text = $0; done.fulfill() }, failure: { XCTFail("\(clip): \($0)"); done.fulfill() })
            wait(for: [done], timeout: 30)
            let seconds = Date().timeIntervalSince(started)
            print("[local] \(clip): \(String(format: "%.2f", seconds)) s — \(text)")
            for word in heard { XCTAssertTrue(text.lowercased().contains(word), "\(clip): \(text)") }
            XCTAssertLessThan(seconds, 3, "\(clip): stop to text")
            XCTAssertEqual(engine.lastAnswer, ModelAnswer(main: "local:mlx-community/Qwen3-ASR-1.7B-8bit"))
        }
    }

    /// A real download from Hugging Face into an empty cache, as on first use: the progress the
    /// Settings row shows rises to 1, then the model is on disk. Uses the small 0.6B 4-bit model.
    func testLiveFirstDownloadReportsProgress() throws {
        guard ProcessInfo.processInfo.environment["LIVE_LOCAL_MODEL"] == "1" else {
            throw XCTSkip("set LIVE_LOCAL_MODEL=1 (./test.sh --local) to run")
        }
        let cache = makeTempURL(self, "hub")
        let model = LocalSpeechModel(repo: "mlx-community/Qwen3-ASR-0.6B-4bit",
                                     runtime: MLXSpeechRuntime(cache: HubCache(cacheDirectory: cache)))
        XCTAssertEqual(model.state, .notDownloaded)
        var seen: [Double] = []
        let watching = model.$state.sink { if case .downloading(let fraction) = $0 { seen.append(fraction) } }
        defer { watching.cancel() }
        let done = expectation(description: "downloaded")
        Task {
            do { try await model.prepare().value } catch { XCTFail("\(error)") }
            done.fulfill()
        }
        wait(for: [done], timeout: 1200)
        print("[local] download progress: \(seen.count) updates, \(seen.prefix(3).map { String(format: "%.2f", $0) }) … \(seen.suffix(2).map { String(format: "%.2f", $0) })")
        XCTAssertGreaterThan(seen.count, 3, "progress while it downloads")
        XCTAssertEqual(seen, seen.sorted(), "never goes backwards")
        XCTAssertEqual(seen.last ?? 0, 1, accuracy: 0.01)
        XCTAssertEqual(model.state, .ready)
        XCTAssertTrue(model.isDownloaded)
    }

    // MARK: Setups

    func testOnDeviceRunsQwenOnThisMac() {
        let setup = DictationSetup.onDevice
        XCTAssertEqual(setup.localModelID, "mlx-community/Qwen3-ASR-1.7B-8bit")
        XCTAssertFalse(setup.isCloud)
        XCTAssertFalse(setup.usesCloud, "nothing leaves the Mac")
        XCTAssertEqual(ModelSpec("local:mlx-community/Qwen3-ASR-0.6B-8bit"), .local(id: "mlx-community/Qwen3-ASR-0.6B-8bit"))
        XCTAssertEqual(ModelSpec.local(id: "a/b").description, "local:a/b")
        XCTAssertNil(ModelSpec("local:"))
        XCTAssertEqual(ModelAnswer.displayName("local:mlx-community/Qwen3-ASR-1.7B-8bit"), "Qwen3-ASR-1.7B-8bit · on this Mac")
    }

    func testCustomSetupsCanNameALocalModelButOnlyForSpeech() throws {
        let url = makeTempURL(self, "setups.json")
        try Data("""
            {"setups": [
              {"id": "small", "title": "Small", "speech": "local:mlx-community/Qwen3-ASR-0.6B-8bit", "polish": "apple", "prompt": "v3"},
              {"id": "zh", "title": "Apple 中文", "speech": "apple:zh-CN", "polish": "apple", "prompt": "v3"},
              {"id": "bad", "title": "Bad", "speech": "apple", "polish": "local:x/y", "prompt": "v3"}
            ]}
            """.utf8).write(to: url)
        let loaded = DictationSetup.loadCustom(from: url)
        XCTAssertEqual(loaded.setups.map(\.id), ["small", "zh"])
        XCTAssertEqual(loaded.setups[0].localModelID, "mlx-community/Qwen3-ASR-0.6B-8bit")
        XCTAssertTrue(loaded.error?.contains("bad: polish must be") == true, loaded.error ?? "")
    }

    // MARK: Settings

    private func hostSettings(_ state: (FakeSpeechRuntime, LocalSpeechModel) -> Void = { _, _ in }) -> HostedView<SettingsView> {
        let runtime = FakeSpeechRuntime()
        let model = LocalSpeechModel(repo: DictationSetup.onDevice.localModelID!, runtime: runtime)
        state(runtime, model)
        let history = HistoryStore(fileURL: makeTempURL(self), defaults: makeDefaults(self))
        let hosted = HostedView(SettingsView(services: makeServices(self, settings: makeSettings(self, localModel: model), history: history)),
                                size: NSSize(width: 640, height: 2100))
        addTeardownBlock { hosted.close() }
        return hosted
    }

    func testSettingsShowsTheModelInsteadOfALanguage() {
        let hosted = hostSettings()
        XCTAssertNil(hosted.element(id: "setting.Language"), "Qwen hears both languages: nothing to pick")
        XCTAssertNotNil(hosted.element(id: "setting.On-device model"))
        XCTAssertTrue(hosted.allText.contains("2.5 GB from Hugging Face"), hosted.allText)
    }

    func testDownloadButtonStartsTheDownload() async throws {
        var fake: FakeSpeechRuntime!
        let hosted = hostSettings { runtime, _ in fake = runtime; runtime.holdDownload = true }
        let button = try XCTUnwrap(hosted.elements { $0.label == "Download" }.first)
        XCTAssertTrue(hosted.click(button))
        try await Task.sleep(for: .milliseconds(50))
        hosted.settle()
        XCTAssertEqual(fake.log, ["download"])
        XCTAssertTrue(hosted.allText.contains("Downloading the speech model from Hugging Face… 50%"), hosted.allText)
        fake.finishDownload()
        try await Task.sleep(for: .milliseconds(50))
        hosted.settle()
        XCTAssertTrue(hosted.allText.contains("Stays in memory"), hosted.allText)
    }
}
