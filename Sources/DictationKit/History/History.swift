import AppKit
import SwiftUI

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

/// One command-mode command: what you said, what ran, and how it went (History › Commands).
struct CommandRun: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var said: String
    /// The command and its choice; nil: none fitted ("Command not found").
    var command: String?
    var choice: String?
    var ok = false
    /// Its first line of output ("Brightness 70%"), or why it didn't run.
    var result = ""
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

// MARK: - View

struct HistoryView: View {
    @Environment(\.dateContext) private var dates
    @ObservedObject var store: HistoryStore
    /// Opens a dictation in Corrections (after its pencil makes a correction).
    var onCorrect: (UUID) -> Void = { _ in }
    /// Prefills a new correction with a cloud model's polish (`CorrectionSuggester`) (nil: keeps what the app wrote).
    var suggester: CorrectionSuggester?
    /// What's typed in the toolbar's search field (MainView).
    var search = ""
    /// Runs a command again from its row (nil: no ↻ button).
    var commandMode: CommandMode?
    @State private var confirmClear = false
    @State var shown = Shown.dictations

    enum Shown: String, CaseIterable {
        case dictations = "Dictations", commands = "Commands"
    }

    /// The Commands list, once there are any; until then the page is just dictations.
    private var showingCommands: Bool { shown == .commands && !store.commands.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if showingCommands { commands } else { dictations }
        }
        .padding(24)
    }

    @ViewBuilder private var dictations: some View {
        if filtered.isEmpty {
            empty(!store.entries.isEmpty ? "No matches."
                  : store.retention == .off ? "History is off. Turn it on in Settings › Keep history."
                  : "No dictations yet. Hold your hotkey and start talking.")
        } else {
            List {
                ForEach(Self.grouped(filtered, by: \.date, dates), id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.items) { entry in
                            HistoryRow(entry: entry, onDelete: { store.delete(entry) }, onCorrect: {
                                if entry.correction == nil {
                                    store.setCorrection(entry.text, for: entry.id)
                                    suggester?.suggest(for: entry, in: store)
                                }
                                onCorrect(entry.id)
                            })
                        }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
            .scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder private var commands: some View {
        if filteredCommands.isEmpty {
            empty("No matches.")
        } else {
            List {
                ForEach(Self.grouped(filteredCommands, by: \.date, dates), id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.items) { run in
                            CommandRow(run: run, onDelete: { store.deleteCommand(run) },
                                       onRunAgain: commandMode.map { mode in { Task { @MainActor in _ = await mode.again(run) } } })
                        }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
            .scrollContentBackground(.hidden)
        }
    }

    private func empty(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("history.empty")
                .frame(maxWidth: .infinity)
            Spacer()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("History").font(.largeTitle.bold())
            Spacer()
            if !store.commands.isEmpty {
                Picker("Show", selection: $shown) {
                    ForEach(Shown.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("history.list")
                Spacer()
            }
            Button("Clear All…") { confirmClear = true }
                .disabled(showingCommands ? store.commands.isEmpty : store.entries.isEmpty)
                .confirmationDialog(showingCommands ? "Delete all command history?" : Self.clearTitle(corrections: store.corrections.count),
                                    isPresented: $confirmClear) {
                    Button("Delete All", role: .destructive) { showingCommands ? store.clearCommands() : store.clear() }
                }
        }
    }

    static func clearTitle(corrections: Int) -> String {
        switch corrections {
        case 0: return "Delete all dictation history?"
        case 1: return "Delete all dictation history, including 1 correction?"
        case let n: return "Delete all dictation history, including \(n) corrections?"
        }
    }

    private var query: String { search.trimmingCharacters(in: .whitespaces) }

    private var filtered: [HistoryEntry] {
        query.isEmpty ? store.entries : store.entries.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    private var filteredCommands: [CommandRun] {
        query.isEmpty ? store.commands : store.commands.filter {
            $0.said.localizedCaseInsensitiveContains(query) || $0.label.localizedCaseInsensitiveContains(query)
        }
    }

    /// Newest first, by day: "Today", "Yesterday", then dates.
    static func grouped<Item>(_ items: [Item], by date: (Item) -> Date, _ dates: DateContext) -> [(title: String, items: [Item])] {
        let calendar = dates.calendar
        var result: [(title: String, items: [Item])] = []
        for item in items {
            let day = date(item)
            let title: String
            if calendar.isDateInToday(day) { title = "Today" }
            else if calendar.isDateInYesterday(day) { title = "Yesterday" }
            else { title = dates.string(day, .dateTime.weekday(.wide).month(.abbreviated).day().year()) }
            if result.last?.title == title { result[result.count - 1].items.append(item) }
            else { result.append((title, [item])) }
        }
        return result
    }
}

extension CommandRun {
    /// "brightness +10"; "none" when nothing fitted.
    var label: String { command.map { [$0, choice].compactMap { $0 }.joined(separator: " ") } ?? "none" }
}

/// A command in History › Commands: when, what you said, what ran, how it went, and ↻ to run it again.
struct CommandRow: View {
    let run: CommandRun
    let onDelete: () -> Void
    var onRunAgain: (() -> Void)?
    @Environment(\.dateContext) private var dates
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(dates.string(run.date, Date.FormatStyle(date: .omitted, time: .shortened)))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(run.said)
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Label(run.label, systemImage: "chevron.forward")
                .labelStyle(CommandChip(muted: run.command == nil))
                .foregroundStyle(run.command == nil ? Color.secondary : Color.accentColor)
                .frame(width: 150, alignment: .leading)
                .accessibilityIdentifier("history.command.name")
            HStack(spacing: 6) {
                Circle().fill(run.ok ? Color.green : Color.red).frame(width: 7, height: 7)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                Text(run.result)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(run.ok ? Color.primary : Color.red)
            }
            .frame(width: 190, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("history.command.result")
            Button { onRunAgain?() } label: {
                Image(systemName: "arrow.clockwise").frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Run again")
            .accessibilityLabel("Run again")
            .accessibilityIdentifier("history.runAgain")
            .disabled(run.command == nil || onRunAgain == nil)
            .opacity(run.command == nil ? 0 : hovering ? 1 : 0.3)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("history.command")
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Delete", role: .destructive, action: onDelete)
        }
    }
}

/// The command and its choice in small monospaced type on a tinted chip.
private struct CommandChip: LabelStyle {
    /// Grey, for "none".
    var muted = false

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 8, weight: .bold))
            configuration.title.font(.caption.monospaced())
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(muted ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.tint.opacity(0.12))))
    }
}

struct HistoryRow: View {
    /// Where "Copy" writes; tests swap in a private pasteboard.
    static var pasteboard: NSPasteboard = .general

    let entry: HistoryEntry
    let onDelete: () -> Void
    var onCorrect: () -> Void = {}
    @Environment(\.dateContext) private var dates
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(dates.string(entry.date, Date.FormatStyle(date: .omitted, time: .shortened)))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(entry.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onCorrect) {
                Image(systemName: entry.correction == nil ? "pencil" : "pencil.circle.fill")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(entry.correction == nil ? Color.secondary : Color.accentColor)
            .help(entry.correction == nil ? "Correct this dictation" : "Corrected — open in Corrections")
            .accessibilityLabel(entry.correction == nil ? "Correct this dictation" : "Open correction")
            .accessibilityIdentifier("history.correct")
            .opacity(hovering || entry.correction != nil ? 1 : 0.3)
            Button(action: copy) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .help("Copy transcript")
            .accessibilityLabel("Copy transcript")
            .accessibilityIdentifier("history.copy")
            // Faint until hover rather than invisible: fully transparent views drop out of
            // accessibility, which would hide the button from VoiceOver.
            .opacity(hovering || copied ? 1 : 0.3)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("history.row")
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy") { copy() }
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private func copy() {
        Self.pasteboard.clearContents()
        Self.pasteboard.setString(entry.text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}

/// What date text depends on: the Mac's region, clock and time zone settings. Views read it from the
/// environment, so snapshot tests can fix it (`HostedView`) and pass whatever those settings are.
struct DateContext {
    var locale: Locale = .autoupdatingCurrent
    var timeZone: TimeZone = .autoupdatingCurrent
    /// In `timeZone`, for "Today" / "Yesterday".
    var calendar: Calendar {
        var calendar = Calendar.autoupdatingCurrent
        calendar.locale = locale
        calendar.timeZone = timeZone
        return calendar
    }

    func string(_ date: Date, _ style: Date.FormatStyle) -> String {
        var style = style.locale(locale)
        style.timeZone = timeZone
        style.calendar = calendar
        return date.formatted(style)
    }
}

extension EnvironmentValues {
    @Entry var dateContext = DateContext()
}
