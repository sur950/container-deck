import SwiftUI

// Form layout for every sheet: grouped boxes, trailing aligned labels in one column,
// fields of the same width, small notes under fields. Use inside SheetScaffold.

enum DeckForm {
    static let labelWidth: CGFloat = 92
}

/// A grouped box with an optional small title above it.
struct DeckFormGroup<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DS.textSecondary)
                    .padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .deckCard(radius: DS.smallRadius + 2)
        }
    }
}

/// One labelled row: label on the left (trailing aligned), field and an optional note on the right.
struct DeckFormRow<Content: View>: View {
    var label: String
    var note: String?
    @ViewBuilder var content: Content

    init(_ label: String, note: String? = nil, @ViewBuilder content: () -> Content) {
        self.label = label
        self.note = note
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(DS.textPrimary)
                .frame(width: DeckForm.labelWidth, alignment: .trailing)
            VStack(alignment: .leading, spacing: 6) {
                content
                if let note {
                    DeckFormNote(note)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Small grey helper text under a field.
struct DeckFormNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(DS.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
