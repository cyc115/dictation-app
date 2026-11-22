import Foundation

/// How you edited a dictation right after it was pasted (`EditWatcher`, *Learn from my edits*),
/// saved on its History entry. Only the pasted text as you left it is kept: never your keys, never
/// the rest of the text box.
struct Capture: Codable, Equatable {
    /// How the edit was followed.
    enum Mode: String, Codable {
        /// The text box was read back (Accessibility).
        case readback
        /// The app doesn't say what's in the box: your keys were applied to the pasted text in memory.
        case keystrokes
    }

    /// Where it stands. Only `accepted` and `auto` train Learn (they set the entry's `correction`).
    enum State: String, Codable {
        /// Waits in Corrections for your Accept. Every capture starts here and stays until you act on
        /// it (the judge makes it `auto` only with `trainOnUnreviewedCaptures`, off by default).
        case waiting
        /// Judged clear enough to train without review (phase 4), only with `trainOnUnreviewedCaptures`
        /// on. Ones already saved stay so (they train, and can be dismissed). Not kept past "Keep history".
        case auto
        /// You accepted it, or typed a correction on it: yours, kept like any correction.
        case accepted
        /// You dismissed it: counts for nothing.
        case dismissed
    }

    /// The pasted text as you left it.
    var edited: String
    var mode: Mode
    /// The app it was pasted into, by name.
    var app: String
    var state: State = .waiting

    /// It trains Learn as a captured fix (the "captured" badge, the tile's count).
    var trains: Bool { state == .accepted || state == .auto }

    init(edited: String, mode: Mode, app: String, state: State = .waiting) {
        self.edited = edited
        self.mode = mode
        self.app = app
        self.state = state
    }

    /// A state or mode this build doesn't know (written by a newer one) reads as `dismissed` and
    /// `keystrokes`, and one with no text as `dismissed`: it then counts for nothing, so history.json
    /// still loads and nothing unknown trains anything after going back to an older build.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let edited = try? c.decodeIfPresent(String.self, forKey: .edited)
        self.edited = edited ?? ""
        mode = (try? c.decodeIfPresent(Mode.self, forKey: .mode)) ?? .keystrokes
        app = (try? c.decodeIfPresent(String.self, forKey: .app)) ?? ""
        state = edited == nil ? .dismissed : (try? c.decodeIfPresent(State.self, forKey: .state)) ?? .dismissed
    }
}
