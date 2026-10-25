import SwiftUI

/// Settings › Experimental: features still being tried out, each with its own switch.
struct ExperimentalSection: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Section {
            SettingRow("Paste where you dictated", "Switch apps while the text is on its way: it still goes into the box you dictated into (and is sent, with the Enter button), then you're brought back. Keys and clicks pause until a second after the paste.") {
                Toggle("Paste where you dictated", isOn: $settings.pasteWhereDictated)
            }
        } header: {
            Label("Experimental", systemImage: "flask")
        }
    }
}
