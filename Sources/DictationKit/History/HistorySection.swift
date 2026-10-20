import SwiftUI

/// Settings › History & recordings: how long History is kept, kept recordings, detailed analytics.
struct HistorySection: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: HistoryStore
    let archive: RecordingArchive

    var body: some View {
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
}
