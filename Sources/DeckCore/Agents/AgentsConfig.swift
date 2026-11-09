import Foundation

/// Constants for the Agents and MCP area.
public enum AgentsConfig {
    /// Label on every container that runs an MCP server for us. Value is the server name.
    public static let serverLabel = "deck.mcp"
    /// Label with the transport: "stdio", "http" or "sse".
    public static let transportLabel = "deck.mcp.transport"
    /// Name prefix of long running MCP server containers.
    public static let containerPrefix = "deck-mcp-"
    /// Keychain service for MCP server secrets. Account is "<server>/<VARIABLE>".
    public static let secretService = AppConfig.dataID + ".mcp"
    /// Keychain service for hosted AI provider keys. Account is the provider id.
    public static let providerKeyService = AppConfig.dataID + ".provider-keys"
    /// First host port tried for HTTP servers.
    public static let firstHostPort = 18_300
    /// Folder under Application Support for installed servers and config backups.
    /// "Container Deck" for the app. Test copies (`<bundleID>.debug`) get their own folder, like
    /// "Container Deck debug", so they never touch the real list of installed servers.
    public static let supportFolder = AppConfig.dataID == AppConfig.bundleID
        ? AppConfig.appName
        : AppConfig.appName + " " + AppConfig.dataID.dropFirst(AppConfig.bundleID.count + 1)
    public static let serversFile = "mcp-servers.json"
    public static let backupsFolder = "Config Backups"
    public static let changeLogFile = "config-changes.json"
    /// MCP protocol version we offer in the initialize handshake.
    public static let protocolVersion = "2025-06-18"
    /// Seconds to wait for an HTTP handshake, and for a stdio one (first run may pull the image).
    public static let httpHandshakeTimeout: TimeInterval = 10
    public static let stdioHandshakeTimeout: TimeInterval = 120
    /// The stdio bridge used for agents that cannot reach HTTP servers directly.
    public static let remoteBridgePackage = "mcp-remote"

    // MARK: Agent tools, profiles and sessions

    /// UserDefaults key with the path overrides from Settings, Agents (JSON, `AgentPathOverrides`).
    public static let pathOverridesKey = "agentPathOverrides"
    /// Folder under Application Support/<bundle id> for agent profiles and per run files.
    public static let agentsFolder = "Agents"
    public static let profilesFolder = "profiles"
    public static let runsFolder = "runs"
    /// Seconds between SIGTERM and SIGKILL when stopping an agent session.
    public static let stopTimeout: TimeInterval = 5
    /// Recent sessions read per agent.
    public static let recentSessionLimit = 40
    /// Debug builds only: a folder of stand in agent tools that replaces the normal search.
    public static let debugToolsEnvironmentKey = "DECK_AGENTS_TOOLS_DIR"
    /// Debug builds only: a fake home folder for agent configs, sessions and profiles (automation runs).
    public static let debugHomeEnvironmentKey = "DECK_AGENTS_HOME"

    /// Application Support/<bundle id>/Agents.
    public static func agentsDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(AppConfig.dataID, isDirectory: true).appendingPathComponent(agentsFolder, isDirectory: true)
    }
}
