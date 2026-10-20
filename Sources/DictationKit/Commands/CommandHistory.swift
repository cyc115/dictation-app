import SwiftUI

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


extension CommandRun {
    /// How it went, for the pill: what the script printed ("Brightness 70%"); "Brightness didn't
    /// work" over why; or "Command not found" over what was heard, so you can tell a mishearing.
    var message: PillMessage {
        if ok { return PillMessage(title: result, tone: .done, seconds: 1.5) }
        if let name = command {
            return PillMessage(title: "\(name.prefix(1).uppercased() + name.dropFirst()) didn’t work", detail: result,
                               tone: .failed, seconds: 3)
        }
        return PillMessage(title: result, detail: "“\(said)”", tone: .failed, seconds: 2.5)
    }

    /// History's ↻ can run it again: a command ran, and it didn't write one.
    var canRunAgain: Bool { command != nil && command != Command.create.name }

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
            .disabled(!run.canRunAgain || onRunAgain == nil)
            .opacity(!run.canRunAgain ? 0 : hovering ? 1 : 0.3)
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
