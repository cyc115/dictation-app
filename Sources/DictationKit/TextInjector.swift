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
    /// The character before the cursor in the focused field (nil: none, or the app doesn't say).
    var charBeforeCursor: () -> Character? = TextInjector.focusedCharBeforeCursor

    /// Tag on every key event this app synthesizes, so its own key monitors can ignore them.
    static let syntheticMarker: Int64 = 0x4449_4354  // "DICT"

    /// Presses Return in the focused app (the mouse's Enter button).
    func pressReturn() {
        guard canPaste() else { return }
        postReturn()
    }
    var postReturn: () -> Void = TextInjector.postReturnKey

    func inject(_ text: String) {
        guard canPaste() else { return }
        let pasteboard = self.pasteboard
        let text = Self.needsSpace(after: charBeforeCursor(), before: text) ? " " + text : text

        // 1. Save everything currently on the clipboard (all types, not just text).
        var saved: [[NSPasteboard.PasteboardType: Data]] = []
        if let items = pasteboard.pasteboardItems {
            for item in items {
                var dict: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types {
                    if let data = item.data(forType: type) { dict[type] = data }
                }
                saved.append(dict)
            }
        }

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

    /// Asks the frontmost app (the system-wide element fails for some apps, e.g. Ghostty), with a
    /// 0.1 s limit so a hung app doesn't hold up the paste. Terminals report the cursor at 0: no space.
    static func focusedCharBeforeCursor() -> Character? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let field = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(field, 0.1)
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
        if let source = CGEventSource(stateID: .hidSystemState) {
            let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) // 0x09 = V
            vDown?.flags = .maskCommand
            vDown?.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
            let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
            vUp?.flags = .maskCommand
            vUp?.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
            vDown?.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.03)
            vUp?.post(tap: .cghidEventTap)
        }
    }

    /// Private source, so a modifier you're holding doesn't turn it into ⌘↩ or ⇧↩.
    static func postReturnKey() {
        let source = CGEventSource(stateID: .privateState)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: keyDown) else { continue }  // 0x24 = Return
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
            event.post(tap: .cghidEventTap)
        }
    }
}
