import SwiftUI
import DeckCore

extension PrefKey {
    /// Last tab on the Agents and MCP screen.
    static let agentsTab = "agentsTab"
}

/// Tabs of the Agents and MCP screen.
enum AgentsTab: String, CaseIterable, Identifiable {
    case servers, catalog, agents, keys
    var id: String { rawValue }
    var title: String {
        switch self {
        case .servers: return "Servers"
        case .catalog: return "Catalog"
        case .agents: return "Agents"
        case .keys: return "API Keys"
        }
    }
}

/// Result of the last health check of a server.
enum MCPHealth: Equatable {
    case checking
    case healthy(MCPHandshakeResult, Date)
    case failed(String, Date)
}

/// State for the Agents and MCP screen. Reads agent configs, runs servers, writes configs.
@MainActor
@Observable
final class AgentsStore {
    private(set) var installed: [MCPInstalledServer] = []
    private(set) var discovered: [DiscoveredMCPServer] = []
    private(set) var configFiles: [AgentConfigFileStatus] = []
    private(set) var projects: [String] = []
    private(set) var tools: [DetectedAgentTool] = []
    private(set) var endpoints: [AgentModelEndpoint] = []
    private(set) var history: [ConfigChangeRecord] = []
    private(set) var savedProviders: Set<HostedProvider> = []
    var health: [String: MCPHealth] = [:]
    private(set) var busy: Set<String> = []
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    private(set) var toolsLoaded = false

    let registry = MCPServerRegistry()
    /// Where agent executables, configs and sessions are (Settings overrides first).
    private(set) var resolver: AgentPathResolver = AgentPathsEnvironment.resolver()
    /// Agent config files. Automation runs can point them at a copy (DECK_AGENTS_HOME) so
    /// visual checks of Write and Undo never touch the real files.
    private(set) var writer: AgentConfigWriter = AgentsStore.makeWriter(AgentPathsEnvironment.resolver())

    nonisolated static func makeWriter(_ resolver: AgentPathResolver) -> AgentConfigWriter {
        if let home = AgentPathsEnvironment.debugHome {
            return AgentConfigWriter(locations: resolver.locations, backupsFolder: URL(fileURLWithPath: home).appendingPathComponent("backups"))
        }
        return AgentConfigWriter(locations: resolver.locations)
    }

    /// Reads Settings overrides and the agents' variables again.
    func refreshPaths() {
        let resolver = AgentPathsEnvironment.resolver()
        self.resolver = resolver
        let writer = Self.makeWriter(resolver)
        if writer.locations != self.writer.locations { self.writer = writer }
    }
    let secrets: any SecretStore = KeychainSecretStore()
    let keys = HostedKeyStore()
    /// Local model endpoints. The Local AI area can hand in its own source later.
    var endpointSource: any AgentModelEndpointSource = DiscoveredAgentModelSource()

    // MARK: Loading

    func load() async {
        refreshPaths()
        isLoading = true
        defer { isLoading = false; hasLoaded = true }
        let registry = self.registry
        let writer = self.writer
        let result = await Task.detached(priority: .userInitiated) {
            (registry.load(), AgentConfigDiscovery(locations: writer.locations).discover(), writer.history())
        }.value
        let (servers, discovery, history) = result
        if servers != installed { installed = servers }
        if discovery.servers != discovered { discovered = discovery.servers }
        if discovery.files != configFiles { configFiles = discovery.files }
        // A config file in a format the app can't read: the agent may have changed it.
        for file in discovery.files where file.exists {
            if let problem = file.problem {
                ComponentHealth.report(component: AgentTool.primary(for: file.agent).componentID,
                                       feature: "Reading the \(file.agent.title) settings", message: "could not parse: \(problem)")
            }
        }
        projects = discovery.projects
        if history != self.history { self.history = history }
        refreshProviders()
    }

    func loadTools() async {
        refreshPaths()
        let tools = await AgentToolDetector(resolver: resolver).detect()
        // A version line that no longer reads as a version means the tool changed.
        for tool in tools where tool.installed && !tool.tool.isApp {
            if let version = tool.version, ToolVersion.firstMatch(in: version) == nil {
                ComponentHealth.report(component: tool.tool.componentID, feature: "Reading the \(tool.tool.title) version",
                                       message: "could not parse the version line: \(version)")
            }
        }
        let endpoints = await endpointSource.endpoints()
        if tools != self.tools { self.tools = tools }
        if endpoints != self.endpoints { self.endpoints = endpoints }
        toolsLoaded = true
    }

    func refreshProviders() {
        savedProviders = Set(keys.savedProviders())
    }

    func rows(containers: [ContainerSummary], cliPath: String) -> [MCPOverviewRow] {
        MCPOverview.rows(installed: installed, discovered: discovered, containers: containers, cliPath: cliPath)
    }

    // MARK: Install and remove

    /// Saves the server and its secrets. Starts long running servers.
    func install(_ server: MCPInstalledServer, secretValues: [String: String], client: ContainerClient) async throws {
        for (key, value) in secretValues where !value.isEmpty {
            try await secrets.set(value, service: AgentsConfig.secretService,
                                  account: MCPLaunch.secretAccount(server: server.name, key: key))
        }
        var list = installed.filter { $0.name != server.name }
        list.append(server)
        try registry.save(list)
        installed = list
        if server.isLongRunning {
            try await start(server, client: client)
        }
    }

    func remove(_ server: MCPInstalledServer, client: ContainerClient?) async throws {
        if server.isLongRunning, let client { try await client.stopMCPServer(server) }
        for key in server.secretKeys {
            try? await secrets.delete(service: AgentsConfig.secretService, account: MCPLaunch.secretAccount(server: server.name, key: key))
        }
        let list = installed.filter { $0.name != server.name }
        try registry.save(list)
        installed = list
        health[server.name] = nil
    }

    func hasSecret(_ server: MCPInstalledServer, key: String) -> Bool {
        secrets.contains(service: AgentsConfig.secretService, account: MCPLaunch.secretAccount(server: server.name, key: key))
    }

    // MARK: Run

    func start(_ server: MCPInstalledServer, client: ContainerClient) async throws {
        busy.insert(server.name)
        defer { busy.remove(server.name) }
        var values: [String: String] = [:]
        for key in server.secretKeys {
            if let value = try await secrets.value(service: AgentsConfig.secretService,
                                                   account: MCPLaunch.secretAccount(server: server.name, key: key)) {
                values[key] = value
            }
        }
        try await client.startMCPServer(server, secrets: values)
        // Give the server a moment, then check it.
        await check(server, cliPath: client.cliPath, attempts: 12)
    }

    func stop(_ server: MCPInstalledServer, client: ContainerClient) async throws {
        busy.insert(server.name)
        defer { busy.remove(server.name) }
        try await client.stopMCPServer(server)
        health[server.name] = nil
    }

    /// MCP initialize handshake. HTTP and SSE: against the published port. stdio: starts a
    /// short lived container the same way an agent would, then closes it.
    func check(_ server: MCPInstalledServer, cliPath: String, attempts: Int = 1) async {
        health[server.name] = .checking
        let entry = MCPLaunch.entry(server, cliPath: cliPath)
        health[server.name] = await Self.handshake(entry, attempts: attempts)
    }

    /// Checks a server found in an agent config. Runs its command for stdio entries.
    func check(_ discovered: DiscoveredMCPServer, key: String) async {
        guard let entry = discovered.entry else { return }
        health[key] = .checking
        health[key] = await Self.handshake(entry, attempts: 1)
    }

    nonisolated static func handshake(_ entry: MCPServerEntry, attempts: Int) async -> MCPHealth {
        var lastError: Error = MCPHandshakeError.timeout
        for attempt in 0..<max(1, attempts) {
            do {
                let result: MCPHandshakeResult
                switch entry.transport {
                case .stdio:
                    let command = entry.command ?? ""
                    let executable = command.hasPrefix("/") ? command : "/usr/bin/env"
                    let args = command.hasPrefix("/") ? entry.args : [command] + entry.args
                    var env = entry.env
                    if env["PATH"] == nil {
                        // Apps do not get the shell PATH. Use the folders where agent tools live.
                        env["PATH"] = (AgentPathsEnvironment.resolver().searchFolders + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
                    }
                    result = try await MCPHandshake.stdio(executable: executable, arguments: args, environment: env)
                case .http:
                    guard let url = entry.url.flatMap(URL.init(string:)) else { throw MCPHandshakeError.badResponse("Bad URL.") }
                    result = try await MCPHandshake.http(url: url, headers: entry.headers)
                case .sse:
                    guard let url = entry.url.flatMap(URL.init(string:)) else { throw MCPHandshakeError.badResponse("Bad URL.") }
                    result = try await MCPHandshake.sse(url: url, headers: entry.headers)
                }
                return .healthy(result, Date())
            } catch {
                lastError = error
                if attempt < attempts - 1 { try? await Task.sleep(nanoseconds: 700_000_000) }
            }
        }
        return .failed(lastError.localizedDescription, Date())
    }

    // MARK: Connect

    func planConnect(_ entry: MCPServerEntry, agent: AgentKind, scope: AgentConfigScope) async throws -> ConfigChangePlan {
        let writer = self.writer
        return try await Task.detached { try writer.planConnect(entry, agent: agent, scope: scope) }.value
    }

    func planDisconnect(_ entry: DiscoveredMCPServer) async throws -> ConfigChangePlan {
        let writer = self.writer
        return try await Task.detached { try writer.planDisconnect(entry.name, agent: entry.agent, scope: entry.scope) }.value
    }

    func apply(_ plan: ConfigChangePlan) async throws -> ConfigChangeRecord {
        let writer = self.writer
        let record = try await Task.detached { try writer.apply(plan) }.value
        await load()
        return record
    }

    func undo(_ record: ConfigChangeRecord, force: Bool = false) async throws {
        let writer = self.writer
        try await Task.detached { try writer.undo(record, force: force) }.value
        await load()
    }

    func isUnchanged(_ record: ConfigChangeRecord) -> Bool {
        writer.isUnchangedSinceWrite(record)
    }

    // MARK: Keys

    func saveKey(_ key: String, for provider: HostedProvider) async throws {
        try await keys.save(key, for: provider)
        refreshProviders()
    }

    func removeKey(_ provider: HostedProvider) async throws {
        try await keys.remove(provider)
        refreshProviders()
    }

    func checkKey(_ provider: HostedProvider) async -> KeyCheckResult {
        await keys.check(provider)
    }

    // MARK: Helpers

    /// Next free host port for a new HTTP server.
    func freePort() -> Int {
        MCPLaunch.freePort(used: Set(installed.compactMap(\.hostPort)))
    }

    func isBusy(_ name: String) -> Bool { busy.contains(name) }

    /// Agents that look installed on this Mac, for the Connect menu. All when tools are not loaded yet.
    var installedAgents: [AgentKind] {
        guard toolsLoaded else { return AgentKind.allCases }
        let present = Set(tools.filter(\.installed).compactMap(\.tool.configAgent))
        let withConfig = Set(configFiles.filter(\.exists).map(\.agent))
        return AgentKind.allCases.filter { present.contains($0) || withConfig.contains($0) }
    }
}
