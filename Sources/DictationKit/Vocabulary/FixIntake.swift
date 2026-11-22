import Foundation

/// One word change in a fix: words the app wrote (`old`) replaced by what you wanted (`new`).
struct WordChange: Codable, Equatable {
    /// What a model made of the change (phase 4). Nothing sets it yet.
    enum Verdict: String, Codable {
        /// The speech model got a word wrong: counts toward vocabulary.
        case misheard
        /// Wording or formatting: trains polish (Learn), not vocabulary.
        case style
        /// You changed what you meant to say: dropped.
        case changedMind
        case unclear
    }

    var old: String
    var new: String
    var verdict: Verdict?

    init(old: String, new: String, verdict: Verdict? = nil) {
        self.old = old
        self.new = new
        self.verdict = verdict
    }

    /// A verdict this build doesn't know (written by a newer one) reads as none, so history.json
    /// still loads after going back to an older build.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        old = try c.decode(String.self, forKey: .old)
        new = try c.decode(String.self, forKey: .new)
        verdict = (try? c.decodeIfPresent(Verdict.self, forKey: .verdict)) ?? nil
    }
}

/// A dictation's fix as word changes, saved on its History entry. `of` is the target it was worked
/// out from (`HistoryEntry.fixTarget`: the correction, else a captured edit you haven't dismissed),
/// so it's worked out again only once that changes, at idle.
struct Intake: Codable, Equatable {
    var of: String
    var changes: [WordChange]
}

/// Turns a fix into word changes, locally: `WordDiff`'s words, diffed; each run of words replaced by
/// other words is a change. Words only added or only removed are not: they say nothing about what
/// the app mishears.
enum FixIntake {
    /// Punctuation around a change isn't part of it ("cloud." → "Claude." is cloud → Claude). Only
    /// sentence punctuation, quotes and brackets: "C++" and "C#" keep their symbols.
    private static let edges = CharacterSet(charactersIn: ".,;:!?…。，、；：！？\"'“”‘’()[]{}（）「」《》—–").union(.whitespaces)

    static func intake(of text: String, target: String) -> Intake {
        Intake(of: target, changes: changes(from: text, to: target))
    }

    static func changes(from text: String, to target: String) -> [WordChange] {
        WordDiff.hunks(from: text, to: target).compactMap { hunk in
            guard let removed = span(hunk.removed, in: text), let inserted = span(hunk.inserted, in: target) else { return nil }
            let old = removed.trimmingCharacters(in: edges), new = inserted.trimmingCharacters(in: edges)
            guard !old.isEmpty, !new.isEmpty, old != new else { return nil }
            return WordChange(old: old, new: new)
        }
    }

    /// Sentence punctuation or a line break inside a side ("file. Two", "mode, for example"): the fix
    /// is formatting or rewording, not a term. An ASCII mark counts only before a space, so
    /// "Node.js", "C++" and "3:30" have none. In a copy of real History, 34 of 72 changes were these.
    static func hasPunctuationInside(_ text: String) -> Bool {
        text.contains(#/[.,;:!?…"”’)\]]\s|\s["“‘(\[]|[\n—–。，、；：！？（）「」《》]/#)
    }

    /// Words in a change ("GeForce Now": 2, "克劳德": 3), as `WordDiff` counts them.
    static func wordCount(_ text: String) -> Int { WordDiff.words(text).count }

    /// The text from the first word to the last, as written (Chinese gets no spaces added).
    private static func span(_ words: [Range<String.Index>], in text: String) -> String? {
        guard let first = words.first, let last = words.last else { return nil }
        return String(text[first.lowerBound..<last.upperBound])
    }
}
