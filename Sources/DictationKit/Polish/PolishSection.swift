import SwiftUI

/// Settings › Output: AI polish on or off, and which prompt (built in, or learned from Corrections).
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

    private var promptDetail: String {
        guard settings.polishEnabled else { return "Turn on AI polish to choose the prompt it polishes with." }
        if let learned = settings.learned.active(for: settings.setup.id) {
            return "\(learned.summary): \(Int(learned.score.mineBefore.rounded()))% → \(Int(learned.score.mine.rounded()))% on them, general set \(Int(learned.score.general.rounded()))%. Learn branches from the version chosen here."
        }
        return settings.learned.versions(for: settings.setup.id).isEmpty
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
            SettingRow("Polish prompt", promptDetail, available: settings.polishEnabled && !settings.learned.versions(for: settings.setup.id).isEmpty) {
                Picker("Polish prompt", selection: Binding(
                    get: { settings.setup.usesLearnedPrompt ? settings.setup.prompt : "" },
                    set: { settings.learned.activate($0.isEmpty ? nil : $0, for: settings.setup.id) })) {
                    Text(builtInScore.map { "\(builtInPrompt) · \($0)% · built in" } ?? "\(builtInPrompt) · built in").tag("")
                    ForEach(settings.learned.versions(for: settings.setup.id)) { learned in
                        Text("\(learned.version) · \(Int(learned.score.mine.rounded()))% · from \(learned.basedOn) · \(dates.string(learned.date, .dateTime.month(.abbreviated).day()))")
                            .tag(learned.version)
                    }
                }
            }
        } header: {
            Label("Output", systemImage: "text.cursor")
        }
    }
}
