import SwiftUI
import DeckCore

/// Chart colors used on the Dashboard. Brand red leads, the rest only tell series apart.
enum DashboardColors {
    static let cpu = DS.accent
    static let memory = Color.adaptive(light: 0x7A4FB8, dark: 0xA783E0)
    static let images = DS.accent
    static let containers = DS.running
    static let volumes = memory
}

/// A metric tile with two small values side by side ("2 Servers   1 MCP"). Same frame,
/// paddings and line count as `MetricTile`, so it sits evenly in the tile row.
/// `trailingAction` makes the right value its own click target.
struct MetricPairTile: View {
    var title: String
    var leading: (value: String, label: String)
    var trailing: (value: String, label: String)
    var subtitle: String?
    var icon: DeckIconName
    var tint: Color = DS.accent
    var trailingHelp: String?
    var trailingAction: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                IconBadge(icon, tint: tint, size: 26)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    pair(leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    trailingPart
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(subtitle ?? " ")
                    .font(.caption)
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(1)
                    .accessibilityHidden(subtitle == nil)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .deckCard()
    }

    @ViewBuilder
    private var trailingPart: some View {
        if let trailingAction {
            Button(action: trailingAction) {
                pair(trailing).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(trailingHelp ?? "")
        } else {
            pair(trailing)
        }
    }

    private func pair(_ item: (value: String, label: String)) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(item.value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(item.label)
                .font(.caption)
                .foregroundStyle(DS.textSecondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}
