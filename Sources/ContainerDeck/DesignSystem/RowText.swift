import SwiftUI

/// Text level for table and list cells. Pairs with `.deckPrimaryText()`, `.deckSecondaryText()`
/// and `.deckTertiaryText()` so a cell can pick its level from data and still turn white on the
/// selected row highlight.
enum RowTextLevel {
    case primary, secondary, tertiary
}

extension View {
    /// Row aware text color for a level picked at run time.
    @ViewBuilder
    func deckRowText(_ level: RowTextLevel) -> some View {
        switch level {
        case .primary: deckPrimaryText()
        case .secondary: deckSecondaryText()
        case .tertiary: deckTertiaryText()
        }
    }
}
