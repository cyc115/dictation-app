import Foundation

/// Which words of a dictation a correction changed: Corrections' highlight, and the word changes
/// vocabulary learns from (`FixIntake`).
enum WordDiff {
    /// One place the texts differ, between two words they share: the words `old` drops there and the
    /// words `new` has instead (either can be empty).
    struct Hunk: Equatable {
        var removed: [Range<String.Index>] = []
        var inserted: [Range<String.Index>] = []
    }

    /// Words: a Chinese character each, else a run of non-space characters.
    static func words(_ text: String) -> [Range<String.Index>] {
        text.ranges(of: #/\p{Han}|[^\s\p{Han}]+/#)
    }

    /// Where `new` differs from `old`, in order. The words neither removes nor inserts are the ones
    /// they share, in the same order in both, so walking both texts pairs each removed run with what
    /// was inserted in its place.
    static func hunks(from old: String, to new: String) -> [Hunk] {
        let before = words(old), after = words(new)
        let difference = after.map { new[$0] }.difference(from: before.map { old[$0] })
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }
        var hunks: [Hunk] = []
        var i = 0, j = 0
        while i < before.count || j < after.count {
            var hunk = Hunk()
            while i < before.count, removed.contains(i) { hunk.removed.append(before[i]); i += 1 }
            while j < after.count, inserted.contains(j) { hunk.inserted.append(after[j]); j += 1 }
            if hunk == Hunk() { i += 1; j += 1 } else { hunks.append(hunk) }  // a shared word
        }
        return hunks
    }

    /// Ranges in `old` of the words `new` drops or replaces.
    static func changed(from old: String, to new: String) -> [Range<String.Index>] {
        hunks(from: old, to: new).flatMap(\.removed)
    }
}
