import SwiftUI

/// Your recent dictations' waits (stop → text) one by one, and which models gave them: for finding
/// a slow model or a slow spell. Home shows it when Settings → Show detailed analytics is on.
struct RecentLatency {
    enum Window: String, CaseIterable, Identifiable {
        case tenMinutes, thirtyMinutes, last25

        var id: String { rawValue }

        var title: String {
            switch self {
            case .tenMinutes: return "10 min"
            case .thirtyMinutes: return "30 min"
            case .last25: return "Last 25"
            }
        }
    }

    struct Row: Identifiable {
        let id: UUID
        let date: Date
        let speaking: TimeInterval
        let transcribing: TimeInterval
        let polishing: TimeInterval?
        let transcribedByBackup: Bool
        let polishedByBackup: Bool

        /// Stop → text: what you waited for.
        var wait: TimeInterval { transcribing + (polishing ?? 0) }
    }

    enum Phase: String {
        case speech = "Speech"
        case polish = "Polish"
    }

    /// One model's share of a phase in the window.
    struct ModelStats: Identifiable {
        let phase: Phase
        let model: String
        let isBackup: Bool
        /// A main model: the dictations it was asked for. A backup: the times it was asked.
        let asked: Int
        /// The times its answer was used.
        let answered: Int
        /// Of the answers used.
        let typical: TimeInterval?
        let slowest: TimeInterval?

        var id: String { "\(phase.rawValue)|\(model)|\(isBackup)" }
    }

    /// Newest first.
    let rows: [Row]
    let models: [ModelStats]

    /// Timed dictations only (History is newest first).
    init(_ entries: [HistoryEntry], window: Window, now: Date) {
        let timed = entries.filter { $0.transcribeSeconds != nil }
        let picked: [HistoryEntry]
        switch window {
        case .tenMinutes: picked = timed.filter { now.timeIntervalSince($0.date) <= 10 * 60 }
        case .thirtyMinutes: picked = timed.filter { now.timeIntervalSince($0.date) <= 30 * 60 }
        case .last25: picked = Array(timed.prefix(25))
        }
        rows = picked.map {
            Row(id: $0.id, date: $0.date, speaking: $0.duration, transcribing: $0.transcribeSeconds ?? 0,
                polishing: $0.polishSeconds, transcribedByBackup: $0.transcribedBy?.byBackup == true,
                polishedByBackup: $0.polishedBy?.byBackup == true)
        }
        models = Self.stats(.speech, picked.compactMap { e in e.transcribedBy.map { ($0, e.transcribeSeconds ?? 0) } })
            + Self.stats(.polish, picked.compactMap { e in e.polishedBy.flatMap { by in e.polishSeconds.map { (by, $0) } } })
    }

    var typicalWait: TimeInterval? { TimeBreakdown.median(rows.map(\.wait)) }
    var slowestWait: TimeInterval? { rows.map(\.wait).max() }
    var typicalTranscribing: TimeInterval? { TimeBreakdown.median(rows.map(\.transcribing)) }
    var typicalPolishing: TimeInterval? { TimeBreakdown.median(rows.compactMap(\.polishing)) }

    func count(slowerThan seconds: TimeInterval) -> Int { rows.filter { $0.wait > seconds }.count }

    /// A phase's main models, then its backups; the most asked first.
    static func stats(_ phase: Phase, _ answers: [(by: ModelAnswer, seconds: TimeInterval)]) -> [ModelStats] {
        func group(backup: Bool) -> [ModelStats] {
            let key: (ModelAnswer) -> String? = { backup ? $0.backup : $0.main }
            return Dictionary(grouping: answers.filter { key($0.by) != nil }, by: { key($0.by)! })
                .map { model, list in
                    let used = list.filter { $0.by.byBackup == backup }.map(\.seconds)
                    return ModelStats(phase: phase, model: model, isBackup: backup, asked: list.count, answered: used.count,
                                      typical: TimeBreakdown.median(used), slowest: used.max())
                }
                .sorted { $0.asked != $1.asked ? $0.asked > $1.asked : $0.model < $1.model }
        }
        return group(backup: false) + group(backup: true)
    }

    /// "3.1× slower than usual" from 1.5 times the usual, else "normal".
    static func comparison(_ recent: TimeInterval, usual: TimeInterval) -> String {
        let ratio = recent / max(usual, 0.01)
        return ratio >= 1.5 ? String(format: "%.1f× slower than usual", ratio) : "normal"
    }
}

// MARK: - View

struct RecentLatencyView: View {
    let entries: [HistoryEntry]
    /// Your typical dictation over the last 100, to compare with.
    var usual: TimeBreakdown?
    /// Seconds before the speech backup is asked, marked on the bars; nil when there's no backup.
    var backupWait: TimeInterval?
    /// Fixed in tests; otherwise the window follows the clock.
    var now: Date?
    @State var window: RecentLatency.Window = .thirtyMinutes
    @Environment(\.dateContext) private var dates

    /// Waits over this count as slow, over `verySlow` very slow (red).
    static let slow: TimeInterval = 3
    static let verySlow: TimeInterval = 8
    /// A bar's full width; longer waits are cut off there (their number still shows).
    static let scale: TimeInterval = 10

    private static let transcribing = Color(nsColor: .systemPurple)
    private static let polishing = Color(nsColor: .systemOrange)

    var body: some View {
        if let now { content(now) } else { TimelineView(.everyMinute) { content($0.date) } }
    }

    private func content(_ now: Date) -> some View {
        let latency = RecentLatency(entries, window: window, now: now)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent dictations").font(.title2.bold())
                    Text(subtitle(latency.rows.count)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Picker("Window", selection: $window) {
                    ForEach(RecentLatency.Window.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("recent.window")
            }
            .padding(.top, 8)
            if latency.rows.isEmpty {
                Text("No dictations in this time. Pick a longer window, or dictate something.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityIdentifier("recent.empty")
            } else {
                Grid(horizontalSpacing: 10) {
                    GridRow {
                        stat(TimeBreakdownView.number(latency.typicalWait ?? 0), "sec", "Typical wait, stop to text", id: "typical")
                        stat(TimeBreakdownView.number(latency.slowestWait ?? 0), "sec", "Slowest wait", id: "slowest")
                        stat(String(latency.count(slowerThan: Self.slow)), "of \(latency.rows.count)",
                             "Waited over \(Int(Self.slow)) seconds", id: "slow")
                    }
                }
                waits(latency)
                if !latency.models.isEmpty { models(latency.models) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recent")
    }

    private func subtitle(_ count: Int) -> String {
        let dictations = count == 1 ? "1 dictation" : "\(count) dictations"
        switch window {
        case .last25: return "Your last \(dictations), newest first"
        default: return "\(dictations) in the last \(window.title), newest first"
        }
    }

    private func stat(_ value: String, _ unit: String, _ caption: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 22, weight: .bold, design: .rounded))
                Text(unit).font(.system(size: 12, weight: .semibold))
            }
            Text(caption).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("recent." + id)
    }

    // MARK: Waits

    private func waits(_ latency: RecentLatency) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let usual {
                VStack(alignment: .leading, spacing: 5) {
                    if let recent = latency.typicalTranscribing {
                        comparison("Transcribing", recent, usual: usual.transcribing, color: Self.transcribing)
                    }
                    if let recent = latency.typicalPolishing, let usualPolish = usual.polishing {
                        comparison("Polishing", recent, usual: usualPolish, color: Self.polishing)
                    }
                }
                Divider()
            }
            legend
            HStack(spacing: 10) {
                Text("Stopped").frame(width: 64, alignment: .leading)
                Text("Spoke").frame(width: 44, alignment: .leading)
                HStack {
                    Text("0"); Spacer(); Text("5 s"); Spacer(); Text("\(Int(Self.scale)) s+")
                }
                Text("Wait").frame(width: 52, alignment: .trailing)
                Text("Backup").frame(width: 92, alignment: .leading)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            VStack(spacing: 2) {
                ForEach(latency.rows) { row(_: $0) }
            }
            Text("Each line is one dictation: the wait after you stopped, split into its parts. Speaking time isn't drawn, so a long dictation doesn't hide a slow model.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func comparison(_ part: String, _ recent: TimeInterval, usual: TimeInterval, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(part) \(RecentLatency.comparison(recent, usual: usual))").fontWeight(.semibold)
            Text("\(TimeBreakdownView.number(recent)) s here, \(TimeBreakdownView.number(usual)) s over your last 100")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("recent.compare." + part)
    }

    private var legend: some View {
        HStack(spacing: 16) {
            swatch(Self.transcribing, "Transcribing")
            swatch(Self.polishing, "Polishing")
            HStack(spacing: 6) {
                Rectangle().fill(Color.secondary).overlay(BackupStripes()).frame(width: 16, height: 8)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                Text("Answered by the backup")
            }
            if let backupWait {
                HStack(spacing: 6) {
                    DashedLine().stroke(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [2, 2])).frame(width: 1, height: 12)
                    Text("\(TimeBreakdownView.number(backupWait)) s: speech backup asked")
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func swatch(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title)
        }
    }

    private func row(_ row: RecentLatency.Row) -> some View {
        let wait = row.wait
        let color: Color = wait > Self.verySlow ? .red : wait > Self.slow ? .orange : .primary
        return HStack(spacing: 10) {
            Text(dates.string(row.date, .dateTime.hour().minute())).frame(width: 64, alignment: .leading)
            Text(row.speaking < 59.5 ? "\(Int(row.speaking.rounded())) s" : TimeBreakdownView.number(row.speaking))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            bar(row)
            Text(TimeBreakdownView.number(wait) + " s")
                .fontWeight(.bold)
                .foregroundStyle(color)
                .frame(width: 52, alignment: .trailing)
            Text(Self.backupLabel(row)).foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
        }
        .font(.callout.monospacedDigit())
        .frame(height: 26)
        .padding(.horizontal, 6)
        .background(wait > Self.verySlow ? Color.red.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, -6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("recent.row")
    }

    /// Which parts the backup answered: "speech", "polish", "speech, polish" or "".
    static func backupLabel(_ row: RecentLatency.Row) -> String {
        [row.transcribedByBackup ? "speech" : nil, row.polishedByBackup ? "polish" : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }

    private func bar(_ row: RecentLatency.Row) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            let transcribing = min(row.transcribing, Self.scale)
            let polishing = min(row.polishing ?? 0, Self.scale - transcribing)
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.primary.opacity(0.1))
                HStack(spacing: 2) {
                    segment(Self.transcribing, width: width * transcribing / Self.scale, byBackup: row.transcribedByBackup)
                    if polishing > 0 {
                        segment(Self.polishing, width: width * polishing / Self.scale, byBackup: row.polishedByBackup)
                    }
                }
                if let backupWait, backupWait < Self.scale {
                    DashedLine()
                        .stroke(Color.primary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                        .frame(width: 1)
                        .offset(x: width * backupWait / Self.scale)
                }
            }
        }
        .frame(height: 12)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func segment(_ color: Color, width: CGFloat, byBackup: Bool) -> some View {
        Rectangle().fill(color)
            .overlay { if byBackup { BackupStripes() } }
            .frame(width: max(width, 3))
            .clipped()
    }

    // MARK: Models

    private func models(_ models: [RecentLatency.ModelStats]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Models").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text("Model")
                    Text("Answered")
                    Text("Typical").gridColumnAlignment(.trailing)
                    Text("Slowest").gridColumnAlignment(.trailing)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Divider()
                ForEach(models) { model in
                    GridRow {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle().fill(model.phase == .speech ? Self.transcribing : Self.polishing).frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ModelAnswer.displayName(model.model)).fontWeight(.semibold)
                                Text("\(model.phase.rawValue) · \(model.isBackup ? "backup" : "main")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("recent.model")  // on one cell: a GridRow's modifiers go to each
                        VStack(alignment: .leading, spacing: 4) {
                            Text(Self.answered(model)).font(.callout)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.primary.opacity(0.1))
                                    Capsule().fill(model.phase == .speech ? Self.transcribing : Self.polishing)
                                        .frame(width: geo.size.width * CGFloat(model.answered) / CGFloat(max(model.asked, 1)))
                                }
                            }
                            .frame(width: 150, height: 5)
                        }
                        Text(model.typical.map { TimeBreakdownView.number($0) + " s" } ?? "–").fontWeight(.bold)
                        Text(model.slowest.map { TimeBreakdownView.number($0) + " s" } ?? "–").fontWeight(.bold)
                            .foregroundStyle((model.slowest ?? 0) > Self.verySlow ? .red : (model.slowest ?? 0) > Self.slow ? .orange : .primary)
                    }
                    .font(.callout.monospacedDigit())
                }
            }
            Text("When the main model hasn't answered in time, the backup is asked too and the first answer is used. Typical is the middle value of the answers each model gave.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// "8 of 11 (73%)" for a main model; "Asked 8, first 3" for a backup.
    static func answered(_ model: RecentLatency.ModelStats) -> String {
        guard !model.isBackup else { return "Asked \(model.asked), first \(model.answered)" }
        let percent = Int((Double(model.answered) / Double(max(model.asked, 1)) * 100).rounded())
        return "\(model.answered) of \(model.asked) (\(percent)%)"
    }
}

/// Diagonal stripes over a bar segment the backup model answered.
private struct BackupStripes: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 5
            }
            context.stroke(path, with: .color(.black.opacity(0.4)), lineWidth: 1.5)
        }
    }
}

/// A vertical line, stroked dashed: where the speech backup is asked.
private struct DashedLine: Shape {
    func path(in rect: CGRect) -> Path {
        Path { $0.move(to: CGPoint(x: rect.minX, y: rect.minY)); $0.addLine(to: CGPoint(x: rect.minX, y: rect.maxY)) }
    }
}
