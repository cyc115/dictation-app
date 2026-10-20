import SwiftUI

/// Settings › Speech model: the setup, its on-device model or cloud API key, and the backup model.
struct SpeechModelSection: View {
    @ObservedObject var settings: AppSettings
    @State private var askForKey = false
    @State private var keyDraft = ""

    var body: some View {
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
            if settings.setup.usesCloud {
                SettingRow("Cloud API key", settings.hasOpenRouterKey
                           ? "Saved on this Mac, readable only by your user account."
                           : "Required for cloud models.") {
                    Button(settings.hasOpenRouterKey ? "Change…" : "Add Key…") { keyDraft = ""; askForKey = true }
                }
            }
        } header: {
            Label("Speech model", systemImage: "waveform.badge.mic")
        }
        .sheet(isPresented: $askForKey) {
            APIKeySheet(key: $keyDraft,
                        onSave: { settings.setOpenRouterKey(keyDraft); askForKey = false },
                        onCancel: {
                            askForKey = false
                            // No key, no cloud model: fall back so dictation keeps working.
                            if !settings.hasOpenRouterKey { settings.setup = .onDevice }
                        })
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
