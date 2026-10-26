import AVFoundation
import Foundation

/// Records the mic to a 16 kHz WAV while dictating, for engines that transcribe the whole dictation
/// once you stop: `CloudEngine` uploads it, `LocalEngine` runs the on-device model on it.
class RecordingEngine {
    var isBatch: Bool { true }
    /// Set while "Keep recordings" is on: finished recordings go here instead of being deleted.
    var archive: RecordingArchive?
    /// Set with `archive`, before each dictation: the polish half of its JSON.
    var note: RecordingNote?

    let mic = MicCapture()
    private let recordings = RecordingSlot()

    /// Starts a new recording file. Called by `start`; tests call it directly with `record(_:)`
    /// to run the real stop path without a microphone.
    func beginRecording() -> Bool {
        recordings.begin(archive: archive, note: note) != nil
    }

    /// Appends audio to the current recording (from the mic tap's thread, or a test).
    func record(_ buffer: AVAudioPCMBuffer) {
        recordings.append(buffer)
    }

    func start(inputUID: String, backups: Bool, onLevel: @escaping (Float) -> Void, onMic: @escaping (MicEvent) -> Void,
               onError: @escaping (String) -> Void) {
        guard beginRecording() else { return onError("Couldn't create a recording file.") }
        // A better mic won (onRestart): its audio from the start replaces what was recorded.
        mic.startDictation(inputUID: inputUID, backups: backups, onBuffer: { [weak self] in self?.record($0) }, onLevel: onLevel,
                  onEvent: onMic, onRestart: { [weak self] in self?.beginRecording() ?? false }, onError: onError)
    }

    /// Stops the mic and closes the recording, ready to transcribe. Nil when there's nothing to
    /// transcribe; then `completion` or `failure` has been called.
    func finishRecording(completion: (String) -> Void, failure: (String) -> Void) -> DictationRecording? {
        mic.stop()
        let recording = recordings.take()
        if mic.heardOnlySilence {  // don't transcribe it: models make up text from silence
            recording?.discard()
            failure(MicCapture.silenceMessage)
            return nil
        }
        guard let recording, recording.isSpeech else {
            recording?.discard()
            completion("")  // too short to be speech
            return nil
        }
        recording.finish()
        return recording
    }

    func cancel() {
        mic.stop()
        recordings.discard()
    }
}
