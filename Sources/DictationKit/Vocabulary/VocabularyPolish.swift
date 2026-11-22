import Foundation

/// A polish backend that replaces your terms in what it's given and in what it answers, as a
/// dictation does around its polish. For the polish runs with no `DictationController.deliver`
/// around them: Learn's student (so a tune measures what you'd get) and Corrections' suggestion.
/// Forwards `prepare()` and `name`: the protocol's defaults would lose the prewarm and rename the
/// model in History.
struct VocabularyPolish: PolishBackend {
    let backend: PolishBackend
    let vocabulary: Vocabulary

    /// `backend` wrapped; itself when there are no terms, so nothing changes.
    static func wrap(_ backend: PolishBackend, _ vocabulary: Vocabulary) -> PolishBackend {
        vocabulary.isEmpty ? backend : VocabularyPolish(backend: backend, vocabulary: vocabulary)
    }

    func prepare() { backend.prepare() }
    var name: String { backend.name }

    func polish(_ text: String) async throws -> String {
        let answer = try await backend.polish(vocabulary.apply(text).text)
        return vocabulary.apply(answer).text
    }
}
