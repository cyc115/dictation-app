import AppKit

/// Mirrored bars driven by the mic level; the newest level enters on the right.
final class WaveformView: NSView {
    private let barCount = PillLook.barCount
    private let barWidth: CGFloat = 2.5
    private let gap: CGFloat = 2.5
    private(set) var levels: [CGFloat]
    private var smoothed: CGFloat = 0
    /// Loudest recent level; bars are scaled against it so any mic fills the height.
    private var peak: CGFloat = 0
    /// Gain never boosts quieter than this (≈ −38 dBFS), so silence and hiss stay flat.
    private static let peakFloor: CGFloat = 0.3
    /// Fixed per-bar variation so neighbouring bars differ like a real waveform
    /// (deterministic, so snapshots stay stable).
    private static let variation: [CGFloat] = [1.0, 0.72, 0.93, 0.8, 1.0, 0.66, 0.88, 0.97, 0.76, 0.9, 0.7, 1.0, 0.84]
    private var pushes = 0
    private var timer: Timer?
    private var phase: CGFloat = 0
    /// Ripple steps over which the bars turn from what they showed into the ripple, and those bars.
    private static let blendTicks = 10
    private var blendFrom: [CGFloat]?
    private var blendTick = 0
    /// The warm-up look's bar heights and opacities (nil: the mic's levels, fully white).
    private var shownLevels: [CGFloat]?
    private var barAlphas: [CGFloat]?

    var processing = false {
        didSet {
            guard processing != oldValue else { return }
            timer?.invalidate()
            timer = nil
            if processing {
                blendFrom = shownLevels ?? levels
                blendTick = 0
                shownLevels = nil
                barAlphas = nil
                timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                    self?.tick()
                }
            } else {
                reset()
            }
        }
    }

    override init(frame: NSRect) {
        levels = Array(repeating: 0, count: barCount)
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Draws `look`'s bars over the mic's levels while the mic starts or goes live.
    func show(_ look: PillLook) {
        let alphas = look.barAlphas.allSatisfy { $0 == 1 } ? nil : look.barAlphas
        guard look.levels != shownLevels || alphas != barAlphas else { return }
        shownLevels = look.levels
        barAlphas = alphas
        needsDisplay = true
    }

    func reset() {
        levels = Array(repeating: 0, count: barCount)
        blendFrom = nil
        smoothed = 0
        peak = 0
        pushes = 0
        needsDisplay = true
    }

    func push(_ level: Float) {
        let level = CGFloat(min(max(level, 0), 1))
        // Automatic gain: track the loudest recent speech (decays ~20%/s) and scale to it.
        peak = max(level, peak * 0.995, Self.peakFloor)
        // Lift quiet syllables so normal speech moves the bars a lot.
        let shaped = pow(level / peak, 0.6)
        // Fast attack, quick release, so syllables read as separate peaks.
        smoothed = max(shaped, smoothed * 0.72)
        let variation = Self.variation[pushes % Self.variation.count]
        pushes += 1
        levels.removeFirst()
        levels.append(min(smoothed * variation, 1))
        needsDisplay = true
    }

    /// One step of the processing ripple (the timer's; the README frames step it by hand).
    func tick() {
        phase += 0.22
        let ripple = (0..<barCount).map { 0.18 + 0.22 * (1 + sin(phase - CGFloat($0) * 0.55)) / 2 }
        if let from = blendFrom, blendTick < Self.blendTicks {
            blendTick += 1
            let t = CGFloat(blendTick) / CGFloat(Self.blendTicks)
            let p = t * t * (3 - 2 * t)
            levels = zip(from, ripple).map { $0 + ($1 - $0) * p }
        } else {
            blendFrom = nil
            levels = ripple
        }
        needsDisplay = true
    }

    /// The bars' color: white, or blue in command mode.
    var tint = NSColor.white { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let levels = shownLevels ?? self.levels
        tint.setFill()
        let total = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * gap
        var x = (bounds.width - total) / 2
        let mid = CGFloat(barCount - 1) / 2
        for i in 0..<barCount {
            let fromCenter = abs(CGFloat(i) - mid) / mid      // 0 at center, 1 at edges
            let envelope = 1 - 0.45 * fromCenter * fromCenter  // taller in the middle
            let h = max(barWidth, levels[i] * envelope * bounds.height)
            if let barAlphas { tint.withAlphaComponent(barAlphas[i]).setFill() }
            let bar = NSRect(x: x, y: (bounds.height - h) / 2, width: barWidth, height: h)
            NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            x += barWidth + gap
        }
    }
}
