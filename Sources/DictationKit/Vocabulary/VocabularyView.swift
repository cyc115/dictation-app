import AppKit
import SwiftUI

/// The Vocabulary tab: add a term (and, optionally, what the app writes instead); the terms seen in
/// your corrections, on their way in (Add now, dismiss); and yours: each with its variants, where it
/// came from, how often it fired, a switch and delete. Click a term or a variant to edit it.
/// Searched from the toolbar. Settings › Vocabulary turns it on or off.
struct VocabularyView: View {
    @ObservedObject var store: VocabularyStore
    /// Dictations a term is learned after (`vocabularyLearnAfter`): the "of 3" in "2 of 3".
    var learnAfter = 3
    /// Use vocabulary is on, so terms are learned on their own.
    var learning = true
    /// What's typed in the toolbar's search field (MainView).
    var search = ""
    @State private var term = ""
    @State private var heard = ""
    /// The entry whose delete is being confirmed, in its row.
    @State private var deleting: UUID?
    /// The entry being edited, in its row.
    @State private var editing: UUID?
    /// Seen in your edits also lists the terms seen once.
    @State private var showAllCandidates = false

    var body: some View {
        let shown = matching
        Form {
            if let problem = store.problem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        .accessibilityIdentifier("vocabulary.problem")
                }
            }
            Section {
                HStack(spacing: 8) {
                    TextField("Term", text: $term, prompt: Text("Term, as you want it written"))
                        .accessibilityIdentifier("vocabulary.add.term")
                    TextField("Heard as", text: $heard, prompt: Text("Heard as (optional): G Four Snow, g force now"))
                        .accessibilityIdentifier("vocabulary.add.heard")
                    Button("Add", action: add)
                        .disabled(term.trimmingCharacters(in: .whitespaces).isEmpty)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("vocabulary.add")
                }
                .labelsHidden()
                .onSubmit(add)
            } header: {
                Text("Add a term")
            } footer: {
                Text("Names, products and jargon the app gets wrong. What it hears instead is replaced with the term in every dictation, and AI polish is told the terms.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            candidatesSection
            Section {
                if shown.isEmpty {
                    Text(store.entries.isEmpty ? "None yet. Add a term above, or from Terminal: DictationApp vocabulary add."
                                               : "None matches “\(search)”.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("vocabulary.empty")
                }
                ForEach(shown) { entry in
                    VocabularyRow(entry: entry, store: store, deleting: $deleting, editing: $editing)
                }
            } header: {
                Text("Your terms (\(store.entries.count))")
            } footer: {
                HStack(spacing: 4) {
                    Text("Saved in")
                    Button("vocabulary.json") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
                    }
                    .buttonStyle(.link)
                    .disabled(!FileManager.default.fileExists(atPath: store.fileURL.path))
                    .help("Show in Finder")
                    .accessibilityIdentifier("vocabulary.file")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onTabShown { store.reloadIfChanged() }
    }

    private func add() {
        guard store.add(term: term, heardAs: VocabularyEntry.variants(from: heard)) != nil else { return }
        term = ""
        heard = ""
    }

    /// Seen in your edits: candidates seen in 2+ dictations or judged misheard, the rest behind Show
    /// all. Not shown with none.
    @ViewBuilder private var candidatesSection: some View {
        let all = candidates
        let listed = all.filter { $0.seen >= 2 || $0.misheard }
        let shown = showAllCandidates ? all : listed
        if !all.isEmpty {
            Section {
                ForEach(shown) { candidate in
                    VocabularyCandidateRow(candidate: candidate, learnAfter: max(learnAfter, 1), store: store)
                }
                if all.count > listed.count {
                    Button(showAllCandidates ? "Show fewer" : "Show all (\(all.count))") { showAllCandidates.toggle() }
                        .buttonStyle(.link)
                        .accessibilityIdentifier("vocabulary.candidates.showAll")
                }
            } header: {
                Text("Seen in your edits")
            } footer: {
                Text(learning ? "Words you fixed in Corrections. A term fixed in \(max(learnAfter, 1)) dictations is added on its own."
                              : "Words you fixed in Corrections. Use vocabulary is off, so none is added on its own.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// Not dismissed or added yet, most seen first; those matching `search`.
    private var candidates: [VocabularyCandidate] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let open = store.candidates.filter { !$0.dismissed && !$0.added && ($0.seen > 0 || $0.misheard) }.filter { candidate in
            query.isEmpty || ([candidate.term] + candidate.heard.map(\.text)).contains { $0.localizedCaseInsensitiveContains(query) }
        }
        return open.enumerated().sorted { $0.element.seen != $1.element.seen ? $0.element.seen > $1.element.seen : $0.offset < $1.offset }.map(\.element)
    }

    /// Newest first; those whose term or variants have `search` in them.
    private var matching: [VocabularyEntry] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return store.entries.reversed().filter { entry in
            query.isEmpty || ([entry.term] + entry.heardAs).contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }
}

/// A term seen in your edits: what you wrote, what the app wrote instead (an ordinary word struck
/// through: it won't be a variant), how far it is from being learned, Add now and dismiss.
private struct VocabularyCandidateRow: View {
    let candidate: VocabularyCandidate
    let learnAfter: Int
    let store: VocabularyStore

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(candidate.term).font(.body.weight(.medium))
                ChipFlow(spacing: 4) {
                    ForEach(candidate.heard, id: \.text) { heard in
                        Chip(text: heard.text, struck: heard.ordinary)
                            .help(heard.ordinary ? "“\(heard.text)” is an ordinary word in your dictations, so it won't be replaced"
                                                 : "The app wrote “\(heard.text)”")
                            .accessibilityIdentifier("vocabulary.candidate.heard." + heard.text)
                    }
                }
                Text(progress).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("vocabulary.candidate.seen." + candidate.term)
            }
            Spacer()
            Button("Add now") { store.learn(candidate.id) }
                .controlSize(.small)
                .accessibilityIdentifier("vocabulary.addNow." + candidate.term)
            Button { store.dismiss(candidate.id) } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Dismiss: never add it")
                .accessibilityLabel("Dismiss \(candidate.term)")
                .accessibilityIdentifier("vocabulary.dismiss." + candidate.term)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vocabulary.candidate." + candidate.term)
    }

    /// "2 of 3": seen in 2 of the 3 dictations it takes; past that (Use vocabulary off), how many.
    private var progress: String {
        candidate.seen < learnAfter ? "\(candidate.seen) of \(learnAfter)" : "Seen in \(candidate.seen) dictations"
    }
}

/// A variant: small text in a capsule.
private struct Chip: View {
    let text: String
    var struck = false

    var body: some View {
        Text(text)
            .strikethrough(struck)
            .font(.caption)
            .foregroundStyle(struck ? .secondary : .primary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.08), in: Capsule())
    }
}

/// One term: the term, its variants as chips, where it came from and how often it fired, a switch
/// and delete (confirmed in the row). Clicking the term or a chip edits it in place.
private struct VocabularyRow: View {
    let entry: VocabularyEntry
    let store: VocabularyStore
    @Binding var deleting: UUID?
    @Binding var editing: UUID?
    @Environment(\.dateContext) private var dates
    @State private var term = ""
    @State private var heard = ""

    var body: some View {
        Group {
            if editing == entry.id { editor } else { row }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vocabulary.row." + entry.term)
    }

    private var row: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Button(entry.term, action: edit)
                    .buttonStyle(.plain)
                    .font(.body.weight(.medium))
                    .help("Edit")
                    .accessibilityIdentifier("vocabulary.term." + entry.term)
                if !entry.heardAs.isEmpty {
                    ChipFlow(spacing: 4) {
                        ForEach(entry.heardAs, id: \.self) { variant in
                            Button(action: edit) { Chip(text: variant) }
                            .buttonStyle(.plain)
                            .help("Heard as “\(variant)”. Click to edit")
                            .accessibilityIdentifier("vocabulary.chip." + variant)
                        }
                    }
                }
                Text(details).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("vocabulary.details." + entry.term)
            }
            Spacer()
            controls
        }
        .opacity(entry.enabled ? 1 : 0.5)
    }

    /// "You added · used 9 times", "Learned Nov 18 · not used yet".
    private var details: String {
        let source = entry.source == .manual ? "You added"
            : "Learned \(dates.string(entry.added, .dateTime.month(.abbreviated).day()))"
        let uses = entry.uses == 0 ? "not used yet" : "used \(entry.uses) time\(entry.uses == 1 ? "" : "s")"
        return source + " · " + uses
    }

    @ViewBuilder private var controls: some View {
        if deleting == entry.id {
            HStack(spacing: 8) {
                Text("Delete “\(entry.term)”?").font(.callout)
                Button("Cancel") { deleting = nil }
                    .accessibilityIdentifier("vocabulary.cancelDelete." + entry.term)
                Button("Delete") { store.remove(id: entry.id); deleting = nil }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .accessibilityIdentifier("vocabulary.confirmDelete." + entry.term)
            }
        } else {
            Toggle(entry.term, isOn: Binding(get: { entry.enabled }, set: { store.setEnabled($0, for: entry.id) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityIdentifier("vocabulary.switch." + entry.term)
            Button { deleting = entry.id } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Delete")
                .accessibilityLabel("Delete \(entry.term)")
                .accessibilityIdentifier("vocabulary.delete." + entry.term)
        }
    }

    private var editor: some View {
        HStack(spacing: 8) {
            TextField("Term", text: $term)
                .accessibilityIdentifier("vocabulary.edit.term")
            TextField("Heard as", text: $heard, prompt: Text("Heard as, comma-separated"))
                .accessibilityIdentifier("vocabulary.edit.heard")
            Button("Cancel") { editing = nil }
                .accessibilityIdentifier("vocabulary.edit.cancel")
            Button("Save", action: save)
                .buttonStyle(.borderedProminent)
                .disabled(term.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("vocabulary.edit.save")
        }
        .labelsHidden()
        .onSubmit(save)
    }

    private func edit() {
        term = entry.term
        heard = entry.heardAs.joined(separator: ", ")
        deleting = nil
        editing = entry.id
    }

    private func save() {
        let trimmed = term.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var changed = entry
        changed.term = trimmed
        changed.heardAs = VocabularyEntry.variants(from: heard)
        store.update(changed)
        editing = nil
    }
}

/// Chips left to right, wrapping onto the next line when the row is full.
private struct ChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if let last = rows.last, last.width + spacing + size.width <= width {
                rows[rows.count - 1].items.append(index)
                rows[rows.count - 1].width += spacing + size.width
                rows[rows.count - 1].height = max(last.height, size.height)
            } else {
                rows.append(([index], size.width, size.height))
            }
        }
        return rows
    }
}
