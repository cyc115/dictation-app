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

// MARK: - View

struct InsightsView: View {
    @ObservedObject var insights: Insights

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
