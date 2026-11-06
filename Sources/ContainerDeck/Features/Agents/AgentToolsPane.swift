import SwiftUI
import AppKit
import DeckCore

/// Agent tools on this Mac, sign in state, and how to point them at a local model.
struct AgentToolsPane: View {
    @Environment(AppState.self) private var state
    let store: AgentsStore
    @State private var endpointID: String?
    @State private var model = ""

    private var installed: [DetectedAgentTool] { store.tools.filter(\.installed) }
    private var missing: [DetectedAgentTool] { store.tools.filter { !$0.installed } }

    var body: some View {
        if !store.toolsLoaded {
            LoadingView("Looking for agent tools", style: .logo)
        } else {
            DeckPage {
                SectionHeader("Agents on this Mac", subtitle: "Command line agents and apps that can use MCP servers.", icon: .agents)
                VStack(spacing: 0) {
                    ForEach(Array(installed.enumerated()), id: \.element.id) { index, tool in
                        if index > 0 { Divider().padding(.leading, 52) }
                        toolRow(tool)
                    }
                    if installed.isEmpty {
                        Text("No agent tools found.").deckSecondaryText().padding(16)
                    }
                }
                .deckCard()

                localModels

                if !missing.filter({ $0.tool.installCommand != nil }).isEmpty {
                    SectionHeader("Not installed", subtitle: "Copy a command to install one in Terminal.", icon: .download)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12, alignment: .top)], spacing: 12) {
                        ForEach(missing.filter { $0.tool.installCommand != nil }) { tool in
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
        }
    }

    private func toolRow(_ tool: DetectedAgentTool) -> some View {
        let servers = store.discovered.filter { $0.agent == tool.tool.configAgent }.count
        return HStack(spacing: 12) {
            IconBadge(tool.tool.isApp ? .openExternal : .terminal, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tool.tool.title).fontWeight(.medium)
                    if let version = tool.version { Text(version).font(.caption).foregroundStyle(DS.textSecondary) }
                }
                Text(abbreviatedPath(tool.path ?? ""))
                    .font(.caption.monospaced())
                    .foregroundStyle(DS.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let signIn = tool.signIn {
                Pill(signIn, tint: DS.running)
            } else if let provider = tool.tool.provider, store.savedProviders.contains(provider) {
                Pill("\(provider.title) key in Keychain", tint: DS.accent)
            } else if tool.tool.provider != nil, !tool.tool.isApp {
                Pill("Not signed in", tint: DS.stopped)
            }
            if tool.tool.configAgent != nil {
                Pill(servers == 1 ? "1 MCP server" : "\(servers) MCP servers", tint: servers > 0 ? DS.accent : DS.stopped)
            } else {
                Pill("Own MCP setup", tint: DS.stopped)
                    .help("\(AppConfig.appName) does not edit this tool's config yet.")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
            .frame(height: 300)
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
                            .controlSize(.small)
                            .help("Run this in your terminal app")
                        }
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
