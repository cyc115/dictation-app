import Foundation

/// What a dictation is for, and so what happens to it: everything the controller does differently
/// by kind is asked here. A new kind (say, translate) is a new case, and the compiler points at each
/// place that has to decide for it.
enum DictationKind: Equatable {
    /// Typed (or pasted) into the front app, polished if AI polish is on, saved to History.
    case text
    /// Run as a command (`CommandMode`): never typed or polished; History › Commands.
    case command

    /// Whether AI polish, if on, gets the transcript.
    var polishes: Bool { self == .text }
    /// Where Keep recordings, if on, keeps its audio (for speech-model test sets): a command's in
    /// Recordings/Commands, apart from the dictations the speech benchmarks read.
    func archive(in archive: RecordingArchive) -> RecordingArchive {
        self == .text ? archive : archive.commands
    }
    /// Whether the pill stays up after you stop, until it's done (a command shows how it went).
    var waitsInThePill: Bool { self == .command }
    /// Whether the Enter button, right after the stop, sends it (presses Return once it's in).
    var canBeSent: Bool { self == .text }
    /// The dictation button stops it (a command is run with the Enter button or ✓ instead).
    var stopsWithDictationButton: Bool { self == .text }
}
