import Foundation

/// Readback mode: the text box's value as last read, and where the pasted text (the span) is in
/// it, in UTF-16 offsets (as Accessibility gives them). Each read is compared with the last: a
/// change before the span moves it, one inside it is the edit, one after it (or text typed at its
/// end that starts with a space) isn't part of it. Held in memory only.
struct SpanTracker {
    private(set) var value: [UInt16]
    private(set) var range: Range<Int>

    /// The box right after the paste: the pasted text must end where the cursor is (`cursor`: the
    /// insertion point; nil, or a selection, and the probe fails).
    init?(value: String, cursor: Int?, pasted: String) {
        let units = Array(value.utf16), pasted = Array(pasted.utf16)
        guard let cursor, !pasted.isEmpty, cursor >= pasted.count, cursor <= units.count,
              Array(units[(cursor - pasted.count)..<cursor]) == pasted else { return nil }
        self.value = units
        range = (cursor - pasted.count)..<cursor
    }

    /// The pasted text as you've left it.
    var span: String { String(decoding: value[range], as: UTF16.self) }

    /// Takes in a new read; false when the change crosses the span's edge (say, the box was cleared
    /// or a selection reached past the span), so it can't be told what's the span's any more: the
    /// last state stands.
    mutating func update(_ newValue: String) -> Bool {
        let new = Array(newValue.utf16), old = value
        guard new != old else { return true }
        var p = 0
        while p < old.count, p < new.count, old[p] == new[p] { p += 1 }
        var q = 0
        while q < old.count - p, q < new.count - p, old[old.count - 1 - q] == new[new.count - 1 - q] { q += 1 }
        let oldEnd = old.count - q, delta = new.count - old.count
        let s = range.lowerBound, e = range.upperBound
        if oldEnd <= s {
            range = (s + delta)..<(e + delta)  // before the span (text typed right at its start included)
        } else if p > e || (p == e && oldEnd > e) {
            // after it
        } else if p == e {
            // Typed at its end: a space starts text of its own, anything else carries on its last word.
            let first = Unicode.Scalar(new[p]).map(Character.init)
            if first.map({ !$0.isWhitespace }) ?? true { range = s..<(e + delta) }
        } else if p >= s, oldEnd <= e {
            range = s..<(e + delta)
        } else {
            return false
        }
        value = new
        return true
    }
}
