import AppKit

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
