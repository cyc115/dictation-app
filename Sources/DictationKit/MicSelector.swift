import Accelerate
import AVFoundation

/// Intelligent mic selection: which of a dictation's mics hears you best, from how far each buffer
/// rises above that mic's own background noise. Comparing against each mic's own noise, not raw
/// loudness, means a mic's gain doesn't matter: the mic nearest your mouth wins.
///
/// A backup wins only when it has heard a few words and its recent speech is
/// `margin` dB (≈4× louder over its noise) clearer than the dictation's mic. Two mics that hear you
/// about as well never trade places. A dead mic (exact zeros) or one in a case hears nothing, so
/// any mic that hears you beats it.
struct MicSelector {
    /// Recent buffers each mic is judged on (~1.4 s of 21 ms buffers).
    static let window = 64
    /// dB above a mic's noise that counts as speech.
    static let speechSNR: Float = 15
    /// Buffers of speech (~0.65 s, a few words) a backup must have heard before it can win.
    static let minimumSpeech = 30
    /// How much clearer (dB) a backup must hear you than the dictation's mic.
    static let margin: Float = 12
    /// What exact zeros (no signal at all) count as.
    static let silence: Float = -120

    struct Meter {
        /// The mic's background noise (dBFS): drops at once to a quieter buffer, rises ~2 dB/s.
        var floor: Float?
        /// The last `window` buffers' rise over the noise (dB).
        var recent: [Float] = []
        /// Buffers of speech so far.
        var speech = 0

        mutating func add(_ decibels: Float) {
            guard decibels > MicSelector.silence + 1 else { return push(0) }  // zeros: hears nothing
            let floor = self.floor.map { decibels < $0 ? decibels : min($0 + 0.05, decibels) } ?? decibels
            self.floor = floor
            let rise = decibels - floor
            if rise >= MicSelector.speechSNR { speech += 1 }
            push(rise)
        }

        private mutating func push(_ rise: Float) {
            recent.append(rise)
            if recent.count > MicSelector.window { recent.removeFirst(recent.count - MicSelector.window) }
        }

        /// How clearly it hears you lately: the loud end (90th percentile) of `recent`, so pauses
        /// between words don't count against it.
        var clarity: Float {
            guard !recent.isEmpty else { return 0 }
            let sorted = recent.sorted()
            return sorted[min(sorted.count - 1, Int(Float(sorted.count) * 0.9))]
        }
    }

    private(set) var meters: [Meter]

    init(mics: Int = 1) { meters = Array(repeating: Meter(), count: mics) }

    /// A backup mic opened; returns its index.
    @discardableResult
    mutating func addMic() -> Int {
        meters.append(Meter())
        return meters.count - 1
    }

    mutating func add(_ decibels: Float, mic: Int) {
        guard meters.indices.contains(mic) else { return }
        meters[mic].add(decibels)
    }

    /// The backup that hears you clearly better than mic `current`, if one does. Only the clearest
    /// backup can win, so a nearer mic isn't beaten by one that merely got there a buffer sooner.
    func better(than current: Int) -> Int? {
        guard meters.indices.contains(current),
              let best = meters.indices.filter({ $0 != current }).max(by: { meters[$0].clarity < meters[$1].clarity })
        else { return nil }
        let clarity = meters[best].clarity
        guard meters[best].speech >= Self.minimumSpeech, clarity >= Self.speechSNR,
              clarity >= meters[current].clarity + Self.margin else { return nil }
        return best
    }

    /// RMS of the first channel in dBFS (`silence` for exact zeros). Runs per buffer on the audio
    /// queues, so it uses Accelerate.
    static func decibels(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return silence }
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(buffer.frameLength))
        return rms > 0 ? max(20 * log10(rms), silence) : silence
    }
}
