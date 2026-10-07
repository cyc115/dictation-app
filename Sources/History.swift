import AppKit
import SwiftUI

/// One pasted dictation.
struct HistoryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var text: String
    var duration: TimeInterval
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
            UserDefaults.standard.set(retention.rawValue, forKey: "historyRetention")
            prune()
        }
    }

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DictationApp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    private init() {
        retention = HistoryRetention(rawValue: UserDefaults.standard.string(forKey: "historyRetention") ?? "") ?? .forever
        if let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            entries = (try? decoder.decode([HistoryEntry].self, from: data)) ?? []
        }
        prune()
    }

    func add(text: String, duration: TimeInterval) {
        guard retention != .off, !text.isEmpty else { return }
        entries.insert(HistoryEntry(date: Date(), text: text, duration: duration), at: 0)
        save()
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
        let kept = entries.filter { $0.date > cutoff }
        if kept.count != entries.count {
            entries = kept
            save()
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - View

struct HistoryView: View {
    @ObservedObject var store: HistoryStore
    @State private var search = ""
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if filtered.isEmpty {
                Spacer()
                Text(store.entries.isEmpty ? "No dictations yet. Hold your hotkey and start talking." : "No matches.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List {
                    ForEach(groups, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.entries) { entry in
                                HistoryRow(entry: entry, onDelete: { store.delete(entry) })
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("History").font(.largeTitle.bold())
                Spacer()
                Button("Clear All…") { confirmClear = true }
                    .disabled(store.entries.isEmpty)
                    .confirmationDialog("Delete all dictation history?", isPresented: $confirmClear) {
                        Button("Delete All", role: .destructive) { store.clear() }
                    }
            }
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Keep history", systemImage: "internaldrive").font(.headline)
                    Text("Stored only on this Mac. Nothing is uploaded.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $store.retention) {
                    ForEach(HistoryRetention.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            .padding(14)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var filtered: [HistoryEntry] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? store.entries : store.entries.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    private var groups: [(title: String, entries: [HistoryEntry])] {
        let calendar = Calendar.current
        var result: [(title: String, entries: [HistoryEntry])] = []
        for entry in filtered {
            let title: String
            if calendar.isDateInToday(entry.date) { title = "Today" }
            else if calendar.isDateInYesterday(entry.date) { title = "Yesterday" }
            else { title = entry.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().year()) }
            if result.last?.title == title { result[result.count - 1].entries.append(entry) }
            else { result.append((title, [entry])) }
        }
        return result
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let onDelete: () -> Void
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(entry.date.formatted(date: .omitted, time: .shortened))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(entry.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: copy) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .help("Copy transcript")
            .opacity(hovering || copied ? 1 : 0)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy") { copy() }
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}
