import Foundation

/// What changed between two prompts, line by line, as hunks: the changed lines with one line of
/// unchanged context on each side. What the Learn tile shows instead of the whole prompt.
enum PromptDiff {
    enum Kind: Equatable { case context, removed, added }

    struct Line: Equatable, Identifiable {
        var kind: Kind
        var text: String
        var id: String { "\(kind)\(text)" }
    }

    struct Hunk: Equatable, Identifiable {
        var lines: [Line]
        var id: String { lines.map(\.id).joined(separator: "\n") }
    }

    static func lines(_ prompt: String) -> [String] {
        prompt.split(separator: "\n", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Empty when nothing changed.
    static func hunks(old: String, new: String) -> [Hunk] {
        let before = lines(old), after = lines(new)
        let diff = after.difference(from: before).inferringMoves()
        var removed = Set<Int>(), added = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): added.insert(offset)
            }
        }
        // Walk both sides, emitting removed, added and shared lines in order.
        var out: [(Line, changed: Bool)] = []
        var i = 0, j = 0
        while i < before.count || j < after.count {
            if i < before.count, removed.contains(i) { out.append((Line(kind: .removed, text: before[i]), true)); i += 1; continue }
            if j < after.count, added.contains(j) { out.append((Line(kind: .added, text: after[j]), true)); j += 1; continue }
            out.append((Line(kind: .context, text: after[min(j, after.count - 1)]), false)); i += 1; j += 1
        }
        // Keep changed lines and one context line on each side; split where the gap is wider.
        var keep = [Bool](repeating: false, count: out.count)
        for (k, line) in out.enumerated() where line.changed {
            for n in max(0, k - 1)...min(out.count - 1, k + 1) { keep[n] = true }
        }
        var hunks: [Hunk] = [], current: [Line] = []
        for (k, line) in out.enumerated() {
            if keep[k] { current.append(line.0) } else if !current.isEmpty { hunks.append(Hunk(lines: current)); current = [] }
        }
        if !current.isEmpty { hunks.append(Hunk(lines: current)) }
        return hunks
    }
}
