import SwiftUI
import DeckCore

extension PrefKey {
    /// Agent path overrides from Settings, Agents (JSON data, `AgentPathOverrides`).
    static let agentPathOverrides = AgentsConfig.pathOverridesKey
}

extension Notification.Name {
    /// Agent paths changed in Settings. The Agents screen reads everything again.
    static let deckAgentPathsChanged = Notification.Name("deckAgentPathsChanged")
    /// Open the Settings window on a tab. `object` is the tab id.
    static let deckOpenSettingsTab = Notification.Name("deckOpenSettingsTab")
}

/// The app's one way to get agent paths: Settings overrides first, then the agents' own
/// variables, the usual places and PATH (`AgentPathResolver`). Debug automation runs can
/// point everything at a fake home (DECK_AGENTS_HOME) and stand in tools (DECK_AGENTS_TOOLS_DIR).
enum AgentPathsEnvironment {
    /// Fake home for automation runs. Configs, sessions, profiles and backups all live in it.
    static var debugHome: String? {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if env["DECK_AUTOMATION"] == "1", let home = env[AgentsConfig.debugHomeEnvironmentKey], !home.isEmpty { return home }
        #endif
        return nil
    }

    static var debugToolsFolder: String? {
        #if DEBUG
        if let dir = ProcessInfo.processInfo.environment[AgentsConfig.debugToolsEnvironmentKey], !dir.isEmpty { return dir }
        #endif
        return nil
    }

    static func resolver(overrides: AgentPathOverrides = .load()) -> AgentPathResolver {
        var resolver: AgentPathResolver
        if let home = debugHome {
            let shell = ShellConfigEnvironment.read(home: home, names: Set(AgentPathResolver.variables.values))
            resolver = AgentPathResolver(home: home, environment: ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? ""],
                                         shellEnvironment: shell, overrides: overrides)
        } else {
            resolver = .standard(overrides: overrides)
        }
        resolver.toolsFolder = debugToolsFolder
        return resolver
    }

    /// Package folder names also match sessions of copies installed elsewhere. Off with stand in tools,
    /// so automation runs never list the real agents.
    static var matchesPackageFolders: Bool { debugToolsFolder == nil }

    static var agentsFolder: URL {
        if let home = debugHome { return URL(fileURLWithPath: home).appendingPathComponent("deck-agents", isDirectory: true) }
        return AgentsConfig.agentsDirectory()
    }

    static var profilesFolder: URL { agentsFolder.appendingPathComponent(AgentsConfig.profilesFolder, isDirectory: true) }
    static var runsFolder: URL { agentsFolder.appendingPathComponent(AgentsConfig.runsFolder, isDirectory: true) }
}

/// Settings tab to show when the window opens.
@MainActor
enum SettingsRouter {
    static var pendingTab: String?
}

/// "Set paths in Settings" link to the Agents tab of Settings.
struct AgentSettingsLink: View {
    @Environment(\.openSettings) private var openSettings
    var title = "Set paths in Settings"

    var body: some View {
        Button {
            SettingsRouter.pendingTab = "agents"
            openSettings()
            NotificationCenter.default.post(name: .deckOpenSettingsTab, object: "agents")
        } label: {
            DeckLabel(title, icon: .settings)
        }
        .deckLink()
        .help("Settings, Agents")
    }
}
