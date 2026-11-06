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
    public static let secretService = AppConfig.bundleID + ".mcp"
    /// Keychain service for hosted AI provider keys. Account is the provider id.
    public static let providerKeyService = AppConfig.bundleID + ".provider-keys"
    /// First host port tried for HTTP servers.
    public static let firstHostPort = 18_300
    /// Folder under Application Support for installed servers and config backups.
    public static let supportFolder = AppConfig.appName
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
}
