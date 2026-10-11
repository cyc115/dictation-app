import Accelerate
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
    /// (buffers seen, any non-zero sample) for this dictation; written on the audio thread.
    private let signal = OSAllocatedUnfairLock(initialState: (buffers: 0, heard: false))

    /// Buffers (~0.5 s at 48 kHz) before all-zero audio counts as silence: some devices start with a few.
    static let silenceBuffers = 24
    /// Shown when a dictation's audio was nothing but exact zeros (see `heardOnlySilence`).
    static let silenceMessage = "The microphone sent only silence. Check it isn't muted, or quit and reopen DictationApp."

    deinit { stop() }

    /// True when this dictation's mic delivered audio but every sample was exactly zero. A real
    /// mic always has some noise; pure zeros mean macOS cut the app off (e.g. microphone access
    /// revoked after its files were replaced while running) or the input is muted digitally.
    var heardOnlySilence: Bool {
        signal.withLock { $0.buffers >= Self.silenceBuffers && !$0.heard }
    }

    /// Every tap buffer goes through here (tests call it directly): checks for signal, then hands it on.
    func received(_ buffer: AVAudioPCMBuffer, to onBuffer: ((AVAudioPCMBuffer) -> Void)?) {
        let needsCheck = signal.withLock { state -> Bool in
            state.buffers += 1
            return !state.heard
        }
        if needsCheck, Self.hasSignal(buffer) { signal.withLock { $0.heard = true } }
        onBuffer?(buffer)
    }

    /// Any non-zero sample in any channel.
    static func hasSignal(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return false }
        for c in 0..<Int(buffer.format.channelCount) {
            var peak: Float = 0
            vDSP_maxmgv(channels[c], 1, &peak, vDSP_Length(buffer.frameLength))
            if peak > 0 { return true }
        }
        return false
    }

    /// `start` for a dictation: also reports each buffer's level (0…1) on the main queue, and a mic
    /// that won't open through `onError`. False if it didn't open.
    @discardableResult
    func start(inputUID: String, onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
               onLevel: @escaping (Float) -> Void, onError: @escaping (String) -> Void) -> Bool {
        do {
            try start(inputUID: inputUID, onBuffer: { buffer in
                onBuffer(buffer)
                let level = Self.level(of: buffer)
                DispatchQueue.main.async { onLevel(level) }
            }, onError: onError)
            return true
        } catch {
            onError("could not open microphone: \(error.localizedDescription)")
            return false
        }
    }

    /// RMS of the first channel mapped from -50…-10 dBFS onto 0…1. Runs on the audio thread for
    /// every buffer, so it uses Accelerate (vDSP) rather than a Swift loop.
    static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(buffer.frameLength))
        let db = 20 * log10(max(rms, 1e-6))
        return min(max((db + 50) / 40, 0), 1)
    }

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
        signal.withLock { $0 = (0, false) }
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
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.received(buffer, to: onBuffer)
        }
        engine.prepare()
        do {
            try startEngine(engine)
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }
}
