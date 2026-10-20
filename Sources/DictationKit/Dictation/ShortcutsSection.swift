import SwiftUI

/// Settings › Shortcuts: the hotkey and how it activates, the mouse buttons, and apps to pause in.
struct ShortcutsSection: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Section {
            SettingRow("Hotkey", settings.hint + ".") {
                Picker("Hotkey", selection: $settings.hotkey) {
                    ForEach(Hotkey.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            SettingRow("Activation", "Hold the key while talking, or press once to start and again to stop. Another key pressed with it (e.g. Right ⌘+C) counts as a shortcut, not dictation.") {
                Picker("Activation", selection: $settings.mode) {
                    ForEach(ActivationMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            SettingRow("Mouse button", "Press once to start, again to stop and paste. The button's normal action (e.g. Back) is blocked while assigned.") {
                Picker("Mouse button", selection: $settings.mouseButton) {
                    ForEach(MouseButton.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            SettingRow("Mouse button for Enter", settings.commandModeOn
                       ? "While dictating, it stops and presses Return once the text is in — dictate and send in one go. Otherwise it starts a command (Commands, below)."
                       : "Press it to send Return. While dictating, it stops instead and presses Return once the text is in — dictate and send in one go.") {
                Toggle("Mouse button for Enter", isOn: $settings.mouseEnterEnabled)
            }
            SettingRow("Enter button", settings.mouseEnterButton == settings.mouseButton
                       ? "Also the dictation button above, so it toggles dictation instead. Pick another."
                       : "Its normal action is blocked while assigned.",
                       available: settings.mouseEnterEnabled) {
                Picker("Enter button", selection: $settings.mouseEnterButton) {
                    ForEach(MouseButton.allCases.filter { $0 != .off }, id: \.self) { Text($0.title).tag($0) }
                }
            }
            ExcludedAppsList(settings: settings)
            if settings.hotkey == .fn {
                Text("Tip: set System Settings → Keyboard → “Press 🌐 key to” → Do Nothing, so Fn doesn't also open the emoji picker.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Label("Shortcuts", systemImage: "keyboard")
        }
    }
}
