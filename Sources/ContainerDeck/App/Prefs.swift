import Foundation
import DeckCore

/// UserDefaults keys. Views use @AppStorage(PrefKey.x). Other code reads UserDefaults.standard.
/// Add new keys here, never inline strings.
enum PrefKey {
    static let appearance = "appearance"                 // AppearanceMode raw value
    static let terminalApp = "terminalApp"               // TerminalApp raw value
    static let refreshInterval = "refreshInterval"       // Double seconds, default 3
    static let notifyOnUnexpectedStop = "notifyOnUnexpectedStop" // Bool
    static let showMenuBarExtra = "showMenuBarExtra"     // Bool, default true
    static let hideDockIcon = "hideDockIcon"             // Bool
    static let autoStartContainers = "autoStartContainers" // [String] container ids
    static let showCommandHints = "showCommandHints"     // Bool, default true
    static let composeDefaultCPUs = "composeDefaultCPUs" // Int
    static let composeDefaultMemory = "composeDefaultMemory" // String like "1G"
    static let checkForUpdates = "checkForUpdates"       // Bool, default true
    static let notifyOnTaskDone = "notifyOnTaskDone"     // Bool, default true. Compose up, pulls, builds.
    static let skippedUpdateVersion = "skippedUpdateVersion" // String. Version the person pressed Later on.
    static let composeRecentFiles = "composeRecentFiles" // [String] paths
    /// Bool, default false. Every call uses the container command instead of the direct API. For troubleshooting.
    static let forceCLIBackend = AppConfig.forceCLIBackendKey
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "Match System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

enum TerminalApp: String, CaseIterable, Identifiable {
    case terminal, iterm, ghostty, warp, kitty, alacritty, wezterm
    var id: String { rawValue }
    var title: String {
        switch self {
        case .terminal: return "Terminal"
        case .iterm: return "iTerm2"
        case .ghostty: return "Ghostty"
        case .warp: return "Warp"
        case .kitty: return "kitty"
        case .alacritty: return "Alacritty"
        case .wezterm: return "WezTerm"
        }
    }
    var bundleIdentifier: String {
        switch self {
        case .terminal: return "com.apple.Terminal"
        case .iterm: return "com.googlecode.iterm2"
        case .ghostty: return "com.mitchellh.ghostty"
        case .warp: return "dev.warp.Warp-Stable"
        case .kitty: return "net.kovidgoyal.kitty"
        case .alacritty: return "org.alacritty"
        case .wezterm: return "com.github.wez.wezterm"
        }
    }
}

enum Prefs {
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            PrefKey.appearance: AppearanceMode.system.rawValue,
            PrefKey.terminalApp: TerminalApp.terminal.rawValue,
            PrefKey.refreshInterval: AppConfig.defaultRefreshInterval,
            PrefKey.notifyOnUnexpectedStop: true,
            PrefKey.notifyOnTaskDone: true,
            PrefKey.showMenuBarExtra: true,
            PrefKey.hideDockIcon: false,
            PrefKey.showCommandHints: true,
            PrefKey.composeDefaultCPUs: 2,
            PrefKey.composeDefaultMemory: "1G",
            PrefKey.checkForUpdates: true,
            PrefKey.forceCLIBackend: false
        ])
    }

    static var refreshInterval: Double {
        max(1, UserDefaults.standard.double(forKey: PrefKey.refreshInterval))
    }

    static var terminalApp: TerminalApp {
        TerminalApp(rawValue: UserDefaults.standard.string(forKey: PrefKey.terminalApp) ?? "") ?? .terminal
    }

    static var autoStartContainers: [String] {
        get { UserDefaults.standard.stringArray(forKey: PrefKey.autoStartContainers) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: PrefKey.autoStartContainers) }
    }
}
