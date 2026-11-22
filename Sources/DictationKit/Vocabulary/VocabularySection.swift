import SwiftUI

/// Settings › Vocabulary: vocabulary on or off, the on-device speech hint; the terms themselves are
/// managed in the Vocabulary tab (`VocabularyView`).
struct VocabularySection: View {
    @ObservedObject var settings: AppSettings
    var onShowVocabulary: (() -> Void)?

    var body: some View {
        Section {
            SettingRow("Use vocabulary", "Replaces what the speech model mishears with your terms, in every dictation, and tells AI polish the terms. Stays on this Mac; with polish on, the terms go where polish goes.") {
                Toggle("Use vocabulary", isOn: $settings.vocabularyEnabled)
            }
            SettingRow("Hint the on-device speech model", "Also gives your terms to the On-device speech model while you speak. Off until it's been measured: hint words have made it translate mixed Chinese into English.",
                       available: settings.vocabularyEnabled) {
                Toggle("Hint the on-device speech model", isOn: $settings.vocabularySpeechHint)
            }
            SettingRow("Vocabulary", "Add, edit, turn off and delete your terms in the Vocabulary tab.") {
                Button("Manage Vocabulary…") { onShowVocabulary?() }
                    .accessibilityIdentifier("settings.manageVocabulary")
            }
        } header: {
            Label("Vocabulary", systemImage: "character.book.closed")
        }
    }
}
