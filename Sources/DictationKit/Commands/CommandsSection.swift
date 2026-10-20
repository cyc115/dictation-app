import AppKit
import SwiftUI

/// Settings › Commands: command mode on or off, the commands folder and what's in it.
struct CommandsSection: View {
    @ObservedObject var settings: AppSettings
    let folder: URL

    private var usable: Bool { settings.commandModeEnabled && settings.mouseEnterEnabled }

    var body: some View {
        Section {
            SettingRow("Command mode", "Press the Enter button when you're not dictating, say what you want — “brightness to half”, “声音小一点” — and press it again: it runs one of the commands below. A cloud model picks which, with your API key; a command it isn't sure of doesn't run.",
                       available: settings.mouseEnterEnabled) {
                Toggle("Command mode", isOn: $settings.commandModeEnabled)
            }
            CommandsList(folder: folder)
                .disabled(!usable)
                .opacity(usable ? 1 : 0.4)
        } header: {
            Label("Commands", systemImage: "chevron.forward.square")
        }
    }
}

/// The commands folder and what's in it: each command, what it does and what it can be told.
struct CommandsList: View {
    let folder: URL
    @State private var commands: [Command] = []

    var body: some View {
        SettingRow("Commands folder", (folder.path as NSString).abbreviatingWithTildeInPath) {
            Button("Show in Finder") {
                CommandMode.installExamples(into: folder)
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            }
        }
        .onAppear { commands = Command.all(in: folder) }
        ForEach(commands, id: \.name) { command in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: command.script == nil ? "sparkle" : "chevron.forward")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tint)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(command.name).font(.body.weight(.medium))
                    Text(command.summary + (command.script == nil ? " · built in" : ""))
                        .font(.callout).foregroundStyle(.secondary)
                    if !command.choices.isEmpty {
                        Text(command.choices.map(\.value).joined(separator: "  "))
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("command." + command.name)
        }
        Text("Add a Python script to the folder: its docstring's first line says what it does, and lines under “Choices:” what it can be told (value: meaning). It's run with uv.")
            .font(.callout).foregroundStyle(.secondary)
    }
}
