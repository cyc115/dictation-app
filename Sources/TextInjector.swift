import AppKit
import ApplicationServices

/// Pastes text into the frontmost app:
/// save clipboard (all types) → write text → synthetic Cmd+V → restore clipboard.
class TextInjector {
    func inject(_ text: String) {
        guard AXIsProcessTrusted() else { return }
        let pasteboard = NSPasteboard.general

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
        if let source = CGEventSource(stateID: .hidSystemState) {
            let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) // 0x09 = V
            vDown?.flags = .maskCommand
            let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
            vUp?.flags = .maskCommand
            vDown?.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.03)
            vUp?.post(tap: .cghidEventTap)
        }

        // 4. Restore the user's original clipboard after the target app has pasted.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            pasteboard.clearContents()
            let items: [NSPasteboardItem] = saved.map { dict in
                let item = NSPasteboardItem()
                for (type, data) in dict { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { pasteboard.writeObjects(items) }
        }
    }
}
