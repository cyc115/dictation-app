import AVFoundation
import Speech

/// On-device streaming speech recognition.
/// The microphone is opened only for the duration of one dictation — never in the background.
class SpeechEngine {
    /// Recognition language, e.g. "en-US" or "zh-CN" (Apple's models are one language each).
    var localeIdentifier = LocalLanguage.english.rawValue
    private var recognizer: SFSpeechRecognizer? { SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) }
    let mic = MicCapture()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var transcript = TranscriptAccumulator()
    /// Bumped whenever a dictation starts or completes; callbacks from older sessions are ignored.
    private var session = 0
    /// Set while stop() waits for the final transcript.
    private var finishHandler: ((String) -> Void)?
    /// After stop(), the recognizer often never sends a final result, so waiting for one cost a flat
    /// 2 s (bench/results/latency/BASELINE-pre-optimization.md). Instead stop() finishes once no new
    /// words have arrived for `settleDelay` (it has caught up with the audio), at least `minimumWait`
    /// after stop, and never later than `finalResultTimeout`. A final result still finishes at once.
    static let finalResultTimeout: TimeInterval = 2.0
    static let settleDelay: TimeInterval = 0.35
    static let minimumWait: TimeInterval = 0.2
    /// When the last recognizer result arrived, and when stop() was called (system uptime).
    private var lastResultAt: TimeInterval = 0
    private var stoppedAt: TimeInterval = 0
    private let clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Set while "Keep recordings" is on: mic dictations are also written to WAV and kept here.
    var archive: RecordingArchive?
    /// Set with `archive`, before each dictation: the polish half of its JSON.
    var note: RecordingNote?
    private var recording: DictationRecording?

    /// Starts listening on the microphone.
    /// - `inputUID` picks a microphone by CoreAudio UID; empty or missing uses the system default.
    /// - `onLevel` gets the mic level (0…1) for each audio buffer, on the main queue.
    /// - `onUtterance` gets each finished utterance (with its leading separator) as soon as you
    ///   pause, on the main queue — for streaming text out while still dictating.
    func start(inputUID: String = "", onLevel: @escaping (Float) -> Void,
               onUtterance: ((String) -> Void)? = nil, onError: @escaping (String) -> Void) {
        guard let (recognizer, request, id) = prepare(onError: onError) else { return }

        let recording = startRecording()
        guard mic.start(inputUID: inputUID, onBuffer: { [weak self] buffer in
            self?.request?.append(buffer)
            recording?.append(buffer)
        }, onLevel: onLevel, onError: onError) else {
            self.request = nil
            finishRecording(transcript: nil)
            return
        }
        recognize(recognizer, request, id: id, onUtterance: onUtterance, onError: onError)
    }

    /// Same pipeline as `start`, fed from an audio file instead of the mic (for end-to-end tests
    /// and benchmarks). Real-time pace by default, like a mic; `realTime: false` feeds it as fast
    /// as possible. Calls `onEnd` on the main queue when the file is used up.
    func startFile(_ url: URL, realTime: Bool = true, onUtterance: ((String) -> Void)? = nil,
                   onError: @escaping (String) -> Void, onEnd: @escaping () -> Void) {
        // Always signal the end, even on failure, so callers (benchmarks) never hang.
        guard let file = try? AVAudioFile(forReading: url) else {
            onError("could not read \(url.path)")
            return DispatchQueue.main.async(execute: onEnd)
        }
        guard let (recognizer, request, id) = prepare(onError: onError) else { return DispatchQueue.main.async(execute: onEnd) }
        recognize(recognizer, request, id: id, onUtterance: onUtterance, onError: onError)
        let format = file.processingFormat
        DispatchQueue.global(qos: .userInitiated).async {
            let chunk: AVAudioFrameCount = 1024
            while file.framePosition < file.length {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk),
                      (try? file.read(into: buffer, frameCount: chunk)) != nil, buffer.frameLength > 0 else { break }
                request.append(buffer)
                if realTime { Thread.sleep(forTimeInterval: Double(buffer.frameLength) / format.sampleRate) }
            }
            DispatchQueue.main.async(execute: onEnd)
        }
    }

    private func prepare(onError: (String) -> Void) -> (SFSpeechRecognizer, SFSpeechAudioBufferRecognitionRequest, Int)? {
        complete()  // deliver any previous dictation still waiting for its final result
        session += 1
        transcript = TranscriptAccumulator()
        lastResultAt = clock()
        guard let recognizer = recognizer else {
            onError("speech recognizer unavailable")
            return nil
        }
        guard recognizer.supportsOnDeviceRecognition else {
            onError("on-device recognition unavailable — check Dictation languages in System Settings → Keyboard")
            return nil
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true   // text streams while you speak
        request.requiresOnDeviceRecognition = true  // nothing leaves the Mac
        request.taskHint = .dictation
        request.addsPunctuation = true
        self.request = request
        return (recognizer, request, session)
    }

    private func recognize(_ recognizer: SFSpeechRecognizer, _ request: SFSpeechAudioBufferRecognitionRequest, id: Int,
                           onUtterance: ((String) -> Void)?, onError: @escaping (String) -> Void) {
        // Results arrive on the recognizer's queue (main by default).
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self, id == self.session else { return }
            let stopping = self.finishHandler != nil
            if let result = result {
                self.lastResultAt = self.clock()
                // Metadata marks the last result of an utterance (the recognizer restarts after it).
                let ended = result.speechRecognitionMetadata != nil || result.isFinal
                if let chunk = self.transcript.update(result.bestTranscription.formattedString, utteranceEnded: ended) {
                    onUtterance?(chunk)
                }
                if result.isFinal { self.complete() }
            }
            if let error = error {
                if stopping { self.complete() } else { onError(error.localizedDescription) }
            }
        }
    }

    /// Stops capture, waits for the recognizer to finish the last words, then calls
    /// `completion` on the main queue with the full transcript.
    func stop(completion: @escaping (String) -> Void) {
        mic.stop()
        guard task != nil else {  // start failed — nothing more is coming
            request = nil
            finishRecording(transcript: nil)
            completion(transcript.text)
            return
        }
        finishHandler = completion
        request?.endAudio()
        stoppedAt = clock()
        finishWhenSettled(session)
    }

    /// Completes once the recognizer has gone quiet (see `remainingWait`); re-checks until then.
    private func finishWhenSettled(_ id: Int) {
        guard id == session, finishHandler != nil else { return }
        let now = clock()
        guard let wait = Self.remainingWait(sinceStop: now - stoppedAt, sinceLastResult: now - lastResultAt) else {
            return complete()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.finishWhenSettled(id) }
    }

    /// How much longer stop() should wait for the last words, or nil to finish now.
    static func remainingWait(sinceStop: TimeInterval, sinceLastResult: TimeInterval) -> TimeInterval? {
        guard sinceStop < finalResultTimeout else { return nil }
        let wait = max(minimumWait - sinceStop, settleDelay - sinceLastResult)
        return wait > 0 ? min(wait, finalResultTimeout - sinceStop) : nil
    }

    /// Stops capture and throws the transcript away.
    func cancel() {
        mic.stop()
        finishHandler = nil
        session += 1
        task?.cancel()
        task = nil
        request = nil
        transcript = TranscriptAccumulator()
        finishRecording(transcript: nil)
    }

    /// Opens a WAV for this dictation when recordings are kept (the mic tap appends to it).
    func startRecording() -> DictationRecording? {
        finishRecording(transcript: nil)
        guard archive != nil else { return nil }
        recording = DictationRecording(archive: archive, note: note)
        return recording
    }

    /// Keeps the WAV with what was heard, or deletes it (nil: cancelled or failed).
    func finishRecording(transcript text: String?) {
        guard let recording else { return }
        self.recording = nil
        guard let text else { return recording.discard() }
        recording.done(RecordingInfo(date: Date(), model: "apple:\(localeIdentifier)", transcript: text,
                                     seconds: recording.duration))
    }

    /// Ends the current session and hands the transcript to the pending stop() caller.
    private func complete() {
        guard let handler = finishHandler else { return }
        finishHandler = nil
        session += 1  // silence any late callbacks from this task
        task?.cancel()
        task = nil
        request = nil
        let text = transcript.text
        handler(text)
        finishRecording(transcript: text)  // after the text is delivered: no file I/O in your wait
    }
}
