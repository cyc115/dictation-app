import Foundation

// MARK: - Engine interface

/// A dictation backend: records while active, then produces the transcript.
protocol DictationEngine: AnyObject {
    /// True when text only arrives after you stop (upload + transcribe), so the UI shows a wait state.
    var isBatch: Bool { get }
    /// Set while "Keep recordings" is on: finished recordings go here instead of being deleted.
    var archive: RecordingArchive? { get set }
    /// Set with `archive`, before each dictation: the polish half of its JSON.
    var note: RecordingNote? { get set }
    /// `backups`: Intelligent mic selection (also record from the other wired and built-in mics and
    /// move to the one that hears you best). `onMic` gets the mic's events on the main queue.
    func start(inputUID: String, backups: Bool, onLevel: @escaping (Float) -> Void, onMic: @escaping (MicEvent) -> Void,
               onError: @escaping (String) -> Void)
    /// Ends recording; exactly one of `completion` / `failure` is called on the main queue.
    func stop(completion: @escaping (String) -> Void, failure: @escaping (String) -> Void)
    func cancel()
    /// Which model gave the transcript just passed to `completion`, for History; nil when there's
    /// no choice of model (on-device).
    var lastAnswer: ModelAnswer? { get }
}

extension DictationEngine {
    var lastAnswer: ModelAnswer? { nil }
}

extension SpeechEngine: DictationEngine {
    var isBatch: Bool { false }
    func start(inputUID: String, backups: Bool, onLevel: @escaping (Float) -> Void, onMic: @escaping (MicEvent) -> Void,
               onError: @escaping (String) -> Void) {
        start(inputUID: inputUID, backups: backups, onLevel: onLevel, onMic: onMic, onUtterance: nil, onError: onError)
    }
    func stop(completion: @escaping (String) -> Void, failure: @escaping (String) -> Void) {
        if mic.heardOnlySilence {
            cancel()
            return failure(MicCapture.silenceMessage)
        }
        stop(completion: completion)
    }
}

enum TranscriptionError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}
