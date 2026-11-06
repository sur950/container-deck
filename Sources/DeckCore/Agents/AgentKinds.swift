import Foundation

/// Agents whose MCP config we read and write. Formats checked against each tool's docs (Nov 2026):
/// - Claude Code: `mcpServers` in `~/.claude.json` (user), `projects.<path>.mcpServers` (local), `.mcp.json` (project).
///   stdio `{type, command, args, env}`, remote `{type: "http" | "sse", url, headers}`.
/// - Claude Desktop: `mcpServers` in `~/Library/Application Support/Claude/claude_desktop_config.json`. stdio only.
/// - Cursor: `mcpServers` in `~/.cursor/mcp.json` or `<project>/.cursor/mcp.json`. stdio `{type, command, args, env}`, remote `{url, headers}`.
/// - VS Code: `servers` in the user `mcp.json` or `<project>/.vscode/mcp.json`. `{type: "stdio" | "http" | "sse", ...}`.
///   Older setups keep `mcp.servers` in `settings.json` (read only here).
/// - Codex CLI: `[mcp_servers.<name>]` in `~/.codex/config.toml`. stdio `command, args, env`, streamable HTTP `url, http_headers`.
/// - Gemini CLI: `mcpServers` in `~/.gemini/settings.json`. stdio `command`, SSE `url`, streamable HTTP `httpUrl`.
public enum AgentKind: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case claudeCode, claudeDesktop, cursor, vscode, codex, gemini

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .claudeDesktop: return "Claude Desktop"
        case .cursor: return "Cursor"
        case .vscode: return "VS Code"
        case .codex: return "Codex CLI"
        case .gemini: return "Gemini CLI"
        }
    }

    /// Transports the agent can use without a bridge.
    public var transports: Set<MCPTransport> {
        switch self {
        case .claudeDesktop: return [.stdio]
        case .codex: return [.stdio, .http]
        default: return [.stdio, .http, .sse]
        }
    }

    /// Whether the agent has a per project config file.
    public var supportsProjectScope: Bool { self != .claudeDesktop }

    public var isTOML: Bool { self == .codex }

    /// Key path of the servers object inside a JSON config.
    public func serversPath(scope: AgentConfigScope) -> [String] {
        switch self {
        case .vscode: return ["servers"]
        case .claudeCode:
            if case .local(let folder) = scope { return ["projects", folder, "mcpServers"] }
            return ["mcpServers"]
        default: return ["mcpServers"]
        }
    }

    /// How to apply a change: restart the app or start a new session.
    public var reloadHint: String {
        switch self {
        case .claudeDesktop: return "Quit and reopen Claude Desktop to load the change."
        case .cursor: return "Cursor picks up the change in a moment. Check Settings, MCP."
        case .vscode: return "VS Code picks up the change. Start the server from the MCP list if needed."
        default: return "Start a new \(title) session to load the change."
        }
    }
}

/// Paths of agent config files under a home folder. Tests point `home` at a copy under /tmp.
public struct AgentConfigLocations: Sendable {
    public var home: String

    public init(home: String = NSHomeDirectory()) {
        self.home = home
    }

    private func join(_ parts: String...) -> String {
        parts.reduce(home) { ($0 as NSString).appendingPathComponent($1) }
    }

    public var claudeJSON: String { join(".claude.json") }
    public var claudeDesktop: String { join("Library", "Application Support", "Claude", "claude_desktop_config.json") }
    public var cursor: String { join(".cursor", "mcp.json") }
    public var vscodeUser: String { join("Library", "Application Support", "Code", "User", "mcp.json") }
    public var vscodeInsidersUser: String { join("Library", "Application Support", "Code - Insiders", "User", "mcp.json") }
    public var vscodeSettings: String { join("Library", "Application Support", "Code", "User", "settings.json") }
    public var codex: String { join(".codex", "config.toml") }
    public var gemini: String { join(".gemini", "settings.json") }

    /// The file that holds the agent's servers for this scope.
    public func file(for agent: AgentKind, scope: AgentConfigScope) -> String {
        if case .project(let folder) = scope {
            let f = folder as NSString
            switch agent {
            case .claudeCode: return f.appendingPathComponent(".mcp.json")
            case .cursor: return f.appendingPathComponent(".cursor/mcp.json")
            case .vscode: return f.appendingPathComponent(".vscode/mcp.json")
            case .codex: return f.appendingPathComponent(".codex/config.toml")
            case .gemini: return f.appendingPathComponent(".gemini/settings.json")
            case .claudeDesktop: return claudeDesktop
            }
        }
        switch agent {
        case .claudeCode: return claudeJSON
        case .claudeDesktop: return claudeDesktop
        case .cursor: return cursor
        case .vscode: return vscodeUser
        case .codex: return codex
        case .gemini: return gemini
        }
    }
}

// MARK: - Entry formats

public enum AgentEntryFormat {
    /// The entry adjusted for what the agent supports. Remote servers become a stdio bridge
    /// (`npx -y mcp-remote <url>`) for agents that only spawn commands.
    public static func adapted(_ entry: MCPServerEntry, for agent: AgentKind) -> MCPServerEntry {
        guard entry.transport != .stdio, !agent.transports.contains(entry.transport), let url = entry.url else { return entry }
        var args = ["-y", AgentsConfig.remoteBridgePackage, url]
        if entry.transport == .sse { args += ["--transport", "sse-only"] }
        for (key, value) in entry.headers.sorted(by: { $0.key < $1.key }) { args += ["--header", "\(key): \(value)"] }
        return .stdio(entry.name, command: "npx", args: args)
    }

    /// True when `adapted` changes the entry into a bridge.
    public static func needsBridge(_ entry: MCPServerEntry, for agent: AgentKind) -> Bool {
        entry.transport != .stdio && !agent.transports.contains(entry.transport)
    }

    /// JSON object for a JSON based agent.
    public static func json(_ original: MCPServerEntry, for agent: AgentKind) -> JSONValue {
        let entry = adapted(original, for: agent)
        var members: [(String, JSONValue)] = []
        let env = entry.env.sorted { $0.key < $1.key }.map { ($0.key, JSONValue.string($0.value)) }
        let headers = entry.headers.sorted { $0.key < $1.key }.map { ($0.key, JSONValue.string($0.value)) }
        switch entry.transport {
        case .stdio:
            switch agent {
            case .claudeCode, .cursor, .vscode: members.append(("type", .string("stdio")))
            default: break
            }
            members.append(("command", .string(entry.command ?? "")))
            members.append(("args", .array(entry.args.map { .string($0) })))
            if !env.isEmpty { members.append(("env", .object(env))) }
        case .http, .sse:
            let url = entry.url ?? ""
            switch agent {
            case .gemini:
                members.append((entry.transport == .http ? "httpUrl" : "url", .string(url)))
            case .cursor:
                members.append(("url", .string(url)))
            default:
                members.append(("type", .string(entry.transport.rawValue)))
                members.append(("url", .string(url)))
            }
            if !headers.isEmpty { members.append(("headers", .object(headers))) }
        }
        return .object(members)
    }

    /// Key and value pairs of a Codex `[mcp_servers.<name>]` table.
    public static func toml(_ original: MCPServerEntry) -> [(String, TOMLValue)] {
        let entry = adapted(original, for: .codex)
        var values: [(String, TOMLValue)] = []
        if entry.transport == .stdio {
            values.append(("command", .string(entry.command ?? "")))
            values.append(("args", .array(entry.args.map { .string($0) })))
            if !entry.env.isEmpty { values.append(("env", .table(entry.env.mapValues { .string($0) }))) }
        } else {
            values.append(("url", .string(entry.url ?? "")))
            if !entry.headers.isEmpty { values.append(("http_headers", .table(entry.headers.mapValues { .string($0) }))) }
        }
        return values
    }

    /// Reads one server from a JSON config dictionary. nil when it has neither command nor URL.
    public static func parse(name: String, _ dict: [String: Any], agent: AgentKind) -> MCPServerEntry? {
        let type = (dict["type"] as? String)?.lowercased()
        let env = (dict["env"] as? [String: Any])?.compactMapValues { $0 as? String ?? ($0 as? NSNumber)?.stringValue } ?? [:]
        let headers = (dict["headers"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
        if let command = dict["command"] as? String {
            let args = (dict["args"] as? [Any])?.compactMap { $0 as? String ?? ($0 as? NSNumber)?.stringValue } ?? []
            return MCPServerEntry(name: name, transport: .stdio, command: command, args: args, env: env)
        }
        if let httpUrl = dict["httpUrl"] as? String {
            return MCPServerEntry(name: name, transport: .http, url: httpUrl, headers: headers)
        }
        if let url = (dict["url"] as? String) ?? (dict["serverUrl"] as? String) {
            let transport: MCPTransport
            switch type {
            case "sse": transport = .sse
            case "http", "streamable-http", "streamablehttp": transport = .http
            default:
                // Gemini and Cursor: a plain url. Gemini means SSE, Cursor picks itself.
                transport = agent == .gemini || url.hasSuffix("/sse") ? .sse : .http
            }
            return MCPServerEntry(name: name, transport: transport, url: url, headers: headers)
        }
        return nil
    }

    /// Reads one Codex server table.
    public static func parse(name: String, toml values: [String: TOMLValue]) -> MCPServerEntry? {
        let env = values["env"]?.tableValue?.compactMapValues { $0.stringValue } ?? [:]
        if let command = values["command"]?.stringValue {
            let args = values["args"]?.arrayValue?.compactMap { $0.stringValue } ?? []
            return MCPServerEntry(name: name, transport: .stdio, command: command, args: args, env: env)
        }
        if let url = values["url"]?.stringValue {
            let headers = values["http_headers"]?.tableValue?.compactMapValues { $0.stringValue } ?? [:]
            return MCPServerEntry(name: name, transport: .http, url: url, headers: headers)
        }
        return nil
    }
}
