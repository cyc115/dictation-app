import Foundation

/// Scores a polish against what was wanted, exactly as the bench does (`bench/harness.py` tokens
/// and error_rate, `bench/suites/polish.py` check); `bench/score_fixture.json` is asserted by both.
enum PolishScore {
    /// A pass needs the words within this share of the wanted text's (bench MAX_ERROR).
    static let maxError = 0.25

    static func isCJK(_ u: Unicode.Scalar) -> Bool {
        (0x3400...0x9fff).contains(u.value) || (0xf900...0xfaff).contains(u.value)
    }
    private static func isWord(_ u: Unicode.Scalar) -> Bool { ("a"..."z").contains(u) || ("0"..."9").contains(u) }
    private static func isLetter(_ u: Unicode.Scalar) -> Bool { ("a"..."z").contains(u) }

    /// Each CJK character is a token; each run of latin letters/digits is a token, with one
    /// apostrophe and letters after it ("let's"). NFKC, lowercased. Same as bench/harness.py's
    /// `[\u3400-\u9fff\uf900-\ufaff]|[a-z0-9]+(?:'[a-z]+)?`.
    static func tokens(_ text: String) -> [String] {
        let scalars = Array(text.precomposedStringWithCompatibilityMapping.lowercased().unicodeScalars)
        var tokens: [String] = [], i = 0
        while i < scalars.count {
            let u = scalars[i]
            if isCJK(u) { tokens.append(String(u)); i += 1; continue }
            guard isWord(u) else { i += 1; continue }
            var j = i
            while j < scalars.count, isWord(scalars[j]) { j += 1 }
            if j + 1 < scalars.count, scalars[j] == "'", isLetter(scalars[j + 1]) {
                j += 1
                while j < scalars.count, isLetter(scalars[j]) { j += 1 }
            }
            tokens.append(String(String.UnicodeScalarView(scalars[i..<j])))
            i = j
        }
        return tokens
    }

    static func editDistance(_ a: [String], _ b: [String]) -> Int {
        // Tokens as ints first: comparing strings in the O(n·m) loop was 100× slower.
        var ids: [String: Int32] = [:]
        func id(_ t: String) -> Int32 { if let i = ids[t] { return i }; ids[t] = Int32(ids.count); return Int32(ids.count - 1) }
        let x = a.map(id), y = b.map(id)
        var prev = [Int32](0...Int32(y.count)), cur = [Int32](repeating: 0, count: y.count + 1)
        for i in x.indices {
            cur[0] = Int32(i + 1)
            for j in y.indices {
                cur[j + 1] = min(prev[j + 1] + 1, cur[j] + 1, prev[j] + (x[i] == y[j] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return Int(prev[y.count])
    }

    /// Token edit distance over the reference's length (1 for anything heard against an empty one).
    static func errorRate(reference: String, hypothesis: String) -> Double {
        let ref = tokens(reference)
        if ref.isEmpty { return tokens(hypothesis).isEmpty ? 0 : 1 }
        return Double(editDistance(ref, tokens(hypothesis))) / Double(ref.count)
    }

    /// Chinese: substring. Latin: whole words, case-insensitive (so "um" doesn't match "umbrella");
    /// a Chinese character next to it is a boundary ("的latency哪个" has "latency").
    static func contains(_ text: String, phrase: String) -> Bool {
        if phrase.unicodeScalars.contains(where: isCJK) || phrase.range(of: #"\w"#, options: .regularExpression) == nil {
            return text.contains(phrase)
        }
        let pattern = "(?<![A-Za-z0-9_'])" + NSRegularExpression.escapedPattern(for: phrase) + "(?![A-Za-z0-9_'])"
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    struct Check: Equatable {
        /// `must` phrases that aren't there (each as written, alternatives joined by "|").
        var missing: [String]
        /// `must_not` phrases that are.
        var kept: [String]
        var error: Double
        var passed: Bool
    }

    /// The bench pass rule: every must present, every must-not absent, words within `maxError`.
    static func check(_ c: GeneralCase, output: String) -> Check {
        let out = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let missing = c.must.filter { m in !m.split(separator: "|").contains { contains(out, phrase: String($0)) } }
        let kept = c.mustNot.filter { m in m.split(separator: "|").contains { contains(out, phrase: String($0)) } }
        let error = (errorRate(reference: c.expected, hypothesis: out) * 1000).rounded() / 1000
        return Check(missing: missing, kept: kept, error: error,
                     passed: !out.isEmpty && missing.isEmpty && kept.isEmpty && error <= maxError)
    }
}

/// One case of the general polish test set (bench/polish_cases*.json): a raw transcript, the
/// cleanup wanted, and the words that must survive or go. The guard when learning a prompt.
struct GeneralCase: Codable, Equatable, Identifiable {
    var id: String
    var raw: String
    var expected: String
    var must: [String] = []
    var mustNot: [String] = []

    enum CodingKeys: String, CodingKey { case id, raw, expected, must, mustNot = "must_not" }

    init(id: String, raw: String, expected: String, must: [String] = [], mustNot: [String] = []) {
        self.id = id; self.raw = raw; self.expected = expected; self.must = must; self.mustNot = mustNot
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        raw = try c.decode(String.self, forKey: .raw)
        expected = try c.decode(String.self, forKey: .expected)
        must = try c.decodeIfPresent([String].self, forKey: .must) ?? []
        mustNot = try c.decodeIfPresent([String].self, forKey: .mustNot) ?? []
    }

    /// The cases in a bench file (`{"cases": [...]}`).
    static func load(_ url: URL) throws -> [GeneralCase] {
        struct File: Decodable { let cases: [GeneralCase] }
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).cases
    }

    /// The main and held-out sets, as build.sh copies them into the app (nil: not there).
    static func loadAll(from folder: URL) -> [GeneralCase]? {
        let files = ["polish_cases.json", "polish_cases_holdout.json"].map { folder.appendingPathComponent($0) }
        let sets = files.compactMap { try? load($0) }
        return sets.count == files.count ? sets.flatMap { $0 } : nil
    }

    /// The sets in the installed app's bundle.
    static var app: [GeneralCase]? { Bundle.main.resourceURL.flatMap(loadAll(from:)) }
}
