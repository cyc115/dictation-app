import AppKit
import SwiftUI

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
