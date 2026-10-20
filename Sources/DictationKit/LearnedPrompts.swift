import Combine
import Foundation

/// A polish prompt the app learned from your corrections (`PromptTuner`), kept as a version of its
/// own: "v5", for one setup, with the scores that justified keeping it.
struct LearnedPrompt: Codable, Equatable, Identifiable {
    struct Score: Codable, Equatable {
        /// 100 × (1 − mean error) on your corrections, cross-validated, with this prompt and the one before.
        var mine: Double
        var mineBefore: Double
        /// Pass rate on the general test set, 0–100.
        var general: Double
        var generalBefore: Double
    }

    var version: String
    var setup: String
    /// The version this was learned from ("v7", or an earlier learned one).
    var basedOn: String
    var date: Date
    var text: String
    var lens: Lens
    /// How many corrections it was learned from.
    var corrections: Int
    var tokens: Int
    var score: Score
    /// Each correction's held-out error (`HistoryEntry.id`), with this prompt and the one before.
    var errors: [String: Double]
    var errorsBefore: [String: Double]

    var id: String { version }

    /// "v5 · learned from 15 corrections".
    var summary: String { "\(version) · learned from \(corrections) correction\(corrections == 1 ? "" : "s")" }
}

/// A prompt's measured scores on your corrections, kept so the tile shows them without measuring again.
struct PromptMeasurement: Codable, Equatable {
    var setup: String
    var prompt: String
    var date: Date
    var mine: Double
    var general: Double
    /// How many corrections it was measured on.
    var corrections: Int
}

/// The learned prompts, and which one each setup uses, in Application Support
/// (learned-prompts.json; each prompt's text also in prompts/<version>.txt for bench/suite.py
/// polish run --prompt-file). `AppSettings` applies the active one to its setups.
final class LearnedPromptStore: ObservableObject {
    static let shared = LearnedPromptStore()

    @Published private(set) var prompts: [LearnedPrompt] = []
    /// Setup id → the version it polishes with (absent: its built-in prompt).
    @Published private(set) var active: [String: String] = [:]
    /// The current prompt's scores, by "<setup>|<prompt version>".
    @Published private(set) var measurements: [String: PromptMeasurement] = [:]

    let fileURL: URL

    static let defaultFileURL = AppPaths.file("learned-prompts.json")

    private struct File: Codable {
        var active: [String: String]
        var prompts: [LearnedPrompt]
        var measurements: [String: PromptMeasurement]?
    }

    init(fileURL: URL = LearnedPromptStore.defaultFileURL) {
        self.fileURL = fileURL
        if let file = JSONFile.read(File.self, from: fileURL) {
            prompts = file.prompts
            active = file.active
            measurements = file.measurements ?? [:]
        }
    }

    /// The next version name: one past the built-in and learned ones ("v8" at first).
    var nextVersion: String {
        let numbers = (PolishPrompt.versions.keys.map { $0 } + prompts.map(\.version)).compactMap { Int($0.dropFirst()) }
        return "v\((numbers.max() ?? 0) + 1)"
    }

    func text(for version: String) -> String? { prompts.first { $0.version == version }?.text }

    /// This setup's learned versions, oldest first.
    func versions(for setup: String) -> [LearnedPrompt] { prompts.filter { $0.setup == setup } }

    func active(for setup: String) -> LearnedPrompt? {
        active[setup].flatMap { version in prompts.first { $0.version == version } }
    }

    /// Adds a learned prompt and makes it its setup's active one.
    func keep(_ prompt: LearnedPrompt) {
        prompts.removeAll { $0.version == prompt.version }
        prompts.append(prompt)
        active[prompt.setup] = prompt.version
        save()
    }

    /// Polishes `setup` with `version` (nil: its built-in prompt again).
    func activate(_ version: String?, for setup: String) {
        guard active[setup] != version else { return }
        active[setup] = version
        save()
    }

    func measurement(setup: String, prompt: String) -> PromptMeasurement? { measurements["\(setup)|\(prompt)"] }

    func record(_ measurement: PromptMeasurement) {
        measurements["\(measurement.setup)|\(measurement.prompt)"] = measurement
        save()
    }

    /// The setup with its active learned prompt applied (unchanged when it has none).
    func apply(to setup: DictationSetup) -> DictationSetup {
        guard let learned = active(for: setup.id) else { return setup }
        var applied = setup
        applied.prompt = learned.version
        applied.learnedText = learned.text
        return applied
    }

    /// A correction's held-out error with the setup's active learned prompt, and with the prompt before it.
    func errors(for entry: UUID, setup: String) -> (before: Double, now: Double)? {
        guard let learned = active(for: setup), let now = learned.errors[entry.uuidString],
              let before = learned.errorsBefore[entry.uuidString] else { return nil }
        return (before, now)
    }

    /// The active learned prompt gets this correction (nearly) right, so the next tune needn't learn it again.
    func isLearned(_ entry: UUID, setup: String) -> Bool {
        (errors(for: entry, setup: setup)?.now).map { $0 <= PromptTuner.learnedError } ?? false
    }

    private func save() {
        let folder = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("prompts"), withIntermediateDirectories: true)
        JSONFile.save(File(active: active, prompts: prompts, measurements: measurements), to: fileURL, pretty: true)
        for prompt in prompts {
            try? (prompt.text + "\n").write(to: folder.appendingPathComponent("prompts/\(prompt.version).txt"), atomically: true, encoding: .utf8)
        }
    }
}
