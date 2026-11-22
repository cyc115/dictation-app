import Foundation

/// One pasted dictation.
struct HistoryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var text: String
    var duration: TimeInterval
    /// What the speech model heard, before polish; nil when it's the same as `text`.
    var raw: String?
    /// The setup's id (Settings → Model) and, when polished, its prompt version.
    var setup: String?
    var prompt: String?
    /// What you wanted instead (Corrections); nil = not corrected.
    var correction: String?
    /// Stop → transcript, and transcript → polished text (nil: not polished, or before these were saved).
    var transcribeSeconds: Double?
    var polishSeconds: Double?
    /// Which speech and polish model answered, main or backup (nil: on-device speech, not polished,
    /// polish failed, or before these were saved). Settings → Show detailed analytics shows them.
    var transcribedBy: ModelAnswer?
    var polishedBy: ModelAnswer?
    /// The fix as word changes (`FixIntake`), worked out when the app is idle (`VocabularyIntake`);
    /// nil until then, and with no fix.
    var intake: Intake?
    /// How you edited it right after it was pasted (*Learn from my edits*); nil when it wasn't watched
    /// or the edit changed no word.
    var capture: Capture?

    /// What polish was given: a test case's input.
    var input: String { raw ?? text }

    /// What it should have been, for vocabulary: your correction, else your captured edit unless you
    /// dismissed it. (Learn trains only on `correction`.)
    var fixTarget: String? {
        if let correction { return correction }
        guard let capture, capture.state != .dismissed else { return nil }
        return capture.edited
    }

    /// Waits in Corrections for your Accept or Dismiss.
    var isWaiting: Bool { capture?.state == .waiting && correction == nil }
}

/// Which model gave a dictation's transcript or polish: the setup's main model, or the backup asked
/// when the main one was late or failed ("Backup model when slow").
struct ModelAnswer: Codable, Equatable {
    /// The setup's model, e.g. "qwen/qwen3-asr-1.7b" or "openrouter:deepseek/deepseek-v4.1-flash@Together".
    var main: String
    /// The backup, when it was asked too; nil when the main model answered within its wait.
    var backup: String?
    /// The backup answered first, and its answer was used.
    var byBackup = false

    /// The model whose answer was used.
    var model: String { byBackup ? backup ?? main : main }

    /// A model id for display: "qwen3-asr-1.7b", "deepseek-v4.1-flash · Together, DeepInfra".
    static func displayName(_ id: String) -> String {
        if id.hasPrefix("apple:") { return "Apple on-device" }
        if id.hasPrefix("local:") { return (id.split(separator: "/").last.map(String.init) ?? id) + " · on this Mac" }
        let spec = id.hasPrefix("openrouter:") ? String(id.dropFirst("openrouter:".count)) : id
        let parts = spec.split(separator: "@", maxSplits: 1).map(String.init)
        let name = parts[0].split(separator: "/").last.map(String.init) ?? parts[0]
        guard parts.count == 2 else { return name }
        return name + " · " + parts[1].replacingOccurrences(of: ",", with: ", ")
    }
}

/// How long history is kept on this Mac.
enum HistoryRetention: String, CaseIterable {
    case forever, days30, days7, off

    var title: String {
        switch self {
        case .forever: return "Forever"
        case .days30: return "30 days"
        case .days7: return "7 days"
        case .off: return "Don't keep"
        }
    }

    var maxAge: TimeInterval? {
        switch self {
        case .forever: return nil
        case .days30: return 30 * 86_400
        case .days7: return 7 * 86_400
        case .off: return 0
        }
    }
}

/// Dictation history, newest first, saved as JSON in Application Support. Never leaves the Mac.
/// Command-mode commands are kept beside it, in their own file and list (`commands`).
final class HistoryStore: ObservableObject {
    /// Published as it changes, except for a correction being typed: that publishes with its save, once
    /// typing pauses (`CorrectionCard` shows what you type itself), so a keystroke doesn't redraw every
    /// page that shows History — with them all kept mounted that took ~70 ms a key at 2k entries.
    private(set) var entries: [HistoryEntry] = [] {
        willSet { if !typing { objectWillChange.send() } }
    }
    private var typing = false
    private var unpublishedEdit = false
    @Published private(set) var commands: [CommandRun] = []
    @Published var retention: HistoryRetention {
        didSet {
            defaults.set(retention.rawValue, forKey: "historyRetention")
            prune()
        }
    }

    let fileURL: URL
    /// history.json → history-commands.json.
    var commandsURL: URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent(fileURL.deletingPathExtension().lastPathComponent + "-commands.json")
    }
    private let defaults: UserDefaults

    static let defaultFileURL = AppPaths.file("history.json")

    init(fileURL: URL = HistoryStore.defaultFileURL, defaults: UserDefaults = .standard) {
        self.fileURL = fileURL
        self.defaults = defaults
        retention = HistoryRetention(rawValue: defaults.string(forKey: "historyRetention") ?? "") ?? .forever
        entries = JSONFile.read([HistoryEntry].self, from: fileURL) ?? []
        commands = JSONFile.read([CommandRun].self, from: commandsURL) ?? []
        prune()
    }

    func addCommand(_ run: CommandRun) {
        guard retention != .off else { return }
        commands.insert(run, at: 0)
        saveCommands()
    }

    func deleteCommand(_ run: CommandRun) {
        commands.removeAll { $0.id == run.id }
        saveCommands()
    }

    func clearCommands() {
        commands.removeAll()
        saveCommands()
    }

    /// The new entry's id; nil when nothing was kept (History off, or no text).
    @discardableResult
    func add(text: String, duration: TimeInterval, raw: String? = nil, setup: String? = nil, prompt: String? = nil,
             transcribeSeconds: Double? = nil, polishSeconds: Double? = nil,
             transcribedBy: ModelAnswer? = nil, polishedBy: ModelAnswer? = nil, date: Date = Date()) -> UUID? {
        guard retention != .off, !text.isEmpty else { return nil }
        let entry = HistoryEntry(date: date, text: text, duration: duration, raw: raw == text ? nil : raw,
                                 setup: setup, prompt: prompt,
                                 transcribeSeconds: transcribeSeconds, polishSeconds: polishSeconds,
                                 transcribedBy: transcribedBy, polishedBy: polishedBy)
        entries.insert(entry, at: 0)
        save()
        return entry.id
    }

    /// Dictations you corrected (or whose captured edit you accepted), newest first.
    var corrections: [HistoryEntry] { entries.filter { $0.correction != nil } }

    /// Captured edits waiting for your Accept, newest first.
    var waiting: [HistoryEntry] { entries.filter(\.isWaiting) }

    /// Saves a captured edit (`EditWatcher`) on its entry: only on one you haven't corrected or had a
    /// capture on already (yours wins, and one dictation is watched once).
    func setCapture(_ capture: Capture, for id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }), entries[i].correction == nil, entries[i].capture == nil else { return }
        entries[i].capture = capture
        save()
    }

    /// Accept on a waiting capture: it becomes the entry's correction, which trains Learn.
    func accept(_ id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }), var capture = entries[i].capture,
              capture.state == .waiting || capture.state == .auto else { return }
        capture.state = .accepted
        entries[i].correction = entries[i].correction ?? capture.edited
        entries[i].capture = capture
        save()
    }

    /// Dismiss on a capture: it counts for nothing, and an `auto` one stops training Learn.
    func dismiss(_ id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }), var capture = entries[i].capture,
              capture.state == .waiting || capture.state == .auto else { return }
        if capture.state == .auto { entries[i].correction = nil }
        capture.state = .dismissed
        entries[i].capture = capture
        save()
    }

    /// Saves what you wanted instead; empty removes the correction. Called on every keystroke, so an
    /// edit is written once typing pauses (a 5k-entry history takes ~15 ms to save); adding or
    /// removing one is written at once.
    func setCorrection(_ text: String, for id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        guard entries[i].correction != value else { return }
        let edit = entries[i].correction != nil && value != nil
        typing = edit
        entries[i].correction = value
        // A correction typed on a captured edit makes it yours; taking yours away dismisses the capture,
        // so its edit doesn't go on feeding vocabulary unseen. One you dismissed stays dismissed: a
        // correction you type on it is simply yours.
        if var capture = entries[i].capture, capture.state != .dismissed {
            capture.state = value == nil ? .dismissed : .accepted
            if capture != entries[i].capture { entries[i].capture = capture }
        }
        typing = false
        if edit {
            unpublishedEdit = true
            saveSoon()
        } else {
            save()
        }
    }

    /// Saves intake worked out at idle (`VocabularyIntake`), one publish and one save for them all.
    /// Each is kept only if it was worked out from the entry's fix as it is now (`fixTarget`; nil: only
    /// once the fix is gone), so one typed on since is worked out again next time.
    func setIntakes(_ intakes: [UUID: Intake?]) {
        var copy = entries
        for i in copy.indices {
            guard let intake = intakes[copy[i].id], intake?.of == copy[i].fixTarget, copy[i].intake != intake else { continue }
            copy[i].intake = intake
        }
        guard copy != entries else { return }
        entries = copy
        save()
    }

    /// Saves the judge's answer (`FixJudge`), one publish and one save: each fix's verdicts and what
    /// they do (`FixJudge.judged`), or one more try where the answer left it out. Only where the fix
    /// is still the one judged (its target and word changes): one you edited or dismissed meanwhile
    /// is left alone, to be judged again as it is now. `trainUnreviewed`: `trainOnUnreviewedCaptures`
    /// (off: every capture keeps waiting for Accept).
    func applyVerdicts(_ judged: [FixJudge.Judged], trainUnreviewed: Bool) {
        var copy = entries
        for fix in judged {
            guard let i = copy.firstIndex(where: { $0.id == fix.item.id }), copy[i].fixTarget == fix.item.target,
                  let intake = copy[i].intake, intake.of == fix.item.target,
                  intake.changes.map({ WordChange(old: $0.old, new: $0.new) }) == fix.item.changes else { continue }
            if let verdicts = fix.verdicts, verdicts.count == intake.changes.count {
                copy[i] = FixJudge.judged(copy[i], verdicts: verdicts, trainUnreviewed: trainUnreviewed)
            } else {
                copy[i].intake?.tries = (intake.tries ?? 0) + 1
            }
        }
        guard copy != entries else { return }
        entries = copy
        save()
    }

    /// Writes an edit that's waiting for typing to pause (at quit).
    func flush() {
        if pendingSave != nil { save() }
    }

    private var pendingSave: DispatchWorkItem?

    private func saveSoon() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func delete(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func prune() {
        guard let maxAge = retention.maxAge else { return }
        let cutoff = Date().addingTimeInterval(-maxAge)
        // Corrections are kept until you delete them, except an `auto` captured one you never looked at.
        let kept = entries.filter { $0.date > cutoff || ($0.correction != nil && $0.capture?.state != .auto) }
        if kept.count != entries.count {
            entries = kept
            save()
        }
        let keptCommands = commands.filter { $0.date > cutoff }
        if keptCommands.count != commands.count {
            commands = keptCommands
            saveCommands()
        }
    }

    private func saveCommands() { JSONFile.save(commands, to: commandsURL) }

    private func save() {
        pendingSave?.cancel()
        pendingSave = nil
        if unpublishedEdit {
            unpublishedEdit = false
            objectWillChange.send()
        }
        JSONFile.save(entries, to: fileURL)
    }
}
