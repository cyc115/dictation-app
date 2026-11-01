import AVFoundation

/// The WAV of the dictation in progress: begun when it starts, appended to from the mic's thread,
/// begun afresh when a better mic wins, taken at stop or discarded. One per engine; the lock is
/// for the mic thread's appends against the main queue's begin, take and discard.
final class RecordingSlot {
    private var recording: DictationRecording?
    private let lock = NSLock()

    /// A new recording, discarding any earlier one; nil when the file couldn't be made.
    @discardableResult
    func begin(archive: RecordingArchive?, note: RecordingNote?) -> DictationRecording? {
        let new = DictationRecording(archive: archive, note: note)
        let old = lock.withLock { swap(new) }
        old?.discard()  // outside the lock: it's file I/O
        return new
    }

    /// From the mic's thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { recording?.append(buffer) }
    }

    /// Hands the recording over, leaving none.
    func take() -> DictationRecording? {
        lock.withLock { swap(nil) }
    }

    /// Under the lock: the recording so far, replaced by `new`.
    private func swap(_ new: DictationRecording?) -> DictationRecording? {
        defer { recording = new }
        return recording
    }

    func discard() { take()?.discard() }
}
