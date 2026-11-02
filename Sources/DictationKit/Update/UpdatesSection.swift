import SwiftUI

/// Settings › Updates: check daily for a new GitHub release, and check (or install) now.
struct UpdatesSection: View {
    @ObservedObject var updates: Updates
    var version = AppVersion.current.version
    @Environment(\.dateContext) private var dates

    var body: some View {
        Section {
            SettingRow("Check for updates automatically", "Look for a new release once a day. A new one shows in the menu bar menu and here; nothing installs until you say so.",
                       available: updates.isAvailable) {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { updates.automaticallyChecks },
                    set: { updates.automaticallyChecks = $0 }))
            }
            SettingRow("Version \(version)", detail, available: updates.isAvailable) {
                if updates.available != nil {
                    Button("Install…") { updates.checkNow() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Check Now") { updates.checkNow() }
                }
            }
        } header: {
            Label("Updates", systemImage: "arrow.down.circle")
        }
    }

    private var detail: String {
        if !updates.isAvailable { return "Updates work in the installed app." }
        if let new = updates.available { return "Version \(new) is available." }
        guard let last = updates.lastChecked else { return "Not checked yet." }
        return "Last checked " + dates.string(last, AppVersion.builtStyle) + "."
    }
}
