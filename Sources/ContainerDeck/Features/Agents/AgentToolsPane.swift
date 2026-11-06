import SwiftUI
import AppKit
import DeckCore

/// The Agents tab: agents on this Mac on the left, and on the right either the overview
/// (saved profiles, local models, tools to install) or one agent's details.
struct AgentToolsPane: View {
    @Environment(AppState.self) private var state
    let store: AgentsStore
    @Bindable var work: AgentWorkStore

    private var installed: [DetectedAgentTool] { store.tools.filter(\.installed) }

    var body: some View {
        if !store.toolsLoaded {
            LoadingView("Looking for agent tools", style: .logo)
        } else {
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 236)
                Divider()
                Group {
                    switch work.selection {
                    case .overview:
                        AgentsOverviewPage(store: store, work: work)
                    case .tool(let tool):
                        if let detected = installed.first(where: { $0.tool == tool }) {
                            AgentDetailView(store: store, work: work, tool: detected)
                                .id(tool)
                        } else {
                            AgentsOverviewPage(store: store, work: work)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .task {
                // Running sessions feed the counts on the left. Light: one ps call.
                while !Task.isCancelled {
                    await work.refreshSessions(tools: store.tools, discovered: store.discovered)
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                row(selection: .overview, icon: .agents, title: "Overview", detail: "Profiles and local models", running: 0)
                Text("On this Mac")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DS.textTertiary)
                    .padding(.horizontal, 10)
                    .padding(.top, 14)
                    .padding(.bottom, 4)
                ForEach(installed) { tool in
                    row(selection: .tool(tool.tool), icon: tool.tool.isApp ? .openExternal : .terminal, title: tool.tool.title,
                        detail: tool.version ?? (tool.tool.isApp ? "App" : "Command line"), running: work.runningCount(tool.tool))
                }
                if installed.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No agents found.").deckSecondaryText()
                        AgentSettingsLink()
                    }
                    .padding(10)
                }
            }
            .padding(10)
        }
        .background(DS.surface)
    }

    private func row(selection: AgentPaneSelection, icon: DeckIconName, title: String, detail: String, running: Int) -> some View {
        let selected = work.selection == selection
        return Button {
            work.selection = selection
        } label: {
            HStack(spacing: 10) {
                IconBadge(icon, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).fontWeight(.medium).foregroundStyle(DS.textPrimary).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(DS.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if running > 0 {
                    HStack(spacing: 4) {
                        Circle().fill(DS.running).frame(width: 6, height: 6)
                        Text("\(running)").font(.caption.monospacedDigit()).foregroundStyle(DS.textSecondary)
                    }
                    .help(running == 1 ? "1 running session" : "\(running) running sessions")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: DS.smallRadius).fill(selected ? DS.accentSoft : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Overview

/// Saved profiles, the local model commands and tools that are not installed.
struct AgentsOverviewPage: View {
    @Environment(AppState.self) private var state
    let store: AgentsStore
    @Bindable var work: AgentWorkStore
    @State private var endpointID: String?
    @State private var model = ""
    @State private var deleting: AgentProfile?

    private var installed: [DetectedAgentTool] { store.tools.filter(\.installed) }
    private var missing: [DetectedAgentTool] { store.tools.filter { !$0.installed && $0.tool.installCommand != nil } }

    var body: some View {
        DeckPage {
            profilesSection
            localModels
            if !missing.isEmpty {
                SectionHeader("Not installed", subtitle: "Copy a command to install one in Terminal.", icon: .download) {
                    AgentSettingsLink(title: "Installed somewhere else?")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12, alignment: .top)], spacing: 12) {
                    ForEach(missing) { tool in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(tool.tool.title).font(.headline)
                            CommandHint(tool.tool.installCommand ?? "")
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .deckCard()
                    }
                }
            }
        }
        .confirmDelete($deleting, title: { "Delete \($0.name)?" },
                       message: "Only the profile is deleted. Its sandbox, folder and the agent stay.") { profile in
            do { try work.delete(profile) } catch { state.showError(error) }
        }
    }

    // MARK: Profiles

    @ViewBuilder
    private var profilesSection: some View {
        SectionHeader("Agent profiles", subtitle: "An agent with its model, MCP servers and folder. Start it in one click.", icon: .agents) {
            Button {
                work.newProfile(tool: installed.first(where: { !$0.tool.isApp })?.tool ?? .claude)
            } label: {
                DeckLabel("New Agent", icon: .add)
            }
            .deckPrimary()
        }
        if work.profiles.isEmpty {
            HStack(spacing: 14) {
                IconBadge(.agents, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text("No profiles yet").font(.headline)
                    Text("Pick an agent, a model and a folder. Run it on this Mac or in a sandbox.")
                        .deckSecondaryText()
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .deckCard()
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: Layout.cardSpacing, alignment: .top)], spacing: Layout.cardSpacing) {
                ForEach(work.profiles) { profile in
                    profileCard(profile)
                }
            }
        }
    }

    private func profileCard(_ profile: AgentProfile) -> some View {
        let toolInstalled = installed.contains { $0.tool == profile.tool }
        let canLaunch = profile.place == .sandbox ? AgentSandboxRecipe.supports(profile.tool) : toolInstalled
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                IconBadge(profile.place == .sandbox ? .sandboxes : .terminal, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name).font(.headline).lineLimit(1)
                    Text(profile.tool.title).font(.caption).foregroundStyle(DS.textSecondary)
                }
                Spacer(minLength: 4)
                Pill(profile.place.title, tint: profile.place == .sandbox ? DS.accent : DS.stopped)
            }
            VStack(alignment: .leading, spacing: 4) {
                detailLine(.aiModels, profile.model.title)
                detailLine(.folder, profile.workspace.map(abbreviatedPath) ?? "No folder")
                detailLine(.link, profile.mcpServers.isEmpty ? "No MCP servers" :
                            (profile.mcpServers.count == 1 ? "1 MCP server" : "\(profile.mcpServers.count) MCP servers"))
            }
            if !canLaunch {
                Text(profile.place == .sandbox ? "\(profile.tool.title) cannot run in a sandbox yet." : "\(profile.tool.title) is not installed.")
                    .font(.caption)
                    .foregroundStyle(DS.warning)
            }
            HStack(spacing: 8) {
                Button {
                    work.launch(profile, agents: store, state: state)
                } label: {
                    DeckLabel("Launch", icon: .play)
                }
                .deckPrimary()
                .disabled(!canLaunch)
                Button("Edit") { work.editor = AgentProfileDraft(profile: profile, isNew: false) }
                Button("Duplicate") {
                    do { try work.duplicate(profile) } catch { state.showError(error) }
                }
                Spacer(minLength: 0)
                Button {
                    deleting = profile
                } label: {
                    DeckIcon(.trash, size: 13)
                }
                .help("Delete profile")
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .deckCard()
    }

    private func detailLine(_ icon: DeckIconName, _ text: String) -> some View {
        HStack(spacing: 6) {
            DeckIcon(icon, size: 12, color: DS.textTertiary)
                .environment(\.deckIconMonochrome, true)
                .frame(width: 16)
            Text(text).font(.callout).foregroundStyle(DS.textSecondary).lineLimit(1).truncationMode(.middle)
        }
    }

    // MARK: Local models

    private var endpoint: AgentModelEndpoint? {
        store.endpoints.first { $0.id == endpointID } ?? store.endpoints.first
    }

    @ViewBuilder
    private var localModels: some View {
        SectionHeader("Use a local model", subtitle: "Start an agent against a model server on this Mac. Nothing leaves your Mac.", icon: .aiModels)
        if store.endpoints.isEmpty {
            EmptyState(icon: .aiModels, title: "No local model server found",
                       message: "Start Ollama, LM Studio or the MLX server, then refresh.",
                       actionTitle: "Open AI Models") {
                state.selection = .aiModels
            }
            .frame(height: 260)
            .deckCard()
        } else if let endpoint {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Picker("Server", selection: Binding(get: { endpoint.id }, set: { endpointID = $0; model = "" })) {
                        ForEach(store.endpoints) { Text("\($0.name)  \($0.baseURL)").tag($0.id) }
                    }
                    .frame(maxWidth: 360)
                    .popUpAppearanceRefresh()
                    Picker("Model", selection: Binding(get: { model.isEmpty ? (endpoint.models.first ?? "") : model }, set: { model = $0 })) {
                        ForEach(endpoint.models, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(maxWidth: 300)
                    .disabled(endpoint.models.isEmpty)
                    .popUpAppearanceRefresh()
                    Spacer(minLength: 0)
                }
                let chosen = model.isEmpty ? (endpoint.models.first ?? "") : model
                let recipes = installed.compactMap { tool in
                    LocalAgentRecipe.command(tool.tool, endpoint: endpoint, model: chosen).map { (tool, $0) }
                }
                if recipes.isEmpty || chosen.isEmpty {
                    Text(chosen.isEmpty ? "This server has no models yet." : "None of the installed agents can use this server directly. Aider, Codex, Goose and Claude Code (with Ollama) can.")
                        .deckSecondaryText()
                }
                if !chosen.isEmpty {
                    ForEach(recipes, id: \.0.id) { tool, command in
                        HStack(spacing: 10) {
                            Text(tool.tool.title).fontWeight(.medium).frame(width: 110, alignment: .leading)
                            CommandHint(command)
                            Button {
                                openInTerminal(command)
                            } label: {
                                DeckLabel("Open", icon: .terminal)
                            }
                            .help("Run this in your terminal app")
                            if AgentSandboxRecipe.supports(tool.tool) {
                                Button {
                                    let local = AgentLocalModel(server: endpoint.name, kind: endpoint.kind, baseURL: endpoint.baseURL, model: chosen)
                                    work.newProfile(tool: tool.tool, model: .local(local), place: .sandbox)
                                } label: {
                                    DeckLabel("Sandbox", icon: .sandboxes)
                                }
                                .help("Run this agent and model in a sandbox")
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .deckCard()
        }
    }

    private func openInTerminal(_ command: String) {
        do {
            try TerminalLauncher.open(command: command) { error in state.showError(error) }
        } catch {
            state.showError(error)
        }
    }
}
