import AppKit
import SwiftUI

/// How the hotkey starts and stops dictation.
enum ActivationMode: String, CaseIterable {
    case hold    // hold the key while speaking, release to paste
    case toggle  // tap once to start, tap again to stop and paste

    var title: String {
        switch self {
        case .hold: return "Hold to talk"
        case .toggle: return "Press to start, press again to stop"
        }
    }
}

/// User settings, saved in UserDefaults. `onChange` fires after any change.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Key {
        static let hotkey = "hotkey"
        static let mode = "activationMode"
        static let polish = "aiPolishEnabled"
        static let mouse = "mouseButton"
    }

    var onChange: (() -> Void)?

    @Published var hotkey: Hotkey {
        didSet { UserDefaults.standard.set(hotkey.rawValue, forKey: Key.hotkey); onChange?() }
    }
    @Published var mode: ActivationMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Key.mode); onChange?() }
    }
    @Published var mouseButton: MouseButton {
        didSet { UserDefaults.standard.set(mouseButton.rawValue, forKey: Key.mouse); onChange?() }
    }
    @Published var polishEnabled: Bool {
        didSet { UserDefaults.standard.set(polishEnabled, forKey: Key.polish); onChange?() }
    }

    private init() {
        let defaults = UserDefaults.standard
        hotkey = Hotkey(rawValue: defaults.string(forKey: Key.hotkey) ?? "") ?? .fn
        mode = ActivationMode(rawValue: defaults.string(forKey: Key.mode) ?? "") ?? .hold
        polishEnabled = defaults.bool(forKey: Key.polish)
        mouseButton = MouseButton(rawValue: defaults.string(forKey: Key.mouse) ?? "") ?? .off
    }

    /// One-line usage hint, e.g. "Hold Fn to dictate — release to paste".
    var hint: String {
        switch mode {
        case .hold: return "Hold \(hotkey.shortName) to dictate — release to paste"
        case .toggle: return "Tap \(hotkey.shortName) to start — tap again to paste"
        }
    }
}

// MARK: - View

struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("Key", selection: $settings.hotkey) {
                    ForEach(Hotkey.allCases, id: \.self) { key in
                        Text(key.title).tag(key)
                    }
                }
                Picker("Activation", selection: $settings.mode) {
                    ForEach(ActivationMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Hotkey")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(settings.hint + ". Pressing another key while holding the hotkey (e.g. Right ⌘+C) is treated as a shortcut, not dictation.")
                    if settings.hotkey == .fn {
                        Text("Tip: set System Settings → Keyboard → “Press 🌐 key to” → Do Nothing, so Fn doesn't also open the emoji picker.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Picker("Mouse button", selection: $settings.mouseButton) {
                    ForEach(MouseButton.allCases, id: \.self) { button in
                        Text(button.title).tag(button)
                    }
                }
            } header: {
                Text("Mouse trigger")
            } footer: {
                Text("Press the button once to start dictating, again to stop and paste. While assigned, the button's normal action (e.g. Back in a browser) is blocked. If your mouse software remaps the button to a keystroke, set it back to the default there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle("AI polish (on-device)", isOn: $settings.polishEnabled)
            } header: {
                Text("Cleanup")
            } footer: {
                Text("Removes filler words and fixes self-corrections with Apple's on-device model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
