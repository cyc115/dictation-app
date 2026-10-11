import Accelerate
import AVFoundation
import os

/// The microphone for one dictation: a fresh input (`HALInput`, so a newly chosen or reconnected mic
/// is picked up) on the chosen device, and recovery when CoreAudio stops it.
///
/// CoreAudio can stop the input just after start (seen on a USB headset ~60–90 ms in), silently, so
/// the whole dictation recorded nothing and the waveform stayed flat until the next press. When the
/// input reports it stopped, this opens it again.
final class MicCapture {
    static let log = Logger(subsystem: "com.mikechen.DictationApp", category: "mic")
    /// Restarts allowed per dictation, so a device that keeps reconfiguring can't loop forever.
    static let maxRestarts = 3

    private(set) var input: MicInput?
    private(set) var restarts = 0
    /// Opens a device: `deliver` gets its audio, `stopped` is called (main queue) if it stops on its
    /// own. Tests swap this out to run without a microphone.
    var openInput: (_ device: AudioDeviceID, _ deliver: @escaping (AVAudioPCMBuffer) -> Void,
                    _ stopped: @escaping () -> Void) throws -> MicInput = { try HALInput(device: $0, deliver: $1, stopped: $2) }
    private var inputUID = ""
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

    /// Opens the mic. `inputUID` picks a microphone by CoreAudio UID; empty, or one that isn't
    /// connected, uses the system default. `onBuffer` runs off the main queue; `onError` on the main
    /// queue, if the mic stops and can't be reopened.
    func start(inputUID: String, onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
               onError: @escaping (String) -> Void) throws {
        stop()
        self.inputUID = inputUID
        self.onBuffer = onBuffer
        self.onError = onError
        restarts = 0
        signal.withLock { $0 = (0, false) }
        do {
            input = try open()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        input?.stop()
        input = nil
        onBuffer = nil
        onError = nil
    }

    /// Main queue: the input stopped without being asked. Reopens it, up to `maxRestarts` times.
    func inputStopped(_ stoppedInput: MicInput) {
        guard let current = input, current === stoppedInput else { return }  // a late notice from an old one
        current.stop()
        guard restarts < Self.maxRestarts else {
            Self.log.error("mic stopped again after \(self.restarts, privacy: .public) restarts; giving up")
            input = nil
            onError?("The microphone stopped. Try again.")
            return
        }
        restarts += 1
        do {
            input = try open()
            Self.log.info("mic restarted (\(self.restarts, privacy: .public))")
        } catch {
            Self.log.error("restart failed: \(error.localizedDescription, privacy: .public)")
            input = nil
            onError?("could not reopen microphone: \(error.localizedDescription)")
        }
    }

    /// The chosen mic (or the default), with its audio going to `received`.
    private func open() throws -> MicInput {
        if !inputUID.isEmpty, !AudioDevices.inputDevices().contains(where: { $0.uid == inputUID }) {
            Self.log.error("input \(self.inputUID, privacy: .public) isn't connected; using the default")
        }
        guard let device = AudioDevices.inputDevice(uid: inputUID) else {
            throw TranscriptionError.message("no microphone is connected")
        }
        let onBuffer = self.onBuffer
        var opened: MicInput?
        let input = try openInput(device, { [weak self] buffer in self?.received(buffer, to: onBuffer) }, { [weak self] in
            guard let self, let opened else { return }
            self.inputStopped(opened)
        })
        opened = input
        Self.log.info("start: device \(device, privacy: .public)")
        return input
    }
}
