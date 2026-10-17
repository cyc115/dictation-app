import Accelerate
import AVFoundation
import os

/// What happens to a dictation's mic, reported on the main queue.
enum MicEvent: Equatable {
    /// The dictation's mic sent its first real audio (any non-zero sample): from here on you're
    /// heard. A Bluetooth headset sends silence, or nothing, for about a second while it switches
    /// into its call mode.
    case live
    /// The dictation's mic has sent no real audio `noAudioAfter` seconds in: it's dead, muted or
    /// cut off, so nothing you say is being heard.
    case noAudio
    /// Intelligent mic selection: this mic hears you clearly better, so the dictation now uses it.
    case switched(to: AudioInputDevice)
}

/// The microphones for one dictation: a fresh input (`HALInput`, so a newly chosen or reconnected mic
/// is picked up) on the chosen device, and recovery when CoreAudio stops it.
///
/// CoreAudio can stop the input just after start (seen on a USB headset ~60–90 ms in), silently, so
/// the whole dictation recorded nothing and the waveform stayed flat until the next press. When the
/// input reports it stopped, this opens it again.
///
/// With `backups` (Intelligent mic selection) every connected wired and built-in mic records too
/// (`AudioDevices.backupInputs`), and `MicSelector` watches which one hears you best. If a backup
/// hears you clearly better, the dictation moves to it, once: `onRestart` lets the engine start
/// over, and the backup's audio from the start of the dictation is handed on, so nothing said
/// before the switch is lost. Then the other mics close.
final class MicCapture {
    static let log = Logger(subsystem: "com.mikechen.DictationApp", category: "mic")
    /// Restarts allowed per dictation, so a device that keeps reconfiguring can't loop forever.
    static let maxRestarts = 3
    /// Backups keep their audio at this rate until one wins (~19 MB each for a 5-minute dictation).
    static let backupFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!

    /// One open mic: the dictation's, or a backup.
    final class Source {
        let device: AudioInputDevice
        /// Index in the selector.
        let index: Int
        fileprivate var input: MicInput?
        fileprivate var buffers = 0
        fileprivate var heard = false
        /// A backup's audio so far, at `backupFormat`, kept in case it wins.
        fileprivate var history: [AVAudioPCMBuffer] = []
        fileprivate let resampler = FormatKeeper(format: MicCapture.backupFormat)

        init(device: AudioInputDevice, index: Int) {
            self.device = device
            self.index = index
        }
    }

    private(set) var restarts = 0
    /// Opens a device: `deliver` gets its audio, `stopped` is called (main queue) if it stops on its
    /// own. Tests swap this out to run without a microphone.
    var openInput: (_ device: AudioDeviceID, _ deliver: @escaping (AVAudioPCMBuffer) -> Void,
                    _ stopped: @escaping () -> Void) throws -> MicInput = { try HALInput(device: $0, deliver: $1, stopped: $2) }
    /// Finds the mic for a UID, as `AudioDevices.activeInput` (tests swap it).
    var resolveInput: (String) -> AudioInputDevice? = { AudioDevices.activeInput(preferredUID: $0) }
    /// The mics that also record with `backups` (tests swap it).
    var backupInputs: (AudioInputDevice) -> [AudioInputDevice] = { AudioDevices.backupInputs(excluding: $0) }
    /// Where backups are opened: off the main queue, so they don't hold up the chosen mic or the
    /// pill (tests run it at once).
    var openInBackground: (@escaping () -> Void) -> Void = { DispatchQueue.global(qos: .userInitiated).async(execute: $0) }
    /// Seconds before a mic that has sent no real audio is reported (`MicEvent.noAudio`).
    var noAudioAfter: TimeInterval = 3

    // Shared with the inputs' queues: read and written under `lock`.
    private let lock = NSLock()
    private var sources: [Source] = []
    /// The mic whose audio the engine gets.
    private var active: Source?
    /// The last dictation's mic, kept after stop() for `heardOnlySilence`.
    private var finished: Source?
    private var selector = MicSelector()
    /// A backup won and the engine is starting over (main queue): nothing is handed on meanwhile.
    private var switching = false
    private var switched = false
    /// Bumped by every start/stop, so late work from an earlier dictation is dropped.
    private var generation = 0
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var onLevel: ((Float) -> Void)?
    private var onEvent: ((MicEvent) -> Void)?
    private var onRestart: (() -> Bool)?
    private var onError: ((String) -> Void)?
    private let formatKeeper = FormatKeeper()
    private var noAudioCheck: DispatchWorkItem?

    /// Buffers (~0.5 s at 48 kHz) before all-zero audio counts as silence: some devices start with a few.
    static let silenceBuffers = 24
    /// Shown when a dictation's audio was nothing but exact zeros (see `heardOnlySilence`).
    static let silenceMessage = "The microphone sent only silence. Check it isn't muted, or quit and reopen DictationApp."

    deinit { stop() }

    /// The mic the dictation records from (a backup, once one has won).
    var device: AudioInputDevice? { locked { active?.device } }
    /// The running input of that mic.
    var input: MicInput? { locked { active?.input } }
    /// Every mic open for this dictation, the chosen one first.
    var openDevices: [AudioInputDevice] { locked { sources.filter { $0.input != nil }.map(\.device) } }

    /// True when this dictation's mic delivered audio but every sample was exactly zero. A real
    /// mic always has some noise; pure zeros mean macOS cut the app off (e.g. microphone access
    /// revoked after its files were replaced while running) or the input is muted digitally.
    var heardOnlySilence: Bool {
        locked {
            guard let mic = active ?? finished else { return false }
            return mic.buffers >= Self.silenceBuffers && !mic.heard
        }
    }

    /// True once this dictation's mic has sent real audio (`MicEvent.live`).
    var isLive: Bool { locked { active?.heard ?? false } }

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

    /// RMS of the first channel (`MicSelector.decibels`) mapped from -50…-10 dBFS onto 0…1, for the
    /// waveform.
    static func level(of buffer: AVAudioPCMBuffer) -> Float {
        min(max((MicSelector.decibels(of: buffer) + 50) / 40, 0), 1)
    }

    /// `start` for a dictation, reporting a mic that won't open through `onError`. False if it didn't open.
    @discardableResult
    func startDictation(inputUID: String, backups: Bool, onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
               onLevel: @escaping (Float) -> Void, onEvent: @escaping (MicEvent) -> Void,
               onRestart: @escaping () -> Bool, onError: @escaping (String) -> Void) -> Bool {
        do {
            try start(inputUID: inputUID, backups: backups, onBuffer: onBuffer, onLevel: onLevel, onEvent: onEvent,
                      onRestart: onRestart, onError: onError)
            return true
        } catch {
            onError("could not open microphone: \(error.localizedDescription)")
            return false
        }
    }

    /// Opens the mic (and, with `backups`, the others). `inputUID` picks a microphone by CoreAudio
    /// UID; empty, or one that isn't connected, uses the system default.
    /// - `onBuffer`: the dictation's audio, off the main queue, one buffer at a time.
    /// - `onLevel`: each live buffer's level (0…1), main queue.
    /// - `onEvent`: `MicEvent`s, main queue.
    /// - `onRestart`: a backup won (main queue; no audio is handed on while it runs). Return true to
    ///   start over and get the backup's audio from the start of the dictation, false to carry on
    ///   with the backup's audio from now.
    /// - `onError`: main queue, if the mic stops and can't be reopened.
    func start(inputUID: String, backups: Bool = false, onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
               onLevel: ((Float) -> Void)? = nil, onEvent: ((MicEvent) -> Void)? = nil,
               onRestart: (() -> Bool)? = nil, onError: @escaping (String) -> Void) throws {
        stop()
        let chosen = resolveInput(inputUID)
        if !inputUID.isEmpty, chosen?.uid != inputUID {
            Self.log.error("input \(inputUID, privacy: .public) isn't connected; using the default")
        }
        guard let chosen else { throw TranscriptionError.message("no microphone is connected") }
        let source = Source(device: chosen, index: 0)
        let generation: Int = locked {
            self.onBuffer = onBuffer
            self.onLevel = onLevel
            self.onEvent = onEvent
            self.onRestart = onRestart
            self.onError = onError
            restarts = 0
            finished = nil
            selector = MicSelector(mics: 1)
            sources = [source]
            active = source
            formatKeeper.reset()
            return self.generation
        }
        do {
            let input = try open(source)
            locked { source.input = input }
        } catch {
            stop()
            throw error
        }
        let check = DispatchWorkItem { [weak self] in self?.reportIfSilent() }
        noAudioCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + noAudioAfter, execute: check)
        if backups { openBackups(backupInputs(chosen), generation: generation) }
    }

    func stop() {
        noAudioCheck?.cancel()
        noAudioCheck = nil
        let all: [Source] = locked {
            generation += 1
            let all = sources
            if let active { finished = active }
            sources = []
            active = nil
            switching = false
            switched = false
            onBuffer = nil
            onLevel = nil
            onEvent = nil
            onRestart = nil
            onError = nil
            return all
        }
        all.forEach { $0.input?.stop() }  // outside the lock: stopping waits for audio in flight
    }

    // MARK: Audio from every mic

    /// Every buffer from every mic goes through here, on that mic's queue: checks for signal, feeds
    /// the selector, then hands the dictation mic's audio on and keeps the backups'.
    func received(_ buffer: AVAudioPCMBuffer, from source: Source) {
        var events: [MicEvent] = []
        var level: Float?
        var winner: (source: Source, mark: Int, generation: Int)?
        lock.lock()
        guard sources.contains(where: { $0 === source }) else { return lock.unlock() }  // a late buffer
        source.buffers += 1
        if !source.heard, Self.hasSignal(buffer) {
            source.heard = true
            if source === active { events.append(.live) }
        }
        let isActive = source === active
        if sources.count > 1, !switched { selector.add(MicSelector.decibels(of: buffer), mic: source.index) }
        if isActive, !switching {
            deliver(buffer)
            level = Self.level(of: buffer)
        } else if !isActive, !switched, let kept = source.resampler.conform(buffer) {
            source.history.append(kept)
        }
        if !switched, !switching, let active, let best = selector.better(than: active.index),
           let found = sources.first(where: { $0.index == best }) {
            switching = true
            winner = (found, found.history.count, generation)
        }
        let onLevel = self.onLevel, onEvent = self.onEvent
        lock.unlock()
        if let level, let onLevel { DispatchQueue.main.async { onLevel(level) } }
        if let onEvent, !events.isEmpty { DispatchQueue.main.async { events.forEach(onEvent) } }
        if let winner {
            DispatchQueue.main.async { [weak self] in self?.finishSwitch(to: winner.source, mark: winner.mark, generation: winner.generation) }
        }
    }

    /// Under `lock`: one buffer to the engine, in this dictation's format.
    private func deliver(_ buffer: AVAudioPCMBuffer) {
        guard let buffer = formatKeeper.conform(buffer) else { return }
        onBuffer?(buffer)
    }

    /// Main queue: the engine starts over (or not), the winner's audio is handed on, the rest close.
    private func finishSwitch(to winner: Source, mark: Int, generation: Int) {
        guard locked({ generation == self.generation }) else { return }
        let fromStart = onRestart?() ?? false
        let others: [Source]? = locked {
            guard generation == self.generation else { return nil }
            if fromStart { formatKeeper.reset() }
            winner.history[(fromStart ? 0 : mark)...].forEach(deliver)
            winner.history = []
            let others = sources.filter { $0 !== winner }
            sources = [winner]
            active = winner
            switching = false
            switched = true
            return others
        }
        guard let others else { return }
        Self.log.info("switched to \(winner.device.name, privacy: .public) (\(fromStart ? "from the start" : "from now", privacy: .public))")
        others.forEach { $0.input?.stop() }
        onEvent?(.switched(to: winner.device))
    }

    /// Main queue, `noAudioAfter` into the dictation.
    private func reportIfSilent() {
        noAudioCheck = nil
        let silent = locked { active.map { !$0.heard } ?? false }
        if silent { onEvent?(.noAudio) }
    }

    // MARK: Opening and reopening

    /// Opens each backup (off the main queue), unless the dictation has ended or switched meanwhile.
    private func openBackups(_ devices: [AudioInputDevice], generation: Int) {
        guard !devices.isEmpty else { return }
        openInBackground { [weak self] in
            for device in devices {
                guard let self else { return }
                let source: Source? = self.locked {
                    guard generation == self.generation, !self.switched else { return nil }
                    let source = Source(device: device, index: self.selector.addMic())
                    self.sources.append(source)
                    return source
                }
                guard let source else { return }
                do {
                    let input = try self.open(source)
                    let kept = self.locked { () -> Bool in
                        guard generation == self.generation, self.sources.contains(where: { $0 === source }) else { return false }
                        source.input = input
                        return true
                    }
                    if !kept { input.stop() }
                } catch {
                    Self.log.error("backup \(device.name, privacy: .public) didn't open: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// `source`'s device, with its audio going to `received`.
    private func open(_ source: Source) throws -> MicInput {
        var opened: MicInput?
        let input = try openInput(source.device.id, { [weak self, weak source] buffer in
            guard let self, let source else { return }
            self.received(buffer, from: source)
        }, { [weak self, weak source] in
            guard let self, let source, let opened else { return }
            self.inputStopped(opened, source: source)
        })
        opened = input
        Self.log.info("start: device \(source.device.id, privacy: .public)")
        return input
    }

    /// Main queue: an input stopped without being asked. The dictation's mic is reopened, up to
    /// `maxRestarts` times; a backup is just let go.
    func inputStopped(_ stoppedInput: MicInput, source: Source) {
        let isActive: Bool? = locked {
            guard source.input === stoppedInput else { return nil }  // a late notice from an old one
            source.input = nil
            return source === active
        }
        guard let isActive else { return }
        stoppedInput.stop()
        guard isActive else { return }
        guard restarts < Self.maxRestarts else {
            Self.log.error("mic stopped again after \(self.restarts, privacy: .public) restarts; giving up")
            onError?("The microphone stopped. Try again.")
            return
        }
        restarts += 1
        do {
            let input = try open(source)
            locked { source.input = input }
            Self.log.info("mic restarted (\(self.restarts, privacy: .public))")
        } catch {
            Self.log.error("restart failed: \(error.localizedDescription, privacy: .public)")
            onError?("could not reopen microphone: \(error.localizedDescription)")
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}
