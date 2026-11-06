import SwiftUI
import AppKit
import DeckCore

/// New Agent and Edit Agent: tool, model, MCP servers, folder and where it runs.
struct AgentProfileSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let store: AgentsStore
    let work: AgentWorkStore
    let draft: AgentProfileDraft

    @State private var name = ""
    @State private var tool: AgentTool = .claude
    @State private var modelMode = "account"
    @State private var provider: HostedProvider = .anthropic
    @State private var endpointID = ""
    @State private var modelName = ""
    @State private var savedLocal: AgentLocalModel?
    @State private var servers: Set<String> = []
    @State private var onlyProfileServers = false
    @State private var workspace = ""
    @State private var place: AgentRunPlace = .mac
    @State private var egress: SandboxEgress = .allowList
    @State private var extraHosts = ""
    @State private var workspaceReadOnly = false
    @State private var cpus = SandboxConfig.defaultCPUs
    @State private var memoryMB = 4096
    @State private var loaded = false

    private static let memoryChoices = [2048, 4096, 8192, 16384]

    private var installedTools: Set<AgentTool> { Set(store.tools.filter(\.installed).map(\.tool)) }
    /// Command line tools that are installed, or that a sandbox can install.
    private var toolChoices: [AgentTool] {
        AgentTool.allCases.filter { !$0.isApp && (installedTools.contains($0) || AgentSandboxRecipe.supports($0)) }
    }
    private var isInstalled: Bool { installedTools.contains(tool) }
    private var providers: [HostedProvider] { AgentLauncher.providers(for: tool) }
    private var localEndpoints: [AgentModelEndpoint] { store.endpoints.filter { LocalAgentRecipe.supports(tool, endpoint: $0) } }
    private var endpoint: AgentModelEndpoint? { localEndpoints.first { $0.id == endpointID } ?? localEndpoints.first }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private var modelChoice: AgentModelChoice? {
        switch modelMode {
        case "key": return providers.contains(provider) ? .providerKey(provider) : nil
        case "local":
            if let endpoint {
                let chosen = modelName.isEmpty ? (endpoint.models.first ?? "") : modelName
                guard !chosen.isEmpty else { return nil }
                return .local(AgentLocalModel(server: endpoint.name, kind: endpoint.kind, baseURL: endpoint.baseURL, model: chosen))
            }
            if let savedLocal, LocalAgentRecipe.supports(tool, endpoint: savedLocal.endpoint) { return .local(savedLocal) }
            return nil
        default: return AgentLauncher.hasOwnAccount(tool) ? .account : nil
        }
    }

    private var profile: AgentProfile? {
        guard let model = modelChoice, !trimmedName.isEmpty else { return nil }
        var result = draft.profile
        result.name = trimmedName
        result.tool = tool
        result.model = model
        result.mcpServers = servers.sorted()
        result.onlyProfileServers = onlyProfileServers
        result.workspace = workspace.isEmpty ? nil : workspace
        result.place = place
        result.sandbox = AgentSandboxOptions(egress: egress.rawValue, extraHosts: EgressPolicy.parseList(extraHosts),
                                             workspaceReadOnly: workspaceReadOnly, cpus: cpus, memoryMB: memoryMB)
        return result
    }

    private var problem: String? {
        if trimmedName.isEmpty { return "Give the profile a name." }
        if work.profiles.contains(where: { $0.name == trimmedName && $0.id != draft.profile.id }) { return "Another profile has this name." }
        if place == .mac && !isInstalled { return "\(tool.title) is not installed on this Mac. Pick Sandbox to install it there." }
        if place == .sandbox && !AgentSandboxRecipe.supports(tool) { return "\(tool.title) cannot run in a sandbox yet." }
        if modelChoice == nil {
            switch modelMode {
            case "local": return "Pick a model server and a model."
            case "key": return "\(tool.title) cannot use a \(provider.title) key."
            default: return "\(tool.title) has no account of its own. Pick a key or a local model."
            }
        }
        if place == .sandbox && egress == .allowList && !EgressPolicy.invalidEntries(extraHosts).isEmpty {
            return "Some extra hosts are not valid."
        }
        return nil
    }

    var body: some View {
        SheetScaffold(draft.isNew ? "New Agent" : "Edit Agent",
                      subtitle: "An agent with its model, MCP servers and folder, ready to start.", icon: .agents, width: 640) {
            agentGroup
            modelGroup
            serversGroup
            placeGroup
            previewGroup
            if let problem, loaded {
                ResourceWarningText(problem)
            }
        } footer: {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save") { save(launch: false) }
                .disabled(profile == nil || problem != nil)
            Button("Save and Launch") { save(launch: true) }
                .deckPrimary()
                .keyboardShortcut(.defaultAction)
                .disabled(profile == nil || problem != nil)
        }
        .frame(height: 720)
        .onAppear(perform: fill)
        .onChange(of: tool) { _, _ in fixModelMode() }
        .onDeckDebugCommand { name, value in
            switch name {
            case "agent-form-name": self.name = value
            case "agent-form-folder": workspace = value
            case "agent-form-place": place = AgentRunPlace(rawValue: value) ?? place
            case "agent-form-model": modelMode = value
            case "agent-form-server": if servers.contains(value) { servers.remove(value) } else { servers.insert(value) }
            case "agent-form-save": save(launch: value == "launch")
            default: break
            }
        }
    }

    // MARK: Groups

    private var agentGroup: some View {
        DeckFormGroup("Agent") {
            DeckFormRow("Name") {
                TextField("Name", text: $name, prompt: Text("Claude in my app"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            }
            DeckFormRow("Tool", note: isInstalled ? nil : "Not on this Mac. A sandbox installs it on first start.") {
                Picker("Tool", selection: $tool) {
                    ForEach(toolChoices) { item in
                        Text(installedTools.contains(item) ? item.title : "\(item.title) (sandbox only)").tag(item)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .popUpAppearanceRefresh()
            }
            DeckFormRow("Folder", note: workspace.isEmpty ? "Optional. The agent starts here." : nil) {
                HStack(spacing: 8) {
                    Text(workspace.isEmpty ? "None" : abbreviatedPath(workspace))
                        .font(workspace.isEmpty ? .body : .body.monospaced())
                        .foregroundStyle(workspace.isEmpty ? DS.textTertiary : DS.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !workspace.isEmpty {
                        Button("Clear") { workspace = "" }
                    }
                    Button("Choose…", action: chooseFolder)
                }
            }
        }
    }

    private var modelGroup: some View {
        DeckFormGroup("Model") {
            DeckFormRow("Source", note: modelMode == "account" ? accountNote : nil) {
                Picker("Source", selection: $modelMode) {
                    if AgentLauncher.hasOwnAccount(tool) { Text("Own account").tag("account") }
                    if !providers.isEmpty { Text("API key").tag("key") }
                    Text("Local model").tag("local")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            switch modelMode {
            case "key":
                DeckFormRow("Provider", note: keyNote) {
                    Picker("Provider", selection: $provider) {
                        ForEach(providers) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .popUpAppearanceRefresh()
                }
            case "local":
                if let endpoint {
                    DeckFormRow("Server") {
                        Picker("Server", selection: Binding(get: { endpoint.id }, set: { endpointID = $0; modelName = "" })) {
                            ForEach(localEndpoints) { Text("\($0.name)  \($0.baseURL)").tag($0.id) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 380)
                        .popUpAppearanceRefresh()
                    }
                    DeckFormRow("Model") {
                        Picker("Model", selection: Binding(get: { modelName.isEmpty ? (endpoint.models.first ?? "") : modelName },
                                                           set: { modelName = $0 })) {
                            ForEach(endpoint.models, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 380)
                        .disabled(endpoint.models.isEmpty)
                        .popUpAppearanceRefresh()
                    }
                } else if let savedLocal {
                    DeckFormRow("Server", note: "Not running now. Start it before you launch.") {
                        Text("\(savedLocal.server), \(savedLocal.model)").font(.body.monospaced())
                    }
                } else {
                    DeckFormNote(LocalAgentRecipe.supports(tool, kind: .ollama) || LocalAgentRecipe.supports(tool, kind: .lmStudio)
                                 ? "No model server this agent can use is running. Start Ollama, LM Studio or MLX."
                                 : "\(tool.title) cannot use a local model server.")
                }
            default:
                EmptyView()
            }
        }
    }

    private var accountNote: String {
        if let signIn = store.tools.first(where: { $0.tool == tool })?.signIn {
            return place == .sandbox ? "Signed in on this Mac as \(signIn). In a sandbox, sign in once inside it." : "Uses \(signIn)."
        }
        return place == .sandbox ? "Sign in once inside the sandbox. The sign in is kept for later runs." : "Uses the agent's own sign in."
    }

    private var keyNote: String {
        if store.savedProviders.contains(provider) {
            return "Read from the Keychain when the agent starts. Never saved in the profile."
        }
        return "No \(provider.title) key saved yet. Add one in the API Keys tab."
    }

    private var serversGroup: some View {
        DeckFormGroup("MCP servers") {
            if store.installed.isEmpty {
                DeckFormNote("No MCP servers in \(AppConfig.appName) yet. Add one from the Catalog tab.")
            } else {
                ForEach(store.installed) { server in
                    Toggle(isOn: Binding(get: { servers.contains(server.name) },
                                         set: { if $0 { servers.insert(server.name) } else { servers.remove(server.name) } })) {
                        HStack(spacing: 6) {
                            Text(server.name)
                            Pill(server.transport.title, tint: server.transport.tint)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                switch (place, AgentMCPRunSupport.of(tool)) {
                case (.sandbox, _):
                    DeckFormNote("MCP servers are not passed into sandboxes yet.")
                case (_, .configFile):
                    Toggle("Use only these servers", isOn: $onlyProfileServers)
                        .toggleStyle(.checkbox)
                    DeckFormNote("Given with --mcp-config for each run. The agent's own config does not change.")
                case (_, .configOverrides):
                    DeckFormNote("Given with -c for each run. The agent's own config does not change.")
                case (_, .none):
                    HStack(spacing: 8) {
                        DeckFormNote("\(tool.title) reads MCP servers only from its own config.")
                        if tool.configAgent != nil, isInstalled {
                            Button("Connect There") {
                                work.selection = .tool(tool)
                                dismiss()
                            }
                            .deckLink()
                        }
                    }
                }
            }
        }
    }

    private var placeGroup: some View {
        DeckFormGroup("Run on") {
            DeckFormRow("Where") {
                Picker("Where", selection: $place) {
                    ForEach(AgentRunPlace.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if place == .sandbox {
                DeckFormRow("Network") {
                    Picker("Network", selection: $egress) {
                        Text("Allow list").tag(SandboxEgress.allowList)
                        Text("Internet").tag(SandboxEgress.open)
                        Text("Isolated").tag(SandboxEgress.isolated)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    if egress == .isolated {
                        DeckFormNote("No internet, so the first run cannot install the tool. Use it after one run with the allow list.")
                    }
                }
                if egress == .allowList {
                    DeckFormRow("Allowed", note: "What \(tool.title) and its install need. Add more below.") {
                        Text(defaultHosts.joined(separator: "  "))
                            .font(.callout.monospaced())
                            .foregroundStyle(DS.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    DeckFormRow("Also allow") {
                        TextField("Also allow", text: $extraHosts, prompt: Text("github.com *.githubusercontent.com"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                    }
                }
                DeckFormRow("Folder access") {
                    Picker("Folder access", selection: $workspaceReadOnly) {
                        Text("Read and write").tag(false)
                        Text("Read only").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .disabled(workspace.isEmpty)
                }
                DeckFormRow("Size") {
                    HStack(spacing: 14) {
                        Stepper(value: $cpus, in: 1...max(1, ProcessInfo.processInfo.activeProcessorCount)) {
                            Text("\(cpus) CPUs").monospacedDigit()
                        }
                        .fixedSize()
                        Picker("Memory", selection: $memoryMB) {
                            ForEach(Self.memoryChoices, id: \.self) { Text("\($0 / 1024) GB").tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .popUpAppearanceRefresh()
                    }
                }
            }
        }
    }

    private var defaultHosts: [String] {
        AgentSandboxRecipe.defaultAllowList(tool, model: modelChoice ?? .account)
    }

    @ViewBuilder
    private var previewGroup: some View {
        if let profile, problem == nil {
            DeckFormGroup("What runs") {
                if place == .mac {
                    if let plan = try? work.macPlan(profile, agents: store, cliPath: state.client?.cliPath ?? "/usr/local/bin/container") {
                        CommandHint(plan.command)
                        DeckFormNote("Opens in your terminal app. Keys are read from the Keychain at that moment.")
                    }
                } else {
                    let name = AgentSandboxRecipe.sandboxName(for: profile)
                    DeckFormNote("Creates or reuses the sandbox \(name), then opens the terminal inside it. "
                                 + "\(tool.title) is installed into the volume \(AgentSandboxRecipe.cacheVolume(tool)) the first time.")
                }
            }
        }
    }

    // MARK: Actions

    private func fill() {
        guard !loaded else { return }
        let p = draft.profile
        name = p.name
        tool = p.tool
        servers = Set(p.mcpServers)
        onlyProfileServers = p.onlyProfileServers
        workspace = p.workspace ?? ""
        place = p.place
        egress = p.sandbox.egressMode
        extraHosts = p.sandbox.extraHosts.joined(separator: " ")
        workspaceReadOnly = p.sandbox.workspaceReadOnly
        cpus = p.sandbox.cpus
        memoryMB = p.sandbox.memoryMB
        switch p.model {
        case .account: modelMode = "account"
        case .providerKey(let value):
            modelMode = "key"
            provider = value
        case .local(let local):
            modelMode = "local"
            savedLocal = local
            if let match = store.endpoints.first(where: { $0.baseURL == local.baseURL }) {
                endpointID = match.id
                modelName = match.models.contains(local.model) ? local.model : ""
            }
        }
        fixModelMode()
        DispatchQueue.main.async { loaded = true }
    }

    /// Keeps the model source valid for the picked tool.
    private func fixModelMode() {
        if modelMode == "account" && !AgentLauncher.hasOwnAccount(tool) { modelMode = providers.isEmpty ? "local" : "key" }
        if modelMode == "key" && providers.isEmpty { modelMode = AgentLauncher.hasOwnAccount(tool) ? "account" : "local" }
        if !providers.contains(provider), let first = providers.first { provider = store.savedProviders.first(where: providers.contains) ?? first }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if !workspace.isEmpty { panel.directoryURL = URL(fileURLWithPath: workspace) }
        if panel.runModal() == .OK, let url = panel.url { workspace = url.path }
    }

    private func save(launch: Bool) {
        guard let profile, problem == nil else { return }
        do {
            try work.save(profile)
            dismiss()
            if launch {
                let agents = store
                let state = self.state
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    work.launch(profile, agents: agents, state: state)
                }
            } else {
                state.showToast("Saved \(profile.name)", style: .success)
            }
        } catch {
            state.showError(error)
        }
    }
}
