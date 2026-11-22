import Foundation

/// Readback mode: the text box's value as last read, and where the pasted text (the span) is in
/// it, in UTF-16 offsets (as Accessibility gives them). Each read is compared with the last: a
/// change before the span moves it, one inside it is the edit, one after it isn't part of it. Text
/// typed right at its end carries on its last word up to the first space or sentence mark; what
/// follows is text of its own. Held in memory only.
struct SpanTracker {
    private(set) var value: [UInt16]
    private(set) var range: Range<Int>
    /// The paste went in with nothing put in front (an empty box, or after a space or line break), so
    /// text typed right at its start is the dictation's first word, not the text before it.
    private let gluedStart: Bool
    /// The pasted text's words (any case, no edge punctuation).
    private let pastedWords: Set<String>

    /// The box right after the paste: the pasted text must end where the cursor is (`cursor`: the
    /// insertion point; nil, or a selection, and the probe fails).
    init?(value: String, cursor: Int?, pasted: String) {
        let units = Array(value.utf16), pasted = Array(pasted.utf16)
        guard let cursor, !pasted.isEmpty, cursor >= pasted.count, cursor <= units.count,
              Array(units[(cursor - pasted.count)..<cursor]) == pasted else { return nil }
        self.value = units
        range = (cursor - pasted.count)..<cursor
        gluedStart = Unicode.Scalar(pasted[0]).map { !$0.properties.isWhitespace } ?? false
        pastedWords = Self.words(String(decoding: pasted, as: UTF16.self))
    }

    private static func words(_ text: String) -> Set<String> {
        Set(WordDiff.words(text).map { text[$0].lowercased().trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty })
    }

    /// Still an edit of the paste: at least half its words are in the span, and at most one more new
    /// word came in than went out ("cloud" → "Claude Code"). When not ("I use cloud for the project"
    /// became "I think the plan is fine", "Sounds good" became "Sounds great, see you at 5": sent, and a
    /// new message typed), only your keys can say it's an edit of it.
    var keepsThePaste: Bool {
        let now = Self.words(span)
        let kept = pastedWords.intersection(now).count
        let removed = pastedWords.count - kept, added = now.count - kept
        return !pastedWords.isEmpty && kept * 2 >= pastedWords.count && added <= removed + 1
    }

    /// Text typed onto the span's last word belongs to it up to a space or line break, or up to and
    /// including a Chinese sentence mark (Chinese has no spaces): "cloud" → "Claude." keeps its period,
    /// "克劳的" → "克劳德。明天见" stops after the "。". Once the span ends in such a mark, text typed
    /// right after it is text of its own.
    static func run(of text: some Collection<Character>, after last: Character?) -> Int {
        if let last, isChineseMark(last) { return 0 }
        var n = 0
        for c in text {
            if c.isWhitespace { break }
            n += 1
            if isChineseMark(c) { break }
        }
        return n
    }

    static func isChineseMark(_ c: Character) -> Bool { "。，、；：！？…".contains(c) }

    private static func character(_ unit: UInt16) -> Character { Unicode.Scalar(unit).map(Character.init) ?? " " }

    /// The pasted text as you've left it.
    var span: String { String(decoding: value[range], as: UTF16.self) }

    /// Takes in a new read; false when the change crosses the span's edge or takes all of it (say,
    /// the box was cleared, or sent and a new message typed), so it can't be told what's the span's
    /// any more: the last state stands.
    mutating func update(_ newValue: String) -> Bool {
        let new = Array(newValue.utf16), old = value
        guard new != old else { return true }
        var p = 0
        while p < old.count, p < new.count, old[p] == new[p] { p += 1 }
        var q = 0
        while q < old.count - p, q < new.count - p, old[old.count - 1 - q] == new[new.count - 1 - q] { q += 1 }
        let delta = new.count - old.count
        if old.count - q == p {
            // Text only inserted: where it went can be ambiguous ("there " after "Hi " is " there" after
            // "Hi"). Take the leftmost without crossing an edge of the span, so text typed at its start
            // counts as before it, and text typed after it never slides into it.
            let floor = p >= range.upperBound ? range.upperBound : p > range.lowerBound ? range.lowerBound : 0
            while p > floor, old[p - 1] == new[p - 1 + delta] { p -= 1; q += 1 }
        }
        let oldEnd = old.count - q
        let s = range.lowerBound, e = range.upperBound
        let newEnd = new.count - q
        if !range.isEmpty, p <= s, oldEnd >= e {
            return false  // all of it replaced: nothing left to say which text is the paste's
        } else if oldEnd == s, p == s, gluedStart, !range.isEmpty, newEnd > p, !Self.character(new[newEnd - 1]).isWhitespace,
                  !Self.isChineseMark(Self.character(new[newEnd - 1])) {
            // Typed onto the first word: only the run touching it (back to a space) is the span's.
            var run = 0
            while newEnd - run > p, !Self.character(new[newEnd - run - 1]).isWhitespace { run += 1 }
            range = (s + delta - run)..<(e + delta)
        } else if oldEnd <= s {
            range = (s + delta)..<(e + delta)  // before the span
        } else if p > e || (p == e && oldEnd > e) {
            // after it
        } else if p == e {
            // Typed at its end: it carries on the last word up to a space (`run`).
            let typed = String(decoding: new[p..<newEnd], as: UTF16.self)
            let last = e > s ? Self.character(old[e - 1]) : nil
            let run = String(typed.prefix(Self.run(of: typed, after: last))).utf16.count
            range = s..<(e + run)
        } else if p >= s, oldEnd <= e {
            range = s..<(e + delta)
        } else {
            return false
        }
        value = new
        return true
    }
}
