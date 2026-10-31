import SwiftUI

/// Settings › Shortcuts: two actions, Dictate and Command & Enter, each on a keyboard key and/or a
/// mouse button (either can be None); how the dictation key activates; apps to pause in.
struct ShortcutsSection: View {
    @ObservedObject var settings: AppSettings

    private static let mouseNote = "A mouse button's normal action (e.g. Back) is blocked while assigned."

    private var commandDetail: String {
        var text = settings.commandModeOn
            ? "While dictating, it stops, pastes and presses Return — dictate and send in one go. Otherwise it starts a command (Commands, below); press it twice to just press Return."
            : "Presses Return. While dictating, it stops, pastes and then presses Return — dictate and send in one go."
        if settings.commandHotkey != .off && settings.commandHotkey == settings.hotkey {
            text += " Its key is also Dictate's, so it dictates instead. Pick another."
        }
        if settings.mouseEnterButton != .off && settings.mouseEnterButton == settings.mouseButton {
            text += " Its button is also Dictate's, so it dictates instead. Pick another."
        }
        return text
    }

    var body: some View {
        Section {
            SettingRow("Dictate", settings.hint + ". " + Self.mouseNote) {
                TriggerPickers(title: "Dictate", key: $settings.hotkey, button: $settings.mouseButton)
            }
            SettingRow("Activation", "How the keyboard key works: hold it while talking, or press once to start and again to stop. Another key pressed with it (e.g. Right ⌘+C) counts as a shortcut, not dictation. A mouse button always toggles.",
                       available: settings.hotkey != .off) {
                Picker("Activation", selection: $settings.mode) {
                    ForEach(ActivationMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            SettingRow("Command & Enter", commandDetail) {
                TriggerPickers(title: "Command & Enter", key: $settings.commandHotkey, button: $settings.mouseEnterButton)
            }
            ExcludedAppsList(settings: settings)
            if settings.hotkey == .fn || settings.commandHotkey == .fn {
                Text("Tip: set System Settings → Keyboard → “Press 🌐 key to” → Do Nothing, so Fn doesn't also open the emoji picker.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Label("Shortcuts", systemImage: "keyboard")
        }
    }
}

/// An action's keyboard key and mouse button, side by side; each can be None.
private struct TriggerPickers: View {
    let title: String
    @Binding var key: Hotkey
    @Binding var button: MouseButton

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "keyboard").foregroundStyle(.secondary)
            Picker(title + " key", selection: $key) {
                ForEach(Hotkey.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("setting.\(title).key")
            Image(systemName: "computermouse").foregroundStyle(.secondary)
            Picker(title + " mouse button", selection: $button) {
                ForEach(MouseButton.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("setting.\(title).mouse")
        }
        .accessibilityElement(children: .contain)
    }
}
