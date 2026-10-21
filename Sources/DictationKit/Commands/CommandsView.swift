import AppKit
import SwiftUI

/// The Commands tab: your commands (the folder's scripts: on or off, deleted, how each has gone)
/// and the built-in ones, searched from the toolbar and yours sorted by name or last use, so a
/// growing list stays easy to manage. Command mode itself is switched on in Settings.
struct CommandsView: View {
    let mode: CommandMode
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: HistoryStore
    var search = ""
    var onOpenSettings: (() -> Void)?
    /// Where a deleted script goes (tests: removed, so nothing lands in your Trash).
    var trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    @StateObject private var list = CommandsInFolder()
    @State private var order = Order.name
    /// The script whose delete is being confirmed, in its row.
    @State private var deleting: URL?

    private var folder: URL { mode.folder }

    enum Order: String, CaseIterable {
        case name = "Name", recent = "Last used"
    }

    var body: some View {
        let usage = Usage(history.commands)
        let yours = sorted(matching(list.commands.filter { $0.script != nil } + list.disabled), usage)
        let builtIn = matching(list.commands.filter { $0.script == nil })
        Form {
            if !settings.commandModeOn {
                Section {
                    HStack {
                        Label("Command mode is off", systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                        Spacer()
                        Button("Turn It On in Settings") { onOpenSettings?() }
                            .accessibilityIdentifier("commands.openSettings")
                    }
                }
            }
            Section {
                if yours.isEmpty {
                    Text(search.isEmpty ? "None yet. Say “create command” and what it should do, or add a Python script to the folder."
                                        : "None of yours matches “\(search)”.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("commands.yours.empty")
                }
                ForEach(yours, id: \.self) { command in
                    CommandListRow(command: command, usage: usage[command.name], on: !list.disabled.contains(command),
                               deleting: $deleting, folder: folder, onChange: reload, onDelete: delete)
                }
            } header: {
                HStack {
                    Text("Yours (\(yours.count))")
                    Spacer()
                    Picker("Sort", selection: $order) {
                        ForEach(Order.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("commands.sort")
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    }
                    if FileManager.default.fileExists(atPath: CommandLog(folder: folder).file.path) {
                        Button("Error Log") { NSWorkspace.shared.open(CommandLog(folder: folder).file) }
                            .help("Every command that failed, with all it printed")
                    }
                }
            } footer: {
                Text("A command is a Python script: its docstring's first line says what it does, and lines under “Choices:” what it can be told (value: meaning). It's run with uv. Say “fix” and a command's name, and what goes wrong, to have Claude Code fix it.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Built in (\(builtIn.count))") {
                ForEach(builtIn, id: \.self) { command in
                    CommandListRow(command: command, usage: usage[command.name], on: true, deleting: $deleting, folder: folder,
                               onChange: reload, onDelete: delete)
                }
            }
        }
        .formStyle(.grouped)
        .onTabShown(perform: reload)
    }

    private func reload() { list.load(mode) }

    private func delete(_ script: URL) {
        try? trash(script)
        deleting = nil
        reload()
    }

    /// The commands whose name, description or choices have `search` in them.
    private func matching(_ commands: [Command]) -> [Command] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return commands }
        return commands.filter { command in
            ([command.name, command.summary] + (command.choicesFromThisMac ? [] : command.choices.map(\.value)))
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private func sorted(_ commands: [Command], _ usage: Usage) -> [Command] {
        switch order {
        case .name: return commands.sorted { $0.name < $1.name }
        case .recent:
            return commands.sorted {
                let (a, b) = (usage[$0.name]?.last.date ?? .distantPast, usage[$1.name]?.last.date ?? .distantPast)
                return a != b ? a > b : $0.name < $1.name
            }
        }
    }
}

/// How each command has gone, from History: how many times it ran, and its last run.
struct Usage {
    struct Entry {
        var count: Int
        var last: CommandRun
    }

    private var entries: [String: Entry] = [:]

    /// `runs`: newest first, as History keeps them.
    init(_ runs: [CommandRun]) {
        for run in runs {
            guard let name = run.command else { continue }
            if entries[name] == nil { entries[name] = Entry(count: 0, last: run) }
            entries[name]?.count += 1
        }
    }

    subscript(name: String) -> Entry? { entries[name] }
}

/// One command: what it does and can be told, how it's gone, and for a script a switch and delete
/// (confirmed in the row, then to the Trash).
private struct CommandListRow: View {
    let command: Command
    let usage: Usage.Entry?
    let on: Bool
    @Binding var deleting: URL?
    let folder: URL
    let onChange: () -> Void
    let onDelete: (URL) -> Void
    @Environment(\.dateContext) private var dates

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: command.script == nil ? "sparkle" : "chevron.forward")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tint)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(command.name).font(.body.weight(.medium))
                    if !on { Text("off").font(.caption2.weight(.semibold)).foregroundStyle(.secondary) }
                }
                Text(command.summary + (command.choosesAnApp ? " (\(command.choices.count - 1) apps)" : ""))
                    .font(.callout).foregroundStyle(.secondary)
                if command.script != nil, !command.choices.isEmpty {
                    Text(command.choices.map(\.value).joined(separator: "  "))
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                        .help(command.choices.map { "\($0.value): \($0.meaning)" }.joined(separator: "\n"))
                }
                usageLine
            }
            Spacer()
            if let script = command.script { controls(script) }
        }
        .opacity(on ? 1 : 0.5)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("command." + command.name)
    }

    @ViewBuilder private var usageLine: some View {
        if let usage {
            let when = dates.string(usage.last.date, Date.FormatStyle(date: .abbreviated, time: .shortened))
            HStack(spacing: 5) {
                Circle().fill(usage.last.ok ? Color.green : Color.red).frame(width: 6, height: 6)
                Text("Used \(usage.count)× · last \(when)" + (usage.last.ok ? "" : " · failed: \(usage.last.result)"))
                    .lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(usage.last.ok ? Color.secondary : Color.red)
            }
            .font(.caption)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("command.usage." + command.name)
        }
    }

    @ViewBuilder private func controls(_ script: URL) -> some View {
        if deleting == script {
            HStack(spacing: 8) {
                Text("Delete “\(command.name)”?").font(.callout)
                Button("Cancel") { deleting = nil }
                    .accessibilityIdentifier("command.cancelDelete." + command.name)
                Button("Move to Trash") { onDelete(script) }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .accessibilityIdentifier("command.confirmDelete." + command.name)
            }
        } else {
            Toggle(command.name, isOn: Binding(get: { on }, set: { enable in
                _ = try? Command.setEnabled(enable, script: script, folder: folder)
                onChange()
            }))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityIdentifier("command.switch." + command.name)
            Button { deleting = script } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Delete")
                .accessibilityLabel("Delete \(command.name)")
                .accessibilityIdentifier("command.delete." + command.name)
        }
    }
}

/// The folder's commands, on and off, read again whenever a script is added, removed or renamed
/// there (a "create command", a script you save, a switch), so the list is never stale.
final class CommandsInFolder: ObservableObject {
    @Published private(set) var commands: [Command] = []
    @Published private(set) var disabled: [Command] = []
    private var watcher: FolderWatcher?

    func load(_ mode: CommandMode) {
        commands = mode.commands
        disabled = Command.disabled(in: mode.folder)
        // Made afresh each time, so a folder that has only just appeared (Disabled) is watched too.
        watcher = FolderWatcher([mode.folder, Command.disabledFolder(mode.folder)]) { [weak self, weak mode] in
            if let mode { self?.load(mode) }
        }
    }
}
