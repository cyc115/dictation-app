import Foundation

/// What the pill is animating, apart from the mic's own levels: the pure part of the overlay.
/// Events (`micLive`, `micSwitched`, …) change it; `look(at:)` says what to draw at a moment.
/// `OverlayWindow` only draws it.
///
/// What wins when several apply: a green or yellow flash shows over the red "no audio" glow; the
/// red glow shows over the warm-up's dots; narrowing (you stopped) replaces all of them.
struct PillState: Equatable {
    struct Flash: Equatable {
        let since: TimeInterval
        let aura: PillLook.Aura
    }

    /// When the slow mic started; nil once it's live.
    private(set) var warmingSince: TimeInterval?
    /// The green (live) or yellow (switched) flash in progress.
    private(set) var flash: Flash?
    /// Since when no audio has come in (red).
    private(set) var silentSince: TimeInterval?
    /// Since you stopped, while the pill narrows to the processing one.
    private(set) var narrowingSince: TimeInterval?

    /// A listening pill, its mic still starting if `warmingUp`.
    static func listening(warmingUp: Bool, at time: TimeInterval) -> PillState {
        PillState(warmingSince: warmingUp ? time : nil)
    }

    /// Stopped: narrowing into the processing pill.
    static func narrowing(at time: TimeInterval) -> PillState { PillState(narrowingSince: time) }

    var isWarmingUp: Bool { warmingSince != nil }
    var isNarrowing: Bool { narrowingSince != nil }
    var isShowingNoAudio: Bool { silentSince != nil }
    /// Something is moving, so the pill needs redrawing every frame.
    var isAnimating: Bool { warmingSince != nil || flash != nil || silentSince != nil || narrowingSince != nil }

    /// The mic sent its first real audio: the wait (if any) ends in a green flash; red goes.
    mutating func micLive(at time: TimeInterval) {
        silentSince = nil
        if warmingSince != nil {
            warmingSince = nil
            flash = Flash(since: time, aura: .green)
        }
    }

    /// Moved to a mic that hears you better: a yellow flash, and the wait and red end.
    mutating func micSwitched(at time: TimeInterval) {
        warmingSince = nil
        silentSince = nil
        flash = Flash(since: time, aura: .yellow)
    }

    /// No audio is coming in: the red glow starts fading in (once).
    mutating func micSilent(at time: TimeInterval) {
        if silentSince == nil { silentSince = time }
    }

    /// The narrowing is over: the pill is the processing one.
    func isNarrowed(at time: TimeInterval) -> Bool {
        narrowingSince.map { PillLook.narrowed(since: time - $0) } ?? false
    }

    /// What to draw at `time`. A finished flash is dropped.
    mutating func look(at time: TimeInterval, reduceMotion: Bool) -> PillLook {
        if let since = narrowingSince { return .narrowing(since: time - since) }
        if let flash, PillLook.settled(since: time - flash.since) { self.flash = nil }
        var look = PillLook.plain
        if let since = warmingSince {
            look = .waiting(elapsed: time - since, reduceMotion: reduceMotion)
        } else if let flash {
            look = .ready(since: time - flash.since, reduceMotion: reduceMotion, aura: flash.aura)
        }
        if let since = silentSince, flash == nil {
            look.glow = PillLook.silentGlow(since: time - since)
            look.aura = .red
        }
        return look
    }
}
