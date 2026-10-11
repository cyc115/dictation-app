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

    /// What polish was given: a test case's input.
    var input: String { raw ?? text }
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
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var entries: [HistoryEntry] = []
    @Published var retention: HistoryRetention {
        didSet {
            defaults.set(retention.rawValue, forKey: "historyRetention")
            prune()
        }
    }

    let fileURL: URL
    private let defaults: UserDefaults

    static let defaultFileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DictationApp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    init(fileURL: URL = HistoryStore.defaultFileURL, defaults: UserDefaults = .standard) {
        self.fileURL = fileURL
        self.defaults = defaults
        retention = HistoryRetention(rawValue: defaults.string(forKey: "historyRetention") ?? "") ?? .forever
        if let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            entries = (try? decoder.decode([HistoryEntry].self, from: data)) ?? []
        }
        prune()
    }

    func add(text: String, duration: TimeInterval, raw: String? = nil, setup: String? = nil, prompt: String? = nil) {
        guard retention != .off, !text.isEmpty else { return }
        entries.insert(HistoryEntry(date: Date(), text: text, duration: duration, raw: raw == text ? nil : raw,
                                    setup: setup, prompt: prompt), at: 0)
        save()
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
    }

    private func save() {
        pendingSave?.cancel()
        pendingSave = nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
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
    @State private var search = ""
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if filtered.isEmpty {
                Spacer()
                Text(!store.entries.isEmpty ? "No matches."
                     : store.retention == .off ? "History is off. Turn it on in Settings › Keep history."
                     : "No dictations yet. Hold your hotkey and start talking.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("history.empty")
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List {
                    ForEach(groups, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.entries) { entry in
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
        .padding(24)
        .searchable(text: $search, placement: .toolbar, prompt: "Search history")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("History").font(.largeTitle.bold())
            Spacer()
            Button("Clear All…") { confirmClear = true }
                .disabled(store.entries.isEmpty)
                .confirmationDialog(Self.clearTitle(corrections: store.corrections.count), isPresented: $confirmClear) {
                    Button("Delete All", role: .destructive) { store.clear() }
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

    private var filtered: [HistoryEntry] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? store.entries : store.entries.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    private var groups: [(title: String, entries: [HistoryEntry])] {
        let calendar = dates.calendar
        var result: [(title: String, entries: [HistoryEntry])] = []
        for entry in filtered {
            let title: String
            if calendar.isDateInToday(entry.date) { title = "Today" }
            else if calendar.isDateInYesterday(entry.date) { title = "Yesterday" }
            else { title = dates.string(entry.date, .dateTime.weekday(.wide).month(.abbreviated).day().year()) }
            if result.last?.title == title { result[result.count - 1].entries.append(entry) }
            else { result.append((title, [entry])) }
        }
        return result
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
