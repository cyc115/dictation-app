import AppKit
import ApplicationServices

/// A modifier key you hold to dictate. Right-hand modifiers are told apart from
/// left-hand ones via the device-specific bits in the event's modifier flags.
enum Hotkey: String, CaseIterable {
    case fn, rightCommand, rightOption, rightControl, rightShift

    var title: String {
        switch self {
        case .fn: return "Fn (🌐)"
        case .rightCommand: return "Right ⌘ Command"
        case .rightOption: return "Right ⌥ Option"
        case .rightControl: return "Right ⌃ Control"
        case .rightShift: return "Right ⇧ Shift"
        }
    }

    var shortName: String {
        switch self {
        case .fn: return "Fn"
        case .rightCommand: return "Right ⌘"
        case .rightOption: return "Right ⌥"
        case .rightControl: return "Right ⌃"
        case .rightShift: return "Right ⇧"
        }
    }

    fileprivate var keyCode: UInt16 {
        switch self {
        case .fn: return 63
        case .rightCommand: return 54
        case .rightOption: return 61
        case .rightControl: return 62
        case .rightShift: return 60
        }
    }

    /// Bit in NSEvent.modifierFlags.rawValue that is set while this key is down.
    fileprivate var flagMask: UInt {
        switch self {
        case .fn: return NSEvent.ModifierFlags.function.rawValue
        case .rightCommand: return 0x10    // NX_DEVICERCMDKEYMASK
        case .rightOption: return 0x40     // NX_DEVICERALTKEYMASK
        case .rightControl: return 0x2000  // NX_DEVICERCTLKEYMASK
        case .rightShift: return 0x04      // NX_DEVICERSHIFTKEYMASK
        }
    }
}

/// An extra mouse button that toggles dictation (press to start, press again to stop).
enum MouseButton: String, CaseIterable {
    case off, middle, button4, button5

    var title: String {
        switch self {
        case .off: return "None"
        case .middle: return "Middle button"
        case .button4: return "Button 4 (Back)"
        case .button5: return "Button 5 (Forward)"
        }
    }

    /// CGEvent button number: 0 left, 1 right, 2 middle, 3 = button 4, 4 = button 5.
    fileprivate var buttonNumber: Int64? {
        switch self {
        case .off: return nil
        case .middle: return 2
        case .button4: return 3
        case .button5: return 4
        }
    }
}

/// Watches the hotkey.
/// - Hold mode: key-down → onPress, key-up → onRelease.
/// - Toggle mode: a tap (press and release) → onTap.
/// Pressing any other key while the hotkey is down (e.g. Right ⌘+C) is treated as a
/// shortcut, not dictation: hold mode calls onCancel, toggle mode ignores the tap.
class HotkeyManager {
    var hotkey: Hotkey {
        didSet { held = false }
    }
    var mode: ActivationMode {
        didSet { held = false }
    }
    var mouseButton: MouseButton
    private let onPress: () -> Void
    private let onRelease: () -> Void
    private let onCancel: () -> Void
    private let onTap: () -> Void
    private var mouseTap: CFMachPort?
    private var monitors: [Any] = []
    private var held = false
    private var cancelled = false

    init(hotkey: Hotkey, mode: ActivationMode, mouseButton: MouseButton,
         onPress: @escaping () -> Void, onRelease: @escaping () -> Void,
         onCancel: @escaping () -> Void, onTap: @escaping () -> Void) {
        self.hotkey = hotkey
        self.mode = mode
        self.mouseButton = mouseButton
        self.onPress = onPress
        self.onRelease = onRelease
        self.onCancel = onCancel
        self.onTap = onTap
    }

    func start() {
        // Prompts the user in System Settings if Accessibility isn't granted yet.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            waitForAccessibility()
            return
        }
        installMonitors()
    }

    /// Keeps checking until Accessibility is granted, then starts listening — no relaunch needed.
    private func waitForAccessibility() {
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            self?.installMonitors()
        }
    }

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            self?.flagsChanged(event)
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] _ in
            self?.otherKeyPressed()
        }) { monitors.append(m) }
        installMouseTap()
    }

    // MARK: Mouse button

    /// An event tap (not a passive monitor) so the assigned button's own action,
    /// like Back in a browser, can be swallowed.
    private func installMouseTap() {
        let mask = (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.otherMouseUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
            return manager.handleMouse(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask), callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        mouseTap = tap
    }

    private func handleMouse(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = mouseTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard let number = mouseButton.buttonNumber,
              event.getIntegerValueField(.mouseEventButtonNumber) == number else {
            return Unmanaged.passUnretained(event)
        }
        if type == .otherMouseDown {
            DispatchQueue.main.async { [weak self] in self?.onTap() }
        }
        return nil  // swallow both down and up
    }

    private func flagsChanged(_ event: NSEvent) {
        guard event.keyCode == hotkey.keyCode else { return }
        let down = event.modifierFlags.rawValue & hotkey.flagMask != 0
        if down && !held {
            held = true
            cancelled = false
            if mode == .hold { onPress() }
        } else if !down && held {
            held = false
            guard !cancelled else { return }
            if mode == .hold { onRelease() } else { onTap() }
        }
    }

    private func otherKeyPressed() {
        guard held, !cancelled else { return }
        cancelled = true
        if mode == .hold { onCancel() }
    }
}
