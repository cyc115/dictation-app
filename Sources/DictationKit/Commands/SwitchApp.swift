import AppKit

/// The switch-app command: brings an app that's already open to the front; in a chat app (WeChat,
/// Muse, Slack, …) it also puts the cursor in the message box, ready to dictate into. Its choices
/// are the apps open now, so the decider picks one by name ("switch to 微信", a misheard "Muse").
enum SwitchApp {
    /// The apps open now with a Dock icon, by name; not this one.
    static func running() -> [String: NSRunningApplication] {
        var apps: [String: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            if let name = app.localizedName, apps[name] == nil { apps[name] = app }
        }
        return apps
    }

    /// Apps whose message box you'd type into as soon as you switch (lowercased names). Not browsers
    /// or note apps, where the cursor is yours to place.
    static let chatApps: Set<String> = ["wechat", "微信", "muse", "messages", "信息", "slack", "discord", "telegram",
                                        "whatsapp", "signal", "claude", "chatgpt", "lark", "飞书", "feishu"]

    @MainActor
    static func switchTo(_ name: String?) async -> CommandResult {
        let apps = running()
        // Any case: History's ↻ and a model can spell it "ghostty".
        guard let name, name != Command.noApp.value,
              let (name, app) = apps[name].map({ (name, $0) }) ?? apps.first(where: { $0.key.lowercased() == name.lowercased() }) else {
            return CommandResult(ok: false, message: "No open app by that name")
        }
        guard await bringForward(app) else {
            return CommandResult(ok: false, message: "Couldn't switch to \(name)", details: "\(name) wasn't frontmost after 1 s")
        }
        if chatApps.contains(name.lowercased()) { focusMessageBox(of: app.processIdentifier) }
        return CommandResult(ok: true, message: "Switched to \(name)")
    }

    /// Asks macOS to bring `app` to the front (as opening it would: a background app like this one
    /// can't just activate another), and waits up to a second for it to get there.
    @MainActor
    private static func bringForward(_ app: NSRunningApplication) async -> Bool {
        if let bundle = app.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try? await NSWorkspace.shared.openApplication(at: bundle, configuration: configuration)
        } else {
            app.activate()
        }
        for _ in 0..<20 where !app.isActive { try? await Task.sleep(for: .milliseconds(50)) }
        return app.isActive
    }

    /// Puts the cursor in the front window's message box: the lowest text box in it that isn't a
    /// search box (a chat's box is at the bottom). Best effort: false if there's none (Muse shows its
    /// only when a chat is open).
    @discardableResult
    static func focusMessageBox(of pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        // Electron and Chromium apps (Slack, Discord) only build their accessibility tree when asked.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let window: AXUIElement = value(app, kAXFocusedWindowAttribute) else { return false }
        guard let box = lowest(textBoxesIn: window) else { return false }
        return AXUIElementSetAttributeValue(box, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }

    /// The editable text boxes under `root` (breadth first, at most `limit` elements looked at), the
    /// lowest on screen first.
    private static func lowest(textBoxesIn root: AXUIElement, limit: Int = 4000) -> AXUIElement? {
        var queue = [root], seen = 0, best: (box: AXUIElement, bottom: CGFloat)?
        while !queue.isEmpty, seen < limit {
            let element = queue.removeFirst()
            seen += 1
            let role: String? = value(element, kAXRoleAttribute)
            let subrole: String? = value(element, kAXSubroleAttribute)
            if role == kAXTextAreaRole || role == kAXTextFieldRole, !isSearch(element, subrole: subrole),
               let bottom = bottom(of: element), bottom > best?.bottom ?? -.infinity {
                best = (element, bottom)
            }
            queue += (value(element, kAXChildrenAttribute) as [AXUIElement]?) ?? []
        }
        return best?.box
    }

    /// A search box, by its subrole or what it's labelled ("Search", "搜索").
    static func isSearch(_ element: AXUIElement, subrole: String?) -> Bool {
        if subrole == "AXSearchField" { return true }
        let labels = [kAXDescriptionAttribute, kAXPlaceholderValueAttribute, kAXTitleAttribute]
            .compactMap { value(element, $0) as String? }
        return labels.contains { isSearchLabel($0) }
    }

    static func isSearchLabel(_ label: String) -> Bool {
        label.localizedCaseInsensitiveContains("search") || label.contains("搜索")
    }

    /// Where the element's bottom edge is on screen (y grows downward).
    private static func bottom(of element: AXUIElement) -> CGFloat? {
        guard let position: AXValue = value(element, kAXPositionAttribute), let size: AXValue = value(element, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &extent), extent.height > 0 else { return nil }
        return origin.y + extent.height
    }

    private static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
