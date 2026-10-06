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

    func start(onPartial: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
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
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            onError("could not open microphone: \(error.localizedDescription)")
            return
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            if let result = result {
                self.lastText = result.bestTranscription.formattedString
                onPartial(self.lastText)
            }
            if let error = error {
                onError(error.localizedDescription)
            }
        }
    }

    /// Stops capture and returns the transcript collected so far.
    @discardableResult
    func stop() -> String {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        task = nil
        request = nil
        return lastText
    }
}
