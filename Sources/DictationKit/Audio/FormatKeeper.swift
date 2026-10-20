import AVFoundation

/// Keeps audio in one format: `fixed`, or else the first buffer's. Uses: the WAV's 16 kHz mono
/// (`WAVRecorder`), a backup mic's kept audio (`MicCapture`), and one format for a whole dictation
/// even when its mic changes mid-way (intelligent mic selection, a restart), for whatever reads it
/// (Apple Speech, the WAV). Thread-safe: runs on whichever input's queue delivers.
final class FormatKeeper {
    private let fixed: AVAudioFormat?
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    private let lock = NSLock()

    init(format: AVAudioFormat? = nil) {
        fixed = format
        self.format = format
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        format = fixed
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
