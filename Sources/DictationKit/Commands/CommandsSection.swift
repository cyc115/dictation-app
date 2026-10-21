import SwiftUI

/// Settings › Commands: command mode on or off; the commands themselves are managed in the
/// Commands tab (`CommandsView`).
struct CommandsSection: View {
    @ObservedObject var settings: AppSettings
    var onShowCommands: (() -> Void)?

    var body: some View {
        Section {
            SettingRow("Command mode", settings.hasOpenRouterKey
                       ? "Press the Enter button when you're not dictating, say what you want — “brightness to half”, “声音小一点” — and press it again: it runs one of your commands. A cloud model picks which, with your API key; a command it isn't sure of doesn't run."
                       : "Needs the cloud API key: a cloud model picks the command. Add it under Speech model.",
                       available: settings.mouseEnterEnabled && settings.hasOpenRouterKey,
                       badge: "Online · needs API key") {
                // Without the key it shows off, as it is: the Enter button just presses Return.
                Toggle("Command mode", isOn: Binding(get: { settings.commandModeOn },
                                                     set: { settings.commandModeEnabled = $0 }))
            }
            SettingRow("Commands", "Add, turn off and delete your commands, and see how each has gone, in the Commands tab.") {
                Button("Manage Commands…") { onShowCommands?() }
                    .accessibilityIdentifier("settings.manageCommands")
            }
        } header: {
            Label("Commands", systemImage: "chevron.forward.square")
        }
    }
}
