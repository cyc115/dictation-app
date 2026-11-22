import AppKit
import Combine
import SwiftUI

/// Starts a new correction from a cloud model's polish of what you said (with your setup's prompt), so you fix less by hand.
/// The model is the `correctionModel` setting (an OpenRouter model id, optionally "@Provider"); the
/// default, GPT-6.1 Sol Pro, is the most accurate polish model benchmarked (100% on bench/suite.py
/// polish, both test sets), but ~3 s and ~$5 per 1,000: too slow and costly while dictating, fine for
/// an occasional correction. Thinking is always off, or the lowest effort for a model that can't
/// turn it off (`OpenRouter.reasoning(for:)`). Asks once, when the pencil makes the correction; the
/// answer replaces the app's text only if you haven't typed yet. Without a cloud API key the
/// correction stays as the app wrote it.
final class CorrectionSuggester: ObservableObject {
    static let defaultModel = "openai/gpt-6.1-sol-pro"
    /// Suggests nothing (no model): the default where no suggester is handed in.
    static var off: CorrectionSuggester { CorrectionSuggester { nil } }

    /// `model` (an OpenRouter model id; blank is the default) with the AI polish prompt of the setup
    /// chosen in Settings and your vocabulary, so it polishes the way the app does.
    static func backend(apiKey: String, setup: DictationSetup, model: String = defaultModel, vocabulary: Vocabulary) -> PolishBackend? {
        guard !apiKey.isEmpty, let backend = DictationSetup.polishBackend(spec: "openrouter:" + modelID(model), apiKey: apiKey,
                                                                          instructions: setup.instructions(vocabulary), wrap: setup.wrap)
        else { return nil }
        return VocabularyPolish.wrap(backend, vocabulary)
    }

    /// The model id as typed, trimmed; the default when blank.
    static func modelID(_ model: String) -> String {
        let id = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? defaultModel : id
    }

    /// Corrections waiting for the model.
    @Published private(set) var pending: Set<UUID> = []
    /// Why the last suggestion failed, by correction.
    @Published private(set) var failed: [UUID: String] = [:]
    private let backend: () -> PolishBackend?
    /// The model's name, for the messages in Corrections.
    let modelName: () -> String

    init(backend: @escaping () -> PolishBackend?, modelName: @escaping () -> String = { CorrectionSuggester.defaultModel }) {
        self.backend = backend
        self.modelName = modelName
    }

    func suggest(for entry: HistoryEntry, in store: HistoryStore) {
        guard !pending.contains(entry.id), let backend = backend() else { return }
        let id = entry.id, start = entry.correction ?? entry.text
        pending.insert(id)
        failed[id] = nil
        Task { @MainActor in
            defer { pending.remove(id) }
            do {
                let text = try await PolishService(backend: backend).polished(entry.input)
                if store.entries.first(where: { $0.id == id })?.correction == start { store.setCorrection(text, for: id) }
            } catch {
                failed[id] = error.localizedDescription
            }
        }
    }
}
