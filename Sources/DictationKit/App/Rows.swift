import SwiftUI

/// The time column a History row starts with: "9:41 AM", in a fixed width so the text lines up.
struct RowTime: View {
    let date: Date
    @Environment(\.dateContext) private var dates

    var body: some View {
        Text(dates.string(date, Date.FormatStyle(date: .omitted, time: .shortened)))
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 70, alignment: .leading)
    }
}

/// A small symbol button at the end of a row (copy, correct, run again). Faint until the row is
/// hovered rather than invisible: fully transparent views drop out of accessibility, which would
/// hide the button from VoiceOver. `label`: for VoiceOver, when it should differ from `help`.
struct RowIconButton: View {
    let symbol: String
    let help: String
    var label: String? = nil
    /// Its accessibility identifier.
    let id: String
    var opacity: Double = 1
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 16, height: 16)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(label ?? help)
        .accessibilityIdentifier(id)
        .opacity(opacity)
    }
}
