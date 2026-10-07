import Foundation

/// Builds the full transcript from recognizer results.
///
/// The on-device recognizer restarts its transcript after every pause: the last result of an
/// utterance carries metadata (or isFinal), and the following results hold only the new words.
/// Keeping just the latest result therefore drops everything said before the last pause.
struct TranscriptAccumulator {
    /// Finished utterances, already joined with separators. Only ever appended to.
    private(set) var committed = ""
    /// The utterance in progress (revised freely until it ends).
    private(set) var current = ""
    private var lastUtterance = ""

    /// Feeds one recognizer result. Returns the text newly committed by it (with its leading
    /// separator), for callers that output each finished utterance as it happens.
    @discardableResult
    mutating func update(_ text: String, utteranceEnded: Bool) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard utteranceEnded else {
            current = text
            return nil
        }
        current = ""
        guard !text.isEmpty, !(text == lastUtterance && committed.hasSuffix(text)) else { return nil }
        let chunk = Self.separator(after: committed, before: text) + text
        committed += chunk
        lastUtterance = text
        return chunk
    }

    /// Everything heard so far, including the utterance still in progress.
    var text: String {
        current.isEmpty ? committed : committed + Self.separator(after: committed, before: current) + current
    }

    /// How to join two utterances: a pause usually ends a sentence, so add a period when the
    /// next one starts a new sentence (capitalized) and the previous one has no punctuation.
    static func separator(after previous: String, before next: String) -> String {
        guard let p = previous.last, let n = next.first else { return "" }
        if isCJK(p) {
            return "，。？！；：、".contains(p) ? "" : "。"
        }
        if ".?!…".contains(p) || ",;:".contains(p) { return isCJK(n) ? "" : " " }
        return n.isUppercase ? ". " : " "
    }

    private static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.contains { (0x3000...0x303F).contains($0.value) || (0x3400...0x9FFF).contains($0.value)
            || (0xF900...0xFAFF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) }
    }
}
