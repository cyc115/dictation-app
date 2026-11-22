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
}

/// Your vocabulary, in Application Support (vocabulary.json). Made once in `AppServices.live()`.
/// `DictationApp vocabulary …` writes the same file from another process, so the store re-reads it
/// when its modification date changed: at the start of each dictation, when the page is shown, and
/// before each save of its own (a save never undoes a change made meanwhile).
final class VocabularyStore: ObservableObject {
    @Published private(set) var entries: [VocabularyEntry] = []
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

    private struct File: Codable {
        var entries: [VocabularyEntry]
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
        return change { entries in
            if let i = entries.firstIndex(where: { $0.term.caseInsensitiveCompare(term) == .orderedSame }) {
                let have = Set(entries[i].heardAs.map { $0.lowercased() })
                entries[i].heardAs += heard.filter { !have.contains($0.lowercased()) }
                return entries[i]
            }
            let entry = VocabularyEntry(term: term, heardAs: heard, source: source, added: now())
            entries.append(entry)
            return entry
        }
    }

    /// Saves an edited entry (its term, variants or switch).
    func update(_ entry: VocabularyEntry) {
        change { entries in
            guard let i = entries.firstIndex(where: { $0.id == entry.id }) else { return }
            entries[i] = entry
        }
    }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        change { entries in
            guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
            entries[i].enabled = enabled
        }
    }

    func remove(id: UUID) {
        change { $0.removeAll { $0.id == id } }
    }

    /// Removes the entry with this term (any case); false when there's none.
    @discardableResult
    func remove(term: String) -> Bool {
        let term = term.trimmingCharacters(in: .whitespaces)
        return change { entries in
            let before = entries.count
            entries.removeAll { $0.term.caseInsensitiveCompare(term) == .orderedSame }
            return entries.count < before
        }
    }

    /// Counts replacements that fired (`Vocabulary.apply`). Called after the paste, never before.
    func recordUses(_ uses: [UUID: Int]) {
        guard !uses.isEmpty else { return }
        change { entries in
            for i in entries.indices { entries[i].uses += uses[entries[i].id] ?? 0 }
        }
    }

    /// Re-reads, changes and saves.
    @discardableResult
    private func change<T>(_ edit: (inout [VocabularyEntry]) -> T) -> T {
        reloadIfChanged()
        var copy = entries
        let result = edit(&copy)
        if copy != entries {
            entries = copy
            if problem != nil, FileManager.default.fileExists(atPath: fileURL.path) {
                try? FileManager.default.removeItem(at: asideURL)
                try? FileManager.default.moveItem(at: fileURL, to: asideURL)
                problem = "\(fileURL.lastPathComponent) couldn't be read, so it was moved to \(asideURL.lastPathComponent)."
            }
            JSONFile.save(File(entries: entries), to: fileURL, pretty: true)
            seen = modified()
        }
        return result
    }

    private func load() {
        seen = modified()
        var read: [VocabularyEntry] = [], problem: String?
        if let data = try? Data(contentsOf: fileURL) {
            do { read = try JSONFile.decoder.decode(File.self, from: data).entries } catch {
                problem = "\(fileURL.lastPathComponent) can't be read: fix it, or add a term and it's moved to \(asideURL.lastPathComponent)."
            }
        }
        if read != entries { entries = read }
        if problem != self.problem { self.problem = problem }
    }

    private func modified() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
    }
}
