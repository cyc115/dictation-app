import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// The edit watcher's reads of the real Mac: the text box through Accessibility, the input source,
/// and the click and app monitors. `EditWatcher` takes each as a closure, so tests use fakes.
extension EditWatcher {
    /// The box's value, insertion point and focus, each with the 0.1 s limit `TextSpot` sets.
    static func readBox(_ spot: TextSpot) -> Read? {
        guard let field = spot.field else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String else { return nil }
        var selection: CFTypeRef?
        var range = CFRange()
        var cursor: Int?
        if AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, &selection) == .success,
           let selection, CFGetTypeID(selection) == AXValueGetTypeID(),
           AXValueGetValue(selection as! AXValue, .cfRange, &range), range.length == 0 {
            cursor = range.location
        }
        return Read(value: text, cursor: cursor, focused: TextSpot.hasFocus(spot))
    }

    static func isSecureField(_ spot: TextSpot) -> Bool {
        guard let field = spot.field else { return false }
        var subrole: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, kAXSubroleAttribute as CFString, &subrole) == .success else { return false }
        return (subrole as? String) == kAXSecureTextFieldSubrole as String
    }

    static func inputMethodActive() -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let type = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else { return false }
        let kind = Unmanaged<CFString>.fromOpaque(type).takeUnretainedValue()
        return kind != kTISTypeKeyboardLayout
    }

    /// A passive monitor (a copy of each click; never holds one back), there only while asked for.
    static func clickMonitor() -> ((() -> Void)?) -> Void {
        var monitor: Any?
        return { handler in
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = handler.flatMap { handler in
                NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in handler() }
            }
        }
    }

    static func appMonitor() -> (((pid_t) -> Void)?) -> Void {
        var observer: NSObjectProtocol?
        return { handler in
            if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
            observer = handler.map { handler in
                NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                  object: nil, queue: .main) { note in
                    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                    handler(app?.processIdentifier ?? 0)
                }
            }
        }
    }
}
