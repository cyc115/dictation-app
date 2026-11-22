import AppKit
import Combine
import SwiftUI

/// Starts a new correction from a cloud model's polish of what you said (with your setup's prompt), so you fix less by hand.
/// The model is the `correctionModel` setting (an OpenRouter model id, optionally "@Provider"); the
/// default, GPT-6.1 Sol Pro, is the most accurate polish model benchmarked (100% on bench/suite.py
/// polish, both test sets), but ~3 s and ~$5 per 1,000: too slow and costly while dictating, fine for
/// an occasional correction. Thinking is always off, or the lowest effort for a model that can't
/// turn it off (`OpenRouter.reasoning(for:)`). Asks once, when the pencil makes the correction; the
/// answer replaces the app's text only if you haven't typed yet. Without a cloud API key, or on a
/// setup that polishes on this Mac (the suggestion follows polish: polish on this Mac, nothing
/// sent), the correction stays as the app wrote it.
final class CorrectionSuggester: ObservableObject {
    static let defaultModel = "openai/gpt-6.1-sol-pro"
    /// Suggests nothing (no model): the default where no suggester is handed in.
    static var off: CorrectionSuggester { CorrectionSuggester { nil } }

    /// Makes the cloud polish a suggestion asks: `DictationSetup.polishBackend` (tests pass one that
    /// must never be called).
    typealias Cloud = (_ spec: String, _ apiKey: String, _ instructions: String, _ wrap: Bool) -> PolishBackend?
    static let cloud: Cloud = { DictationSetup.polishBackend(spec: $0, apiKey: $1, instructions: $2, wrap: $3) }

    /// `model` (an OpenRouter model id; blank is the default) with the AI polish prompt of the setup
    /// chosen in Settings and your vocabulary, so it polishes the way the app does. Nil (no
    /// suggestion, nothing sent) without a key, and on a setup that polishes on this Mac: the one
    /// place that rule lives.
    static func backend(apiKey: String, setup: DictationSetup, model: String = defaultModel, vocabulary: Vocabulary,
                        cloud: Cloud = CorrectionSuggester.cloud) -> PolishBackend? {
        guard !setup.polishesOnDevice, !apiKey.isEmpty,
              let backend = cloud("openrouter:" + modelID(model), apiKey, setup.instructions(vocabulary), setup.wrap)
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
