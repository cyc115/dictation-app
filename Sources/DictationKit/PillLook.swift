import CoreGraphics
import Foundation

/// How the pill looks while a slow mic (Bluetooth) starts and the moment it goes live, as a pure
/// function of time, so tests and the README animation can render any frame.
///
/// - Waiting: the bars are dots with a highlight sweeping across them left to right, and ✓ is dimmed.
///   Words spoken now would be lost.
/// - Ready: the edge flashes green and the pill bounces once while the bars ripple out from the
///   center. That's the cue to talk. Then it's the plain listening pill.
/// - Switched (Intelligent mic selection moved to a mic that hears you better): the same flash in yellow.
/// - No audio (the mic has sent nothing real for 3 s): a red edge and glow fade in and stay.
/// - Narrowing (you stopped, text is on the way): ✕, ✓ and the mic name fade, then the pill narrows
///   to the small processing pill while the bars turn into its ripple (`WaveformView`).
struct PillLook: Equatable {
    /// The edge and glow's color: what it's telling you.
    enum Aura: Equatable {
        /// The mic is live: talk.
        case green
        /// Moved to a mic that hears you better.
        case yellow
        /// No audio is coming in.
        case red
    }

    static let barCount = 13
    /// One sweep of the highlight across the dots.
    static let sweepPeriod: TimeInterval = 1.1
    /// The ripple out from the center; after it the bars follow the mic.
    static let rippleDuration: TimeInterval = 0.35
    static let bounceDuration: TimeInterval = 0.26
    /// The green edge fades out over this long; then the look is `plain`.
    static let glowDuration: TimeInterval = 0.65
    /// The red "no audio" glow fades in over this long.
    static let silentFadeIn: TimeInterval = 1.5
    /// Listening → processing, after which the pill is laid out narrow.
    static let narrowDuration: TimeInterval = 0.4

    /// Per bar, 0…1.
    var barAlphas = Array(repeating: CGFloat(1), count: barCount)
    /// Bar heights to draw instead of the mic's (0…1); nil: follow the mic.
    var levels: [CGFloat]?
    /// The edge and glow, 0…1, in `aura`'s color.
    var glow: CGFloat = 0
    var aura = Aura.green
    var scale: CGFloat = 1
    var captionAlpha: CGFloat = 1
    /// ✓ button, 1 = normal.
    var confirmEmphasis: CGFloat = 1
    /// ✕ and ✓ together (fading out as the pill narrows).
    var controlsAlpha: CGFloat = 1
    /// 0 = the listening pill's width and layout, 1 = the processing pill's.
    var narrowing: CGFloat = 0

    static let plain = PillLook()

    /// `elapsed` seconds into the wait. With `reduceMotion` the dots hold still.
    static func waiting(elapsed: TimeInterval, reduceMotion: Bool) -> PillLook {
        var look = PillLook(levels: Array(repeating: 0, count: barCount), confirmEmphasis: 0.3)
        if reduceMotion {
            look.barAlphas = Array(repeating: 0.4, count: barCount)
        } else {
            let sweep = CGFloat(elapsed.truncatingRemainder(dividingBy: sweepPeriod) / sweepPeriod)
            let position = sweep * CGFloat(barCount + 4) - 2  // enters and leaves off the ends
            look.barAlphas = (0..<barCount).map { 0.24 + 0.56 * exp(-pow(CGFloat($0) - position, 2) / 2.5) }
        }
        return look
    }

    /// `since` seconds after the mic went live (green) or the dictation moved to a better one
    /// (yellow). With `reduceMotion` there's no bounce.
    static func ready(since: TimeInterval, reduceMotion: Bool, aura: Aura = .green) -> PillLook {
        let s = CGFloat(since)
        var look = PillLook()
        look.aura = aura
        look.glow = clamp(1 - s / CGFloat(glowDuration))
        look.scale = reduceMotion ? 1 : 1 + 0.045 * sin(.pi * clamp(s / CGFloat(bounceDuration)))
        look.captionAlpha = clamp(s / 0.2)
        if since < rippleDuration {
            let mid = CGFloat(barCount - 1) / 2
            look.levels = (0..<barCount).map { i in
                let fromCenter = abs(CGFloat(i) - mid) / mid
                return 0.62 * sin(.pi * clamp((s - fromCenter * 0.11) / 0.22))
            }
            look.barAlphas = Array(repeating: 0.6 + 0.4 * clamp(s / 0.12), count: barCount)
            look.confirmEmphasis = 0.3 + 0.7 * clamp(s / 0.2)
        }
        return look
    }

    /// The red "no audio" glow `since` seconds after it was reported: fades in, then stays.
    static func silentGlow(since: TimeInterval) -> CGFloat {
        let t = clamp(CGFloat(since / silentFadeIn))
        return t * t * (3 - 2 * t)
    }

    /// `since` seconds after you stopped.
    static func narrowing(since: TimeInterval) -> PillLook {
        let s = CGFloat(since)
        var look = PillLook()
        look.controlsAlpha = 1 - easeInOut(clamp(s / 0.16))
        look.captionAlpha = 1 - clamp(s / 0.14)
        look.narrowing = easeInOut(clamp((s - 0.06) / 0.34))
        return look
    }

    /// The narrowing is over.
    static func narrowed(since: TimeInterval) -> Bool { since >= narrowDuration }

    /// The ready animation is over.
    static func settled(since: TimeInterval) -> Bool { since >= glowDuration }

    private static func clamp(_ value: CGFloat) -> CGFloat { min(max(value, 0), 1) }

    /// Slow, fast, slow (cubic).
    private static func easeInOut(_ t: CGFloat) -> CGFloat { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
}
