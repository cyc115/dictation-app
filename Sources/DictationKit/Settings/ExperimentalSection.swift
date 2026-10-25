import SwiftUI

/// Settings › Experimental: features still being tried out, each with its own switch.
struct ExperimentalSection: View {
    @ObservedObject var settings: AppSettings
    /// Whether Decider is ready (tests fake it).
    var checkDecider: () async -> LocalDecider.Status = { await LocalDecider.status() }

    var body: some View {
        Section {
            SettingRow("Paste where you dictated", "Switch apps while the text is on its way: it still goes into the box you dictated into (and is sent, with the Enter button), then you're brought back. Keys and clicks pause until a second after the paste.") {
                Toggle("Paste where you dictated", isOn: $settings.pasteWhereDictated)
            }
            SettingRow("Decide commands on this Mac", "Command mode asks Decider, a free app from Perplexity, on this Mac instead of Jev online: picking the command needs no key and no network. About as often right, but slower (about 0.9 s a command, to 0.2 s).") {
                Toggle("Decide commands on this Mac", isOn: $settings.localCommandDecider)
            }
            if settings.localCommandDecider {
                LocalDeciderRow(check: checkDecider)
            }
        } header: {
            Label("Experimental", systemImage: "flask")
        }
    }
}
