import AppKit

/// Small pill at the bottom of the screen: ✕ cancel · live waveform (+ mic name) · ✓ paste.
/// Also shows short status text ("Polishing…", errors) in the same pill.
///
/// With a slow mic (Bluetooth) the pill first shows that the mic is starting, then flashes green when
/// it's live (`PillLook`), so you know when you can talk. It flashes yellow when the dictation moves
/// to a mic that hears you better, and glows red while no audio is coming in.
class OverlayWindow {
    var onCancel: (() -> Void)?
    var onConfirm: (() -> Void)?

    enum Mode { case hidden, listening, processing, message }

    static let height: CGFloat = 40
    static let listeningWidth: CGFloat = 164
    /// The pill widens to fit a long mic name, up to this width (then truncates).
    static let maxListeningWidth: CGFloat = 340
    /// The "working" pill: just the ripple.
    static let processingWidth: CGFloat = 84
    private static let bottomMargin: CGFloat = 28
    /// The edge and glow colors (system green, yellow, red).
    private static func color(_ aura: PillLook.Aura) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        switch aura {
        case .green: return (52, 199, 89)
        case .yellow: return (255, 204, 0)
        case .red: return (255, 59, 48)
        }
    }
    /// Clear space around the pill inside its window, for the ready glow and bounce to draw into.
    static let glowMargin: CGFloat = 16

    private(set) var panel: NSPanel?
    /// Makes the pill's window. Snapshot tests swap in one with a fixed scale, so the pill renders
    /// the same whatever display it would open on.
    var makePanel: (NSRect) -> NSPanel = {
        NSPanel(contentRect: $0, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    }
    /// The clock the warm-up animation runs on (tests and the README frames step it by hand).
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private let background = NSView()
    let waveform = WaveformView()
    let label = NSTextField(labelWithString: "")
    /// Small caption under the waveform naming the microphone in use.
    let micLabel = NSTextField(labelWithString: "")
    private lazy var cancelButton = CircleButton(symbol: "xmark", label: "Cancel dictation", fill: NSColor(white: 1, alpha: 0.18), tint: .white) { [weak self] in
        self?.onCancel?()
    }
    private(set) lazy var confirmButton = CircleButton(symbol: "checkmark", label: "Stop and paste", fill: .white, tint: .black) { [weak self] in
        self?.onConfirm?()
    }
    private(set) var mode = Mode.hidden
    private var autoHide: DispatchWorkItem?
    private var micName = ""
    /// When the slow mic started (while it's starting); the green or yellow flash in progress; and
    /// since when no audio has come in (red).
    private var warmingSince: TimeInterval?
    private var flash: (since: TimeInterval, aura: PillLook.Aura)?
    private var silentSince: TimeInterval?
    /// The glow last applied, so an unchanged one isn't set again every frame.
    private var shownGlow: (CGFloat, PillLook.Aura) = (0, .green)
    /// Since you stopped, while the pill narrows to the processing one: when, and what it started from.
    private var narrowing: (since: TimeInterval, width: CGFloat, waveform: NSRect)?
    private var animation: Timer?
    /// While the mic is starting: the width its plain caption will need, so the pill keeps one width.
    private var plainCaptionWidth: CGFloat = 0

    /// The mic is starting: the pill is showing "Starting <mic>…".
    var isWarmingUp: Bool { warmingSince != nil }
    /// The listening pill is narrowing into the processing one.
    var isNarrowing: Bool { narrowing != nil }
    /// Where the pill itself is on screen (its window is `glowMargin` bigger all round).
    var pillFrame: NSRect { panel?.frame.insetBy(dx: Self.glowMargin, dy: Self.glowMargin) ?? .zero }

    // MARK: - Public

    /// `micName` is shown in full under the waveform; nil hides the caption. `warmingUp`: the mic is
    /// slow to start (Bluetooth), so the pill says so until `micLive()`.
    func showListening(micName: String? = nil, warmingUp: Bool = false) {
        stopAnimation()
        waveform.reset()
        waveform.processing = false
        self.micName = micName ?? ""
        warmingSince = warmingUp ? now() : nil
        plainCaptionWidth = 0
        if warmingUp, let micName, !micName.isEmpty {
            plainCaptionWidth = Self.caption(micName, symbol: "mic.fill").size().width
            setCaption("Starting \(micName)…", symbol: "headphones", accessibility: "Microphone starting: \(micName)")
        } else {
            setMicName(micName)
        }
        present(.listening)
        if warmingUp { startAnimation() }
    }

    /// The mic sent its first real audio: if the pill was showing the wait, it flashes green; any
    /// red "no audio" glow goes.
    func micLive() {
        guard mode == .listening else { return }
        silentSince = nil
        if warmingSince != nil {
            warmingSince = nil
            flash = (now(), .green)
            plainCaptionWidth = 0
            setMicName(micName)
        }
        animate()
    }

    /// The dictation moved to a mic that hears you better: its name, and a yellow flash.
    func micSwitched(to name: String) {
        guard mode == .listening else { return }
        micName = name
        warmingSince = nil
        silentSince = nil
        plainCaptionWidth = 0
        flash = (now(), .yellow)
        setMicName(name)
        present(.listening)
        animate()
    }

    /// No audio is coming in from the mic: a red glow fades in and stays until it does.
    func micSilent() {
        guard mode == .listening, silentSince == nil else { return }
        silentSince = now()
        animate()
    }

    /// Whether the pill is glowing red for "no audio".
    var isShowingNoAudio: Bool { silentSince != nil }

    private func setMicName(_ name: String?) {
        guard let name = name, !name.isEmpty else {
            micLabel.attributedStringValue = NSAttributedString()
            return
        }
        setCaption(name, symbol: "mic.fill", accessibility: "Microphone: \(name)")
    }

    private func setCaption(_ text: String, symbol: String, accessibility: String) {
        micLabel.attributedStringValue = Self.caption(text, symbol: symbol)
        micLabel.setAccessibilityLabel(accessibility)
    }

    /// The caption: a small symbol, then `text`, dimmed.
    private static func caption(_ string: String, symbol: String) -> NSAttributedString {
        let dim = NSColor(white: 1, alpha: 0.5)
        let font = NSFont.systemFont(ofSize: 9, weight: .medium)
        let text = NSMutableAttributedString()
        if let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 7, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [dim]))) {
            let attachment = NSTextAttachment()
            attachment.image = icon
            attachment.bounds = NSRect(x: 0, y: -0.5, width: icon.size.width, height: icon.size.height)
            text.append(NSAttributedString(attachment: attachment))
            text.append(NSAttributedString(string: " "))
        }
        text.append(NSAttributedString(string: string))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        text.addAttributes([.font: font, .foregroundColor: dim, .paragraphStyle: paragraph],
                           range: NSRange(location: 0, length: text.length))
        return text
    }

    func setLevel(_ level: Float) {
        guard mode == .listening else { return }
        waveform.push(level)
    }

    /// Bars ripple while waiting on something (e.g. AI polish). From the listening pill, it narrows
    /// into this one rather than jumping.
    func showProcessing() {
        let from = background.frame.width
        let fromListening = mode == .listening && panel?.isVisible == true && from > Self.processingWidth
        waveform.processing = true
        guard fromListening else { return present(.processing) }
        stopAnimation()
        autoHide?.cancel()
        mode = .processing
        narrowing = (now(), from, waveform.frame)
        startAnimation()
    }

    func showMessage(_ text: String, hideAfter seconds: TimeInterval = 3) {
        label.stringValue = text
        present(.message)
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        autoHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide() {
        autoHide?.cancel()
        guard mode != .hidden, let panel = panel else { return }
        mode = .hidden
        stopAnimation()
        waveform.processing = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            if self?.mode == .hidden { panel.orderOut(nil) }
        })
    }

    /// Hides the pill unless it is showing a message the user still needs to read.
    func hideUnlessMessage() {
        if mode != .message { hide() }
    }

    // MARK: - Warm-up animation

    /// Redraws the animated look for `now()` (the timer calls it; tests and the README frames call it
    /// after moving the clock).
    func tick() { applyLook() }

    private func startAnimation() {
        guard animation == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        animation = timer
        applyLook()
    }

    /// Runs the animation if something needs it, else shows the look as it is now.
    private func animate() {
        if warmingSince != nil || flash != nil || silentSince != nil { startAnimation() } else { applyLook() }
    }

    /// Back to the plain pill, with no animation running.
    private func stopAnimation() {
        animation?.invalidate()
        animation = nil
        warmingSince = nil
        flash = nil
        silentSince = nil
        narrowing = nil
        cancelButton.alphaValue = 1
        confirmButton.alphaValue = 1
        plainCaptionWidth = 0
        apply(.plain)
        panel?.hasShadow = true
    }

    private func applyLook() {
        let reduce = reduceMotion()
        if let narrowing {
            let elapsed = now() - narrowing.since
            if PillLook.narrowed(since: elapsed) {
                present(.processing)  // the final layout, in a window its size
            } else {
                layOutNarrowing(.narrowing(since: elapsed), from: narrowing)
            }
            return
        }
        var look = PillLook.plain
        if let since = warmingSince {
            look = .waiting(elapsed: now() - since, reduceMotion: reduce)
        } else if let flash {
            let elapsed = now() - flash.since
            if PillLook.settled(since: elapsed) {
                self.flash = nil
            } else {
                look = .ready(since: elapsed, reduceMotion: reduce, aura: flash.aura)
            }
        }
        if let since = silentSince, flash == nil {
            look.glow = PillLook.silentGlow(since: now() - since)
            look.aura = .red
        }
        apply(look)
        if warmingSince == nil, flash == nil, silentSince == nil, animation != nil {
            animation?.invalidate()
            animation = nil
        }
    }

    /// The pill partway from its listening layout (`from`) to the processing one, centered in the
    /// window it had while listening.
    private func layOutNarrowing(_ look: PillLook, from: (since: TimeInterval, width: CGFloat, waveform: NSRect)) {
        guard let panel else { return }
        let h = Self.height, button: CGFloat = 28, pad = (h - button) / 2
        let lerp = { (a: CGFloat, b: CGFloat) in a + (b - a) * look.narrowing }
        let width = lerp(from.width, Self.processingWidth)
        background.frame = NSRect(x: (panel.frame.width - width) / 2, y: Self.glowMargin, width: width, height: h)
        confirmButton.frame.origin.x = width - pad - button
        cancelButton.alphaValue = look.controlsAlpha
        confirmButton.alphaValue = look.controlsAlpha
        micLabel.alphaValue = look.captionAlpha
        let x = lerp(from.waveform.minX, 14)
        waveform.frame = NSRect(x: x, y: lerp(from.waveform.minY, 9), width: width - 2 * x, height: lerp(from.waveform.height, h - 18))
        panel.invalidateShadow()
    }

    private func apply(_ look: PillLook) {
        waveform.show(look)
        confirmButton.emphasis = look.confirmEmphasis
        micLabel.alphaValue = look.captionAlpha
        let g = look.glow
        let (r, gr, b) = Self.color(look.aura)
        if shownGlow != (g, look.aura) {
            shownGlow = (g, look.aura)
            // The view's shadow, not the layer's: AppKit resets a layer-backed view's layer shadow.
            if g > 0 {
                let glow = NSShadow()
                glow.shadowColor = NSColor(red: r / 255, green: gr / 255, blue: b / 255, alpha: 0.8 * g)
                glow.shadowBlurRadius = 14 * g
                glow.shadowOffset = .zero
                background.shadow = glow
            } else {
                background.shadow = nil
            }
            // The glow stands in for the window's drop shadow while it shows.
            if let panel, panel.hasShadow != (g == 0) {
                panel.hasShadow = g == 0
                panel.invalidateShadow()
            }
        }
        guard let layer = background.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.borderWidth = 0.5 + 1.1 * g
        // White at 14% (the resting edge) → the aura's color.
        layer.borderColor = NSColor(red: (255 - (255 - r) * g) / 255, green: (255 - (255 - gr) * g) / 255,
                                    blue: (255 - (255 - b) * g) / 255, alpha: 0.14 + 0.76 * g).cgColor
        let bounds = layer.bounds
        // AppKit puts a view's layer anchor at its corner: scale about the pill's center.
        var transform = CATransform3DMakeTranslation(-bounds.midX, -bounds.midY, 0)
        transform = CATransform3DConcat(transform, CATransform3DMakeScale(look.scale, look.scale, 1))
        layer.transform = CATransform3DConcat(transform, CATransform3DMakeTranslation(bounds.midX, bounds.midY, 0))
        CATransaction.commit()
    }

    // MARK: - Layout

    private func present(_ newMode: Mode) {
        autoHide?.cancel()
        if panel == nil { build() }
        guard let panel = panel else { return }
        let wasHidden = mode == .hidden
        mode = newMode
        if newMode != .listening { stopAnimation() }
        background.layer?.transform = CATransform3DIdentity  // laid out unscaled; the look re-applies it

        let h = Self.height
        let button: CGFloat = 28, pad = (h - button) / 2
        let width: CGFloat
        switch newMode {
        case .message:
            label.sizeToFit()
            width = min(max(label.frame.width + 36, Self.listeningWidth), 460)
        case .processing:
            width = Self.processingWidth
        default:
            // Wide enough for the whole mic name between the two buttons (and, while the mic starts,
            // for its plain caption too, so the pill doesn't change width when it goes live).
            let sideInset = pad + button + 5
            let shown = micLabel.attributedStringValue.length > 0 ? micLabel.attributedStringValue.size().width : 0
            let needed = max(shown, plainCaptionWidth)
            let caption = needed > 0 ? ceil(needed) + 6 : 0
            width = min(max(Self.listeningWidth, caption + 2 * sideInset), Self.maxListeningWidth)
        }

        let showControls = newMode == .listening
        cancelButton.isHidden = !showControls
        confirmButton.isHidden = !showControls
        waveform.isHidden = newMode == .message
        label.isHidden = newMode != .message
        let showMic = showControls && micLabel.attributedStringValue.length > 0
        micLabel.isHidden = !showMic

        cancelButton.frame = NSRect(x: pad, y: pad, width: button, height: button)
        confirmButton.frame = NSRect(x: width - pad - button, y: pad, width: button, height: button)
        let inset = showControls ? pad + button + 5 : 14
        if showMic {
            // Waveform on top, mic caption tucked underneath.
            waveform.frame = NSRect(x: inset, y: 16, width: width - 2 * inset, height: 18)
            micLabel.frame = NSRect(x: inset - 2, y: 4, width: width - 2 * inset + 4, height: 12)
        } else {
            waveform.frame = NSRect(x: inset, y: 9, width: width - 2 * inset, height: h - 18)
        }
        let labelHeight = label.frame.height
        label.frame = NSRect(x: 18, y: (h - labelHeight) / 2, width: width - 36, height: labelHeight)
        let m = Self.glowMargin
        background.frame = NSRect(x: m, y: m, width: width, height: h)

        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(NSRect(x: visible.midX - width / 2 - m, y: visible.minY + Self.bottomMargin - m,
                              width: width + 2 * m, height: h + 2 * m), display: true)
        applyLook()

        if wasHidden {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
    }

    private func build() {
        let m = Self.glowMargin
        let panel = makePanel(NSRect(x: 0, y: 0, width: Self.listeningWidth + 2 * m, height: Self.height + 2 * m))
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let content = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        content.autoresizingMask = [.width, .height]
        content.wantsLayer = true  // so the pill's glow and bounce are part of one layer tree
        panel.contentView = content

        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor(white: 0.06, alpha: 0.92).cgColor
        background.layer?.cornerRadius = Self.height / 2
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        content.addSubview(background)

        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.alignment = .center

        micLabel.lineBreakMode = .byTruncatingTail
        micLabel.cell?.truncatesLastVisibleLine = true
        micLabel.setAccessibilityIdentifier("overlay.mic")

        for view in [waveform, label, micLabel, cancelButton, confirmButton] as [NSView] {
            background.addSubview(view)
        }
        self.panel = panel
    }
}

// MARK: - Waveform

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

    override func draw(_ dirtyRect: NSRect) {
        let levels = shownLevels ?? self.levels
        NSColor.white.setFill()
        let total = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * gap
        var x = (bounds.width - total) / 2
        let mid = CGFloat(barCount - 1) / 2
        for i in 0..<barCount {
            let fromCenter = abs(CGFloat(i) - mid) / mid      // 0 at center, 1 at edges
            let envelope = 1 - 0.45 * fromCenter * fromCenter  // taller in the middle
            let h = max(barWidth, levels[i] * envelope * bounds.height)
            if let barAlphas { NSColor(white: 1, alpha: barAlphas[i]).setFill() }
            let bar = NSRect(x: x, y: (bounds.height - h) / 2, width: barWidth, height: h)
            NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            x += barWidth + gap
        }
    }
}

// MARK: - Round icon button

/// Clickable without activating the app, so focus stays in the app you're typing into.
final class CircleButton: NSView {
    private let symbol: String
    private let fill: NSColor
    private let tint: NSColor
    private let action: () -> Void
    private var pressed = false
    /// 1 = normal; lower dims it (✓ while the mic is still starting: nothing to paste yet).
    var emphasis: CGFloat = 1 {
        didSet { if emphasis != oldValue { needsDisplay = true } }
    }

    init(symbol: String, label: String, fill: NSColor, tint: NSColor, action: @escaping () -> Void) {
        self.symbol = symbol
        self.fill = fill
        self.tint = tint
        self.action = action
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        setAccessibilityIdentifier("overlay." + symbol)
    }

    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        pressed = false
        needsDisplay = true
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let alpha = fill.alphaComponent * emphasis
        (pressed ? fill.withAlphaComponent(alpha * 0.6) : fill.withAlphaComponent(alpha)).setFill()
        NSBezierPath(ovalIn: bounds).fill()
        let tint = emphasis < 1 ? self.tint.withAlphaComponent(0.35 + 0.65 * emphasis) : self.tint
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)?
            .withSymbolConfiguration(config) else { return }
        let size = image.size
        image.draw(in: NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                              width: size.width, height: size.height))
    }
}
