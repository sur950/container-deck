import Foundation

/// How an agent talks to an MCP server.
public enum MCPTransport: String, Sendable, Hashable, Codable, CaseIterable {
    case stdio, http, sse

    public var title: String {
        switch self {
        case .stdio: return "stdio"
        case .http: return "HTTP"
        case .sse: return "SSE"
        }
    }
}

/// A server entry as an agent config sees it: either a command to spawn or a URL.
/// Env values are only kept in memory while writing a config, never shown.
public struct MCPServerEntry: Sendable, Hashable {
    public var name: String
    public var transport: MCPTransport
    public var command: String?
    public var args: [String]
    public var env: [String: String]
    public var url: String?
    public var headers: [String: String]

    public init(name: String, transport: MCPTransport, command: String? = nil, args: [String] = [],
                env: [String: String] = [:], url: String? = nil, headers: [String: String] = [:]) {
        self.name = name
        self.transport = transport
        self.command = command
        self.args = args
        self.env = env
        self.url = url
        self.headers = headers
    }

    public static func stdio(_ name: String, command: String, args: [String] = [], env: [String: String] = [:]) -> MCPServerEntry {
        MCPServerEntry(name: name, transport: .stdio, command: command, args: args, env: env)
    }

    public static func remote(_ name: String, transport: MCPTransport, url: String, headers: [String: String] = [:]) -> MCPServerEntry {
        MCPServerEntry(name: name, transport: transport, url: url, headers: headers)
    }

    /// One line for people: the URL or the command with arguments, secrets masked.
    public var target: String {
        if let url { return url }
        return ([command ?? ""] + MCPServerEntry.maskSecrets(args)).filter { !$0.isEmpty }.map { arg in
            arg.contains(" ") ? "'\(arg)'" : arg
        }.joined(separator: " ")
    }

    /// Masks argument values that look like keys or tokens.
    public static func maskSecrets(_ args: [String]) -> [String] {
        var out: [String] = []
        var maskNext = false
        for arg in args {
            if maskNext { out.append("••••"); maskNext = false; continue }
            let lower = arg.lowercased()
            let flagLike = lower.hasPrefix("-")
            let secretWord = ["key", "token", "secret", "password", "auth"].contains { lower.contains($0) }
            if flagLike, secretWord {
                if let eq = arg.firstIndex(of: "=") {
                    out.append(String(arg[...eq]) + "••••")
                } else {
                    out.append(arg)
                    maskNext = true
                }
                continue
            }
            if looksLikeSecret(arg) { out.append("••••"); continue }
            out.append(arg)
        }
        return out
    }

    static func looksLikeSecret(_ value: String) -> Bool {
        let prefixes = ["sk-", "sk_", "ghp_", "gho_", "github_pat_", "xoxb-", "xoxp-", "AIza", "glpat-"]
        if prefixes.contains(where: { value.hasPrefix($0) }) && value.count > 12 { return true }
        if value.contains("="), let eq = value.firstIndex(of: "=") {
            let key = value[..<eq].uppercased()
            if ["KEY", "TOKEN", "SECRET", "PASSWORD"].contains(where: { key.contains($0) }) { return true }
        }
        return false
    }
}

/// Where in an agent's config a server lives.
public enum AgentConfigScope: Sendable, Hashable {
    /// The user wide file of the agent.
    case user
    /// A project file such as `.mcp.json` or `.vscode/mcp.json` in a folder.
    case project(String)
    /// Claude Code local scope: `projects.<path>.mcpServers` in `~/.claude.json`.
    case local(String)

    public var title: String {
        switch self {
        case .user: return "User"
        case .project: return "Project"
        case .local: return "Local"
        }
    }

    public var folder: String? {
        switch self {
        case .user: return nil
        case .project(let path), .local(let path): return path
        }
    }
}

/// A server found in an agent config file on this Mac.
public struct DiscoveredMCPServer: Sendable, Hashable, Identifiable {
    public var agent: AgentKind
    public var scope: AgentConfigScope
    public var file: String
    public var name: String
    public var transport: MCPTransport
    public var target: String
    /// Names of env variables and headers, never their values.
    public var envKeys: [String]
    public var headerKeys: [String]
    public var disabled: Bool
    /// Server name of ours when the entry runs one of our containers.
    public var managedServer: String?
    /// The URL when remote, for matching.
    public var url: String?
    /// The full entry, kept in memory only so it can be copied to another agent. Never shown.
    public var entry: MCPServerEntry?

    public var id: String { "\(agent.rawValue)|\(file)|\(scope.folder ?? "")|\(name)" }

    public init(agent: AgentKind, scope: AgentConfigScope, file: String, name: String, transport: MCPTransport,
                target: String, envKeys: [String] = [], headerKeys: [String] = [], disabled: Bool = false,
                managedServer: String? = nil, url: String? = nil, entry: MCPServerEntry? = nil) {
        self.agent = agent
        self.scope = scope
        self.file = file
        self.name = name
        self.transport = transport
        self.target = target
        self.envKeys = envKeys
        self.headerKeys = headerKeys
        self.disabled = disabled
        self.managedServer = managedServer
        self.url = url
        self.entry = entry
    }
}

/// A config file we looked at, with what we found or why we could not read it.
public struct AgentConfigFileStatus: Sendable, Hashable, Identifiable {
    public var agent: AgentKind
    public var path: String
    public var exists: Bool
    public var serverCount: Int
    public var problem: String?
    public var id: String { agent.rawValue + "|" + path }

    public init(agent: AgentKind, path: String, exists: Bool, serverCount: Int, problem: String? = nil) {
        self.agent = agent
        self.path = path
        self.exists = exists
        self.serverCount = serverCount
        self.problem = problem
    }
}
