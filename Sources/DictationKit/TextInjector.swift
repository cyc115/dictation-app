import AppKit
import ApplicationServices

/// Pastes text into the frontmost app:
/// save clipboard (all types) → write text → synthetic Cmd+V → restore clipboard.
class TextInjector {
    /// Overridable so tests can use a private pasteboard and a fake paste.
    var pasteboard: NSPasteboard = .general
    var restoreDelay: TimeInterval = 0.8
    var canPaste: () -> Bool = { AXIsProcessTrusted() }
    var paste: () -> Void = TextInjector.postCommandV
    var typeText: (String) -> Void = TextInjector.postUnicode

    /// Tag on every key event this app synthesizes, so its own key monitors can ignore them.
    static let syntheticMarker: Int64 = 0x4449_4354  // "DICT"

    /// Types text straight into the focused app as keystrokes (no clipboard involved).
    func type(_ text: String) {
        guard canPaste(), !text.isEmpty else { return }
        typeText(text)
    }

    /// Presses Return in the focused app (the mouse's Enter button).
    func pressReturn() {
        guard canPaste() else { return }
        postReturn()
    }
    var postReturn: () -> Void = TextInjector.postReturnKey

    func inject(_ text: String) {
        guard canPaste() else { return }
        let pasteboard = self.pasteboard

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

    /// Posts the text as Unicode key events, 16 UTF-16 units per event (some apps drop more),
    /// never splitting a surrogate pair. Uses a private event source with no modifier flags,
    /// so keys you're physically holding don't leak into the typed text.
    static func postUnicode(_ text: String) {
        let source = CGEventSource(stateID: .privateState)
        let units = Array(text.utf16)
        var start = 0
        while start < units.count {
            var end = min(start + 16, units.count)
            if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
            var chunk = Array(units[start..<end])
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else { continue }
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                event.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
                event.post(tap: .cghidEventTap)
            }
            start = end
        }
    }
}
