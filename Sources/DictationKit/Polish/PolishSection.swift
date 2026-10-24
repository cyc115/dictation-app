import SwiftUI

/// Settings › Output: AI polish on or off, and which prompt (built in, or learned from Corrections on
/// any setup: one learned on another is labelled with it, since its scores are that setup's model's).
struct PolishSection: View {
    @Environment(\.dateContext) private var dates
    @ObservedObject var settings: AppSettings

    private var builtInPrompt: String { settings.builtInPrompt(for: settings.setup) }

    /// The built-in prompt's score on your corrections, once measured (by the tile, or as the baseline
    /// of a version learned from it).
    private var builtInScore: Int? {
        let setup = settings.setup.id, prompt = builtInPrompt
        let measured = settings.learned.measurement(setup: setup, prompt: prompt)?.mine
            ?? settings.learned.versions(for: setup).last { $0.basedOn == prompt }?.score.mineBefore
        return measured.map { Int($0.rounded()) }
    }

    private var builtInLabel: String {
        builtInScore.map { "\(builtInPrompt) · \($0)% · built in" } ?? "\(builtInPrompt) · built in"
    }

    /// "Cloud Flash" for a learned prompt's setup.
    private func title(of setup: String) -> String { settings.setups.first { $0.id == setup }?.title ?? setup }

    /// A learned version in the picker: its score, and where it was scored when that's another setup.
    private func label(_ learned: LearnedPrompt) -> String {
        let score = "\(Int(learned.score.mine.rounded()))%" + (learned.setup == settings.setup.id ? "" : " on \(title(of: learned.setup))")
        return "\(learned.version) · \(score) · from \(learned.basedOn) · \(dates.string(learned.date, .dateTime.month(.abbreviated).day()))"
    }

    private var promptDetail: String {
        guard settings.polishEnabled else { return "Turn on AI polish to choose the prompt it polishes with." }
        if let learned = settings.learned.active(for: settings.setup.id) {
            let scores = "\(Int(learned.score.mineBefore.rounded()))% → \(Int(learned.score.mine.rounded()))% on them, general set \(Int(learned.score.general.rounded()))%"
            let measured = learned.setup == settings.setup.id ? ": \(scores)."
                : " with \(title(of: learned.setup)): \(scores) there, not measured with this setup's model."
            return learned.summary + measured + " Learn branches from the version chosen here."
        }
        return settings.learned.prompts.isEmpty
            ? "The built-in prompt. Learn one from your corrections in the Corrections tab."
            : "The built-in prompt."
    }

    var body: some View {
        Section {
            SettingRow("AI polish", settings.setup.polishesOnDevice
                       ? "Removes filler words and fixes self-corrections, on this Mac like the speech model: nothing leaves it. Adds about 1 second to a sentence, up to 3 to a long paragraph."
                       : "Removes filler words and fixes self-corrections with a cloud model, like the speech model. Adds about half a second.") {
                Toggle("AI polish", isOn: $settings.polishEnabled)
            }
            // Greyed only while polish is off; with nothing learned yet it shows the prompt in use, not
            // a picker with one choice.
            SettingRow("Polish prompt", promptDetail, available: settings.polishEnabled) {
                if settings.learned.prompts.isEmpty {
                    Text(builtInLabel).foregroundStyle(.secondary)
                } else {
                    Picker("Polish prompt", selection: Binding(
                        get: { settings.setup.usesLearnedPrompt ? settings.setup.prompt : "" },
                        set: { settings.learned.activate($0.isEmpty ? nil : $0, for: settings.setup.id) })) {
                        Text(builtInLabel).tag("")
                        ForEach(settings.learned.prompts) { learned in
                            Text(label(learned)).tag(learned.version)
                        }
                    }
                }
            }
        } header: {
            Label("Output", systemImage: "text.cursor")
        }
    }
}
