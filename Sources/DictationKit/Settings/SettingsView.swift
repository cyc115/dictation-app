import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(\.dateContext) private var dates
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: HistoryStore
    let archive: RecordingArchive
    /// Command mode's folder.
    let commandsFolder: URL
    @State private var microphones: [AudioInputDevice] = []
    @State private var askForKey = false
    @State private var keyDraft = ""

    init(services: AppServices) {
        settings = services.settings
        history = services.history
        archive = services.archive
        commandsFolder = services.commands.folder
    }

    private var cloud: Bool { settings.setup.usesCloud }

    private var builtInPrompt: String { settings.builtInPrompt(for: settings.setup) }

    /// The built-in prompt's score on your corrections, once measured (by the tile, or as the baseline
    /// of a version learned from it).
    private var builtInScore: Int? {
        let setup = settings.setup.id, prompt = builtInPrompt
        let measured = settings.learned.measurement(setup: setup, prompt: prompt)?.mine
            ?? settings.learned.versions(for: setup).last { $0.basedOn == prompt }?.score.mineBefore
        return measured.map { Int($0.rounded()) }
    }

    private var promptDetail: String {
        guard settings.polishEnabled else { return "Turn on AI polish to choose the prompt it polishes with." }
        if let learned = settings.learned.active(for: settings.setup.id) {
            return "\(learned.summary): \(Int(learned.score.mineBefore.rounded()))% → \(Int(learned.score.mine.rounded()))% on them, general set \(Int(learned.score.general.rounded()))%. Learn branches from the version chosen here."
        }
        return settings.learned.versions(for: settings.setup.id).isEmpty
            ? "The built-in prompt. Learn one from your corrections in the Corrections tab."
            : "The built-in prompt."
    }


    var body: some View {
        Form {
            Section {
                SettingRow("Model", settings.setup.summary + (settings.setupsError.map { "\n⚠︎ " + $0 } ?? "")) {
                    Picker("Model", selection: Binding(
                        get: { settings.setup },
                        set: { setup in
                            settings.setup = setup
                            if setup.usesCloud && !settings.hasOpenRouterKey { keyDraft = ""; askForKey = true }
                            // First use: downloads the model now, rather than at the first dictation.
                            if let id = setup.localModelID { settings.localModel(id).prepare() }
                        })) {
                        ForEach(settings.setups) { Text($0.title).tag($0) }
                    }
                }
                if let id = settings.setup.localModelID {
                    LocalModelRow(model: settings.localModel(id))
                }
                SettingRow("Backup model when slow", settings.setup.backupHelp ?? "Only works with cloud models.",
                           available: settings.setup.backup != nil) {
                    Toggle("Backup model when slow", isOn: Binding(
                        get: { settings.effectiveBackup },
                        set: { settings.backupWhenSlow = $0 }))
                }
                if cloud {
                    SettingRow("Cloud API key", settings.hasOpenRouterKey
                               ? "Saved on this Mac, readable only by your user account."
                               : "Required for cloud models.") {
                        Button(settings.hasOpenRouterKey ? "Change…" : "Add Key…") { keyDraft = ""; askForKey = true }
                    }
                }
            } header: {
                Label("Speech model", systemImage: "waveform.badge.mic")
            }

            Section {
                SettingRow("Appearance", "Choose between light and dark modes.") {
                    Picker("Appearance", selection: $settings.appearance) {
                        ForEach(AppearanceMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                SettingRow("Launch app at login", settings.loginItemNeedsApproval
                           ? "Waiting for approval in System Settings → General → Login Items."
                           : "Open DictationApp automatically when your Mac starts.") {
                    Toggle("Launch app at login", isOn: Binding(
                        get: { settings.launchAtLogin },
                        set: { settings.setLaunchAtLogin($0) }))
                }
                SettingRow("Show app in Dock", "Display DictationApp in your Dock for quick access.") {
                    Toggle("Show app in Dock", isOn: $settings.showInDock)
                }
            } header: {
                Label("General", systemImage: "laptopcomputer")
            }

            Section {
                SettingRow("Microphone", "Choose the microphone used to capture your voice.") {
                    Picker("Microphone", selection: $settings.microphoneUID) {
                        Text("System default").tag("")
                        if !settings.microphoneUID.isEmpty,
                           !microphones.contains(where: { $0.uid == settings.microphoneUID }) {
                            Text("Disconnected device").tag(settings.microphoneUID)
                        }
                        ForEach(microphones, id: \.uid) { Text($0.name).tag($0.uid) }
                    }
                }
                SettingRow("Intelligent mic selection",
                           "Also listen on your wired and built-in mics, and switch to the one that hears you best. "
                           + "Bluetooth mics are only used when chosen above.") {
                    Toggle("Intelligent mic selection", isOn: $settings.intelligentMicSelection)
                        .accessibilityIdentifier("settings.intelligentMic")
                }
                SettingRow("Interaction sounds", "Play sounds for key actions like start/stop.") {
                    Toggle("Interaction sounds", isOn: $settings.interactionSounds)
                }
                SettingRow("Mute when dictating", "Automatically silence other audio while you dictate.") {
                    Toggle("Mute when dictating", isOn: $settings.muteWhileDictating)
                }
            } header: {
                Label("Audio", systemImage: "mic")
            }

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
                SettingRow("Mouse button for Enter", settings.commandModeEnabled
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

            Section {
                SettingRow("Command mode", "Press the Enter button when you're not dictating, say what you want — “brightness to half”, “声音小一点” — and press it again: it runs one of the commands below. A cloud model picks which, with your API key; a command it isn't sure of doesn't run.",
                           available: settings.mouseEnterEnabled) {
                    Toggle("Command mode", isOn: $settings.commandModeEnabled)
                }
                CommandsList(folder: commandsFolder)
                    .disabled(!settings.commandModeEnabled || !settings.mouseEnterEnabled)
                    .opacity(settings.commandModeEnabled && settings.mouseEnterEnabled ? 1 : 0.4)
            } header: {
                Label("Commands", systemImage: "chevron.forward.square")
            }

            Section {
                SettingRow("AI polish", settings.setup.polishesOnDevice
                           ? "Removes filler words and fixes self-corrections, on this Mac like the speech model: nothing leaves it. Adds about 1 second to a sentence, up to 3 to a long paragraph."
                           : "Removes filler words and fixes self-corrections with a cloud model, like the speech model. Adds about half a second.") {
                    Toggle("AI polish", isOn: $settings.polishEnabled)
                }
                SettingRow("Polish prompt", promptDetail, available: settings.polishEnabled && !settings.learned.versions(for: settings.setup.id).isEmpty) {
                    Picker("Polish prompt", selection: Binding(
                        get: { settings.setup.usesLearnedPrompt ? settings.setup.prompt : "" },
                        set: { settings.learned.activate($0.isEmpty ? nil : $0, for: settings.setup.id) })) {
                        Text(builtInScore.map { "\(builtInPrompt) · \($0)% · built in" } ?? "\(builtInPrompt) · built in").tag("")
                        ForEach(settings.learned.versions(for: settings.setup.id)) { learned in
                            Text("\(learned.version) · \(Int(learned.score.mine.rounded()))% · from \(learned.basedOn) · \(dates.string(learned.date, .dateTime.month(.abbreviated).day()))")
                                .tag(learned.version)
                        }
                    }
                }
            } header: {
                Label("Output", systemImage: "text.cursor")
            }

            Section {
                SettingRow("Keep history", "Stored only on this Mac. Nothing is uploaded.") {
                    Picker("Keep history", selection: $history.retention) {
                        ForEach(HistoryRetention.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SettingRow("Keep recordings", "Save each dictation's audio and what was heard on this Mac, to build a test set for comparing speech models. When off, audio is deleted once it's transcribed.") {
                    Toggle("Keep recordings", isOn: $settings.keepRecordings)
                }
                if settings.keepRecordings {
                    SettingRow("Recordings folder", "Application Support › DictationApp › Recordings. Cancelled dictations aren't kept.") {
                        Button("Show in Finder") { archive.showInFinder() }
                    }
                }
                SettingRow("Show detailed analytics", "Adds your recent dictations' wait times to Home, model by model, with how often the backup model answered. For finding a slow model.") {
                    Toggle("Show detailed analytics", isOn: $settings.showDetailedAnalytics)
                }
            } header: {
                Label("History & recordings", systemImage: "internaldrive")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $askForKey) {
            APIKeySheet(key: $keyDraft,
                        onSave: { settings.setOpenRouterKey(keyDraft); askForKey = false },
                        onCancel: {
                            askForKey = false
                            // No key, no cloud model: fall back so dictation keeps working.
                            if !settings.hasOpenRouterKey { settings.setup = .onDevice }
                        })
        }
        .onTabShown {
            let found = AudioDevices.inputDevices()
            if found != microphones { microphones = found }
            settings.refreshLoginItem()
            settings.reloadSetups()
        }
    }
}

/// The on-device speech model: downloaded or not, with progress while it downloads.
private struct LocalModelRow: View {
    @ObservedObject var model: LocalSpeechModel

    private var detail: String {
        switch model.state {
        case .notDownloaded: return "The speech model, 2.5 GB from Hugging Face. Downloads now, or the first time you dictate."
        case .downloading(let fraction): return "Downloading the speech model from Hugging Face… \(Int(fraction * 100))%"
        case .failed(let message): return "Download or loading failed: \(message)"
        case .onDisk, .loading, .ready:
            return "Downloaded. Stays in memory (2.6 GB) on power; on battery, until 30 minutes after you last dictate."
        }
    }

    var body: some View {
        SettingRow("On-device model", detail) {
            switch model.state {
            case .notDownloaded:
                Button("Download") { model.prepare() }
            case .failed:
                Button("Try Again") { model.prepare() }
            case .downloading(let fraction):
                ProgressView(value: fraction).frame(width: 120)
            case .loading:
                ProgressView().controlSize(.small)
            case .onDisk:
                Text("Downloaded").foregroundStyle(.secondary)
            case .ready:
                Text("Ready").foregroundStyle(.secondary)
            }
        }
    }
}

/// Asks for the OpenRouter API key when a cloud model is chosen.
private struct APIKeySheet: View {
    @Binding var key: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cloud API key").font(.headline)
            Text("Cloud models need an API key. It's saved on this Mac, readable only by your user account, and shared by every cloud setup.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Paste your API key", text: $key)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("apikey.field")
                .onSubmit { if !key.isEmpty { onSave() } }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
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

/// Title and description on the left, control on the right.
private struct SettingRow<Control: View>: View {
    let title: String
    let detail: String
    let available: Bool
    let control: Control

    /// `available: false` greys out the whole row (not just the control) and labels it, so it
    /// clearly can't be used with the current choice.
    init(_ title: String, _ detail: String, available: Bool = true, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.available = available
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.body.weight(.medium))
                    if !available {
                        Text("Unavailable")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .overlay(Capsule().stroke(.secondary.opacity(0.6)))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control
                .accessibilityIdentifier("setting." + title)
                .labelsHidden()
                .toggleStyle(.switch)
                .fixedSize()
        }
        .padding(.vertical, 3)
        .disabled(!available)
        .opacity(available ? 1 : 0.4)
        .accessibilityElement(children: .contain)
        .accessibilityHint(available ? "" : "Unavailable with the current speech model")
    }
}
