import Accelerate
import AVFoundation
import os

/// What happens to a dictation's mic, reported on the main queue.
enum MicEvent: Equatable {
    /// The first real audio arrived (any non-zero sample): from here on you're heard. A Bluetooth
    /// headset sends silence, or nothing, for about a second while it switches into its call mode.
    case live
    /// The chosen mic stayed silent, so the dictation moved to this one.
    case switched(to: String)
}

/// The microphone for one dictation: a fresh input (`HALInput`, so a newly chosen or reconnected mic
/// is picked up) on the chosen device, and recovery when CoreAudio stops it.
///
/// CoreAudio can stop the input just after start (seen on a USB headset ~60–90 ms in), silently, so
/// the whole dictation recorded nothing and the waveform stayed flat until the next press. When the
/// input reports it stopped, this opens it again.
///
/// A Bluetooth mic that still hasn't sent real audio `fallbackAfter` seconds in is given up on:
/// the dictation moves to the Mac's own mic (`AudioDevices.fallbackInput`) instead of recording silence.
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
    /// Seconds a Bluetooth mic gets to send real audio before the dictation moves to the built-in mic.
    var fallbackAfter: TimeInterval = 3
    /// The mic to move to from a silent one (tests swap it).
    var fallbackInput: (AudioInputDevice) -> AudioInputDevice? = { AudioDevices.fallbackInput(for: $0) }
    /// Finds the mic for a UID, as `AudioDevices.activeInput` (tests swap it).
    var resolveInput: (String) -> AudioInputDevice? = { AudioDevices.activeInput(preferredUID: $0) }
    /// The mic this dictation records from (the fallback, once it has moved).
    private(set) var device: AudioInputDevice?
    private var inputUID = ""
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var onEvent: ((MicEvent) -> Void)?
    private var onError: ((String) -> Void)?
    private var fallback: DispatchWorkItem?
    private let formatKeeper = FormatKeeper()
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

    /// True once this dictation's mic has sent real audio (`MicEvent.live`).
    var isLive: Bool { signal.withLock { $0.heard } }

    /// Every tap buffer goes through here (tests call it directly): checks for signal, then hands it
    /// on in this dictation's format.
    func received(_ buffer: AVAudioPCMBuffer, to onBuffer: ((AVAudioPCMBuffer) -> Void)?) {
        let needsCheck = signal.withLock { state -> Bool in
            state.buffers += 1
            return !state.heard
        }
        if needsCheck, Self.hasSignal(buffer) {
            let first = signal.withLock { state -> Bool in
                defer { state.heard = true }
                return !state.heard
            }
            if first, let onEvent { DispatchQueue.main.async { onEvent(.live) } }
        }
        guard let buffer = formatKeeper.conform(buffer) else { return }
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
               onLevel: @escaping (Float) -> Void, onEvent: @escaping (MicEvent) -> Void,
               onError: @escaping (String) -> Void) -> Bool {
        do {
            try start(inputUID: inputUID, onBuffer: { buffer in
                onBuffer(buffer)
                let level = Self.level(of: buffer)
                DispatchQueue.main.async { onLevel(level) }
            }, onEvent: onEvent, onError: onError)
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
    /// connected, uses the system default. `onBuffer` runs off the main queue; `onEvent` on the main
    /// queue; `onError` on the main queue, if the mic stops and can't be reopened.
    func start(inputUID: String, onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
               onEvent: ((MicEvent) -> Void)? = nil, onError: @escaping (String) -> Void) throws {
        stop()
        self.inputUID = inputUID
        self.onBuffer = onBuffer
        self.onEvent = onEvent
        self.onError = onError
        restarts = 0
        signal.withLock { $0 = (0, false) }
        formatKeeper.reset()
        let chosen = resolveInput(inputUID)
        if !inputUID.isEmpty, chosen?.uid != inputUID {
            Self.log.error("input \(inputUID, privacy: .public) isn't connected; using the default")
        }
        guard let chosen else {
            stop()
            throw TranscriptionError.message("no microphone is connected")
        }
        device = chosen
        do {
            input = try open(chosen)
        } catch {
            stop()
            throw error
        }
        if chosen.isBluetooth { scheduleFallback() }
    }

    func stop() {
        fallback?.cancel()
        fallback = nil
        input?.stop()
        input = nil
        device = nil
        onBuffer = nil
        onEvent = nil
        onError = nil
    }

    private func scheduleFallback() {
        let work = DispatchWorkItem { [weak self] in self?.fallBackIfSilent() }
        fallback = work
        DispatchQueue.main.asyncAfter(deadline: .now() + fallbackAfter, execute: work)
    }

    /// Main queue, `fallbackAfter` into a Bluetooth dictation (tests call it directly): if the mic
    /// still hasn't sent real audio, moves to `fallbackInput`. The audio so far was silence, so
    /// nothing is lost.
    func fallBackIfSilent() {
        fallback = nil
        guard let current = input, let device, !isLive,
              let backup = fallbackInput(device), backup.id != device.id else { return }
        Self.log.error("\(device.name, privacy: .public) sent no audio in \(self.fallbackAfter, privacy: .public) s; using \(backup.name, privacy: .public)")
        current.stop()
        input = nil
        do {
            input = try open(backup)
            self.device = backup
            onEvent?(.switched(to: backup.name))
        } catch {
            Self.log.error("fallback failed: \(error.localizedDescription, privacy: .public)")
            onError?("could not open \(backup.name): \(error.localizedDescription)")
        }
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
            guard let device else { throw TranscriptionError.message("no microphone is connected") }
            input = try open(device)
            Self.log.info("mic restarted (\(self.restarts, privacy: .public))")
        } catch {
            Self.log.error("restart failed: \(error.localizedDescription, privacy: .public)")
            input = nil
            onError?("could not reopen microphone: \(error.localizedDescription)")
        }
    }

    /// `device`, with its audio going to `received`.
    private func open(_ chosen: AudioInputDevice) throws -> MicInput {
        let device = chosen.id
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

/// Keeps one dictation's audio in one format: the first buffer's. A mic switched mid-dictation (the
/// Bluetooth fallback, or a restart) can run at another rate, and whatever reads the audio (Apple
/// Speech, the WAV) is handed a single format for the whole dictation. Runs off the main queue,
/// on whichever input's queue delivers.
final class FormatKeeper {
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    private let lock = NSLock()

    func reset() {
        lock.lock(); defer { lock.unlock() }
        format = nil
        converter = nil
    }

    /// `buffer` in this dictation's format; nil if it couldn't be converted.
    func conform(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        lock.lock(); defer { lock.unlock() }
        guard let format else {
            format = buffer.format
            return buffer
        }
        if buffer.format == format { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }
}
