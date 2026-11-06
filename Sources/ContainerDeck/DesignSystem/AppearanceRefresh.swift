import SwiftUI

/// AppKit backed pop-up buttons, menus and segmented controls keep their old text color
/// after a Light or Dark switch, which can leave white text on a white button.
/// Rebuilding only the control on a switch fixes it, and keeps every selection elsewhere.
struct PopUpAppearanceRefresh: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.id(colorScheme)
    }
}

extension View {
    /// Use on menu style pickers and menus so they stay readable after a Light or Dark switch.
    func popUpAppearanceRefresh() -> some View {
        modifier(PopUpAppearanceRefresh())
    }
}
