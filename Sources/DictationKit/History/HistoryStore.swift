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

    /// What polish was given: a test case's input.
    var input: String { raw ?? text }
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
    static let shared = HistoryStore()

    @Published private(set) var entries: [HistoryEntry] = []
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

    func add(text: String, duration: TimeInterval, raw: String? = nil, setup: String? = nil, prompt: String? = nil,
             transcribeSeconds: Double? = nil, polishSeconds: Double? = nil,
             transcribedBy: ModelAnswer? = nil, polishedBy: ModelAnswer? = nil, date: Date = Date()) {
        guard retention != .off, !text.isEmpty else { return }
        entries.insert(HistoryEntry(date: date, text: text, duration: duration, raw: raw == text ? nil : raw,
                                    setup: setup, prompt: prompt,
                                    transcribeSeconds: transcribeSeconds, polishSeconds: polishSeconds,
                                    transcribedBy: transcribedBy, polishedBy: polishedBy), at: 0)
        save()
    }

    /// Fills in transcribe and polish times on dictations from before they were saved, from kept
    /// recordings with the same transcript (`RecordingInfo`). Once: `timingsBackfilled` in defaults.
    func backfillTimings(from recordings: @autoclosure () -> [RecordingInfo]) {
        guard !defaults.bool(forKey: "timingsBackfilled") else { return }
        defaults.set(true, forKey: "timingsBackfilled")
        var byTranscript: [String: RecordingInfo] = [:]
        for info in recordings() where info.transcribeSeconds != nil {
            byTranscript[info.transcript.trimmingCharacters(in: .whitespacesAndNewlines)] = info
        }
        var changed = false
        for i in entries.indices where entries[i].transcribeSeconds == nil {
            guard let info = byTranscript[entries[i].input] else { continue }
            entries[i].transcribeSeconds = info.transcribeSeconds
            entries[i].polishSeconds = info.polishSeconds
            changed = true
        }
        if changed { save() }
    }

    /// Dictations you corrected, newest first.
    var corrections: [HistoryEntry] { entries.filter { $0.correction != nil } }

    /// Saves what you wanted instead; empty removes the correction. Called on every keystroke, so an
    /// edit is written once typing pauses (a 5k-entry history takes ~15 ms to save); adding or
    /// removing one is written at once.
    func setCorrection(_ text: String, for id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        guard entries[i].correction != value else { return }
        let edit = entries[i].correction != nil && value != nil
        entries[i].correction = value
        if edit { saveSoon() } else { save() }
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
        let kept = entries.filter { $0.date > cutoff || $0.correction != nil }  // corrections are kept until you delete them
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
        JSONFile.save(entries, to: fileURL)
    }
}
