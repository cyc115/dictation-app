import AppKit

/// Small pill at the bottom of the screen: ✕ cancel · live waveform (+ mic name) · ✓ paste.
/// Also shows short status text ("Polishing…", errors) in the same pill.
///
/// With a slow mic (Bluetooth) the pill first shows that the mic is starting, then flashes green when
/// it's live, so you know when you can talk. It flashes yellow when the dictation moves to a mic that
/// hears you better, and glows red while no audio is coming in. In command mode it's blue, with
/// "Command" for the mic name, and ends in a green or red message (`PillMessage`). What it's animating is `PillState`,
/// each frame's look `PillLook`, and where things sit `PillLayout`; this class draws them.
class OverlayWindow {
    var onCancel: (() -> Void)?
    var onConfirm: (() -> Void)?

    enum Mode { case hidden, listening, processing, message }

    private static let bottomMargin: CGFloat = 28
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
    /// Listening for (or deciding) a command: blue bars and edge, "Command" for the mic name.
    private(set) var isCommand = false
    private(set) var state = PillState()
    /// The layout on screen; while narrowing, the listening one it started from.
    private var layout = PillLayout(width: PillLayout.listeningWidth, content: .listening(caption: false))
    /// The glow last applied, so an unchanged one isn't set again every frame.
    private var shownGlow: (CGFloat, PillLook.Aura) = (0, .green)
    private var animation: Timer?
    /// While the mic is starting: the width its plain caption will need, so the pill keeps one width.
    private var plainCaptionWidth: CGFloat = 0

    /// The mic is starting: the pill is showing "Starting <mic>…".
    var isWarmingUp: Bool { state.isWarmingUp }
    /// The listening pill is narrowing into the processing one.
    var isNarrowing: Bool { state.isNarrowing }
    /// Whether the pill is glowing red for "no audio".
    var isShowingNoAudio: Bool { state.isShowingNoAudio }
    /// Where the pill itself is on screen (its window is at least `glowMargin` bigger all round).
    var pillFrame: NSRect {
        guard let panel else { return .zero }
        return background.frame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
    }

    // MARK: - Public

    /// `micName` is shown in full under the waveform; nil hides the caption. `warmingUp`: the mic is
    /// slow to start (Bluetooth), so the pill says so until `micLive()`.
    func showListening(micName: String? = nil, warmingUp: Bool = false, command: Bool = false) {
        isCommand = command
        stopAnimation()
        waveform.reset()
        waveform.processing = false
        waveform.tint = command ? NSColor(PillLook.commandBlue) : .white
        self.micName = micName ?? ""
        state = .listening(warmingUp: warmingUp, at: now())
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
        if state.isWarmingUp {
            plainCaptionWidth = 0
            setMicName(micName)
        }
        state.micLive(at: now())
        animate()
    }

    /// The dictation moved to a mic that hears you better: its name, and a yellow flash.
    func micSwitched(to name: String) {
        guard mode == .listening else { return }
        micName = name
        state.micSwitched(at: now())
        plainCaptionWidth = 0
        setMicName(name)
        present(.listening)
        animate()
    }

    /// No audio is coming in from the mic: a red glow fades in and stays until it does.
    func micSilent() {
        guard mode == .listening, !state.isShowingNoAudio else { return }
        state.micSilent(at: now())
        animate()
    }

    private func setMicName(_ name: String?) {
        if isCommand { return setCaption("Command", symbol: "chevron.forward", accessibility: "Command mode") }
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
    /// into this one rather than jumping. Already showing it (transcribing, then polishing): nothing
    /// changes, so a narrowing in progress isn't cut short.
    func showProcessing() {
        guard mode != .processing else { return }
        let fromListening = mode == .listening && panel?.isVisible == true && layout.width > PillLayout.processingWidth
        waveform.processing = true
        guard fromListening else { return present(.processing) }
        stopAnimation()
        autoHide?.cancel()
        mode = .processing
        state = .narrowing(at: now())  // from `layout`, the listening one
        startAnimation()
    }

    /// A message for `message.seconds`: its title over a dimmer detail, with a green edge when
    /// something worked, or a red one and a small shake when it didn't.
    func show(_ message: PillMessage) {
        isCommand = false
        label.attributedStringValue = Self.message(message.title, detail: message.detail)
        present(.message)
        if message.tone != .plain { apply(PillLook(glow: 1, aura: message.tone == .done ? .green : .red)) }
        if message.tone == .failed && !reduceMotion() {
            let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
            shake.values = [0, -6, 6, -4, 4, 0]
            shake.duration = 0.3
            shake.isAdditive = true
            background.layer?.add(shake, forKey: "shake")
        }
        hide(after: message.seconds)
    }

    private func hide(after seconds: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        autoHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// A message line, and an optional dimmer, smaller line under it.
    private static func message(_ text: String, detail: String?) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium), .foregroundColor: NSColor.white, .paragraphStyle: paragraph])
        if let detail, !detail.isEmpty {
            result.append(NSAttributedString(string: "\n" + detail, attributes: [
                .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor(white: 1, alpha: 0.6), .paragraphStyle: paragraph]))
        }
        return result
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

    // MARK: - Animation

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
        if state.isAnimating { startAnimation() } else { applyLook() }
    }

    /// Back to the plain pill, with no animation running.
    private func stopAnimation() {
        animation?.invalidate()
        animation = nil
        state = PillState()
        cancelButton.alphaValue = 1
        confirmButton.alphaValue = 1
        plainCaptionWidth = 0
        apply(.plain)
        panel?.hasShadow = true
    }

    private func applyLook() {
        let time = now()
        if state.isNarrowing {
            if state.isNarrowed(at: time) {
                finishNarrowing()
            } else {
                layOutNarrowing(state.look(at: time, reduceMotion: false))
            }
            return
        }
        apply(state.look(at: time, reduceMotion: reduceMotion()))
        if !state.isAnimating, animation != nil {
            animation?.invalidate()
            animation = nil
        }
    }

    /// The pill partway from its listening layout to the processing one, centered in the window it
    /// had while listening.
    private func layOutNarrowing(_ look: PillLook) {
        guard let panel else { return }
        let current = layout.interpolated(to: PillLayout(width: PillLayout.processingWidth, content: .processing), look.narrowing)
        background.frame = NSRect(x: (panel.frame.width - current.width) / 2, y: Self.glowMargin, width: current.width,
                                  height: PillLayout.height)
        place(current)
        micLabel.frame = layout.caption  // the name fades out where it was
        cancelButton.alphaValue = look.controlsAlpha
        confirmButton.alphaValue = look.controlsAlpha
        micLabel.alphaValue = look.captionAlpha
        panel.invalidateShadow()
    }

    /// The narrowing is over: the processing pill, left in the window it narrowed in. Resizing the
    /// window now could show the pill a frame out of place: the window and its contents don't
    /// always change on the same frame.
    private func finishNarrowing() {
        layOutNarrowing(.narrowing(since: PillLook.narrowDuration))
        layout = PillLayout(width: PillLayout.processingWidth, content: .processing)
        stopAnimation()
        cancelButton.isHidden = true
        confirmButton.isHidden = true
        micLabel.isHidden = true
    }

    /// Every part of the pill where `layout` puts it.
    private func place(_ layout: PillLayout) {
        cancelButton.frame = layout.cancel
        confirmButton.frame = layout.confirm
        waveform.frame = layout.waveform
        micLabel.frame = layout.caption
        label.frame = layout.label
    }

    private func apply(_ look: PillLook) {
        waveform.show(look)
        confirmButton.emphasis = look.confirmEmphasis
        micLabel.alphaValue = look.captionAlpha
        let g = look.glow
        if shownGlow != (g, look.aura) {
            shownGlow = (g, look.aura)
            // The view's shadow, not the layer's: AppKit resets a layer-backed view's layer shadow.
            if g > 0 {
                let glow = NSShadow()
                glow.shadowColor = NSColor(PillLook.color(look.aura, alpha: 0.8 * g))
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
        let edge = look.edge(command: isCommand)
        layer.borderWidth = edge.width
        layer.borderColor = NSColor(edge.color).cgColor
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

        let showControls = newMode == .listening
        let showMic = showControls && micLabel.attributedStringValue.length > 0
        switch newMode {
        case .message:
            label.sizeToFit()
            layout = PillLayout(width: PillLayout.messageWidth(text: label.frame.width), content: .message,
                                labelHeight: label.frame.height)
        case .processing:
            layout = PillLayout(width: PillLayout.processingWidth, content: .processing)
        default:
            // Wide enough for the whole mic name between the two buttons (and, while the mic starts,
            // for its plain caption too, so the pill doesn't change width when it goes live).
            let shown = showMic ? micLabel.attributedStringValue.size().width : 0
            layout = PillLayout(width: PillLayout.listeningWidth(caption: max(shown, plainCaptionWidth)),
                                content: .listening(caption: showMic))
        }
        cancelButton.isHidden = !showControls
        confirmButton.isHidden = !showControls
        waveform.isHidden = newMode == .message
        label.isHidden = newMode != .message
        micLabel.isHidden = !showMic
        place(layout)
        let width = layout.width, h = PillLayout.height
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
        let panel = makePanel(NSRect(x: 0, y: 0, width: PillLayout.listeningWidth + 2 * m, height: PillLayout.height + 2 * m))
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
        background.layer?.cornerRadius = PillLayout.height / 2
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        content.addSubview(background)

        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.alignment = .center
        label.maximumNumberOfLines = 2  // a command's result has a second, smaller line

        micLabel.lineBreakMode = .byTruncatingTail
        micLabel.cell?.truncatesLastVisibleLine = true
        micLabel.setAccessibilityIdentifier("overlay.mic")

        for view in [waveform, label, micLabel, cancelButton, confirmButton] as [NSView] {
            background.addSubview(view)
        }
        self.panel = panel
    }
}

private extension NSColor {
    convenience init(_ color: PillLook.RGBA) {
        self.init(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }
}
