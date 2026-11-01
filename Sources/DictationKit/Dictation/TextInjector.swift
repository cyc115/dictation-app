import AppKit
import ApplicationServices

/// Pastes text into the frontmost app:
/// save clipboard (all types) → write text → synthetic Cmd+V → restore clipboard.
/// Text pasted right after other text gets a space in front (see `needsSpace`).
class TextInjector {
    /// Overridable so tests can use a private pasteboard and a fake paste.
    var pasteboard: NSPasteboard = .general
    var restoreDelay: TimeInterval = 0.8
    var canPaste: () -> Bool = { AXIsProcessTrusted() }
    var paste: () -> Void = TextInjector.postCommandV
    /// The character before the cursor in a text box (nil: none, or the app doesn't say); given nil,
    /// the front app's focused one.
    var charBeforeCursor: (AXUIElement?) -> Character? = TextInjector.charBeforeCursor(in:)

    /// Tag on every key event this app synthesizes, so its own key monitors can ignore them.
    static let syntheticMarker: Int64 = 0x4449_4354  // "DICT"

    /// Presses Return in the focused app (the mouse's Enter button).
    func pressReturn() {
        guard canPaste() else { return }
        postReturn()
    }
    var postReturn: () -> Void = TextInjector.postReturnKey

    /// Leaves `text` on the clipboard for you to paste (it's not restored).
    func copy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// `field`: the text box the paste goes into, when the caller has already found it (one
    /// Accessibility round trip fewer); nil asks the front app.
    func inject(_ text: String, in field: AXUIElement? = nil) {
        guard canPaste() else { return }
        let pasteboard = self.pasteboard
        let text = Self.needsSpace(after: charBeforeCursor(field), before: text) ? " " + text : text

        // 1. Save everything currently on the clipboard (all types, not just text).
        let saved: [[NSPasteboard.PasteboardType: Data]] = pasteboard.pasteboardItems?.map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        } ?? []

        // 2. Put our text on the clipboard.
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // 3. Synthetic Cmd+V.
        paste()

        // 4. Restore the user's original clipboard after the target app has pasted.
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
            pasteboard.clearContents()
            let items: [NSPasteboardItem] = saved.map { dict in
                let item = NSPasteboardItem()
                for (type, data) in dict { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { pasteboard.writeObjects(items) }
        }
    }

    /// A space between the text already there and the pasted text, except: after a space, a line
    /// break or an opening bracket; before punctuation; and next to Chinese punctuation, or with
    /// Chinese on both sides ("一个 text field" gets one, "我觉得这个" doesn't).
    static func needsSpace(after previous: Character?, before text: String) -> Bool {
        guard let previous, let next = text.first else { return false }
        if previous.isWhitespace || next.isWhitespace || "([{<".contains(previous) || ",.!?;:)]}>…".contains(next) {
            return false
        }
        if isCJKPunctuation(previous) || isCJKPunctuation(next) { return false }
        return !(isCJK(previous) && isCJK(next))
    }

    private static func isCJK(_ c: Character) -> Bool {
        // Chinese characters, kana, Hangul.
        c.unicodeScalars.contains {
            $0.properties.isIdeographic || (0x3040...0x30FF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value)
        }
    }

    /// CJK symbols (、。「」…) and full-width forms (，！？（）…).
    private static func isCJKPunctuation(_ c: Character) -> Bool {
        guard let s = c.unicodeScalars.first?.value else { return false }
        return (0x3000...0x303F).contains(s) || (0xFF00...0xFFEF).contains(s)
    }

    /// Asks `field`, or the frontmost app's focused one (with a 0.1 s limit so a hung app doesn't
    /// hold up the paste). Terminals report the cursor at 0: no space.
    static func charBeforeCursor(in field: AXUIElement?) -> Character? {
        guard let field = field ?? NSWorkspace.shared.frontmostApplication.flatMap({ TextSpot.focusedElement(of: $0.processIdentifier) })
        else { return nil }
        var selection: CFTypeRef?
        var range = CFRange()
        guard AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, &selection) == .success,
              let selection, CFGetTypeID(selection) == AXValueGetTypeID(),
              AXValueGetValue(selection as! AXValue, .cfRange, &range), range.location > 0 else { return nil }
        var before = CFRange(location: range.location - 1, length: 1)
        var text: CFTypeRef?
        guard let param = AXValueCreate(.cfRange, &before),
              AXUIElementCopyParameterizedAttributeValue(
                field, kAXStringForRangeParameterizedAttribute as CFString, param, &text) == .success
        else { return nil }
        return (text as? String)?.last
    }

    static func postCommandV() {
        press(0x09, flags: .maskCommand, source: .hidSystemState, gap: 0.03)  // 0x09 = V; the gap lets slow apps see the ⌘
    }

    /// Private source, so a modifier you're holding doesn't turn it into ⌘↩ or ⇧↩.
    static func postReturnKey() {
        press(0x24, flags: [], source: .privateState)  // 0x24 = Return
    }

    /// Presses and releases `key`, tagged with `syntheticMarker` so the app's own hotkey watching
    /// doesn't take it for a key the user pressed. `gap`: how long the key stays down; the release is
    /// scheduled on the main queue rather than waited for. `post`: what sends each event (tests look).
    static func press(_ key: CGKeyCode, flags: CGEventFlags, source: CGEventSourceStateID, gap: TimeInterval = 0,
                      post: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }) {
        let source = CGEventSource(stateID: source)
        func event(down: Bool) -> CGEvent? {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            event?.flags = flags
            event?.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
            return event
        }
        guard let down = event(down: true), let up = event(down: false) else { return }
        post(down)
        if gap > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + gap) { post(up) }
        } else {
            post(up)
        }
    }
}
