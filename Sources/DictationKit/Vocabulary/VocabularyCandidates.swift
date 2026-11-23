import Foundation

/// A term you fixed in your corrections, on its way to the vocabulary: one per term (the new side,
/// any case), with each way it was misheard and the dictations it was seen in. Kept in
/// vocabulary.json. Learned (`VocabularyStore.updateCandidates`) once seen in `vocabularyLearnAfter`
/// dictations, or at once with Add now; dismissed, never again.
struct VocabularyCandidate: Codable, Equatable, Identifiable {
    /// One way the term was misheard: what the app wrote instead.
    struct Heard: Codable, Equatable {
        var text: String
        /// The dictations it was seen in, newest first.
        var dictations: [UUID] = []
        /// Also stands in 3 or more dictations you didn't correct: never a variant (it would be
        /// replaced where you meant it).
        var ordinary = false
        /// Judged misheard (`FixJudge`) at least once.
        var misheard = false

        init(text: String, dictations: [UUID] = [], ordinary: Bool = false, misheard: Bool = false) {
            self.text = text
            self.dictations = dictations
            self.ordinary = ordinary
            self.misheard = misheard
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = try c.decode(String.self, forKey: .text)
            dictations = try c.decodeIfPresent([UUID].self, forKey: .dictations) ?? []
            ordinary = try c.decodeIfPresent(Bool.self, forKey: .ordinary) ?? false
            misheard = try c.decodeIfPresent(Bool.self, forKey: .misheard) ?? false
        }
    }

    /// As you last wrote it.
    var term: String
    var heard: [Heard] = []
    /// You dismissed it: never learned, never shown again.
    var dismissed = false
    /// It became an entry, or its variants went into yours. A learned entry you delete isn't made again.
    var added = false
    /// Variants (lowercased) already handed to the vocabulary, so one you take off isn't put back.
    var addedHeard: [String] = []

    var id: String { term.lowercased() }
    /// Different dictations it was seen in.
    var seen: Int { Set(heard.flatMap(\.dictations)).count }
    var misheard: Bool { heard.contains(where: \.misheard) }

    init(term: String, heard: [Heard] = [], dismissed: Bool = false, added: Bool = false, addedHeard: [String] = []) {
        self.term = term
        self.heard = heard
        self.dismissed = dismissed
        self.added = added
        self.addedHeard = addedHeard
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        term = try c.decode(String.self, forKey: .term)
        heard = try c.decodeIfPresent([Heard].self, forKey: .heard) ?? []
        dismissed = try c.decodeIfPresent(Bool.self, forKey: .dismissed) ?? false
        added = try c.decodeIfPresent(Bool.self, forKey: .added) ?? false
        addedHeard = try c.decodeIfPresent([String].self, forKey: .addedHeard) ?? []
    }
}

/// Counts candidates from History, from scratch each time (so a deleted or edited correction no
/// longer counts): pure, so the idle pass runs it off the main thread.
enum CandidateTally {
    /// A change counts only if both sides are at most this many words (with a verdict or without).
    static let maxWords = 4
    /// A heard standing in this many dictations you didn't correct is an ordinary word.
    static let ordinaryAfter = 3

    /// Candidates from History's current intake, newest first (`entries` is History, newest first).
    /// A change counts only when both sides are at most 4 words with no sentence punctuation inside
    /// (English or Chinese), and then when judged *misheard*, or, not judged, when its heard isn't an
    /// ordinary word. The verdict stands in for "is this a mishearing", not for the shape: a long hunk
    /// across a sentence break could never match again as a variant. `judging` (the judge is on and
    /// can run): a change not yet judged waits instead, unless the judge gave up on its fix
    /// (`FixJudge.maxTries`). Only the flags it counts are set: `dismissed`, `added`
    /// and `addedHeard` are the store's (`VocabularyStore.updateCandidates`).
    static func support(in entries: [HistoryEntry], judging: Bool = false) -> [VocabularyCandidate] {
        var fixes: [(id: UUID, change: WordChange, rules: Bool)] = []
        for entry in entries {
            guard let intake = entry.currentIntake else { continue }
            let rules = !judging || (intake.tries ?? 0) >= FixJudge.maxTries
            for change in intake.changes where counts(change, ordinary: false, rules: rules) { fixes.append((entry.id, change, rules)) }
        }
        guard !fixes.isEmpty else { return [] }
        let ordinary = OrdinaryWords(heard: fixes.map(\.change.old), in: entries)

        var candidates: [VocabularyCandidate] = []
        var at: [String: Int] = [:]
        for (id, change, rules) in fixes {
            let isOrdinary = ordinary.isOrdinary(change.old, term: change.new)
            guard counts(change, ordinary: isOrdinary, rules: rules) else { continue }
            let key = change.new.lowercased()
            let c: Int
            if let i = at[key] { c = i } else {
                c = candidates.count
                at[key] = c
                candidates.append(VocabularyCandidate(term: change.new))
            }
            let heardKey = change.old.lowercased()
            var heard = candidates[c].heard
            let h: Int
            if let i = heard.firstIndex(where: { $0.text.lowercased() == heardKey }) { h = i } else {
                h = heard.count
                heard.append(.init(text: change.old, ordinary: isOrdinary))
            }
            if !heard[h].dictations.contains(id) { heard[h].dictations.append(id) }
            if change.verdict == .misheard { heard[h].misheard = true }
            candidates[c].heard = heard
        }
        return candidates
    }

    /// For each (heard, term), whether it's an ordinary word in History: the guard `support` applies
    /// before a heard can become a variant. The history bench flags vocabulary variants with it.
    static func ordinary(_ pairs: [(heard: String, term: String)], in entries: [HistoryEntry]) -> [Bool] {
        let words = OrdinaryWords(heard: pairs.map(\.heard), in: entries)
        return pairs.map { words.isOrdinary($0.heard, term: $0.term) }
    }

    /// The whole rule: the shape first (at most `maxWords` words a side, no sentence punctuation
    /// inside), whatever the verdict; then a verdict decides (misheard counts, even an ordinary heard,
    /// which is flagged and never added as a variant); without one, the rules do (`rules`), or it
    /// waits for one.
    private static func counts(_ change: WordChange, ordinary: Bool, rules: Bool) -> Bool {
        guard FixIntake.wordCount(change.old) <= maxWords, FixIntake.wordCount(change.new) <= maxWords,
              !FixIntake.hasPunctuationInside(change.old), !FixIntake.hasPunctuationInside(change.new) else { return false }
        switch change.verdict {
        case .misheard: return true
        case nil: return rules && !ordinary
        default: return false
        }
    }


    /// Where each heard stands in the dictations you didn't fix (no correction, no capture you kept), matched as replacement would
    /// match it. One read of each dictation.
    private struct OrdinaryWords {
        private var index: [String: Int] = [:]
        /// By heard: for each dictation it stands in, the text as written there.
        private var found: [[Set<String>]]

        init(heard: [String], in entries: [HistoryEntry]) {
            var phrases: [String] = []
            for text in heard where index[text.lowercased()] == nil {
                index[text.lowercased()] = phrases.count
                phrases.append(text)
            }
            found = Array(repeating: [], count: phrases.count)
            let finder = Vocabulary.Finder(phrases)
            for entry in entries where entry.fixTarget == nil {
                var here: [Int: Set<String>] = [:]
                for match in finder.find(in: entry.text) { here[match.phrase, default: []].insert(match.text) }
                for (phrase, texts) in here { found[phrase].append(texts) }
            }
        }

        /// It stands in 3 or more of them other than as the term itself ("remarkable" where
        /// "reMarkable" is written isn't the ordinary word).
        func isOrdinary(_ heard: String, term: String) -> Bool {
            guard let i = index[heard.lowercased()] else { return false }
            var n = 0
            for texts in found[i] where texts.contains(where: { $0 != term }) {
                n += 1
                if n >= CandidateTally.ordinaryAfter { return true }
            }
            return false
        }
    }
}
