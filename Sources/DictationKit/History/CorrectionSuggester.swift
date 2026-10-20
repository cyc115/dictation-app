import AppKit
import Combine
import SwiftUI

/// Which words of a dictation a correction changed, for highlighting.
enum WordDiff {
    /// Words: a Chinese character each, else a run of non-space characters.
    static func words(_ text: String) -> [Range<String.Index>] {
        text.ranges(of: #/\p{Han}|[^\s\p{Han}]+/#)
    }

    /// Ranges in `old` of the words `new` drops or replaces.
    static func changed(from old: String, to new: String) -> [Range<String.Index>] {
        let before = words(old)
        let after = words(new).map { new[$0] }
        return after.difference(from: before.map { old[$0] }).removals.map {
            guard case let .remove(offset, _, _) = $0 else { fatalError("removals only") }
            return before[offset]
        }
    }
}

/// Starts a new correction from GPT-6.1 Sol Pro's polish of what you said (with your setup's prompt), so you fix less by hand.
/// The most accurate polish model benchmarked (100% on bench/suite.py polish, both test sets), but ~3 s
/// and ~$5 per 1,000: too slow and costly while dictating, fine for an occasional correction. Asks
/// once, when the pencil makes the correction; the answer replaces the app's text only if you haven't
/// typed yet. Without a cloud API key the correction stays as the app wrote it.
final class CorrectionSuggester: ObservableObject {
    static let model = "openrouter:openai/gpt-6.1-sol-pro"
    static let modelName = "GPT-6.1 Sol Pro"
    /// Suggests nothing (no model): the default where no suggester is handed in.
    static var off: CorrectionSuggester { CorrectionSuggester { nil } }

    /// The model with the AI polish prompt of the setup chosen in Settings, so it polishes the way the app does.
    static func backend(apiKey: String, setup: DictationSetup) -> PolishBackend? {
        apiKey.isEmpty ? nil : DictationSetup.polishBackend(spec: model, apiKey: apiKey, instructions: setup.promptText, wrap: setup.wrap)
    }

    /// Corrections waiting for the model.
    @Published private(set) var pending: Set<UUID> = []
    /// Why the last suggestion failed, by correction.
    @Published private(set) var failed: [UUID: String] = [:]
    private let backend: () -> PolishBackend?

    init(backend: @escaping () -> PolishBackend?) { self.backend = backend }

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
