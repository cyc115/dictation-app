import SwiftUI

/// One Settings row: title and description on the left, control on the right. Every section uses it,
/// so a new setting is one `SettingRow` in its feature's section.
struct SettingRow<Control: View>: View {
    let title: String
    let detail: String
    let available: Bool
    /// A tag beside the title, like "Online · needs API key" for a feature that isn't on-device.
    let badge: String?
    let control: Control

    /// `available: false` greys out the whole row (not just the control) and labels it, so it
    /// clearly can't be used with the current choice.
    init(_ title: String, _ detail: String, available: Bool = true, badge: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.available = available
        self.badge = badge
        self.control = control()
    }

    private func tag(_ text: String, color: some ShapeStyle) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(Capsule().stroke(color.opacity(0.6)))
            .foregroundStyle(color)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.body.weight(.medium))
                    if let badge {
                        tag(badge, color: Color.blue).accessibilityIdentifier("badge." + title)
                    }
                    if !available { tag("Unavailable", color: HierarchicalShapeStyle.secondary) }
                }
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control
                .accessibilityIdentifier("setting." + title)
                .labelsHidden()
                .toggleStyle(.switch)
                .fixedSize()
        }
        .padding(.vertical, 3)
        .disabled(!available)
        .opacity(available ? 1 : 0.4)
        .accessibilityElement(children: .contain)
        .accessibilityHint(available ? "" : "Unavailable")
    }
}
