import AppKit
import SwiftUI

/// Settings › Commands: command mode on or off, the commands folder and what's in it.
struct CommandsSection: View {
    @ObservedObject var settings: AppSettings
    let folder: URL

    private var usable: Bool { settings.commandModeOn && settings.mouseEnterEnabled }

    var body: some View {
        Section {
            SettingRow("Command mode", settings.hasOpenRouterKey
                       ? "Press the Enter button when you're not dictating, say what you want — “brightness to half”, “声音小一点” — and press it again: it runs one of the commands below. A cloud model picks which, with your API key; a command it isn't sure of doesn't run."
                       : "Needs the cloud API key: a cloud model picks the command. Add it under Speech model.",
                       available: settings.mouseEnterEnabled && settings.hasOpenRouterKey,
                       badge: "Online · needs API key") {
                // Without the key it shows off, as it is: the Enter button just presses Return.
                Toggle("Command mode", isOn: Binding(get: { settings.commandModeOn },
                                                     set: { settings.commandModeEnabled = $0 }))
            }
            CommandsList(folder: folder)
                .disabled(!usable)
                .opacity(usable ? 1 : 0.4)
        } header: {
            Label("Commands", systemImage: "chevron.forward.square")
        }
    }
}

/// The commands folder and what's in it: each command, what it does and what it can be told, with a
/// switch to turn a script off (a script that fails is turned off for you).
struct CommandsList: View {
    let folder: URL
    @State private var commands: [Command] = []
    @State private var disabled: [Command] = []

    private func reload() {
        commands = Command.all(in: folder)
        disabled = Command.disabled(in: folder)
    }

    var body: some View {
        SettingRow("Commands folder", (folder.path as NSString).abbreviatingWithTildeInPath) {
            Button("Show in Finder") {
                CommandMode.installExamples(into: folder)
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            }
        }
        .onAppear(perform: reload)
        ForEach(commands + disabled, id: \.self) { command in
            let on = !disabled.contains(command)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: command.script == nil ? "sparkle" : "chevron.forward")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tint)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(command.name).font(.body.weight(.medium))
                    Text(command.summary + (command.name == Command.openApp.name ? " you installed (\(command.choices.count - 1))" : "")
                         + (command.script == nil ? " · built in" : ""))
                        .font(.callout).foregroundStyle(.secondary)
                    if command.script != nil, !command.choices.isEmpty {
                        Text(command.choices.map(\.value).joined(separator: "  "))
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let script = command.script {
                    Toggle(command.name, isOn: Binding(get: { on }, set: { enable in
                        _ = try? Command.setEnabled(enable, script: script, folder: folder)
                        reload()
                    }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityIdentifier("command.switch." + command.name)
                }
            }
            .opacity(on ? 1 : 0.5)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("command." + command.name)
        }
        Text("Add a Python script to the folder, or say “create command” and what it should do. A script's docstring's first line says what it does, and lines under “Choices:” what it can be told (value: meaning). It's run with uv; one that fails is turned off.")
            .font(.callout).foregroundStyle(.secondary)
    }
}
