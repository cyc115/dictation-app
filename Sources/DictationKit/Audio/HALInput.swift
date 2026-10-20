import AudioToolbox
import AVFoundation
import CoreAudio

/// A running microphone: `HALInput` in the app, a fake in tests.
protocol MicInput: AnyObject {
    var isRunning: Bool { get }
    func stop()
}

/// One microphone through an input-only CoreAudio unit (AUHAL with output disabled).
///
/// Not AVAudioEngine: on macOS its input and output share one unit, so with Bluetooth headphones as
/// the output it ignored the microphone you picked (the MacBook's) and recorded from the headphones'
/// own mic instead, switching them to the low-quality headset mode: near-silence at 16 kHz. This
/// unit only ever opens the input device it's given and never touches the output.
///
/// Audio arrives in chunks of ~21 ms (1024 frames at 48 kHz, as the engine's tap gave), whatever
/// the device's rate or I/O size, so the waveform and the silence check keep their pace. `deliver`
/// runs on a serial queue, off the real-time audio thread; `stopped` on the main queue when CoreAudio
/// stops the unit or the device goes away.
final class HALInput: MicInput {
    static let chunkSeconds = 1024.0 / 48_000

    let device: AudioDeviceID
    private(set) var format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    private let unit: AudioUnit
    private let deliver: (AVAudioPCMBuffer) -> Void
    private let stopped: () -> Void
    private let queue = DispatchQueue(label: "com.mikechen.DictationApp.mic", qos: .userInitiated)
    /// Audio-thread state: what AudioUnitRender writes into, and the chunks it's cut into.
    private var scratch: [Float] = []
    private var chunker = AudioChunker(format: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!)
    private var stoppedByUs = false
    private var aliveListener: AudioObjectPropertyListenerBlock?

    init(device: AudioDeviceID, deliver: @escaping (AVAudioPCMBuffer) -> Void,
         stopped: @escaping () -> Void) throws {
        self.device = device
        self.deliver = deliver
        self.stopped = stopped

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        var made: AudioUnit?
        guard let component = AudioComponentFindNext(nil, &description),
              AudioComponentInstanceNew(component, &made) == noErr, let unit = made else {
            throw Self.error("create the audio input", -1)
        }
        self.unit = unit

        do {
            var on: UInt32 = 1, off: UInt32 = 0, id = device
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, 4), "enable input")
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, 4), "disable output")
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                                &id, UInt32(MemoryLayout<AudioDeviceID>.size)), "select the microphone")
            var hardware = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try Self.check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size),
                           "read the microphone's format")
            guard hardware.mSampleRate > 0,
                  let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardware.mSampleRate,
                                             channels: 1, interleaved: false) else {
                throw Self.error("the microphone has no usable format", -1)
            }
            self.format = format
            var client = format.streamDescription.pointee  // mono: the unit maps the mic's first channel
            try Self.check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, size),
                           "set the recording format")
            var maxFrames: UInt32 = 4096
            var maxSize = UInt32(4)
            AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, &maxSize)
            scratch = [Float](repeating: 0, count: Int(max(maxFrames, 4096)))
            chunker = AudioChunker(format: format)

            var callback = AURenderCallbackStruct(inputProc: { refCon, flags, time, _, frames, _ in
                Unmanaged<HALInput>.fromOpaque(refCon).takeUnretainedValue().render(flags, time, frames)
            }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                                &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "listen to the microphone")
            try Self.check(AudioUnitAddPropertyListener(unit, kAudioOutputUnitProperty_IsRunning, Self.runningProc,
                                                        Unmanaged.passUnretained(self).toOpaque()), "watch the microphone")
            try Self.check(AudioUnitInitialize(unit), "open the microphone")
            watchDevice()
            try Self.check(AudioOutputUnitStart(unit), "start the microphone")
        } catch {
            stop()
            throw error
        }
    }

    deinit { stop() }

    var isRunning: Bool {
        var running: UInt32 = 0
        var size = UInt32(4)
        return AudioUnitGetProperty(unit, kAudioOutputUnitProperty_IsRunning, kAudioUnitScope_Global, 0, &running, &size) == noErr
            && running != 0
    }

    func stop() {
        guard !stoppedByUs else { return }
        stoppedByUs = true
        if let listener = aliveListener {
            var address = Self.aliveAddress
            AudioObjectRemovePropertyListenerBlock(device, &address, .main, listener)
            aliveListener = nil
        }
        AudioOutputUnitStop(unit)  // waits for a callback in progress
        AudioUnitRemovePropertyListenerWithUserData(unit, kAudioOutputUnitProperty_IsRunning, Self.runningProc,
                                                    Unmanaged.passUnretained(self).toOpaque())
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    // MARK: Audio thread

    private func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ time: UnsafePointer<AudioTimeStamp>,
                        _ frames: UInt32) -> OSStatus {
        guard Int(frames) <= scratch.count else { return kAudioUnitErr_TooManyFramesToProcess }
        return scratch.withUnsafeMutableBufferPointer { samples -> OSStatus in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 1, mDataByteSize: frames * 4, mData: UnsafeMutableRawPointer(samples.baseAddress)))
            let status = AudioUnitRender(unit, flags, time, 1, frames, &list)
            if status == noErr {
                let deliver = deliver, queue = queue
                chunker.append(samples.baseAddress!, Int(frames)) { chunk in queue.async { deliver(chunk) } }
            }
            return status
        }
    }

    // MARK: Stops we didn't ask for

    private static var aliveAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsAlive, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    /// The mic unplugged or its Bluetooth link dropped.
    private func watchDevice() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.reportStop() }
        var address = Self.aliveAddress
        if AudioObjectAddPropertyListenerBlock(device, &address, .main, listener) == noErr { aliveListener = listener }
    }

    private static let runningProc: AudioUnitPropertyListenerProc = { refCon, _, _, _, _ in
        Unmanaged<HALInput>.fromOpaque(refCon).takeUnretainedValue().runningChanged()
    }

    private func runningChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isRunning else { return }
            self.reportStop()
        }
    }

    private func reportStop() {
        guard !stoppedByUs else { return }
        stopped()
    }

    private static func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr { throw error(what, status) }
    }

    private static func error(_ what: String, _ status: OSStatus) -> Error {
        TranscriptionError.message("could not \(what) (OSStatus \(status))")
    }
}

/// Cuts a stream of mono samples into buffers of `HALInput.chunkSeconds` (the last partial one is
/// kept for the next call). Runs on the real-time audio thread: one allocation per chunk, no locks.
struct AudioChunker {
    let format: AVAudioFormat
    let chunkFrames: AVAudioFrameCount
    private var chunk: AVAudioPCMBuffer?

    init(format: AVAudioFormat) {
        self.format = format
        chunkFrames = AVAudioFrameCount(max(1, (format.sampleRate * HALInput.chunkSeconds).rounded()))
    }

    mutating func append(_ samples: UnsafePointer<Float>, _ count: Int, full: (AVAudioPCMBuffer) -> Void) {
        var offset = 0
        while offset < count {
            if chunk == nil { chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) }
            guard let current = chunk, let data = current.floatChannelData?[0] else { return }
            let n = min(Int(chunkFrames - current.frameLength), count - offset)
            (data + Int(current.frameLength)).update(from: samples + offset, count: n)
            current.frameLength += AVAudioFrameCount(n)
            offset += n
            if current.frameLength == chunkFrames {
                chunk = nil
                full(current)
            }
        }
    }
}
