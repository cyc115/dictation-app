import AVFoundation
import Foundation
import HuggingFace
import IOKit.ps
import MLX
import MLXAudioCore
import MLXAudioSTT

/// The On-device setup's speech model: Qwen3-ASR running on this Mac's GPU (MLX), the open weights
/// of Cloud Flash's model. It hears English and Chinese, mixed too, so there's no language to pick.
/// On 460 of your dictations (bench/results/local/README.md) the 1.7B took 0.95 s typical from stop
/// to text, with no network stalls, at Cloud Flash's accuracy.
///
/// Downloaded from Hugging Face the first time it's needed (2.5 GB), loaded while you speak, and
/// kept in memory (2.6 GB) as `KeepLoaded` says: indefinitely on power, 30 idle minutes on battery.
@MainActor
final class LocalSpeechModel: ObservableObject {
    enum State: Equatable {
        case notDownloaded
        /// 0…1.
        case downloading(Double)
        /// Downloaded, not in memory.
        case onDisk
        case loading
        /// In memory, ready to transcribe.
        case ready
        case failed(String)
    }

    /// One per model, shared by every setup that names it.
    static func named(_ repo: String) -> LocalSpeechModel {
        if let model = models[repo] { return model }
        let model = LocalSpeechModel(repo: repo)
        models[repo] = model
        return model
    }
    private static var models: [String: LocalSpeechModel] = [:]

    let repo: String
    @Published private(set) var state: State
    var keep = KeepLoaded()
    var onBattery: () -> Bool = PowerSource.onBattery
    var now: () -> Date = Date.init
    /// How often an idle model is checked for unloading.
    var idleCheckEvery: TimeInterval = 60

    private let runtime: SpeechRuntime
    private var lastUsed = Date.distantPast
    private var preparing: Task<Void, Error>?
    private var idleTimer: Timer?

    init(repo: String, runtime: SpeechRuntime = MLXSpeechRuntime()) {
        self.repo = repo
        self.runtime = runtime
        state = runtime.downloaded(repo) == nil ? .notDownloaded : .onDisk
    }

    /// As History and kept recordings name it: "local:<repo>".
    var name: String { ModelSpec.local(id: repo).description }

    var isDownloaded: Bool { runtime.downloaded(repo) != nil }
    var isDownloading: Bool { if case .downloading = state { return true }; return false }

    /// Downloads the model if it isn't yet, and loads it if it isn't in memory. Call it when a
    /// dictation starts, so loading overlaps with speaking. Safe to call again while it runs.
    @discardableResult
    func prepare() -> Task<Void, Error> {
        lastUsed = now()
        if let preparing { return preparing }
        if state == .ready { return Task {} }
        let task = Task { @MainActor in
            defer { self.preparing = nil }
            do {
                let directory: URL
                if let found = runtime.downloaded(repo) {
                    directory = found
                } else {
                    state = .downloading(0)
                    directory = try await runtime.download(repo) { fraction in
                        if self.isDownloading { self.state = .downloading(fraction) }
                    }
                }
                state = .loading
                try await runtime.load(directory)
                state = .ready
                startIdleTimer()
            } catch {
                state = .failed(error.localizedDescription)
                throw error
            }
        }
        preparing = task
        return task
    }

    /// The transcript of a 16 kHz mono WAV. While the model is still downloading this throws at once
    /// (`stillDownloading`) rather than holding your text for minutes; loading from disk is waited for.
    func transcribe(wav: URL) async throws -> String {
        lastUsed = now()
        switch state {
        case .notDownloaded, .failed:
            if runtime.downloaded(repo) == nil {
                prepare()
                throw LocalSpeechError.stillDownloading(0)
            }
        case .downloading(let fraction):
            throw LocalSpeechError.stillDownloading(fraction)
        case .onDisk, .loading, .ready:
            break
        }
        try await prepare().value
        let samples = try Self.samples(wav)
        let text = try await runtime.transcribe(samples, maxTokens: Self.maxTokens(seconds: Double(samples.count) / 16_000))
        lastUsed = now()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Enough for fast speech (about 5 tokens a second) three times over: a model stuck repeating
    /// itself stops there instead of running for minutes (the local 0.6B once wrote "ah, ah…" for 112 s).
    nonisolated static func maxTokens(seconds: Double) -> Int { 64 + Int(seconds * 15) }

    /// Drops the model from memory if `keep` says so (checked every `idleCheckEvery` while loaded).
    /// Returns the unloading, if it started.
    @discardableResult
    func unloadIfIdle() -> Task<Void, Never>? {
        guard state == .ready, preparing == nil,
              keep.shouldUnload(idle: now().timeIntervalSince(lastUsed), onBattery: onBattery()) else { return nil }
        idleTimer?.invalidate()
        idleTimer = nil
        state = .onDisk
        return Task { await runtime.unload() }
    }

    private func startIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: idleCheckEvery, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.unloadIfIdle() }
        }
        idleTimer?.tolerance = idleCheckEvery / 2
    }

    /// 16 kHz mono samples from a WAV the app recorded (`WAVRecorder`).
    nonisolated static func samples(_ wav: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: wav, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw LocalSpeechError.unreadableAudio
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { throw LocalSpeechError.unreadableAudio }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}

enum LocalSpeechError: LocalizedError, Equatable {
    case stillDownloading(Double)
    case unreadableAudio
    case notLoaded

    var errorDescription: String? {
        switch self {
        case .stillDownloading(let fraction):
            return "The on-device model is still downloading (\(Int(fraction * 100))%). Dictate again once it's done."
        case .unreadableAudio: return "Couldn't read the recording."
        case .notLoaded: return "The on-device model isn't loaded."
        }
    }
}

/// When the on-device model leaves memory: never while on power, so it's always ready; on battery,
/// after `batteryIdle` without a dictation, to give the 2.6 GB back. It loads again (about a second,
/// while you speak) on the next dictation.
struct KeepLoaded: Equatable {
    var batteryIdle: TimeInterval = 30 * 60

    func shouldUnload(idle: TimeInterval, onBattery: Bool) -> Bool {
        onBattery && idle >= batteryIdle
    }
}

enum PowerSource {
    /// This Mac is running on its battery (false on power, and on Macs without one).
    static func onBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }
}

// MARK: - Runtime

/// Where the model's work happens, so `LocalSpeechModel` can be tested without a GPU or a download.
protocol SpeechRuntime: AnyObject {
    /// The model's folder if it's fully downloaded, else nil.
    func downloaded(_ repo: String) -> URL?
    /// Downloads the model from Hugging Face; `progress` gets 0…1 on the main actor.
    func download(_ repo: String, progress: @escaping @MainActor (Double) -> Void) async throws -> URL
    func load(_ directory: URL) async throws
    func transcribe(_ samples: [Float], maxTokens: Int) async throws -> String
    func unload() async
}

/// Qwen3-ASR through mlx-audio-swift: one model in memory, one transcription at a time.
final class MLXSpeechRuntime: SpeechRuntime {
    private let worker = Worker()
    /// The Hugging Face cache (~/.cache/huggingface/hub, or $HF_HUB_CACHE); tests use an empty one.
    let cache: HubCache

    init(cache: HubCache = .default) { self.cache = cache }

    /// mlx-audio's own cache layout: <Hugging Face cache>/mlx-audio/<owner>_<name>.
    func directory(_ repo: String) -> URL {
        cache.cacheDirectory.appendingPathComponent("mlx-audio")
            .appendingPathComponent(repo.replacingOccurrences(of: "/", with: "_"))
    }

    func downloaded(_ repo: String) -> URL? {
        let directory = directory(repo)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let weights = files.contains { $0.pathExtension == "safetensors" && ((try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) > 0 }
        let config = files.contains { $0.lastPathComponent == "config.json" }
        return weights && config ? directory : nil
    }

    func download(_ repo: String, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        guard let id = Repo.ID(rawValue: repo) else { throw LocalSpeechError.notLoaded }
        return try await ModelUtils.resolveOrDownloadModel(
            client: HubClient(cache: cache), cache: cache, repoID: id, requiredExtension: "safetensors",
            progressHandler: { progress($0.fractionCompleted) })
    }

    func load(_ directory: URL) async throws { try await worker.load(directory) }

    func transcribe(_ samples: [Float], maxTokens: Int) async throws -> String {
        try await worker.transcribe(samples, maxTokens: maxTokens)
    }

    func unload() async { await worker.unload() }

    private actor Worker {
        private var model: Qwen3ASRModel?

        func load(_ directory: URL) async throws {
            guard model == nil else { return }
            let model = try await Qwen3ASRModel.fromModelDirectory(directory)
            // Buffers MLX keeps for reuse after a transcription; without a limit they hold on to
            // gigabytes between dictations.
            MLX.Memory.cacheLimit = 256 * 1024 * 1024
            // The first decode compiles the GPU kernels (6.4 s for a 3.5 s clip, then 0.4–0.6 s):
            // pay that here, while loading, rather than on the first dictation.
            _ = model.generate(audio: MLXArray.zeros([8_000]), generationParameters: STTGenerateParameters(maxTokens: 8, temperature: 0))
            self.model = model
        }

        func transcribe(_ samples: [Float], maxTokens: Int) throws -> String {
            guard let model else { throw LocalSpeechError.notLoaded }
            // No language: the model detects English, Chinese, or both.
            let output = model.generate(audio: MLXArray(samples),
                                        generationParameters: STTGenerateParameters(maxTokens: maxTokens, temperature: 0))
            return output.text
        }

        func unload() {
            model = nil
            MLX.Memory.clearCache()
        }
    }
}

// MARK: - Engine

/// Records the mic like `CloudEngine`, then transcribes on this Mac when you stop.
final class LocalEngine: RecordingEngine, DictationEngine {
    var model: LocalSpeechModel
    /// Which model gave the last transcript (set before `completion`).
    private(set) var lastAnswer: ModelAnswer?

    init(model: LocalSpeechModel) {
        self.model = model
    }

    override func start(inputUID: String, backups: Bool, onLevel: @escaping (Float) -> Void, onMic: @escaping (MicEvent) -> Void,
                        onError: @escaping (String) -> Void) {
        MainActor.assumeIsolated { _ = model.prepare() }  // loads while you speak
        super.start(inputUID: inputUID, backups: backups, onLevel: onLevel, onMic: onMic, onError: onError)
    }

    func stop(completion: @escaping (String) -> Void, failure: @escaping (String) -> Void) {
        guard let recording = finishRecording(completion: completion, failure: failure) else { return }
        let model = self.model
        var info = RecordingInfo(date: Date(), model: MainActor.assumeIsolated { model.name }, transcript: "", seconds: recording.duration)
        lastAnswer = nil
        Task { @MainActor [weak self] in
            do {
                let text = try await model.transcribe(wav: recording.url)
                info.transcript = text
                self?.lastAnswer = ModelAnswer(main: model.name)
                completion(text)
            } catch {
                info.error = error.localizedDescription
                failure(error.localizedDescription)
            }
            recording.done(info)  // after the text is delivered, as CloudEngine does
        }
    }
}
