import SwiftUI
import DeckCore

/// What the Agents tab shows on the right: the overview or one agent.
enum AgentPaneSelection: Hashable {
    case overview
    case tool(AgentTool)
}

/// A profile open in the New Agent sheet. `isNew` is false when editing a saved one.
struct AgentProfileDraft: Identifiable {
    let id = UUID()
    var profile: AgentProfile
    var isNew: Bool
}

/// Progress of starting a profile in a sandbox, for the launch sheet.
struct AgentLaunchState: Identifiable {
    let id = UUID()
    var profile: AgentProfile
    var sandboxName: String
    var steps: [AgentSandboxStep]
    var current: AgentSandboxStep?
    var done: Set<AgentSandboxStep> = []
    var error: String?
    var finished = false
    var command: String?
    var note: String?
}

/// Profiles, running sessions, saved sessions and launches for the Agents tab.
/// Every process and file call goes through DeckCore.
@MainActor
@Observable
final class AgentWorkStore {
    private(set) var profiles: [AgentProfile] = []
    private(set) var profilesLoaded = false
    private(set) var sessions: [AgentTool: [AgentSession]] = [:]
    private(set) var sessionsLoaded = false
    private(set) var history: [AgentTool: [AgentSessionRecord]] = [:]
    private(set) var historyLoading: Set<AgentTool> = []
    private(set) var stopping: Set<Int32> = []
    var selection: AgentPaneSelection = .overview
    var editor: AgentProfileDraft?
    var launch: AgentLaunchState?

    @ObservationIgnored private let cache = AgentSessionCache()
    @ObservationIgnored private var scanning = false

    private var profileStore: AgentProfileStore { AgentProfileStore(folder: AgentPathsEnvironment.profilesFolder) }

    // MARK: Profiles

    func loadProfiles() async {
        let store = profileStore
        let list = await Task.detached { store.load() }.value
        if list != profiles { profiles = list }
        profilesLoaded = true
    }

    func save(_ profile: AgentProfile) throws {
        try profileStore.save(profile)
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        profiles.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func delete(_ profile: AgentProfile) throws {
        try profileStore.delete(profile)
        profiles.removeAll { $0.id == profile.id }
    }

    @discardableResult
    func duplicate(_ profile: AgentProfile) throws -> AgentProfile {
        let copy = AgentProfileStore.duplicate(profile, existing: profiles)
        try save(copy)
        return copy
    }

    func newProfile(tool: AgentTool, model: AgentModelChoice = .account, place: AgentRunPlace = .mac) {
        let name = profiles.contains { $0.name == tool.title } ? "\(tool.title) \(profiles.count + 1)" : tool.title
        editor = AgentProfileDraft(profile: AgentProfile(name: name, tool: tool, model: model, place: place), isNew: true)
    }

    // MARK: Sessions

    /// Running sessions of every installed command line agent.
    func refreshSessions(tools: [DetectedAgentTool], discovered: [DiscoveredMCPServer]) async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false; sessionsLoaded = true }
        var paths: [AgentTool: String] = [:]
        for tool in tools where !tool.tool.isApp { if let path = tool.path { paths[tool.tool] = path } }
        var servers: [AgentTool: [MCPServerEntry]] = [:]
        for tool in paths.keys {
            guard let agent = tool.configAgent else { continue }
            servers[tool] = discovered.filter { $0.agent == agent }.compactMap(\.entry)
        }
        let scanner = AgentProcessScanner(useMarkers: AgentPathsEnvironment.matchesPackageFolders)
        let found = await scanner.scan(tools: paths, servers: servers)
        if found != sessions { sessions = found }
    }

    func runningCount(_ tool: AgentTool) -> Int { sessions[tool]?.count ?? 0 }

    func refreshHistory(_ tool: AgentTool, resolver: AgentPathResolver) async {
        guard AgentSessionHistory.supported.contains(tool) else { return }
        historyLoading.insert(tool)
        defer { historyLoading.remove(tool) }
        let cache = self.cache
        let list = await Task.detached(priority: .userInitiated) {
            AgentSessionHistory.sessions(for: tool, resolver: resolver, cache: cache)
        }.value
        if list != history[tool] { history[tool] = list }
    }

    func isStopping(_ session: AgentSession) -> Bool { stopping.contains(session.pid) }

    func stop(_ session: AgentSession) async throws -> AgentProcessScanner.StopOutcome {
        stopping.insert(session.pid)
        defer { stopping.remove(session.pid) }
        let outcome = try await AgentProcessScanner().stop(session)
        sessions[session.tool]?.removeAll { $0.pid == session.pid }
        if sessions[session.tool]?.isEmpty == true { sessions[session.tool] = nil }
        return outcome
    }

    // MARK: Launch

    /// MCP entries for the profile's servers, as the agent should spawn or reach them.
    func entries(for profile: AgentProfile, agents: AgentsStore, cliPath: String) -> [MCPServerEntry] {
        agents.installed.filter { profile.mcpServers.contains($0.name) }.map { MCPLaunch.entry($0, cliPath: cliPath) }
    }

    /// The command for this Mac. Writes the per run MCP file (never secrets), the agent's own config stays as it is.
    func macPlan(_ profile: AgentProfile, agents: AgentsStore, cliPath: String) throws -> AgentLaunchPlan {
        let executable = agents.tools.first { $0.tool == profile.tool }?.path
        return try AgentLauncher.macPlan(profile, executable: executable, entries: entries(for: profile, agents: agents, cliPath: cliPath),
                                         runFolder: AgentPathsEnvironment.runsFolder)
    }

    func launchOnMac(_ profile: AgentProfile, agents: AgentsStore, state: AppState) {
        do {
            let plan = try macPlan(profile, agents: agents, cliPath: state.client?.cliPath ?? "/usr/local/bin/container")
            try AgentLauncher.writeFiles(plan)
            try TerminalLauncher.open(command: plan.command) { error in state.showError(error) }
            if let note = plan.notes.first { state.showToast(note, style: .info) }
        } catch {
            state.showError(error)
        }
    }

    func launch(_ profile: AgentProfile, agents: AgentsStore, state: AppState) {
        switch profile.place {
        case .mac: launchOnMac(profile, agents: agents, state: state)
        case .sandbox: Task { await launchInSandbox(profile, state: state) }
        }
    }

    /// Creates or reuses the profile's sandbox, waits for its network guard, then opens the terminal attached.
    func launchInSandbox(_ profile: AgentProfile, state: AppState) async {
        let spec: SandboxSpec
        do {
            spec = try AgentSandboxRecipe.spec(for: profile)
        } catch {
            state.showError(error)
            return
        }
        launch = AgentLaunchState(profile: profile, sandboxName: spec.name, steps: AgentSandboxStep.allCases)
        guard let client = state.client else {
            fail("The container tool is not set up.")
            return
        }
        let runtime = SandboxRuntime.shared
        runtime.attach()
        do {
            step(.volume)
            try await client.ensureAgentCacheVolume(AgentSandboxRecipe.cacheVolume(profile.tool),
                                          labels: [SandboxConfig.labelAgent: profile.tool.rawValue])
            let existing = try await client.listSandboxes().first { $0.name == spec.name }
            let action = AgentSandboxRecipe.action(existing: existing, spec: spec)
            step(.sandbox)
            switch action {
            case .create:
                runtime.clearKill(spec.name)
                try await client.createSandbox(spec, apiKey: nil)
            case .recreate:
                if let existing { try await runtime.remove(existing, client: client) }
                runtime.clearKill(spec.name)
                try await client.createSandbox(spec, apiKey: nil)
                launch?.note = "The settings changed, so the sandbox was made again. The installed tool was kept."
            case .start, .reuse:
                break
            }
            step(.starting)
            if action == .start, let existing { try await runtime.start(existing, client: client) }
            state.resourcesChanged()
            guard let sandbox = await waitForRunning(spec.name) else {
                throw DeckError.commandFailed("The sandbox did not start in time. Open Sandboxes to see why.")
            }
            step(.network)
            if sandbox.gatewayPlan != nil {
                try await waitForServices(sandbox.name)
            }
            step(.terminal)
            let command = try AgentSandboxRecipe.terminalCommand(profile, sandbox: sandbox, cliPath: client.cliPath)
            launch?.command = command
            try TerminalLauncher.open(command: command) { error in state.showError(error) }
            launch?.done.insert(.terminal)
            launch?.current = nil
            launch?.finished = true
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func step(_ step: AgentSandboxStep) {
        if let current = launch?.current { launch?.done.insert(current) }
        launch?.current = step
    }

    private func fail(_ message: String) {
        launch?.error = message
        launch?.finished = true
    }

    private func waitForRunning(_ name: String) async -> Sandbox? {
        for _ in 0..<40 {
            BackgroundServices.shared.pollNow()
            SandboxRuntime.shared.reconcile(BackgroundServices.shared.containers)
            if let box = SandboxRuntime.shared.sandboxes.first(where: { $0.name == name }), box.isRunning, box.gateway != nil { return box }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }

    private func waitForServices(_ name: String) async throws {
        for _ in 0..<40 {
            if SandboxRuntime.shared.activeServices.contains(name) { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
        let reason = SandboxRuntime.shared.serviceErrors[name] ?? "The network guard did not start in time."
        throw DeckError.commandFailed(reason)
    }
}
