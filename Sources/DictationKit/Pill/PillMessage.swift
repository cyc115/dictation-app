import Foundation

/// A short message in the pill (`OverlayWindow.show`): a line, an optional smaller second line, and
/// what its edge says. Errors, "Add your cloud API key…", and how a command went are all one.
struct PillMessage: Equatable {
    enum Tone: Equatable {
        /// The resting edge.
        case plain
        /// Green: it worked.
        case done
        /// Red, with a small shake: it didn't.
        case failed
    }

    var title: String
    var detail: String?
    var tone = Tone.plain
    /// How long it stays up.
    var seconds: TimeInterval = 3

    static func plain(_ title: String, seconds: TimeInterval = 3) -> PillMessage {
        PillMessage(title: title, seconds: seconds)
    }
}
