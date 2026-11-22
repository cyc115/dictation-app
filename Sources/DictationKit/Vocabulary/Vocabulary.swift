import CryptoKit
import Foundation

/// A word the app keeps getting wrong, written the way you want it, and what the speech model
/// writes instead.
struct VocabularyEntry: Codable, Identifiable, Equatable {
    enum Source: String, Codable {
        /// Added by you (the Vocabulary page, the command line).
        case manual
        /// Learned from your corrections (phase 2).
        case learned
    }

    var id = UUID()
    /// How it's written: "GeForce Now".
    var term: String
    /// What the recognizer writes instead: ["G Four Snow", "g force now"].
    var heardAs: [String] = []
    var enabled = true
    var source: Source = .manual
    var added: Date
    /// Times a replacement fired.
    var uses = 0

    init(id: UUID = UUID(), term: String, heardAs: [String] = [], enabled: Bool = true, source: Source = .manual,
         added: Date, uses: Int = 0) {
        self.id = id
        self.term = term
        self.heardAs = heardAs
        self.enabled = enabled
        self.source = source
        self.added = added
        self.uses = uses
    }

    /// Only `term` is required, so a hand-edited vocabulary.json still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        term = try c.decode(String.self, forKey: .term)
        heardAs = try c.decodeIfPresent([String].self, forKey: .heardAs) ?? []
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        source = try c.decodeIfPresent(Source.self, forKey: .source) ?? .manual
        added = try c.decodeIfPresent(Date.self, forKey: .added) ?? Date()
        uses = try c.decodeIfPresent(Int.self, forKey: .uses) ?? 0
    }
}

/// The enabled vocabulary at one moment: what a dictation, a correction's suggestion or a tune runs
/// with. Made once per use (`VocabularyStore.vocabulary(enabled:)`), with its matchers built then,
/// so `apply` costs microseconds on the way to the paste.
struct Vocabulary {
    /// Terms told to polish at most.
    static let maxPromptTerms = 100
    /// Terms given to the on-device speech models at most (`SpeechContext`).
    static let maxSpeechWords = 50
    static let none = Vocabulary([])

    /// The enabled entries.
    let entries: [VocabularyEntry]
    /// Every term (first, at its entry's index) and variant, indexed for one pass over the text.
    private let patterns: [Pattern]
    private let index: PatternIndex
    private let hasVariants: Bool

    init(_ entries: [VocabularyEntry]) {
        self.entries = entries.compactMap { entry in
            var entry = entry
            entry.term = entry.term.trimmingCharacters(in: .whitespaces)  // a hand-edited "Claude " pastes no space
            return entry.enabled && !entry.term.isEmpty ? entry : nil
        }
        var patterns = self.entries.enumerated().map { Pattern($1.term, entry: $0, isTerm: true) }
        var seen = Set<String>()
        for (index, entry) in self.entries.enumerated() {
            for variant in entry.heardAs {
                let variant = variant.trimmingCharacters(in: .whitespaces)
                // The first entry with a variant keeps it.
                guard !variant.isEmpty, variant != entry.term, seen.insert(variant.lowercased()).inserted else { continue }
                patterns.append(Pattern(variant, entry: index, isTerm: false))
            }
        }
        self.patterns = patterns
        index = PatternIndex(patterns)
        hasVariants = patterns.count > self.entries.count
    }

    var isEmpty: Bool { entries.isEmpty }

    /// Most used first, then newest.
    private var ranked: [VocabularyEntry] {
        entries.sorted { $0.uses != $1.uses ? $0.uses > $1.uses : $0.added > $1.added }
    }

    // MARK: Replacement

    /// `text` with each variant replaced by its term, and how many times each entry's fired. Latin
    /// variants match case-insensitively at word boundaries (Chinese next to them is a boundary);
    /// variants with Chinese characters match literally. Longest variant first. A match is skipped
    /// where a term already stands: over it (variant "Claude" inside "Claude Code"), across part of
    /// it, or exactly on another entry's term. A shorter term inside the match doesn't count
    /// ("claude code" → "Claude Code" though "Claude" is a term). So a second run changes nothing
    /// more, short of contrived cases (a Chinese variant replaced right next to Latin letters).
    func apply(_ text: String) -> (text: String, uses: [UUID: Int]) {
        guard hasVariants, !text.isEmpty else { return (text, [:]) }
        let units = Array(text.utf16)
        let found = index.find(in: units, patterns)
        let stands = found.filter { patterns[$0.pattern].isTerm }
        // Longest first; equal lengths in the entries' order, then left to right.
        let candidates = found.filter { !patterns[$0.pattern].isTerm }.sorted {
            $0.length != $1.length ? $0.length > $1.length : $0.pattern != $1.pattern ? $0.pattern < $1.pattern : $0.location < $1.location
        }
        var covered = [Bool](repeating: false, count: units.count)
        var claimed: [Match] = []
        for match in candidates {
            guard !covered[match.range].contains(true) else { continue }
            let entry = patterns[match.pattern].entry
            let blocked = stands.contains { stand in
                guard stand.range.overlaps(match.range) else { return false }
                // A shorter term inside the match ("claude" in "claude code") doesn't stand in its way.
                if match.range.contains(stand.range.lowerBound), match.range.contains(stand.range.upperBound - 1), stand.range != match.range {
                    return false
                }
                // Its own term, cased differently ("Remarkable" for "reMarkable"): a fix, not a term standing.
                let caseFix = stand.pattern == entry && stand.range == match.range && !units[match.range].elementsEqual(patterns[entry].units)
                return !caseFix
            }
            guard !blocked else { continue }
            for i in match.range { covered[i] = true }
            claimed.append(match)
        }
        guard !claimed.isEmpty else { return (text, [:]) }
        var out: [UInt16] = []
        out.reserveCapacity(units.count + 16)
        var at = 0, uses: [UUID: Int] = [:]
        for match in claimed.sorted(by: { $0.location < $1.location }) {
            let entry = patterns[match.pattern].entry
            out.append(contentsOf: units[at..<match.location])
            out.append(contentsOf: patterns[entry].units)
            at = match.range.upperBound
            uses[entries[entry].id, default: 0] += 1
        }
        out.append(contentsOf: units[at...])
        return (String(decoding: out, as: UTF16.self), uses)
    }

    /// A term or variant found in the text, in UTF-16 units.
    private struct Match {
        let location: Int
        let length: Int
        let pattern: Int
        var range: Range<Int> { location..<(location + length) }
    }

    /// One term or variant, as `apply` matches it.
    private struct Pattern {
        let units: [UInt16]
        let lowered: [UInt16]
        /// Has Chinese characters: matched literally, no word boundaries.
        let literal: Bool
        /// Its first and last units are word characters (a boundary is checked only there).
        let wordStart: Bool
        let wordEnd: Bool
        let entry: Int
        let isTerm: Bool

        init(_ text: String, entry: Int, isTerm: Bool) {
            units = Array(text.utf16)
            lowered = units.map(Text.lower)
            literal = text.unicodeScalars.contains(where: Text.isChinese)
            wordStart = units.first.map(Text.isWord) ?? false
            wordEnd = units.last.map(Text.isWord) ?? false
            self.entry = entry
            self.isTerm = isTerm
        }

        /// A Latin pattern ending in a letter or digit can't end inside a word.
        func endsCleanly(in text: [UInt16], at end: Int) -> Bool {
            literal || !(wordEnd && end < text.count && Text.isWord(text[end]))
        }
    }

    /// The patterns in tries, so the text is read once and each spot costs only as many steps as
    /// the longest pattern it starts: Latin patterns (lowered) are walked only where a word starts,
    /// which is their start boundary; patterns with Chinese (exactly as written), and the few that
    /// start with punctuation, from every unit that starts one.
    private struct PatternIndex {
        private var words = Trie(), anywhere = Trie(), literal = Trie()

        init(_ patterns: [Pattern]) {
            for (n, p) in patterns.enumerated() where !p.units.isEmpty {
                if p.literal { literal.insert(p.units, n) } else if p.wordStart { words.insert(p.lowered, n) } else { anywhere.insert(p.lowered, n) }
            }
        }

        func find(in text: [UInt16], _ patterns: [Pattern]) -> [Match] {
            var found: [Match] = []
            var i = 0
            let add = { (n: Int, end: Int) in
                if patterns[n].endsCleanly(in: text, at: end) { found.append(Match(location: i, length: end - i, pattern: n)) }
            }
            var wordEnd = 0  // where the word the scan is in ends
            while i < text.count {
                let unit = text[i], lowered = Text.lower(unit)
                if literal.starts(with: unit) { literal.walk(text, from: i, lowered: false, add) }
                if anywhere.starts(with: lowered) { anywhere.walk(text, from: i, lowered: true, add) }
                if i >= wordEnd, Text.isWord(lowered) {
                    var j = i + 1
                    while j < text.count, Text.isWord(text[j]) { j += 1 }
                    wordEnd = j
                    if words.starts(with: lowered) { words.walk(text, from: i, lowered: true, add) }
                }
                i += 1
            }
            return found
        }
    }

    /// Patterns by their units, one node per prefix.
    private struct Trie {
        private var children: [[UInt16: Int]] = [[:]]
        /// The patterns that end at each node.
        private var ends: [[Int]] = [[]]
        /// Units some pattern starts with: most spots in the text skip the walk.
        private var starts = [Bool](repeating: false, count: 0x10000)

        mutating func insert(_ units: [UInt16], _ pattern: Int) {
            starts[Int(units[0])] = true
            var node = 0
            for unit in units {
                if let next = children[node][unit] { node = next; continue }
                children.append([:]); ends.append([])
                children[node][unit] = children.count - 1
                node = children.count - 1
            }
            ends[node].append(pattern)
        }

        func starts(with unit: UInt16) -> Bool { starts[Int(unit)] }

        /// Calls `found(pattern, end)` for every pattern that starts at `i`.
        func walk(_ text: [UInt16], from i: Int, lowered: Bool, _ found: (Int, Int) -> Void) {
            var node = 0, j = i
            while j < text.count, let next = children[node][lowered ? Text.lower(text[j]) : text[j]] {
                node = next
                j += 1
                for pattern in ends[node] { found(pattern, j) }
            }
        }
    }

    /// What a word is made of, unit by unit.
    private enum Text {
        static func lower(_ unit: UInt16) -> UInt16 {
            if unit < 0x80 { return (0x41...0x5A).contains(unit) ? unit + 0x20 : unit }
            guard let scalar = Unicode.Scalar(unit), !isChinese(scalar) else { return unit }
            let lowered = scalar.properties.lowercaseMapping.utf16
            return lowered.count == 1 ? lowered.first! : unit
        }

        /// A letter or digit that isn't Chinese: what a Latin word is made of.
        static func isWord(_ unit: UInt16) -> Bool {
            if unit < 0x80 { return (0x30...0x39).contains(unit) || (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit) }
            guard let scalar = Unicode.Scalar(unit), !isChinese(scalar) else { return false }  // or half of a surrogate pair
            return CharacterSet.alphanumerics.contains(scalar)
        }

        static func isChinese(_ scalar: Unicode.Scalar) -> Bool { PolishScore.isCJK(scalar) || scalar.properties.isIdeographic }
    }

    // MARK: Polish and speech

    /// The terms for polish, appended to its instructions; "" with none, so nothing changes.
    var promptBlock: String {
        guard !entries.isEmpty else { return "" }
        let lines = ranked.prefix(Self.maxPromptTerms).map { entry in
            let heard = entry.heardAs.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return entry.term + (heard.isEmpty ? "" : " (heard as: \(heard.joined(separator: ", ")))")
        }
        return (["Vocabulary (write these exactly; the recognizer may mishear them):"] + lines).joined(separator: "\n")
    }

    /// A polish prompt with the terms block after it: what every backend built from a setup is told
    /// (main, backup, on-device, Corrections' suggestion, Learn's student). With no terms, `prompt` itself.
    func instructions(_ prompt: String) -> String {
        let block = promptBlock
        return block.isEmpty ? prompt : prompt + "\n\n" + block
    }

    /// Terms for the on-device speech models (`SpeechContext`), most used first.
    var speechWords: [String] { ranked.prefix(Self.maxSpeechWords).map(\.term) }

    /// Identifies the enabled terms and variants (not their uses), so a measurement made with other
    /// ones is known to be stale; nil with none.
    var fingerprint: String? { Self.fingerprint(of: entries) }

    /// The enabled ones of `entries`, fingerprinted.
    static func fingerprint(of entries: [VocabularyEntry]) -> String? {
        // Trimmed as `init` trims, so the store's fingerprint and a snapshot's always agree.
        let enabled = entries.filter(\.enabled).map { ($0.term.trimmingCharacters(in: .whitespaces), $0.heardAs) }.filter { !$0.0.isEmpty }
        guard !enabled.isEmpty else { return nil }
        let lines = enabled.map { ([$0.0] + $0.1.sorted()).joined(separator: "\t") }.sorted()
        let digest = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

extension DictationSetup {
    /// This setup's prompt with the vocabulary's terms block.
    func instructions(_ vocabulary: Vocabulary) -> String { vocabulary.instructions(promptText) }
}
