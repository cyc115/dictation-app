import AppKit
import ApplicationServices

/// A modifier key that dictates (or runs a command), or `.off` for none. Right-hand modifiers are
/// told apart from left-hand ones via the device-specific bits in the event's modifier flags.
enum Hotkey: String, CaseIterable {
    case off, fn, rightCommand, rightOption, rightControl, rightShift

    var title: String {
        switch self {
        case .off: return "None"
        case .fn: return "Fn (🌐)"
        case .rightCommand: return "Right ⌘ Command"
        case .rightOption: return "Right ⌥ Option"
        case .rightControl: return "Right ⌃ Control"
        case .rightShift: return "Right ⇧ Shift"
        }
    }

    var shortName: String {
        switch self {
        case .off: return "None"
        case .fn: return "Fn"
        case .rightCommand: return "Right ⌘"
        case .rightOption: return "Right ⌥"
        case .rightControl: return "Right ⌃"
        case .rightShift: return "Right ⇧"
        }
    }

    var keyCode: UInt16? {
        switch self {
        case .off: return nil
        case .fn: return 63
        case .rightCommand: return 54
        case .rightOption: return 61
        case .rightControl: return 62
        case .rightShift: return 60
        }
    }

    /// Bit in NSEvent.modifierFlags.rawValue that is set while this key is down.
    var flagMask: UInt {
        switch self {
        case .off: return 0
        case .fn: return NSEvent.ModifierFlags.function.rawValue
        case .rightCommand: return 0x10    // NX_DEVICERCMDKEYMASK
        case .rightOption: return 0x40     // NX_DEVICERALTKEYMASK
        case .rightControl: return 0x2000  // NX_DEVICERCTLKEYMASK
        case .rightShift: return 0x04      // NX_DEVICERSHIFTKEYMASK
        }
    }
}

/// An extra mouse button: one toggles dictation (press to start, press again to stop), one can press Return.
enum MouseButton: String, CaseIterable {
    case off, middle, button4, button5, button6

    var title: String {
        switch self {
        case .off: return "None"
        case .middle: return "Middle button"
        case .button4: return "Button 4 (Back)"
        case .button5: return "Button 5 (Forward)"
        case .button6: return "Button 6"
        }
    }

    /// CGEvent button number: 0 left, 1 right, 2 middle, 3 = button 4, 4 = button 5, 5 = button 6.
    var buttonNumber: Int64? {
        switch self {
        case .off: return nil
        case .middle: return 2
        case .button4: return 3
        case .button5: return 4
        case .button6: return 5
        }
    }
}

/// Watches the hotkey, the mouse buttons and Esc, and calls the actions below.
/// - Hold mode: key-down → onPress, key-up → onRelease.
/// - Toggle mode: a tap (press and release) → onTap; so does the dictation mouse button.
/// - The command key: a tap → onEnter, like the Enter mouse button.
/// Pressing any other key while the hotkey is down (e.g. Right ⌘+C) is treated as a
/// shortcut, not dictation: hold mode calls onCancel, toggle mode ignores the tap. Likewise a
/// command key combo is not a tap.
class HotkeyManager {
    var hotkey: Hotkey {
        didSet { if hotkey != oldValue { dictate = ModifierTap() } }
    }
    var mode: ActivationMode {
        didSet { if mode != oldValue { dictate = ModifierTap() } }
    }
    var mouseButton: MouseButton
    /// Pressed → `onEnter` (Return). The dictation button wins if they're the same.
    var enterButton: MouseButton = .off
    /// Tapped → `onEnter`, like `enterButton`. The hotkey wins if they're the same.
    var commandKey: Hotkey = .off {
        didSet { if commandKey != oldValue { command = ModifierTap() } }
    }

    // MARK: Actions (main queue)

    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}
    var onCancel: () -> Void = {}
    var onTap: () -> Void = {}
    var onEnter: () -> Void = {}
    /// Called when Esc is pressed while `isRecording()` is true; the Esc is swallowed.
    var onEscape: () -> Void = {}
    var isRecording: () -> Bool = { false }
    /// True while an excluded app (e.g. a game) is in front: the hotkey can't start dictation and
    /// the mouse buttons and Esc pass through to that app.
    var isPaused: () -> Bool = { false }

    private var eventTap: CFMachPort?
    private var monitors: [Any] = []
    private var dictate = ModifierTap()
    private var command = ModifierTap()
    var held: Bool { dictate.held }

    init(hotkey: Hotkey, mode: ActivationMode, mouseButton: MouseButton) {
        self.hotkey = hotkey
        self.mode = mode
        self.mouseButton = mouseButton
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
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            // Keys this app sends itself (⌘V to paste, Return) are not "another key".
            guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != TextInjector.syntheticMarker else { return }
            self?.otherKeyPressed()
        }) { monitors.append(m) }
        installEventTap()
    }

    static let escapeKeyCode: Int64 = 53

    // MARK: Mouse buttons / Esc

    /// An event tap (not a passive monitor) so the assigned buttons' own actions, like Back in a
    /// browser, and Esc during a recording can be swallowed.
    private func installEventTap() {
        let mask = (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.otherMouseUp.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
            return manager.handleTap(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask), callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
    }

    func handleTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if isPaused() { return Unmanaged.passUnretained(event) }
        if type == .keyDown {
            // Esc cancels a recording; swallowed so it doesn't also close a dialog in the
            // app being typed into. Outside a recording, Esc passes through untouched.
            guard event.getIntegerValueField(.keyboardEventKeycode) == Self.escapeKeyCode, isRecording() else {
                return Unmanaged.passUnretained(event)
            }
            _ = dictate.cancel()  // the hotkey's release must not paste afterwards
            DispatchQueue.main.async { [weak self] in self?.onEscape() }
            return nil
        }
        let number = event.getIntegerValueField(.mouseEventButtonNumber)
        if number == mouseButton.buttonNumber {
            if type == .otherMouseDown { DispatchQueue.main.async { [weak self] in self?.onTap() } }
            return nil  // swallow both down and up
        }
        if number == enterButton.buttonNumber {
            if type == .otherMouseDown { DispatchQueue.main.async { [weak self] in self?.onEnter() } }
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    private func flagsChanged(_ event: NSEvent) {
        handleFlags(keyCode: event.keyCode, rawFlags: event.modifierFlags.rawValue)
    }

    /// Hotkey state machine, fed from flagsChanged events (separate so tests can drive it).
    func handleFlags(keyCode: UInt16, rawFlags: UInt) {
        // Presses don't start while paused; releases still count, so a key held into the excluded
        // app isn't stuck down.
        if keyCode == commandKey.keyCode, commandKey != hotkey {
            // The command key: a tap alone (no other key while it's down) is `onEnter`.
            if case .released(cancelled: false) = command.update(down: rawFlags & commandKey.flagMask != 0, canStart: !isPaused()) {
                onEnter()
            }
            return
        }
        guard keyCode == hotkey.keyCode else { return }
        switch dictate.update(down: rawFlags & hotkey.flagMask != 0, canStart: !isPaused()) {
        case .pressed: if mode == .hold { onPress() }
        case .released(cancelled: false): if mode == .hold { onRelease() } else { onTap() }
        case .released(cancelled: true), nil: break
        }
    }

    func otherKeyPressed() {
        _ = command.cancel()
        if dictate.cancel(), mode == .hold { onCancel() }
    }
}

/// One modifier key's press-and-release tracking: another key pressed while it's down turns the
/// tap into a shortcut (`cancelled`), which the release then reports instead of firing.
private struct ModifierTap {
    private(set) var held = false
    private var cancelled = false

    enum Event {
        case pressed
        case released(cancelled: Bool)
    }

    /// Feeds the key's current state; `canStart` is only consulted on a press.
    mutating func update(down: Bool, canStart: @autoclosure () -> Bool) -> Event? {
        if down && !held {
            guard canStart() else { return nil }
            held = true
            cancelled = false
            return .pressed
        }
        if !down && held {
            held = false
            return .released(cancelled: cancelled)
        }
        return nil
    }

    /// Marks the tap a shortcut; true the first time while the key is held.
    mutating func cancel() -> Bool {
        guard held, !cancelled else { return false }
        cancelled = true
        return true
    }
}
