import AppKit
import Combine
import SwiftUI

/// Dictations you corrected: what the app wrote, and what you wanted. Each one is a test case for
/// AI polish (`bench/suite.py polish run --corrections`); they live on their History entries.
struct CorrectionsView: View {
    @ObservedObject var store: HistoryStore
    @ObservedObject var suggester: CorrectionSuggester = .off
    /// Learns the polish prompt from these corrections (`LearnView`); nil hides the tile.
    var learn: LearnController?
    /// The correction to put the cursor in when the tab opens (the one just made from History).
    var editing: UUID?
    /// What's typed in the toolbar's search field (MainView).
    var search = ""
    @FocusState private var focused: UUID?
    /// Bumped as `learn` changes, so the cards' fits follow a tune (the controller is optional, so it can't be observed directly).
    @State private var learnChanges = 0

    var body: some View {
        let _ = learnChanges  // read here so a tune's progress re-renders the cards' fits
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Corrections").font(.largeTitle.bold())
                Text("Teach the app the way you speak.").foregroundStyle(.secondary)
            }
            if let learn { LearnView(controller: learn) }
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
                                               suggesting: suggester.pending.contains(entry.id),
                                               suggestionError: suggester.failed[entry.id],
                                               fit: learn?.fit(for: entry.id),
                                               onChange: { store.setCorrection($0, for: entry.id) },
                                               onDelete: { store.setCorrection("", for: entry.id) })
                                    .id(entry.id)
                            }
                        }
                    }
                    .overlay { if let learn { SweepOverlay(trigger: learn.sweep) } }
                    .onTabShown {
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
        // Kept hidden behind the other tabs (MainView), so a card mustn't keep the keyboard.
        .onTabHidden { focused = nil }
        .onReceive(learn?.objectWillChange.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { _ in
            DispatchQueue.main.async { learnChanges += 1 }
        }
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
    @Environment(\.dateContext) private var dates
    let entry: HistoryEntry
    var focused: FocusState<UUID?>.Binding
    var suggesting = false
    var suggestionError: String?
    /// How far off this dictation was before and after the learned prompt ("v4 38% off → v5 9% off").
    var fit: LearnController.Fit?
    let onChange: (String) -> Void
    let onDelete: () -> Void
    @State private var draft: String

    init(entry: HistoryEntry, focused: FocusState<UUID?>.Binding, suggesting: Bool = false, suggestionError: String? = nil,
         fit: LearnController.Fit? = nil, onChange: @escaping (String) -> Void, onDelete: @escaping () -> Void) {
        self.entry = entry
        self.focused = focused
        self.suggesting = suggesting
        self.suggestionError = suggestionError
        self.fit = fit
        self.onChange = onChange
        self.onDelete = onDelete
        _draft = State(initialValue: entry.correction ?? entry.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(dates.string(entry.date, .dateTime.month(.abbreviated).day().hour().minute()))
                if let about { Text(about).padding(.horizontal, 8).padding(.vertical, 1).background(.quaternary, in: Capsule()) }
                Spacer()
                if let fit {
                    HStack(spacing: 5) {
                        Text("\(fit.from) \(Int((fit.before * 100).rounded()))% off")
                        Text("→").foregroundStyle(.tertiary)
                        Text("\(fit.to) \(Int((fit.now * 100).rounded()))% off")
                            .fontWeight(fit.learned ? .semibold : .medium)
                            .foregroundStyle(fit.learned ? LearnView.good : .secondary)
                        if fit.learned {
                            Text("learned").font(.caption2.weight(.semibold)).foregroundStyle(LearnView.good)
                                .padding(.horizontal, 6).padding(.vertical, 1).background(LearnView.good.opacity(0.16), in: Capsule())
                        }
                    }
                    .monospacedDigit()
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("corrections.fit")
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
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
                    // A scroll bar showing up narrows the text, which can re-wrap it and hide the bar again,
                    // around and around, when a line ends right at the edge (the card hung the test).
                    .scrollIndicators(.never)
                    .padding(4)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                    .focused(focused, equals: entry.id)
                    .accessibilityLabel("You want")
                    .accessibilityIdentifier("corrections.wanted")
                    .onChange(of: draft) { onChange(draft) }
                    .onChange(of: entry.correction) {
                        if let correction = entry.correction, correction != draft { draft = correction }
                    }
            }
            if suggesting {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("\(CorrectionSuggester.modelName) is polishing a suggestion…")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("corrections.suggesting")
            } else if let suggestionError {
                Text("Couldn't get \(CorrectionSuggester.modelName)'s suggestion: \(suggestionError)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("corrections.suggestionError")
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
        .animation(.spring(duration: 0.5), value: fit)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("corrections.card")
    }

    /// "Cloud Flash · prompt v3".
    private var about: String? {
        guard let id = entry.setup else { return nil }
        let title = DictationSetup.builtIns.first { $0.id == DictationSetup.currentID(id) }?.title ?? id
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
