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
