import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: HistoryStore = .shared
    @State private var microphones: [AudioInputDevice] = []
    @State private var askForKey = false
    @State private var keyDraft = ""

    private var cloud: Bool { settings.setup.usesCloud }


    var body: some View {
        Form {
            Section {
                SettingRow("Model", settings.setup.summary + (settings.setupsError.map { "\n⚠︎ " + $0 } ?? "")) {
                    Picker("Model", selection: Binding(
                        get: { settings.setup },
                        set: { setup in
                            settings.setup = setup
                            if setup.usesCloud && !settings.hasOpenRouterKey { keyDraft = ""; askForKey = true }
                        })) {
                        ForEach(settings.setups) { Text($0.title).tag($0) }
                    }
                }
                SettingRow("Language", settings.setup.supportsLanguageChoice
                           ? "Language the on-device model listens for."
                           : "Cloud models detect English and Chinese automatically.",
                           available: settings.setup.supportsLanguageChoice) {
                    if settings.setup.supportsLanguageChoice {
                        Picker("Language", selection: $settings.localLanguage) {
                            ForEach(LocalLanguage.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                    } else {
                        Text("Auto-detect").foregroundStyle(.secondary)
                    }
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
                SettingRow("Mouse button for Enter", "Press it to send Return, e.g. to send what you dictated without touching the keyboard.") {
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
                SettingRow("Type as you speak", settings.setup.supportsStreaming
                           ? "Insert each phrase into the focused app as soon as you pause, instead of pasting everything when you stop. Cancelling keeps what's already typed. With a held ⌘/⌥/⌃/⇧ hotkey, text is typed when you release it."
                           : "Only works with the On-device model. Cloud models write the text after you stop.",
                           available: settings.setup.supportsStreaming) {
                    // Shown off while unavailable so it doesn't look active; the saved choice is
                    // kept and comes back with the On-device model.
                    Toggle("Type as you speak", isOn: Binding(
                        get: { settings.effectiveStreaming },
                        set: { settings.streamWhileSpeaking = $0 }))
                }
                SettingRow("AI polish", settings.effectiveStreaming
                           ? "Not used while “Type as you speak” is on — polish needs the whole dictation."
                           : settings.setup.polishesOnDevice
                           ? "Removes filler words and fixes self-corrections, on this Mac like the speech model: nothing leaves it. Adds about 1 second to a sentence, up to 3 to a long paragraph."
                           : "Removes filler words and fixes self-corrections with a cloud model, like the speech model. Adds about half a second.") {
                    Toggle("AI polish", isOn: $settings.polishEnabled)
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
                        Button("Show in Finder") { RecordingArchive.shared.showInFinder() }
                    }
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
        .onAppear {
            microphones = AudioDevices.inputDevices()
            settings.refreshLoginItem()
            settings.reloadSetups()
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
