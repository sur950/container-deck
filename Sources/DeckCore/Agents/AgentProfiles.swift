import Foundation

// MARK: - Profile

/// Where a profile runs.
public enum AgentRunPlace: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    /// In the terminal on this Mac.
    case mac
    /// In a sandbox container with its own network.
    case sandbox

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .mac: return "This Mac"
        case .sandbox: return "Sandbox"
        }
    }
}

/// A model server on this Mac, saved by address (the profile does not need it running to be saved).
public struct AgentLocalModel: Sendable, Hashable, Codable {
    public var server: String
    public var kind: AgentModelEndpoint.Kind
    public var baseURL: String
    public var model: String

    public init(server: String, kind: AgentModelEndpoint.Kind, baseURL: String, model: String) {
        self.server = server
        self.kind = kind
        self.baseURL = baseURL
        self.model = model
    }

    public var endpoint: AgentModelEndpoint {
        AgentModelEndpoint(name: server, kind: kind, baseURL: baseURL, models: [model])
    }
}

/// Which model a profile uses.
public enum AgentModelChoice: Sendable, Hashable, Codable {
    /// The agent's own sign in (its hosted account).
    case account
    /// A provider key from the Keychain, passed as an environment variable at launch.
    case providerKey(HostedProvider)
    /// A model server on this Mac (Ollama, LM Studio, MLX).
    case local(AgentLocalModel)

    public var title: String {
        switch self {
        case .account: return "Own account"
        case .providerKey(let provider): return "\(provider.title) key"
        case .local(let model): return "\(model.server), \(model.model)"
        }
    }

    public var provider: HostedProvider? {
        if case .providerKey(let provider) = self { return provider }
        return nil
    }
}

/// Sandbox settings of a profile.
public struct AgentSandboxOptions: Sendable, Hashable, Codable {
    /// `SandboxEgress` raw value.
    public var egress: String
    /// Hosts added to the default allow list.
    public var extraHosts: [String]
    public var workspaceReadOnly: Bool
    public var cpus: Int
    public var memoryMB: Int

    public init(egress: String = SandboxEgress.allowList.rawValue, extraHosts: [String] = [], workspaceReadOnly: Bool = false,
                cpus: Int = SandboxConfig.defaultCPUs, memoryMB: Int = 4096) {
        self.egress = egress
        self.extraHosts = extraHosts
        self.workspaceReadOnly = workspaceReadOnly
        self.cpus = cpus
        self.memoryMB = memoryMB
    }

    public var egressMode: SandboxEgress { SandboxEgress(rawValue: egress) ?? .allowList }
}

/// A saved way to start an agent: tool, model, MCP servers, folder and where it runs.
/// Saved as JSON. Never holds a secret: keys stay in the Keychain and are read at launch.
public struct AgentProfile: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var tool: AgentTool
    public var model: AgentModelChoice
    /// Names of MCP servers installed in the app.
    public var mcpServers: [String]
    /// Only the profile's servers, not the agent's own (Claude Code `--strict-mcp-config`).
    public var onlyProfileServers: Bool
    public var workspace: String?
    public var place: AgentRunPlace
    public var sandbox: AgentSandboxOptions
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, tool: AgentTool, model: AgentModelChoice = .account, mcpServers: [String] = [],
                onlyProfileServers: Bool = false, workspace: String? = nil, place: AgentRunPlace = .mac,
                sandbox: AgentSandboxOptions = AgentSandboxOptions(), createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.tool = tool
        self.model = model
        self.mcpServers = mcpServers
        self.onlyProfileServers = onlyProfileServers
        self.workspace = workspace
        self.place = place
        self.sandbox = sandbox
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Store

/// Profiles as one JSON file each in Application Support/<bundle id>/Agents/profiles.
public struct AgentProfileStore: Sendable {
    public var folder: URL

    public init(folder: URL = AgentsConfig.agentsDirectory().appendingPathComponent(AgentsConfig.profilesFolder, isDirectory: true)) {
        self.folder = folder
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static func encode(_ profile: AgentProfile) throws -> Data {
        try encoder.encode(profile)
    }

    public static func decode(_ data: Data) throws -> AgentProfile {
        try decoder.decode(AgentProfile.self, from: data)
    }

    func file(_ id: UUID) -> URL {
        folder.appendingPathComponent(id.uuidString.lowercased() + ".json")
    }

    /// Every profile that reads cleanly, by name. Broken files are skipped.
    public func load() -> [AgentProfile] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? Self.decode($0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func save(_ profile: AgentProfile) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var copy = profile
        copy.updatedAt = Date()
        try Self.encode(copy).write(to: file(profile.id), options: .atomic)
    }

    public func delete(_ profile: AgentProfile) throws {
        let url = file(profile.id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    /// A copy with a new id and a free name.
    public static func duplicate(_ profile: AgentProfile, existing: [AgentProfile]) -> AgentProfile {
        var copy = profile
        copy.id = UUID()
        copy.createdAt = Date()
        copy.updatedAt = Date()
        let names = Set(existing.map(\.name))
        var name = "\(profile.name) copy"
        var number = 2
        while names.contains(name) {
            name = "\(profile.name) copy \(number)"
            number += 1
        }
        copy.name = name
        return copy
    }
}

// MARK: - Launch on this Mac

/// How an agent can get MCP servers for one run without its global config changing.
public enum AgentMCPRunSupport: Sendable, Equatable {
    /// Claude Code: `--mcp-config <file>` (and `--strict-mcp-config`), checked with `claude --help`.
    case configFile
    /// Codex: `-c mcp_servers.<name>.<key>=<TOML>`, checked with `codex --help`.
    case configOverrides
    /// No per run way. The person can connect servers to the agent's config instead.
    case none

    public static func of(_ tool: AgentTool) -> AgentMCPRunSupport {
        switch tool {
        case .claude: return .configFile
        case .codex: return .configOverrides
        default: return .none
        }
    }
}

/// A file written before the agent starts (never holds secrets).
public struct AgentLaunchFile: Sendable, Hashable {
    public var path: String
    public var contents: String
}

/// What runs in the terminal, and the files it needs.
public struct AgentLaunchPlan: Sendable, Hashable {
    public var command: String
    public var files: [AgentLaunchFile]
    /// Short notes for the person, like servers that could not be passed.
    public var notes: [String]
}

public enum AgentLaunchError: Error, LocalizedError, Equatable {
    case toolMissing(String)
    case noModel(String)
    case providerNotSupported(String, String)
    case sandboxNotSupported(String)

    public var errorDescription: String? {
        switch self {
        case .toolMissing(let tool): return "\(tool) is not installed on this Mac."
        case .noModel(let tool): return "\(tool) cannot use this model server."
        case .providerNotSupported(let tool, let provider): return "\(tool) cannot use a \(provider) key."
        case .sandboxNotSupported(let tool): return "\(tool) cannot run in a sandbox yet."
        }
    }
}

public enum AgentLauncher {
    /// Providers whose key a tool can use from the environment.
    public static func providers(for tool: AgentTool) -> [HostedProvider] {
        switch tool {
        case .claude: return [.anthropic]
        case .codex: return [.openai]
        case .gemini: return [.gemini]
        case .aider, .goose, .opencode: return HostedProvider.allCases
        default: return []
        }
    }

    /// Tools that sign in to their own hosted account.
    public static func hasOwnAccount(_ tool: AgentTool) -> Bool {
        !tool.isApp && tool != .aider
    }

    /// Shell lines (two) that load a provider key from the Keychain into the environment.
    /// The key is never in the command text or in a process argument.
    public static func keyExport(_ provider: HostedProvider) -> String {
        let q = MCPLaunch.shellQuote
        let name = provider.environmentVariable
        return "\(name)=\"$(\(KeychainSecretStore.securityTool) find-generic-password -s \(q(AgentsConfig.providerKeyService)) -a \(q(provider.rawValue)) -w)\""
            + " || { echo \(q("No \(provider.title) key in the Keychain. Add one in Agents and MCP, API Keys.")); exit 1; }\nexport \(name)"
    }

    /// Variables and arguments for the model choice. nil when the tool cannot use it.
    public static func modelParts(_ tool: AgentTool, model: AgentModelChoice) throws -> AgentCommandParts {
        switch model {
        case .account:
            return AgentCommandParts()
        case .providerKey(let provider):
            guard providers(for: tool).contains(provider) else { throw AgentLaunchError.providerNotSupported(tool.title, provider.title) }
            return AgentCommandParts()
        case .local(let local):
            guard let parts = LocalAgentRecipe.parts(tool, endpoint: local.endpoint, model: local.model) else {
                throw AgentLaunchError.noModel(tool.title)
            }
            return parts
        }
    }

    /// Arguments that give the agent the profile's MCP servers for this run, and the file they need.
    public static func mcpParts(_ profile: AgentProfile, entries: [MCPServerEntry], runFolder: URL) -> (args: [String], file: AgentLaunchFile?) {
        guard !entries.isEmpty else { return ([], nil) }
        switch AgentMCPRunSupport.of(profile.tool) {
        case .configFile:
            let servers = entries.sorted { $0.name < $1.name }.map { ($0.name, AgentEntryFormat.json($0, for: .claudeCode)) }
            let text = JSONValue.object([("mcpServers", .object(servers))]).render() + "\n"
            let path = runFolder.appendingPathComponent("\(profile.id.uuidString.lowercased())-mcp.json").path
            var args = ["--mcp-config", path]
            if profile.onlyProfileServers { args.append("--strict-mcp-config") }
            return (args, AgentLaunchFile(path: path, contents: text))
        case .configOverrides:
            var args: [String] = []
            for entry in entries.sorted(by: { $0.name < $1.name }) {
                for (key, value) in AgentEntryFormat.toml(entry) {
                    args += ["-c", "mcp_servers.\(entry.name).\(key)=\(TOMLEditor.render(value))"]
                }
            }
            return (args, nil)
        case .none:
            return ([], nil)
        }
    }

    /// The terminal command for a profile on this Mac. Never edits the agent's config.
    public static func macPlan(_ profile: AgentProfile, executable: String?, entries: [MCPServerEntry], runFolder: URL) throws -> AgentLaunchPlan {
        guard let executable, !executable.isEmpty else { throw AgentLaunchError.toolMissing(profile.tool.title) }
        let q = MCPLaunch.shellQuote
        let model = try modelParts(profile.tool, model: profile.model)
        let mcp = mcpParts(profile, entries: entries, runFolder: runFolder)
        var notes: [String] = []
        if !entries.isEmpty, AgentMCPRunSupport.of(profile.tool) == .none {
            notes.append("\(profile.tool.title) reads MCP servers only from its own config. Connect them there.")
        }
        var lines: [String] = []
        if let folder = profile.workspace, !folder.isEmpty { lines.append("cd \(q(folder)) || exit 1") }
        if let provider = profile.model.provider { lines.append(keyExport(provider)) }
        let parts = AgentCommandParts(env: model.env, args: mcp.args + model.args)
        lines.append(parts.commandLine(program: executable))
        return AgentLaunchPlan(command: lines.joined(separator: "\n"), files: mcp.file.map { [$0] } ?? [], notes: notes)
    }

    /// Writes the plan's files (0600). Called right before the terminal opens.
    public static func writeFiles(_ plan: AgentLaunchPlan) throws {
        let fm = FileManager.default
        for file in plan.files {
            let url = URL(fileURLWithPath: file.path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data(file.contents.utf8).write(to: url, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}
