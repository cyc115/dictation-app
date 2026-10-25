import AppKit
import ApplicationServices

/// Where text goes: an app, and the text box in it that had the cursor (nil: the app doesn't say).
struct TextSpot {
    let pid: pid_t
    let name: String
    let field: AXUIElement?

    /// The same app and, when both say, the same text box.
    func isSame(as other: TextSpot?) -> Bool {
        guard let other, other.pid == pid else { return false }
        guard let field, let otherField = other.field else { return true }
        return CFEqual(field, otherField)
    }

    /// The app in front and its focused element.
    static func frontmost() -> TextSpot? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return TextSpot(pid: app.processIdentifier, name: app.localizedName ?? "the app",
                        field: focusedElement(of: app.processIdentifier))
    }

    /// Asks the app itself (the system-wide element fails for some apps, e.g. Ghostty), with a 0.1 s
    /// limit so a hung app doesn't hold anything up.
    static func focusedElement(of pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let field = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(field, 0.1)
        return field
    }

    /// Puts the cursor back in `field`: its window to the front of its app, then the field focused.
    static func focus(_ spot: TextSpot) {
        guard let field = spot.field else { return }
        if let window: AXUIElement = SwitchApp.value(field, kAXWindowAttribute) {
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    /// The app's focused element is `field`.
    static func hasFocus(_ spot: TextSpot) -> Bool {
        guard let field = spot.field, let focused = focusedElement(of: spot.pid) else { return false }
        return CFEqual(field, focused)
    }
}

/// Experimental (Settings › Experimental › Paste where you dictated): text that arrives after you've
/// moved to another app or text box goes back to the one you dictated into. It brings that app forward,
/// puts the cursor back in the box, checks it's there, pastes (and presses Return when it's being sent),
/// then takes you back to where you were. Your keys and clicks are blocked from the switch until a
/// second after the paste, so your typing doesn't land in the wrong box. If the box can't be got back
/// to (closed, or the app doesn't say where its cursor is), nothing is pasted or sent: the text is left
/// on the clipboard.
///
/// Each step that touches the Mac is a closure, so tests run the sequence with fakes.
final class GoBack {
    enum Outcome: Equatable {
        case delivered
        /// Couldn't get back to the app named: the text is on the clipboard.
        case lost(String)
    }

    let injector: TextInjector
    var current: () -> TextSpot? = TextSpot.frontmost
    var bringForward: @MainActor (pid_t) async -> Bool = { pid in
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return await SwitchApp.bringForward(app)
    }
    var focus: (TextSpot) -> Void = TextSpot.focus
    var hasFocus: (TextSpot) -> Bool = TextSpot.hasFocus
    var blockInput: (Bool) -> Void
    /// Wait between pasting and pressing Return, so the app has taken the paste first.
    var sendDelay: TimeInterval = 0.15
    /// Wait after the last key before leaving, so it reaches this app and not the next one.
    var leaveDelay: TimeInterval = 0.3
    /// Keys and clicks stay blocked this long after the paste.
    var holdInput: TimeInterval = 1
    /// How long the cursor gets to land in the box.
    var focusTimeout: TimeInterval = 0.5
    /// One at a time: two at once would switch apps under each other.
    private var busy = false

    init(injector: TextInjector) {
        self.injector = injector
        let blocker = InputBlocker()
        blockInput = { blocker.set($0) }
    }

    /// You're still where the text should go (or it's not known where that is): paste as usual.
    func isStill(at target: TextSpot) -> Bool {
        target.isSame(as: current())
    }

    /// Takes `text` back to `target`, and Return too if `send()` says so by then.
    @MainActor
    func deliver(_ text: String, to target: TextSpot, send: () -> Bool) async -> Outcome {
        while busy { try? await Task.sleep(for: .milliseconds(50)) }
        busy = true
        defer { busy = false }
        let here = current()
        guard target.field != nil else { return lost(text, target) }
        blockInput(true)
        guard await bringForward(target.pid), await putCursor(in: target) else {
            if let here, !here.isSame(as: current()) { await goTo(here) }
            blockInput(false)
            return lost(text, target)
        }
        injector.inject(text)
        let pasted = ProcessInfo.processInfo.systemUptime
        if send() {
            await sleep(sendDelay)
            injector.pressReturn()
        }
        await sleep(leaveDelay)
        if let here { await goTo(here) }
        await sleep(holdInput - (ProcessInfo.processInfo.systemUptime - pasted))
        blockInput(false)
        return .delivered
    }

    private func lost(_ text: String, _ target: TextSpot) -> Outcome {
        injector.copy(text)
        return .lost(target.name)
    }

    /// Focuses the box and waits for it to take the cursor.
    @MainActor
    private func putCursor(in spot: TextSpot) async -> Bool {
        focus(spot)
        let end = ProcessInfo.processInfo.systemUptime + focusTimeout
        while !hasFocus(spot) {
            guard ProcessInfo.processInfo.systemUptime < end else { return false }
            await sleep(0.05)
        }
        return true
    }

    @MainActor
    private func goTo(_ spot: TextSpot) async {
        guard await bringForward(spot.pid) else { return }
        focus(spot)
    }

    private func sleep(_ seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        try? await Task.sleep(for: .seconds(seconds))
    }
}

/// While on, swallows your key presses and clicks (not this app's own keys, nor the extra mouse
/// buttons, so dictating still works). Only key-downs and button-downs: a key or button you're
/// already holding still gets its release, so nothing is left stuck down.
final class InputBlocker {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    func set(_ on: Bool) {
        if on { start() } else { stop() }
    }

    /// Whether an event of `type` from `marker`'s source is swallowed.
    static func blocks(_ type: CGEventType, marker: Int64) -> Bool {
        guard marker != TextInjector.syntheticMarker else { return false }
        return type == .keyDown || type == .leftMouseDown || type == .rightMouseDown
    }

    private func start() {
        guard tap == nil else { return }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput, let refcon,
               let tap = Unmanaged<InputBlocker>.fromOpaque(refcon).takeUnretainedValue().tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            let marker = event.getIntegerValueField(.eventSourceUserData)
            return InputBlocker.blocks(type, marker: marker) ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask), callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
    }

    private func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
    }
}
