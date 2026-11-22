import SwiftUI

/// Settings › Vocabulary: vocabulary on or off, the on-device speech hint, Learn from my edits (and
/// how the edit watcher has fared in each app), Ask a model about my fixes (cloud setups only); the
/// terms themselves are managed in the Vocabulary tab (`VocabularyView`).
struct VocabularySection: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var editStats: EditWatchStats
    var onShowVocabulary: (() -> Void)?

    /// The judge runs on cloud setups only (`FixJudge.backend`): a setup that polishes on this Mac
    /// sends nothing, so there the row is unavailable and shows off, whatever `judgeFixes` holds (it's
    /// kept for when you switch back).
    private var judgeAvailable: Bool { !settings.setup.polishesOnDevice }

    private var judgeDetail: String {
        judgeAvailable
            ? "When the app is idle, asks a cloud model whether each word you changed was misheard, style, or a change of mind: only misheard words go into vocabulary, and a captured edit keeps only its misheard and style changes. Captured edits still wait for your Accept. Sends what the app wrote, what you changed it to, and your vocabulary's terms."
            : "Works on cloud setups only. On this setup nothing is sent: your fixes are counted by the rules, and captured edits wait for your Accept."
    }

    /// Off where it can't run, so the row never looks on and working there.
    private var judgeToggle: Binding<Bool> {
        Binding(get: { judgeAvailable && settings.judgeFixes }, set: { settings.judgeFixes = $0 })
    }

    var body: some View {
        Section {
            SettingRow("Use vocabulary", "Replaces what the speech model mishears with your terms, in every dictation, and tells AI polish the terms. The list stays on this Mac; the terms go where polish goes, and with an API key to the cloud models behind Corrections' suggestions and Learn.") {
                Toggle("Use vocabulary", isOn: $settings.vocabularyEnabled)
            }
            SettingRow("Hint the on-device speech model", "Also gives your terms to the On-device speech model while you speak. Off until it's been measured: hint words have made it translate mixed Chinese into English.",
                       available: settings.vocabularyEnabled) {
                Toggle("Hint the on-device speech model", isOn: $settings.vocabularySpeechHint)
            }
            SettingRow("Learn from my edits", "Keeps how you edit a dictation right after it's pasted (only the pasted text, as you left it), for you to accept in Corrections. Reads the text box you typed into, or follows your keys where the app doesn't say; never in password fields or paused apps. Nothing is sent anywhere, unless you also turn on Ask a model about my fixes.") {
                Toggle("Learn from my edits", isOn: $settings.learnFromEdits)
            }
            if settings.learnFromEdits && !editStats.apps.isEmpty {
                EditWatchStatsView(stats: editStats)
            }
            SettingRow("Ask a model about my fixes", judgeDetail, available: judgeAvailable, badge: "Online · needs API key") {
                Toggle("Ask a model about my fixes", isOn: judgeToggle)
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

/// How the edit watcher has fared in each app: watched, read back (the rest followed your keys),
/// and given up (keystroke mode couldn't follow).
struct EditWatchStatsView: View {
    @ObservedObject var stats: EditWatchStats

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Edits watched, by app").font(.callout.weight(.medium))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 2) {
                GridRow {
                    Text("App"); Text("Watched"); Text("Read back"); Text("Gave up")
                }
                .foregroundStyle(.secondary)
                ForEach(stats.apps.keys.sorted(), id: \.self) { name in
                    let app = stats.apps[name] ?? .init()
                    GridRow {
                        Text(name)
                        Text("\(app.armed)")
                        Text("\(app.armed - app.probesFailed)")
                        Text("\(app.gaveUp)")
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("editStats." + name)
                }
            }
            .font(.callout.monospacedDigit())
        }
        .padding(.vertical, 3)
    }
}
