import Combine
import Foundation

extension VocabularyEntry {
    /// "G Four Snow, g force now" as variants: split on commas (full-width too), trimmed, no blanks
    /// or repeats.
    static func variants(from text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0 == "," || $0 == "，" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// Its term is `term`, ignoring case (as given: no trimming).
    func isTerm(_ term: String) -> Bool { self.term.caseInsensitiveCompare(term) == .orderedSame }

    /// Adds the variants it doesn't have yet (any case), in order.
    mutating func addVariants(_ variants: [String]) {
        let have = Set(heardAs.map { $0.lowercased() })
        heardAs += variants.filter { !have.contains($0.lowercased()) }
    }
}

extension Array where Element == VocabularyEntry {
    /// The first entry whose term is `term` (`isTerm`).
    func firstIndex(ofTerm term: String) -> Int? { firstIndex { $0.isTerm(term) } }
}

/// Your vocabulary, in Application Support (vocabulary.json). Made once in `AppServices.live()`.
/// `DictationApp vocabulary …` writes the same file from another process, so the store re-reads it
/// when its modification date changed: at the start of each dictation, when the page is shown, and
/// before each save of its own (a save never undoes a change made meanwhile).
final class VocabularyStore: ObservableObject {
    @Published private(set) var entries: [VocabularyEntry] = []
    /// Terms seen in your corrections, on their way in (`updateCandidates`); dismissed ones too.
    @Published private(set) var candidates: [VocabularyCandidate] = []
    /// Set when vocabulary.json is there but can't be read (a hand edit gone wrong). The next save
    /// moves it aside first (`asideURL`), so no term in it is lost.
    @Published private(set) var problem: String?
    let fileURL: URL
    /// Where an unreadable vocabulary.json is kept: vocabulary-unreadable.json beside it.
    var asideURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent(fileURL.deletingPathExtension().lastPathComponent + "-unreadable.json")
    }
    var now: () -> Date = Date.init
    /// The file's modification date as last read or written.
    private var seen: Date?

    static let defaultFileURL = AppPaths.file("vocabulary.json")

    private struct File: Codable, Equatable {
        var entries: [VocabularyEntry] = []
        var candidates: [VocabularyCandidate] = []

        private enum CodingKeys: String, CodingKey { case entries, candidates }

        init(entries: [VocabularyEntry], candidates: [VocabularyCandidate]) {
            self.entries = entries
            self.candidates = candidates
        }

        /// A file from before candidates existed has none.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            entries = try c.decode([VocabularyEntry].self, forKey: .entries)
            candidates = try c.decodeIfPresent([VocabularyCandidate].self, forKey: .candidates) ?? []
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(entries, forKey: .entries)
            if !candidates.isEmpty { try c.encode(candidates, forKey: .candidates) }
        }
    }

    init(fileURL: URL = VocabularyStore.defaultFileURL) {
        self.fileURL = fileURL
        load()
    }

    /// The enabled entries, ready to apply; nothing when `enabled` (Use vocabulary) is off.
    func vocabulary(enabled: Bool) -> Vocabulary { enabled ? Vocabulary(entries) : .none }

    /// `vocabulary(enabled:).fingerprint`, without building its matchers (views ask this).
    func fingerprint(enabled: Bool) -> String? { enabled ? Vocabulary.fingerprint(of: entries) : nil }

    /// Re-reads the file if something else changed it.
    func reloadIfChanged() {
        if modified() != seen { load() }
    }

    /// Adds a term, or the new variants to the term already there (any case). Nil for a blank term.
    @discardableResult
    func add(term: String, heardAs: [String] = [], source: VocabularyEntry.Source = .manual) -> VocabularyEntry? {
        let term = term.trimmingCharacters(in: .whitespaces)
        let heard = VocabularyEntry.variants(from: heardAs.joined(separator: ","))
        guard !term.isEmpty else { return nil }
        return change { file -> VocabularyEntry in
            if let i = file.entries.firstIndex(ofTerm: term) {
                file.entries[i].addVariants(heard)
                return file.entries[i]
            }
            file.entries.append(VocabularyEntry(term: term, heardAs: heard, source: source, added: now()))
            Self.countCorrected(in: &file)
            return file.entries[file.entries.count - 1]
        }
    }

    /// Saves an edited entry (its term, variants or switch). Its counts stay the store's: a
    /// replacement or a pass while the editor was open isn't undone, and a renamed term is recounted.
    func update(_ entry: VocabularyEntry) {
        change { file in
            guard let i = file.entries.firstIndex(where: { $0.id == entry.id }) else { return }
            var entry = entry
            entry.uses = file.entries[i].uses
            file.entries[i] = entry
            Self.countCorrected(in: &file)
        }
    }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        change { file in
            guard let i = file.entries.firstIndex(where: { $0.id == id }) else { return }
            file.entries[i].enabled = enabled
        }
    }

    func remove(id: UUID) {
        change { $0.entries.removeAll { $0.id == id } }
    }

    /// Removes the entry with this term (any case); false when there's none.
    @discardableResult
    func remove(term: String) -> Bool {
        let term = term.trimmingCharacters(in: .whitespaces)
        return change { file in
            let before = file.entries.count
            file.entries.removeAll { $0.isTerm(term) }
            return file.entries.count < before
        } ?? false
    }

    /// Counts replacements that fired (`Vocabulary.apply`). Called after the paste, never before.
    func recordUses(_ uses: [UUID: Int]) {
        guard !uses.isEmpty else { return }
        change { file in
            for i in file.entries.indices { file.entries[i].uses += uses[file.entries[i].id] ?? 0 }
        }
    }

    // MARK: Candidates

    /// Takes the candidates counted from History (`CandidateTally.support`), keeping what's yours on
    /// them (dismissed, what was already handed over), and learns each seen in `learnAfter` dictations;
    /// with `learnAfter` nil (Use vocabulary off), only collects them. A dismissed or handed-over term
    /// is remembered with nothing left to count; any other is dropped. Writes nothing when nothing
    /// changed, and nothing while vocabulary.json can't be read (that's moved aside only for
    /// something you do). Also keeps each entry's `corrected` in step with the candidates.
    func updateCandidates(_ support: [VocabularyCandidate], learnAfter: Int?) {
        change(byYou: false) { file in
            var kept = Dictionary(file.candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var candidates = support.map { found -> VocabularyCandidate in
                var candidate = found
                if let had = kept.removeValue(forKey: found.id) {
                    candidate.dismissed = had.dismissed
                    candidate.added = had.added
                    candidate.addedHeard = had.addedHeard
                }
                return candidate
            }
            candidates += file.candidates.filter { kept[$0.id] != nil && ($0.dismissed || $0.added) }.map {
                var remembered = $0
                remembered.heard = []
                return remembered
            }
            file.candidates = candidates
            if let learnAfter {
                for i in file.candidates.indices where !file.candidates[i].dismissed && file.candidates[i].seen >= max(learnAfter, 1) {
                    learn(at: i, in: &file)
                }
            }
            Self.countCorrected(in: &file)
        }
    }

    /// Each entry's `corrected`: the dictations its candidate was seen in (0 with none), so the speech
    /// hint can rank by it without the store.
    private static func countCorrected(in file: inout File) {
        let seen = Dictionary(file.candidates.map { ($0.id, $0.seen) }, uniquingKeysWith: max)
        for i in file.entries.indices {
            let n = seen[file.entries[i].term.trimmingCharacters(in: .whitespaces).lowercased()] ?? 0
            if file.entries[i].corrected != n { file.entries[i].corrected = n }
        }
    }

    /// Add now: the candidate becomes an entry (or its variants go into yours) at once.
    func learn(_ id: String) {
        change { file in
            guard let i = file.candidates.firstIndex(where: { $0.id == id }) else { return }
            learn(at: i, in: &file)
            Self.countCorrected(in: &file)
        }
    }

    /// Never learned or shown again.
    func dismiss(_ id: String) {
        change { file in
            guard let i = file.candidates.firstIndex(where: { $0.id == id }) else { return }
            file.candidates[i].dismissed = true
        }
    }

    /// Hands a candidate's new variants (not ordinary words, not handed over before) to the entry with
    /// its term, or makes a learned entry for it, unless one was made before (you deleted it).
    /// Once a term is in, a new way of mishearing it needs 2 dictations of its own (or a *misheard*
    /// verdict): one change of mind ("GPT" → "Claude") mustn't replace "GPT" everywhere.
    /// Variants go in as they are: one with a comma in it stays one.
    private func learn(at i: Int, in file: inout File) {
        let candidate = file.candidates[i]
        let handed = Set(candidate.addedHeard)
        let variants = candidate.heard.filter {
            !$0.ordinary && !handed.contains($0.text.lowercased()) && (!candidate.added || $0.dictations.count >= 2 || $0.misheard)
        }.map(\.text)
        if let e = file.entries.firstIndex(ofTerm: candidate.term) {
            file.entries[e].addVariants(variants)
        } else if !candidate.added {
            file.entries.append(VocabularyEntry(term: candidate.term, heardAs: variants, source: .learned, added: now()))
        } else {
            return
        }
        file.candidates[i].added = true
        file.candidates[i].addedHeard += variants.map { $0.lowercased() }
    }

    // MARK: File

    /// Re-reads, changes and saves. A change not `byYou` (the idle pass) isn't made while the file
    /// can't be read: only something you do moves it aside.
    @discardableResult
    private func change<T>(byYou: Bool = true, _ edit: (inout File) -> T) -> T? {
        reloadIfChanged()
        guard byYou || problem == nil else { return nil }
        let before = File(entries: entries, candidates: candidates)
        var copy = before
        let result = edit(&copy)
        if copy != before {
            if copy.entries != entries { entries = copy.entries }
            if copy.candidates != candidates { candidates = copy.candidates }
            if problem != nil, FileManager.default.fileExists(atPath: fileURL.path) {
                try? FileManager.default.removeItem(at: asideURL)
                try? FileManager.default.moveItem(at: fileURL, to: asideURL)
                problem = "\(fileURL.lastPathComponent) couldn't be read, so it was moved to \(asideURL.lastPathComponent)."
            }
            JSONFile.save(copy, to: fileURL, pretty: true)
            seen = modified()
        }
        return result
    }

    private func load() {
        seen = modified()
        var read = File(entries: [], candidates: []), problem: String?
        if let data = try? Data(contentsOf: fileURL) {
            do { read = try JSONFile.decoder.decode(File.self, from: data) } catch {
                problem = "\(fileURL.lastPathComponent) can't be read: fix it, or add a term and it's moved to \(asideURL.lastPathComponent)."
            }
        }
        if read.entries != entries { entries = read.entries }
        if read.candidates != candidates { candidates = read.candidates }
        if problem != self.problem { self.problem = problem }
    }

    private func modified() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
    }
}
