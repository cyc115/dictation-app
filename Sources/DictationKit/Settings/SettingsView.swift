import AppKit
import SwiftUI

/// The Settings page: one section per feature, each kept in that feature's folder
/// (`SpeechModelSection`, `AudioSection`, `CommandsSection`, …). A new feature adds its section here.
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    let services: AppServices
    /// Opens the Commands tab (Settings › Commands › Manage Commands…).
    var onShowCommands: (() -> Void)?
    @State private var microphones: [AudioInputDevice] = []

    init(services: AppServices, onShowCommands: (() -> Void)? = nil) {
        settings = services.settings
        self.services = services
        self.onShowCommands = onShowCommands
    }

    var body: some View {
        Form {
            SpeechModelSection(settings: settings)
            GeneralSection(settings: settings)
            AudioSection(settings: settings, microphones: microphones)
            ShortcutsSection(settings: settings)
            CommandsSection(settings: settings, onShowCommands: onShowCommands)
            PolishSection(settings: settings)
            HistorySection(settings: settings, history: services.history, archive: services.archive)
            ExperimentalSection(settings: settings)
        }
        .formStyle(.grouped)
        .onTabShown {
            let found = AudioDevices.inputDevices()
            if found != microphones { microphones = found }
            settings.refreshLoginItem()
            settings.reloadSetups()
        }
    }
}

/// Settings › General: appearance, launch at login, Dock icon.
private struct GeneralSection: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
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
    }
}
