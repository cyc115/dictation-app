import SwiftUI

/// Settings › Audio: the microphone, intelligent mic selection, sounds and muting.
struct AudioSection: View {
    @ObservedObject var settings: AppSettings
    /// The Mac's mics, as of when Settings was last shown.
    let microphones: [AudioInputDevice]

    var body: some View {
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
    }
}
