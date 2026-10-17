import AppKit

/// Where everything sits in the pill (points, in the pill's own coordinates) for one width and
/// content: the one place the pill's sizes live. `OverlayWindow` lays out from it, and the stop
/// animation moves from the listening layout to the processing one (`interpolated`).
struct PillLayout: Equatable {
    enum Content: Equatable {
        /// ✕ · waveform · ✓, with the mic's name under the waveform when `caption`.
        case listening(caption: Bool)
        /// Just the ripple.
        case processing
        /// A line of text.
        case message
    }

    static let height: CGFloat = 40
    static let listeningWidth: CGFloat = 164
    /// The pill widens to fit a long mic name, up to this width (then truncates).
    static let maxListeningWidth: CGFloat = 340
    /// The "working" pill: just the ripple.
    static let processingWidth: CGFloat = 84
    static let maxMessageWidth: CGFloat = 460
    static let button: CGFloat = 28
    /// Around each button (centered top to bottom).
    static let pad = (height - button) / 2
    /// From the pill's edge, past a button, to the waveform.
    static let sideInset = pad + button + 5

    let width: CGFloat
    let cancel: NSRect
    let confirm: NSRect
    let waveform: NSRect
    let caption: NSRect
    let label: NSRect

    /// `labelHeight`: the message text's height, for centering it.
    init(width: CGFloat, content: Content, labelHeight: CGFloat = 0) {
        let h = Self.height, pad = Self.pad, button = Self.button
        let inset: CGFloat
        if case .listening = content { inset = Self.sideInset } else { inset = 14 }
        let waveform = content == .listening(caption: true)
            ? NSRect(x: inset, y: 16, width: width - 2 * inset, height: 18)  // the mic's name tucked underneath
            : NSRect(x: inset, y: 9, width: width - 2 * inset, height: h - 18)
        self.init(width: width,
                  cancel: NSRect(x: pad, y: pad, width: button, height: button),
                  confirm: NSRect(x: width - pad - button, y: pad, width: button, height: button),
                  waveform: waveform,
                  caption: NSRect(x: inset - 2, y: 4, width: width - 2 * inset + 4, height: 12),
                  label: NSRect(x: 18, y: (h - labelHeight) / 2, width: width - 36, height: labelHeight))
    }

    private init(width: CGFloat, cancel: NSRect, confirm: NSRect, waveform: NSRect, caption: NSRect, label: NSRect) {
        self.width = width
        self.cancel = cancel
        self.confirm = confirm
        self.waveform = waveform
        self.caption = caption
        self.label = label
    }

    /// Listening: wide enough for a caption `caption` points wide (0: none) between the buttons.
    static func listeningWidth(caption: CGFloat) -> CGFloat {
        let needed = caption > 0 ? ceil(caption) + 6 : 0
        return min(max(listeningWidth, needed + 2 * sideInset), maxListeningWidth)
    }

    /// A message `text` points wide.
    static func messageWidth(text: CGFloat) -> CGFloat {
        min(max(text + 36, listeningWidth), maxMessageWidth)
    }

    /// Partway (`t`, 0…1) from this layout to `other`.
    func interpolated(to other: PillLayout, _ t: CGFloat) -> PillLayout {
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * t }
        func mix(_ a: NSRect, _ b: NSRect) -> NSRect {
            NSRect(x: mix(a.minX, b.minX), y: mix(a.minY, b.minY), width: mix(a.width, b.width), height: mix(a.height, b.height))
        }
        return PillLayout(width: mix(width, other.width), cancel: mix(cancel, other.cancel), confirm: mix(confirm, other.confirm),
                          waveform: mix(waveform, other.waveform), caption: mix(caption, other.caption),
                          label: mix(label, other.label))
    }
}
