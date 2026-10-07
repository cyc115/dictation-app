import AppKit
import ApplicationServices

/// A modifier key you hold to dictate. Right-hand modifiers are told apart from
/// left-hand ones via the device-specific bits in the event's modifier flags.
enum Hotkey: String, CaseIterable {
    case fn, rightCommand, rightOption, rightControl, rightShift

    static let defaultsKey = "hotkey"

    static var saved: Hotkey {
        get { Hotkey(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .fn }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

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

/// Hold the hotkey to dictate: key-down starts, key-up stops and pastes.
/// Pressing any other key while holding it (e.g. Right ⌘+C) is treated as a
/// shortcut, not dictation, and cancels.
class HotkeyManager {
    var hotkey: Hotkey {
        didSet { held = false }
    }
    private let onPress: () -> Void
    private let onRelease: () -> Void
    private let onCancel: () -> Void
    private var monitors: [Any] = []
    private var held = false
    private var cancelled = false

    init(hotkey: Hotkey, onPress: @escaping () -> Void, onRelease: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.hotkey = hotkey
        self.onPress = onPress
        self.onRelease = onRelease
        self.onCancel = onCancel
    }

    func start() {
        // Prompts the user in System Settings if Accessibility isn't granted yet.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { return }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            self?.flagsChanged(event)
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] _ in
            self?.otherKeyPressed()
        }) { monitors.append(m) }
    }

    private func flagsChanged(_ event: NSEvent) {
        guard event.keyCode == hotkey.keyCode else { return }
        let down = event.modifierFlags.rawValue & hotkey.flagMask != 0
        if down && !held {
            held = true
            cancelled = false
            onPress()
        } else if !down && held {
            held = false
            if !cancelled { onRelease() }
        }
    }

    private func otherKeyPressed() {
        guard held, !cancelled else { return }
        cancelled = true
        onCancel()
    }
}
