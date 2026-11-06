import SwiftUI

/// Control bar at the top of a container detail tab (logs, files, inspect).
/// Same height, padding and background on every tab.
struct ContainerTabBar<Content: View>: View {
    @ViewBuilder var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 10) {
            content
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .background(DS.surface)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Small search field used in tab bars.
struct ContainerFilterField: View {
    var prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            DeckIcon(.search, size: 12, color: DS.textSecondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.callout)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    DeckIcon(.close, size: 9, color: DS.textSecondary)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DS.surfaceSunken))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(DS.border, lineWidth: 1))
    }
}

/// Muted one line text for an empty card, like "No mounts".
struct CardEmptyText: View {
    var text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(DS.textTertiary)
            .padding(.vertical, 5)
    }
}
