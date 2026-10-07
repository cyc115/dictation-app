import AVFoundation
import Speech

/// On-device streaming speech recognition.
/// The microphone is opened only for the duration of one dictation — never in the background.
class SpeechEngine {
    private let recognizer: SFSpeechRecognizer? = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var lastText = ""
    /// Bumped whenever a dictation starts or completes; callbacks from older sessions are ignored.
    private var session = 0
    /// Set while stop() waits for the final transcript.
    private var finishHandler: ((String) -> Void)?
    /// How long stop() waits for the recognizer's final result before using what it has.
    private let finalResultTimeout: TimeInterval = 2.0

    /// `onLevel` gets the mic level (0…1) for each audio buffer, on the main queue.
    func start(onLevel: @escaping (Float) -> Void, onError: @escaping (String) -> Void) {
        complete()  // deliver any previous dictation still waiting for its final result
        session += 1
        let id = session
        lastText = ""
        guard let recognizer = recognizer else {
            onError("speech recognizer unavailable")
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            onError("on-device recognition unavailable — check Dictation languages in System Settings → Keyboard")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true   // text streams while you speak
        request.requiresOnDeviceRecognition = true  // nothing leaves the Mac
        request.taskHint = .dictation
        if #available(macOS 13.0, *) { request.addsPunctuation = true }
        self.request = request

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

        // Results arrive on the recognizer's queue (main by default).
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self, id == self.session else { return }
            let stopping = self.finishHandler != nil
            if let result = result {
                self.lastText = result.bestTranscription.formattedString
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
            completion(lastText)
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
        lastText = ""
    }

    /// Ends the current session and hands the transcript to the pending stop() caller.
    private func complete() {
        guard let handler = finishHandler else { return }
        finishHandler = nil
        session += 1  // silence any late callbacks from this task
        task?.cancel()
        task = nil
        request = nil
        handler(lastText)
    }

    /// RMS of the first channel mapped from -50…-10 dBFS onto 0…1.
    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += samples[i] * samples[i] }
        let db = 20 * log10(max(sqrt(sum / Float(n)), 1e-6))
        return min(max((db + 50) / 40, 0), 1)
    }
}
