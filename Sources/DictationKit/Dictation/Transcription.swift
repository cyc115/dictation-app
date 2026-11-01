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
    /// `mics`: the mic to record from and, with Intelligent mic selection, the backups (also recorded
    /// from, moving to the one that hears you best); nil when none is connected (reported through
    /// `onError`). `onMic` gets the mic's events on the main queue.
    func start(mics: MicPick?, onLevel: @escaping (Float) -> Void, onMic: @escaping (MicEvent) -> Void,
               onError: @escaping (String) -> Void)
    /// Ends recording; exactly one of `completion` / `failure` is called on the main queue.
    func stop(completion: @escaping (String) -> Void, failure: @escaping (String) -> Void)
    func cancel()
    /// Which model gave the transcript just passed to `completion`, for History; nil when there's
    /// no choice of model (on-device).
    var lastAnswer: ModelAnswer? { get }
    /// What this dictation is likely to say, set before `start` (`.none` for plain dictation).
    var context: SpeechContext { get set }
}

extension DictationEngine {
    var lastAnswer: ModelAnswer? { nil }
}

/// Words a dictation is likely to use, for the speech models that can be told: a command's ("press
/// Enter", "brightness", the open apps' names), so a two-word command isn't heard as "Presenter" or
/// "Increase fitness". The on-device model gets it as its context prompt, Apple's as contextual
/// words; the cloud models' transcription endpoint has no way to take it.
struct SpeechContext: Equatable {
    var words: [String] = []

    static let none = SpeechContext()

    /// For Qwen3-ASR's context (its system prompt): just the words, the Chinese ones first. The words
    /// it reads first tell it the language: an English sentence around them, or English words first,
    /// made it translate mixed Chinese into English ("帮我 build 一个" came back "Help me build one";
    /// 2–3 of the bench's 21 mixed clips with English first, none with Chinese first).
    var prompt: String {
        let chinese = words.filter { $0.unicodeScalars.contains(where: PolishScore.isCJK) }
        return (chinese + words.filter { !chinese.contains($0) }).joined(separator: ", ")
    }
}

extension SpeechEngine: DictationEngine {
    var isBatch: Bool { false }
    var context: SpeechContext {
        get { SpeechContext(words: contextualWords) }
        set { contextualWords = newValue.words }
    }
    func start(mics: MicPick?, onLevel: @escaping (Float) -> Void, onMic: @escaping (MicEvent) -> Void,
               onError: @escaping (String) -> Void) {
        start(mics: mics, onLevel: onLevel, onMic: onMic, onUtterance: nil, onError: onError)
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
