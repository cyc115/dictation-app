import AppKit
import ServiceManagement
import SwiftUI

/// How the hotkey starts and stops dictation.
enum ActivationMode: String, CaseIterable {
    case hold    // hold the key while speaking, release to paste
    case toggle  // tap once to start, tap again to stop and paste

    var title: String {
        switch self {
        case .hold: return "Hold to talk"
        case .toggle: return "Press to toggle"
        }
    }
}

/// Light / dark mode for the app window.
enum AppearanceMode: String, CaseIterable {
    case system, light, dark

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
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
        static let microphone = "microphoneUID"
        static let sounds = "interactionSounds"
        static let mute = "muteWhileDictating"
        static let appearance = "appearance"
        static let dock = "showInDock"
        static let streaming = "streamWhileSpeaking"
        static let model = "transcriptionModel"
        static let language = "localLanguage"
    }

    var onChange: (() -> Void)?

    @Published var hotkey: Hotkey {
        didSet { defaults.set(hotkey.rawValue, forKey: Key.hotkey); onChange?() }
    }
    @Published var mode: ActivationMode {
        didSet { defaults.set(mode.rawValue, forKey: Key.mode); onChange?() }
    }
    @Published var mouseButton: MouseButton {
        didSet { defaults.set(mouseButton.rawValue, forKey: Key.mouse); onChange?() }
    }
    @Published var polishEnabled: Bool {
        didSet { defaults.set(polishEnabled, forKey: Key.polish); onChange?() }
    }
    /// CoreAudio device UID; empty means the system default input.
    @Published var microphoneUID: String {
        didSet { defaults.set(microphoneUID, forKey: Key.microphone); onChange?() }
    }
    @Published var interactionSounds: Bool {
        didSet { defaults.set(interactionSounds, forKey: Key.sounds); onChange?() }
    }
    @Published var muteWhileDictating: Bool {
        didSet { defaults.set(muteWhileDictating, forKey: Key.mute); onChange?() }
    }
    @Published var appearance: AppearanceMode {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance); onChange?() }
    }
    /// Type each finished phrase into the focused app while dictating (instead of one paste at the end).
    @Published var streamWhileSpeaking: Bool {
        didSet { defaults.set(streamWhileSpeaking, forKey: Key.streaming); onChange?() }
    }
    @Published var transcriptionModel: TranscriptionModel {
        didSet { defaults.set(transcriptionModel.rawValue, forKey: Key.model); onChange?() }
    }
    /// Language for the local model (kept while a cloud model is selected).
    @Published var localLanguage: LocalLanguage {
        didSet { defaults.set(localLanguage.rawValue, forKey: Key.language); onChange?() }
    }
    @Published private(set) var hasOpenRouterKey = false
    private let secrets: SecretStore
    static let openRouterAccount = "openrouter-api-key"

    var openRouterKey: String? { secrets.get(Self.openRouterAccount) }

    func setOpenRouterKey(_ key: String?) {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        secrets.set(trimmed, for: Self.openRouterAccount)
        hasOpenRouterKey = !(openRouterKey ?? "").isEmpty
        onChange?()
    }

    /// "Type as you speak" only when the setting is on and the model streams; the saved
    /// preference is kept either way.
    var effectiveStreaming: Bool { streamWhileSpeaking && transcriptionModel.supportsStreaming }

    @Published var showInDock: Bool {
        didSet { defaults.set(showInDock, forKey: Key.dock); onChange?() }
    }
    /// Mirrors macOS's login-item state; change it with setLaunchAtLogin(_:).
    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var loginItemNeedsApproval = false

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, secrets: SecretStore = KeychainStore()) {
        self.defaults = defaults
        self.secrets = secrets
        hotkey = Hotkey(rawValue: defaults.string(forKey: Key.hotkey) ?? "") ?? .fn
        mode = ActivationMode(rawValue: defaults.string(forKey: Key.mode) ?? "") ?? .hold
        polishEnabled = defaults.bool(forKey: Key.polish)
        mouseButton = MouseButton(rawValue: defaults.string(forKey: Key.mouse) ?? "") ?? .off
        microphoneUID = defaults.string(forKey: Key.microphone) ?? ""
        interactionSounds = defaults.object(forKey: Key.sounds) as? Bool ?? true
        muteWhileDictating = defaults.bool(forKey: Key.mute)
        appearance = AppearanceMode(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
        showInDock = defaults.bool(forKey: Key.dock)
        streamWhileSpeaking = defaults.bool(forKey: Key.streaming)
        transcriptionModel = TranscriptionModel(rawValue: defaults.string(forKey: Key.model) ?? "") ?? .local
        localLanguage = LocalLanguage(rawValue: defaults.string(forKey: Key.language) ?? "") ?? .english
        hasOpenRouterKey = !(secrets.get(Self.openRouterAccount) ?? "").isEmpty
        launchAtLogin = false
        refreshLoginItem()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("DictationApp: login item change failed: \(error.localizedDescription)")
        }
        refreshLoginItem()
    }

    func refreshLoginItem() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled || status == .requiresApproval
        loginItemNeedsApproval = status == .requiresApproval
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
    @State private var microphones: [AudioInputDevice] = []
    @State private var askForKey = false
    @State private var keyDraft = ""

    private var cloud: Bool { settings.transcriptionModel.isCloud }

    private var modelDetail: String {
        let model = settings.transcriptionModel
        guard let provider = model.provider, let cost = model.costPerAudioHour else {
            return "Runs on this Mac; nothing leaves it."
        }
        return "Audio is sent to \(provider) via OpenRouter when you stop (~$\(String(format: cost < 0.1 ? "%.3f" : "%.2f", cost)) per hour of audio). Handles English mixed into Chinese."
    }

    var body: some View {
        Form {
            Section {
                SettingRow("Model", modelDetail) {
                    Picker("Model", selection: Binding(
                        get: { settings.transcriptionModel },
                        set: { model in
                            settings.transcriptionModel = model
                            if model.isCloud && !settings.hasOpenRouterKey { keyDraft = ""; askForKey = true }
                        })) {
                        ForEach(TranscriptionModel.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                SettingRow("Language", settings.transcriptionModel.supportsLanguageChoice
                           ? "Language the local model listens for."
                           : "Not needed — this model detects English and Chinese automatically.") {
                    Picker("Language", selection: $settings.localLanguage) {
                        ForEach(LocalLanguage.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                .disabled(!settings.transcriptionModel.supportsLanguageChoice)
                if cloud {
                    SettingRow("OpenRouter API key", settings.hasOpenRouterKey
                               ? "Saved in your Keychain."
                               : "Required for this model.") {
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
                if settings.hotkey == .fn {
                    Text("Tip: set System Settings → Keyboard → “Press 🌐 key to” → Do Nothing, so Fn doesn't also open the emoji picker.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label("Shortcuts", systemImage: "keyboard")
            }

            Section {
                SettingRow("Type as you speak", settings.transcriptionModel.supportsStreaming
                           ? "Insert each phrase into the focused app as soon as you pause, instead of pasting everything when you stop. Cancelling keeps what's already typed. With a held ⌘/⌥/⌃/⇧ hotkey, text is typed when you release it."
                           : "Not available with \(settings.transcriptionModel.title) — it transcribes after you stop.") {
                    Toggle("Type as you speak", isOn: $settings.streamWhileSpeaking)
                }
                .disabled(!settings.transcriptionModel.supportsStreaming)
            } header: {
                Label("Output", systemImage: "text.cursor")
            }

            Section {
                SettingRow("AI polish", settings.effectiveStreaming
                           ? "Not used while “Type as you speak” is on — polish needs the whole dictation."
                           : "Remove filler words and fix self-corrections with Apple's on-device model.") {
                    Toggle("AI polish", isOn: $settings.polishEnabled)
                }
            } header: {
                Label("Cleanup", systemImage: "wand.and.stars")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $askForKey) {
            APIKeySheet(key: $keyDraft,
                        onSave: { settings.setOpenRouterKey(keyDraft); askForKey = false },
                        onCancel: {
                            askForKey = false
                            // No key, no cloud model: fall back so dictation keeps working.
                            if !settings.hasOpenRouterKey { settings.transcriptionModel = .local }
                        })
        }
        .onAppear {
            microphones = AudioDevices.inputDevices()
            settings.refreshLoginItem()
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
            Text("OpenRouter API key").font(.headline)
            Text("Cloud models run through OpenRouter. Paste an API key from openrouter.ai/keys — it's stored in your Keychain and shared by all cloud models. The account needs credits; Meta Muse also needs the 18+ confirmation in OpenRouter's preferences.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("sk-or-v1-…", text: $key)
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
    let control: Control

    init(_ title: String, _ detail: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
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
    }
}
