import AVFoundation
import os

/// The microphone for one dictation: a fresh `AVAudioEngine` (so a newly chosen or reconnected mic
/// is picked up), the tap, and recovery when CoreAudio stops it.
///
/// CoreAudio often reconfigures the input unit just after start (~60–90 ms in on a USB headset).
/// Usually AVAudioEngine only posts `AVAudioEngineConfigurationChange`, but sometimes it stops itself
/// first — silently, so the whole dictation recorded nothing and the waveform stayed flat until the
/// next press. On that notice this re-installs the tap with the input's current format and restarts.
final class MicCapture {
    static let log = Logger(subsystem: "com.mikechen.DictationApp", category: "mic")
    /// Restarts allowed per dictation, so a device that keeps reconfiguring can't loop forever.
    static let maxRestarts = 3

    private(set) var engine: AVAudioEngine?
    private(set) var restarts = 0
    /// Tests swap this out to run without a microphone.
    var startEngine: (AVAudioEngine) throws -> Void = { try $0.start() }
    private var observer: NSObjectProtocol?
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var onError: ((String) -> Void)?

    deinit { stop() }

    /// Opens the mic. `inputUID` picks a microphone by CoreAudio UID; empty uses the system default.
    /// `onBuffer` runs on the audio thread; `onError` on the main queue, if a restart fails.
    func start(inputUID: String, onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
               onError: @escaping (String) -> Void) throws {
        stop()
        let engine = AVAudioEngine()
        if !inputUID.isEmpty, !AudioDevices.route(engine, toInputUID: inputUID) {
            Self.log.error("could not route to input \(inputUID, privacy: .public); using the default")
        }
        self.engine = engine
        self.onBuffer = onBuffer
        self.onError = onError
        restarts = 0
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self, weak engine] _ in
            guard let self = self, let engine = engine, engine === self.engine else { return }
            self.configurationChanged()
        }
        do {
            try run(engine)
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let observer = observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if let engine = engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
        onBuffer = nil
        onError = nil
    }

    /// Main queue. Restarts only if CoreAudio stopped the engine; a running one is fine as it is.
    func configurationChanged() {
        guard let engine = engine else { return }
        Self.log.info("configuration changed, running=\(engine.isRunning, privacy: .public)")
        guard !engine.isRunning else { return }
        guard restarts < Self.maxRestarts else {
            Self.log.error("engine stopped again after \(self.restarts, privacy: .public) restarts; giving up")
            onError?("The microphone stopped. Try again.")
            return
        }
        restarts += 1
        do {
            try run(engine)
            Self.log.info("engine restarted (\(self.restarts, privacy: .public))")
        } catch {
            Self.log.error("restart failed: \(error.localizedDescription, privacy: .public)")
            onError?("could not reopen microphone: \(error.localizedDescription)")
        }
    }

    /// (Re)installs the tap with the input's current format and starts the engine.
    private func run(_ engine: AVAudioEngine) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        Self.log.info("start: \(format.sampleRate, privacy: .public) Hz, \(format.channelCount, privacy: .public) ch")
        input.removeTap(onBus: 0)
        let onBuffer = self.onBuffer
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in onBuffer?(buffer) }
        engine.prepare()
        do {
            try startEngine(engine)
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }
}
