import Foundation
import SwiftUI

/// Running totals across all pasted dictations, saved in UserDefaults.
final class Insights: ObservableObject {
    static let shared = Insights()

    /// Typing speed used to estimate time saved.
    static let typingWPM: Double = 40

    private enum Key {
        static let words = "insights.words"
        static let seconds = "insights.seconds"
    }

    @Published private(set) var words: Int
    @Published private(set) var seconds: Double

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        words = defaults.integer(forKey: Key.words)
        seconds = defaults.double(forKey: Key.seconds)
    }

    /// Records one pasted dictation. `duration` is how long the mic was open.
    func record(text: String, duration: TimeInterval) {
        let count = Self.wordCount(text)
        guard count > 0 else { return }
        words += count
        seconds += max(duration, 0)
        defaults.set(words, forKey: Key.words)
        defaults.set(seconds, forKey: Key.seconds)
    }

    var wordsPerMinute: Int {
        seconds > 0 ? Int((Double(words) / (seconds / 60)).rounded()) : 0
    }

    /// Time typing these words would have taken, minus the time spent dictating.
    var secondsSaved: Double {
        max(Double(words) / Self.typingWPM * 60 - seconds, 0)
    }

    /// Counts words the way macOS segments text, so Chinese and mixed text count sensibly.
    static func wordCount(_ text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            count += 1
        }
        return count
    }
}

/// Where a typical dictation's time goes: you speaking, the speech model, AI polish. Each part is
/// the median of your last `limit` timed dictations, so a few very long or slow ones don't skew it.
struct TimeBreakdown: Equatable {
    let speaking: TimeInterval
    let transcribing: TimeInterval
    /// Median of the polished ones; nil when none were polished.
    let polishing: TimeInterval?
    /// Dictations it's based on.
    let count: Int

    var total: TimeInterval { speaking + transcribing + (polishing ?? 0) }

    /// nil until `minimum` dictations have times. Taps under a second aren't dictations.
    init?(_ entries: [HistoryEntry], limit: Int = 100, minimum: Int = 5) {
        let timed = Array(entries.filter { $0.transcribeSeconds != nil && $0.duration >= 1 }.prefix(limit))
        guard timed.count >= minimum else { return nil }
        speaking = Self.median(timed.map(\.duration))!
        transcribing = Self.median(timed.compactMap(\.transcribeSeconds))!
        polishing = Self.median(timed.compactMap(\.polishSeconds))
        count = timed.count
    }

    init(speaking: TimeInterval, transcribing: TimeInterval, polishing: TimeInterval?, count: Int) {
        self.speaking = speaking
        self.transcribing = transcribing
        self.polishing = polishing
        self.count = count
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted(), mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }
}

// MARK: - View

struct InsightsView: View {
    @ObservedObject var insights: Insights
    /// Shown under the totals once there are enough timed dictations.
    var breakdown: TimeBreakdown?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    card(parts: wordsParts, caption: "Words dictated")
                    card(parts: durationParts(insights.secondsSaved), caption: "Time saved")
                }
                GridRow {
                    card(parts: [(String(insights.wordsPerMinute), "WPM")], caption: "Average dictation speed")
                    card(parts: durationParts(insights.seconds), caption: "Total dictation time")
                }
            }
            if let breakdown { TimeBreakdownView(breakdown: breakdown) }
            Text("Time saved assumes typing at \(Int(Insights.typingWPM)) WPM.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var wordsParts: [(String, String)] {
        let n = insights.words
        if n < 1000 { return [(String(n), "words")] }
        return [(String(format: "%.1fK", Double(n) / 1000), "words")]
    }

    private func durationParts(_ seconds: Double) -> [(String, String)] {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return [(String(h), "hr"), (String(m), "min")] }
        if m > 0 { return [(String(m), "min"), (String(s), "sec")] }
        return [(String(s), "sec")]
    }

    private func card(parts: [(String, String)], caption: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    Text(part.0).font(.system(size: 22, weight: .bold, design: .rounded))
                    Text(part.1).font(.system(size: 12, weight: .semibold)).padding(.trailing, 4)
                }
            }
            Text(caption).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("insights." + caption)
    }
}

/// A typical dictation as one bar, like a disk's storage bar: speaking, transcribing, polishing.
struct TimeBreakdownView: View {
    let breakdown: TimeBreakdown

    private struct Part: Identifiable {
        let id: String
        let seconds: TimeInterval
        let color: Color
    }

    private var parts: [Part] {
        [Part(id: "Speaking", seconds: breakdown.speaking, color: Color(nsColor: .systemBlue)),
         Part(id: "Transcribing", seconds: breakdown.transcribing, color: Color(nsColor: .systemPurple))]
            + (breakdown.polishing.map { [Part(id: "Polishing", seconds: $0, color: Color(nsColor: .systemOrange))] } ?? [])
    }

    /// Every part at least this wide, so a quick polish still shows; speaking gives up the room.
    private static let minWidth: CGFloat = 6
    private static let gap: CGFloat = 2

    private func widths(in total: CGFloat) -> [CGFloat] {
        let room = total - Self.gap * CGFloat(parts.count - 1)
        let sum = max(breakdown.total, 0.001)
        var widths = parts.map { max(Self.minWidth, room * CGFloat($0.seconds / sum)) }
        widths[0] = max(Self.minWidth, room - widths.dropFirst().reduce(0, +))
        return widths
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(Self.number(breakdown.total)).font(.system(size: 22, weight: .bold, design: .rounded))
                Text("sec").font(.system(size: 12, weight: .semibold)).padding(.trailing, 4)
                Text("Typical dictation, start to pasted text").font(.callout).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                let widths = widths(in: geo.size.width)
                HStack(spacing: Self.gap) {
                    ForEach(Array(parts.enumerated()), id: \.element.id) { i, part in
                        Rectangle().fill(part.color).frame(width: widths[i])
                    }
                }
            }
            .frame(height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(parts.map { "\($0.id) \(Self.number($0.seconds)) seconds" }.joined(separator: ", "))
            .accessibilityIdentifier("insights.breakdown.bar")
            HStack(spacing: 18) {
                ForEach(parts) { part in
                    HStack(spacing: 6) {
                        Circle().fill(part.color).frame(width: 8, height: 8)
                        Text(part.id).foregroundStyle(.secondary)
                        Text(Self.number(part.seconds) + " s").fontWeight(.semibold).monospacedDigit()
                    }
                }
            }
            .font(.callout)
            Text("The middle value of each part over your last \(breakdown.count) dictations, so a few long or slow ones don't skew it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("insights.breakdown")
    }

    /// "15.8" under a minute, "1:05" from a minute.
    static func number(_ seconds: TimeInterval) -> String {
        guard seconds >= 59.95 else { return String(format: "%.1f", seconds) }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
