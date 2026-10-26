import SwiftUI

extension View {
    /// The rounded card History, Insights, analytics and Learn are made of: `padding` inside.
    func tileBackground(padding: CGFloat = 14) -> some View {
        self.padding(padding)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// A number with its unit and a caption, as a card: "12 min / Time saved", "1 hr 5 min / Spoken".
struct StatTile: View {
    /// (value, unit) pairs, side by side.
    let parts: [(String, String)]
    let caption: String
    /// Its accessibility identifier.
    let id: String

    init(_ value: String, _ unit: String, caption: String, id: String) {
        self.init(parts: [(value, unit)], caption: caption, id: id)
    }

    init(parts: [(String, String)], caption: String, id: String) {
        self.parts = parts
        self.caption = caption
        self.id = id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                    Text(part.0).font(.system(size: 22, weight: .bold, design: .rounded))
                    Text(part.1).font(.system(size: 12, weight: .semibold))
                        .padding(.trailing, index < parts.count - 1 ? 4 : 0)
                }
            }
            Text(caption).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tileBackground()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }
}
