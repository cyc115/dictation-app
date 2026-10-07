import AVFoundation
import Speech

/// On-device streaming speech recognition.
/// The microphone is opened only for the duration of one dictation — never in the background.
class SpeechEngine {
    private let recognizer: SFSpeechRecognizer? = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var transcript = TranscriptAccumulator()
    /// Bumped whenever a dictation starts or completes; callbacks from older sessions are ignored.
    private var session = 0
    /// Set while stop() waits for the final transcript.
    private var finishHandler: ((String) -> Void)?
    /// How long stop() waits for the recognizer's final result before using what it has.
    private let finalResultTimeout: TimeInterval = 2.0
    /// Debug hook: every raw recognizer result (used by Diagnostics).
    var onResult: ((SFSpeechRecognitionResult) -> Void)?

    /// Starts listening on the microphone.
    /// - `inputUID` picks a microphone by CoreAudio UID; empty or missing uses the system default.
    /// - `onLevel` gets the mic level (0…1) for each audio buffer, on the main queue.
    /// - `onUtterance` gets each finished utterance (with its leading separator) as soon as you
    ///   pause, on the main queue — for streaming text out while still dictating.
    func start(inputUID: String = "", onLevel: @escaping (Float) -> Void,
               onUtterance: ((String) -> Void)? = nil, onError: @escaping (String) -> Void) {
        guard let (recognizer, request, id) = prepare(onError: onError) else { return }

        // Fresh engine per dictation so a newly chosen or reconnected mic is picked up.
        audioEngine = AVAudioEngine()
        if !inputUID.isEmpty { AudioDevices.route(audioEngine, toInputUID: inputUID) }
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
            let level = Self.level(of: buffer)
            DispatchQueue.main.async { onLevel(level) }
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.request = nil
            onError("could not open microphone: \(error.localizedDescription)")
            return
        }
        recognize(recognizer, request, id: id, onUtterance: onUtterance, onError: onError)
    }

    /// Same pipeline as `start`, fed from an audio file at real-time pace instead of the mic
    /// (for end-to-end tests). Calls `onEnd` on the main queue when the file is used up.
    func startFile(_ url: URL, onUtterance: ((String) -> Void)? = nil,
                   onError: @escaping (String) -> Void, onEnd: @escaping () -> Void) {
        guard let file = try? AVAudioFile(forReading: url) else { return onError("could not read \(url.path)") }
        guard let (recognizer, request, id) = prepare(onError: onError) else { return }
        recognize(recognizer, request, id: id, onUtterance: onUtterance, onError: onError)
        let format = file.processingFormat
        DispatchQueue.global(qos: .userInitiated).async {
            let chunk: AVAudioFrameCount = 1024
            while file.framePosition < file.length {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk),
                      (try? file.read(into: buffer, frameCount: chunk)) != nil, buffer.frameLength > 0 else { break }
                request.append(buffer)
                Thread.sleep(forTimeInterval: Double(buffer.frameLength) / format.sampleRate)
            }
            DispatchQueue.main.async(execute: onEnd)
        }
    }

    private func prepare(onError: (String) -> Void) -> (SFSpeechRecognizer, SFSpeechAudioBufferRecognitionRequest, Int)? {
        complete()  // deliver any previous dictation still waiting for its final result
        session += 1
        transcript = TranscriptAccumulator()
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
                self.onResult?(result)
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
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        guard task != nil else {  // start failed — nothing more is coming
            request = nil
            completion(transcript.text)
            return
        }
        finishHandler = completion
        request?.endAudio()
        let id = session
        DispatchQueue.main.asyncAfter(deadline: .now() + finalResultTimeout) { [weak self] in
            guard let self = self, id == self.session else { return }
            self.complete()
        }
    }

    /// Stops capture and throws the transcript away.
    func cancel() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        finishHandler = nil
        session += 1
        task?.cancel()
        task = nil
        request = nil
        transcript = TranscriptAccumulator()
    }

    /// Ends the current session and hands the transcript to the pending stop() caller.
    private func complete() {
        guard let handler = finishHandler else { return }
        finishHandler = nil
        session += 1  // silence any late callbacks from this task
        task?.cancel()
        task = nil
        request = nil
        handler(transcript.text)
    }

    /// RMS of the first channel mapped from -50…-10 dBFS onto 0…1.
    static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += samples[i] * samples[i] }
        let db = 20 * log10(max(sqrt(sum / Float(n)), 1e-6))
        return min(max((db + 50) / 40, 0), 1)
    }
}
