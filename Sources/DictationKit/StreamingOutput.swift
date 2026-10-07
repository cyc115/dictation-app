import Foundation

/// "Type as you speak": types each finished utterance into the focused app while you're still
/// dictating, then whatever is left when you stop.
///
/// Typing waits while `canTypeNow()` is false (e.g. a held ⌘/⌥/⌃/⇧ hotkey would turn typed
/// letters into shortcuts or capitals); held-back text is typed as soon as it's safe.
final class StreamingOutput {
    private(set) var typed = ""
    private var pending = ""
    private let canTypeNow: () -> Bool
    private let type: (String) -> Void

    init(canTypeNow: @escaping () -> Bool, type: @escaping (String) -> Void) {
        self.canTypeNow = canTypeNow
        self.type = type
    }

    /// A finished utterance (with its leading separator) from the recognizer.
    func utteranceFinished(_ chunk: String) {
        pending += chunk
        flush()
    }

    /// Types held-back text if it's safe now.
    func flush() {
        guard !pending.isEmpty, canTypeNow() else { return }
        type(pending)
        typed += pending
        pending = ""
    }

    /// Dictation stopped (hotkey released): type everything the final transcript adds beyond
    /// what's already on screen.
    func finish(fullText: String) {
        if fullText.hasPrefix(typed) {
            pending = String(fullText.dropFirst(typed.count))
        }
        guard !pending.isEmpty else { return }
        type(pending)
        typed += pending
        pending = ""
    }
}
