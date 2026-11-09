import SwiftUI
import DeckCore

/// The two parts of the Images screen. Explore was its own screen until
/// November 2026. It only had images, so it moved in here.
enum ImagesSection: String, CaseIterable, Identifiable {
    case local, explore

    var id: String { rawValue }
    var title: String { self == .local ? "On this Mac" : "Explore" }

    /// UserDefaults key for the section that shows (read by `@AppStorage`).
    static let storageKey = "images.section"
    /// Where the section is kept. Tests use their own suite, so parallel runs never share it.
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    static var saved: ImagesSection {
        defaults.string(forKey: storageKey).flatMap(ImagesSection.init(rawValue:)) ?? .local
    }

    /// Opens Images on `section`.
    @MainActor
    static func show(_ section: ImagesSection, state: AppState) {
        defaults.set(section.rawValue, forKey: storageKey)
        state.selection = .images
    }
}

extension SidebarItem {
    /// A screen by name, including names that are gone: "explore" opens Images on
    /// its Explore section. Used by saved selections, links and debug commands.
    static func resolve(_ name: String) -> (item: SidebarItem, section: ImagesSection?)? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key == "explore" { return (.images, .explore) }
        guard let item = SidebarItem(rawValue: key) ?? SidebarItem.allCases.first(where: { $0.rawValue.lowercased() == key }) else {
            return nil
        }
        return (item, nil)
    }

    /// Opens the screen `name` names. False when there is no such screen.
    @MainActor @discardableResult
    static func open(_ name: String, state: AppState) -> Bool {
        guard let target = resolve(name) else { return false }
        if let section = target.section {
            ImagesSection.show(section, state: state)
        } else {
            state.selection = target.item
        }
        return true
    }
}
