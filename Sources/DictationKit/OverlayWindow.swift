import AppKit

/// Small pill at the bottom of the screen: ✕ cancel · live waveform (+ mic name) · ✓ paste.
/// Also shows short status text ("Polishing…", errors) in the same pill.
class OverlayWindow {
    var onCancel: (() -> Void)?
    var onConfirm: (() -> Void)?

    enum Mode { case hidden, listening, processing, message }

    static let height: CGFloat = 40
    static let listeningWidth: CGFloat = 164
    /// The pill widens to fit a long mic name, up to this width (then truncates).
    static let maxListeningWidth: CGFloat = 340
    private static let bottomMargin: CGFloat = 28

    private(set) var panel: NSPanel?
    private let background = NSView()
    let waveform = WaveformView()
    let label = NSTextField(labelWithString: "")
    /// Small caption under the waveform naming the microphone in use.
    let micLabel = NSTextField(labelWithString: "")
    private lazy var cancelButton = CircleButton(symbol: "xmark", label: "Cancel dictation", fill: NSColor(white: 1, alpha: 0.18), tint: .white) { [weak self] in
        self?.onCancel?()
    }
    private lazy var confirmButton = CircleButton(symbol: "checkmark", label: "Stop and paste", fill: .white, tint: .black) { [weak self] in
        self?.onConfirm?()
    }
    private(set) var mode = Mode.hidden
    private var autoHide: DispatchWorkItem?

    // MARK: - Public

    /// `micName` is shown in full under the waveform; nil hides the caption.
    func showListening(micName: String? = nil) {
        waveform.reset()
        waveform.processing = false
        setMicName(micName)
        present(.listening)
    }

    private func setMicName(_ name: String?) {
        guard let name = name, !name.isEmpty else {
            micLabel.attributedStringValue = NSAttributedString()
            return
        }
        let dim = NSColor(white: 1, alpha: 0.5)
        let font = NSFont.systemFont(ofSize: 9, weight: .medium)
        let text = NSMutableAttributedString()
        if let icon = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 7, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [dim]))) {
            let attachment = NSTextAttachment()
            attachment.image = icon
            attachment.bounds = NSRect(x: 0, y: -0.5, width: icon.size.width, height: icon.size.height)
            text.append(NSAttributedString(attachment: attachment))
            text.append(NSAttributedString(string: " "))
        }
        text.append(NSAttributedString(string: name))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        text.addAttributes([.font: font, .foregroundColor: dim, .paragraphStyle: paragraph],
                           range: NSRange(location: 0, length: text.length))
        micLabel.attributedStringValue = text
        micLabel.setAccessibilityLabel("Microphone: \(name)")
    }

    func setLevel(_ level: Float) {
        guard mode == .listening else { return }
        waveform.push(level)
    }

    /// Bars ripple while waiting on something (e.g. AI polish).
    func showProcessing() {
        waveform.processing = true
        present(.processing)
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

    // MARK: - Layout

    private func present(_ newMode: Mode) {
        autoHide?.cancel()
        if panel == nil { build() }
        guard let panel = panel else { return }
        let wasHidden = mode == .hidden
        mode = newMode

        let h = Self.height
        let button: CGFloat = 28, pad = (h - button) / 2
        let width: CGFloat
        switch newMode {
        case .message:
            label.sizeToFit()
            width = min(max(label.frame.width + 36, Self.listeningWidth), 460)
        case .processing:
            width = 84
        default:
            // Wide enough for the whole mic name between the two buttons.
            let sideInset = pad + button + 5
            let caption = micLabel.attributedStringValue.length > 0 ? ceil(micLabel.attributedStringValue.size().width) + 6 : 0
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
        background.frame = NSRect(x: 0, y: 0, width: width, height: h)

        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(NSRect(x: visible.midX - width / 2, y: visible.minY + Self.bottomMargin, width: width, height: h), display: true)

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
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.listeningWidth, height: Self.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let content = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        content.autoresizingMask = [.width, .height]
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
    private let barCount = 13
    private let barWidth: CGFloat = 2.5
    private let gap: CGFloat = 2.5
    private(set) var levels: [CGFloat]
    private var smoothed: CGFloat = 0
    private var timer: Timer?
    private var phase: CGFloat = 0

    var processing = false {
        didSet {
            guard processing != oldValue else { return }
            timer?.invalidate()
            timer = nil
            if processing {
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

    func reset() {
        levels = Array(repeating: 0, count: barCount)
        smoothed = 0
        needsDisplay = true
    }

    func push(_ level: Float) {
        // Fast attack, slow release, so speech looks lively but not jittery.
        smoothed = max(CGFloat(level), smoothed * 0.82)
        levels.removeFirst()
        levels.append(smoothed)
        needsDisplay = true
    }

    private func tick() {
        phase += 0.22
        for i in 0..<barCount {
            levels[i] = 0.18 + 0.22 * (1 + sin(phase - CGFloat(i) * 0.55)) / 2
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        let total = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * gap
        var x = (bounds.width - total) / 2
        let mid = CGFloat(barCount - 1) / 2
        for i in 0..<barCount {
            let fromCenter = abs(CGFloat(i) - mid) / mid      // 0 at center, 1 at edges
            let envelope = 1 - 0.6 * fromCenter * fromCenter  // taller in the middle
            let h = max(barWidth, levels[i] * envelope * bounds.height)
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
        (pressed ? fill.withAlphaComponent(fill.alphaComponent * 0.6) : fill).setFill()
        NSBezierPath(ovalIn: bounds).fill()
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)?
            .withSymbolConfiguration(config) else { return }
        let size = image.size
        image.draw(in: NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                              width: size.width, height: size.height))
    }
}
