import AppKit

/// The ask-muse command: sends what you ask Muse (Meta's assistant app) to do, in a new side chat.
/// "Ask Muse to look up whether we can go to a movie tonight" → opens Muse, presses its "New side
/// chat" (through Accessibility), pastes "look up whether we can go to a movie tonight" and sends it.
enum AskMuse {
    static let bundleID = "com.meta.endo"
    /// Muse's labels (its sidebar's + button, its message box, a reply's copy button).
    static let newSideChat = "New side chat"
    static let messageBox = "Message"
    static let copyResponse = "Copy response"

    @MainActor
    static func ask(_ said: String) async -> CommandResult {
        let request = request(from: said)
        guard !request.isEmpty else { return CommandResult(ok: false, message: "What should Muse do?") }
        guard AXIsProcessTrusted() else { return CommandResult(ok: false, message: "Needs Accessibility permission to work Muse") }
        guard let muse = await open() else { return CommandResult(ok: false, message: "Muse isn't installed") }
        guard await SwitchApp.bringForward(muse) else {
            return CommandResult(ok: false, message: "Couldn't open Muse", details: "Muse wasn't frontmost after 1 s")
        }
        let app = AXUIElementCreateApplication(muse.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.5)
        // Just launched, Muse takes a few seconds to show its chats.
        guard let button = await poll(seconds: 10, { find(newSideChat, in: app) }) else {
            return CommandResult(ok: false, message: "Couldn't find Muse's New side chat",
                                 details: "No “\(newSideChat)” button in Muse's window (its sidebar hidden?)")
        }
        // A press while Muse is still coming forward can go missing: pressed once more.
        var opened = false
        for _ in 0..<2 where !opened {
            AXUIElementPerformAction(button, kAXPressAction as CFString)
            opened = await poll(seconds: 2, { draftOpen(app) ? true : nil }) ?? false
        }
        guard opened, NSWorkspace.shared.frontmostApplication?.processIdentifier == muse.processIdentifier else {
            return CommandResult(ok: false, message: "Muse's new side chat didn't open", details: "Nothing sent: “\(request)”")
        }
        selectAll()  // a draft left unsent comes back with its text: replaced
        let injector = TextInjector()
        injector.inject(request)
        try? await Task.sleep(for: .milliseconds(300))
        injector.pressReturn()
        return CommandResult(ok: true, message: "Asked Muse")
    }

    /// What to send: what was said without "ask Muse to" ("让 Muse 帮我"); all of it when it doesn't
    /// start that way.
    static func request(from said: String) -> String {
        let text = said.trimmingCharacters(in: .whitespacesAndNewlines)
        let lead = #"^(?:(?:hey|ok|okay|please|can you|could you|go|and)[\s,]+)*"#
        let patterns = [lead + #"(?:ask|tell|have|get)\s+muse(?![a-z])(?:\s+to\b)?[\s,:：，]*"#,
                        #"^(?:请|麻烦)?\s*(?:让|叫|请|问|跟|告诉)(?:一下)?\s*muse(?![a-z])\s*(?:帮我|帮忙|去|一下)?[\s,:：，]*"#]
        for pattern in patterns {
            if let match = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                return String(text[match.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text
    }

    /// Muse running, else launched.
    @MainActor
    private static func open() async -> NSRunningApplication? {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { return running }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return try? await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// A new side chat is open: its message box has the cursor, and no reply is showing.
    private static func draftOpen(_ app: AXUIElement) -> Bool {
        guard let focused: AXUIElement = SwitchApp.value(app, kAXFocusedUIElementAttribute),
              (SwitchApp.value(focused, kAXTitleAttribute) as String?)?.hasPrefix(messageBox) == true else { return false }
        return find(copyResponse, in: app) == nil
    }

    /// The button labelled `label` in Muse's window (breadth first, at most `limit` elements looked at).
    private static func find(_ label: String, in app: AXUIElement, limit: Int = 4000) -> AXUIElement? {
        guard let window: AXUIElement = SwitchApp.value(app, kAXMainWindowAttribute) else { return nil }
        var queue = [window], seen = 0
        while !queue.isEmpty, seen < limit {
            let element = queue.removeFirst()
            seen += 1
            if SwitchApp.value(element, kAXRoleAttribute) == kAXButtonRole as String,
               [kAXTitleAttribute, kAXDescriptionAttribute].contains(where: { SwitchApp.value(element, $0) == label }) {
                return element
            }
            queue += (SwitchApp.value(element, kAXChildrenAttribute) as [AXUIElement]?) ?? []
        }
        return nil
    }

    /// ⌘A in the front app.
    private static func selectAll() {
        let source = CGEventSource(stateID: .hidSystemState)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0x00, keyDown: keyDown) else { continue }  // 0x00 = A
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: TextInjector.syntheticMarker)
            event.post(tap: .cghidEventTap)
        }
    }

    /// `check`'s first answer, tried every 100 ms for up to `seconds`.
    @MainActor
    private static func poll<T>(seconds: Double, _ check: () -> T?) async -> T? {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if let found = check() { return found }
            try? await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        return nil
    }
}
