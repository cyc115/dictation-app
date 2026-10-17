import CoreGraphics
import Foundation

/// How the pill looks while a slow mic (Bluetooth) starts and the moment it goes live, as a pure
/// function of time, so tests and the README animation can render any frame.
///
/// - Waiting: the bars are dots with a highlight sweeping across them left to right, and ✓ is dimmed.
///   Words spoken now would be lost.
/// - Ready: the edge flashes green and the pill bounces once while the bars ripple out from the
///   center. That's the cue to talk. Then it's the plain listening pill.
struct PillLook: Equatable {
    static let barCount = 13
    /// One sweep of the highlight across the dots.
    static let sweepPeriod: TimeInterval = 1.1
    /// The ripple out from the center; after it the bars follow the mic.
    static let rippleDuration: TimeInterval = 0.35
    static let bounceDuration: TimeInterval = 0.26
    /// The green edge fades out over this long; then the look is `plain`.
    static let glowDuration: TimeInterval = 0.65

    /// Per bar, 0…1.
    var barAlphas = Array(repeating: CGFloat(1), count: barCount)
    /// Bar heights to draw instead of the mic's (0…1); nil: follow the mic.
    var levels: [CGFloat]?
    /// The green edge and glow, 0…1.
    var glow: CGFloat = 0
    var scale: CGFloat = 1
    var captionAlpha: CGFloat = 1
    /// ✓ button, 1 = normal.
    var confirmEmphasis: CGFloat = 1

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

    /// `since` seconds after the mic went live. With `reduceMotion` there's no bounce.
    static func ready(since: TimeInterval, reduceMotion: Bool) -> PillLook {
        let s = CGFloat(since)
        var look = PillLook()
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

    /// The ready animation is over.
    static func settled(since: TimeInterval) -> Bool { since >= glowDuration }

    private static func clamp(_ value: CGFloat) -> CGFloat { min(max(value, 0), 1) }
}
