import AppKit
import ApplicationServices

/// Hold-Fn to dictate: Fn key-down starts, Fn key-up stops and pastes.
class HotkeyManager {
    private let onPress: () -> Void
    private let onRelease: () -> Void
    private var monitor: Any?
    private var fnDown = false

    init(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        self.onPress = onPress
        self.onRelease = onRelease
    }

    func start() {
        // Prompts the user in System Settings if Accessibility isn't granted yet.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self = self, event.keyCode == 63 else { return } // 63 = Fn key
            let down = event.modifierFlags.contains(.function)
            if down && !self.fnDown {
                self.fnDown = true
                self.onPress()
            } else if !down && self.fnDown {
                self.fnDown = false
                self.onRelease()
            }
        }
    }
}
