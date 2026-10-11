import AppKit
import SwiftUI

/// Which words of a dictation a correction changed, for highlighting.
enum WordDiff {
    /// Words: a Chinese character each, else a run of non-space characters.
    static func words(_ text: String) -> [Range<String.Index>] {
        text.ranges(of: #/\p{Han}|[^\s\p{Han}]+/#)
    }

    /// Ranges in `old` of the words `new` drops or replaces.
    static func changed(from old: String, to new: String) -> [Range<String.Index>] {
        let before = words(old)
        let after = words(new).map { new[$0] }
        return after.difference(from: before.map { old[$0] }).removals.map {
            guard case let .remove(offset, _, _) = $0 else { fatalError("removals only") }
            return before[offset]
        }
    }
}

/// Dictations you corrected: what the app wrote, and what you wanted. Each one is a test case for
/// AI polish (`bench/suite.py polish run --corrections`); they live on their History entries.
struct CorrectionsView: View {
    @ObservedObject var store: HistoryStore
    /// The correction to put the cursor in when the tab opens (the one just made from History).
    var editing: UUID?
    @State private var search = ""
    @FocusState private var focused: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Corrections").font(.largeTitle.bold())
                Text("Teach the app the way you speak.").foregroundStyle(.secondary)
            }
            if shown.isEmpty {
                Spacer()
                Text(store.corrections.isEmpty
                     ? "No corrections yet. In History, click the pencil beside a dictation that came out wrong."
                     : "No matches.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("corrections.empty")
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(shown) { entry in
                                CorrectionCard(entry: entry, focused: $focused,
                                               onChange: { store.setCorrection($0, for: entry.id) },
                                               onDelete: { store.setCorrection("", for: entry.id) })
                                    .id(entry.id)
                            }
                        }
                    }
                    .onAppear {
                        guard let editing else { return }
                        proxy.scrollTo(editing, anchor: .center)
                        focused = editing
                    }
                }
            }
            HStack(spacing: 4) {
                Text("Corrections are saved in")
                Button("history.json") { NSWorkspace.shared.activateFileViewerSelecting([store.fileURL]) }
                    .buttonStyle(.link)
                    .help("Show in Finder")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(24)
        .searchable(text: $search, placement: .toolbar, prompt: "Search corrections")
    }

    /// Corrections, plus the one you're typing in even while it's empty (emptied ones go when you leave them).
    private var shown: [HistoryEntry] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return store.entries.filter { entry in
            (entry.correction != nil || entry.id == focused)
                && (q.isEmpty || entry.text.localizedCaseInsensitiveContains(q)
                    || (entry.correction ?? "").localizedCaseInsensitiveContains(q))
        }
    }
}

struct CorrectionCard: View {
    let entry: HistoryEntry
    var focused: FocusState<UUID?>.Binding
    let onChange: (String) -> Void
    let onDelete: () -> Void
    @State private var draft: String

    init(entry: HistoryEntry, focused: FocusState<UUID?>.Binding,
         onChange: @escaping (String) -> Void, onDelete: @escaping () -> Void) {
        self.entry = entry
        self.focused = focused
        self.onChange = onChange
        self.onDelete = onDelete
        _draft = State(initialValue: entry.correction ?? entry.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(entry.date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                if let about { Text(about).padding(.horizontal, 8).padding(.vertical, 1).background(.quaternary, in: Capsule()) }
                Spacer()
                Button(action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Delete correction")
                    .accessibilityLabel("Delete correction")
                    .accessibilityIdentifier("corrections.delete")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 14) {
                Text(written)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(8)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("App wrote")
                    .accessibilityValue(entry.text)
                TextEditor(text: $draft)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                    .focused(focused, equals: entry.id)
                    .accessibilityLabel("You want")
                    .accessibilityIdentifier("corrections.wanted")
                    .onChange(of: draft) { onChange(draft) }
            }
            if let raw = entry.raw {
                DisclosureGroup("Before polish") {
                    Text(raw).font(.callout.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.background.secondary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("corrections.card")
    }

    /// "Cloud Flash · prompt v3".
    private var about: String? {
        guard let id = entry.setup else { return nil }
        let title = DictationSetup.builtIns.first { $0.id == id }?.title ?? id
        return entry.prompt.map { "\(title) · prompt \(URL(fileURLWithPath: $0).lastPathComponent)" } ?? title
    }

    /// What the app wrote, with the words you changed in orange.
    private var written: AttributedString {
        var text = AttributedString(entry.text)
        for range in WordDiff.changed(from: entry.text, to: draft) {
            guard let r = Range(range, in: text) else { continue }
            text[r].backgroundColor = .orange.opacity(0.25)
            text[r].foregroundColor = .orange
        }
        return text
    }
}
