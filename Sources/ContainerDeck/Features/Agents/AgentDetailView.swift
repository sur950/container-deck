import SwiftUI
import AppKit
import DeckCore

/// Tabs of one agent's detail.
enum AgentDetailTab: String, CaseIterable, Identifiable {
    case overview, servers, sessions, history
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "Overview"
        case .servers: return "MCP Servers"
        case .sessions: return "Running"
        case .history: return "Recent"
        }
    }
}

/// One agent: where it lives, its MCP servers, running sessions and saved sessions.
struct AgentDetailView: View {
    @Environment(AppState.self) private var state
    let store: AgentsStore
    @Bindable var work: AgentWorkStore
    let tool: DetectedAgentTool
    @State private var tab: AgentDetailTab = .overview
    @State private var connectTarget: ConnectTarget?
    @State private var stopping: AgentSession?

    private var agent: AgentKind? { tool.tool.configAgent }
    private var tabs: [AgentDetailTab] {
        var list: [AgentDetailTab] = [.overview, .servers]
        if !tool.tool.isApp { list.append(.sessions) }
        if AgentSessionHistory.supported.contains(tool.tool) { list.append(.history) }
        return list
    }
    private var servers: [DiscoveredMCPServer] {
        guard let agent else { return [] }
        return store.discovered.filter { $0.agent == agent }
    }
    private var sessions: [AgentSession] { work.sessions[tool.tool] ?? [] }
    private var history: [AgentSessionRecord] { work.history[tool.tool] ?? [] }
    private var cliPath: String { state.client?.cliPath ?? "/usr/local/bin/container" }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, Layout.pagePadding)
                .padding(.top, 18)
                .padding(.bottom, 12)
            HStack {
                SegmentedFilter(selection: $tab, options: tabs, label: { $0.title }, count: count)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Layout.pagePadding)
            .padding(.bottom, 10)
            Divider()
            Group {
                switch tab {
                case .overview: overview
                case .servers: serversTab
                case .sessions: sessionsTab
                case .history: historyTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DS.surface)
        .task(id: tab) {
            if tab == .history { await work.refreshHistory(tool.tool, resolver: store.resolver) }
        }
        .task {
            if AgentSessionHistory.supported.contains(tool.tool) { await work.refreshHistory(tool.tool, resolver: store.resolver) }
        }
        .sheet(item: $connectTarget) { target in
            MCPConnectSheet(store: store, target: target)
                .environment(state)
        }
        .confirmDelete($stopping, title: { "Stop \(tool.tool.title) in \(($0.folder.map(abbreviatedPath)) ?? "process \($0.pid)")?" },
                       message: "Unsaved work in that session is lost. It gets a few seconds to quit, then it is stopped.",
                       actionTitle: "Stop Session") { session in
            stop(session)
        }
        .onDeckDebugCommand { name, value in
            guard name == "agent-tab", let next = AgentDetailTab(rawValue: value) else { return }
            tab = next
        }
    }

    private func count(_ tab: AgentDetailTab) -> Int? {
        switch tab {
        case .overview: return nil
        case .servers: return agent == nil ? nil : servers.count
        case .sessions: return work.sessionsLoaded ? sessions.count : nil
        case .history: return work.history[tool.tool]?.count
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            IconBadge(tool.tool.isApp ? .openExternal : .terminal, size: 38)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(tool.tool.title).font(.title3.weight(.semibold))
                    if let version = tool.version { Pill(version, tint: DS.stopped) }
                }
                HStack(spacing: 6) {
                    accountPill
                    if !sessions.isEmpty {
                        Pill(sessions.count == 1 ? "1 running" : "\(sessions.count) running", tint: DS.running)
                    }
                }
            }
            Spacer(minLength: 8)
            if !tool.tool.isApp {
                Button {
                    work.newProfile(tool: tool.tool)
                } label: {
                    DeckLabel("New Profile", icon: .add)
                }
                .help("Save this agent with a model, MCP servers and a folder")
            }
        }
    }

    @ViewBuilder
    private var accountPill: some View {
        if let signIn = tool.signIn {
            Pill(signIn, tint: DS.running)
        } else if let provider = tool.tool.provider, store.savedProviders.contains(provider) {
            Pill("\(provider.title) key in Keychain", tint: DS.accent)
        } else if tool.tool.provider != nil, !tool.tool.isApp {
            Pill("Not signed in", tint: DS.stopped)
        } else {
            Pill(tool.tool.isApp ? "App" : "Command line", tint: DS.stopped)
        }
    }

    // MARK: Overview

    private var overview: some View {
        DeckPage {
            Card("Where it lives", icon: .folder) {
                VStack(alignment: .leading, spacing: 10) {
                    pathRow("Program", store.resolver.executable(tool.tool), reveal: true)
                    if let config = store.resolver.configFile(tool.tool) {
                        pathRow("MCP config", config, reveal: config.exists)
                    }
                    if let sessions = store.resolver.sessionsFolder(tool.tool) {
                        pathRow("Sessions", sessions, reveal: sessions.exists)
                    }
                    HStack {
                        Spacer()
                        AgentSettingsLink(title: "Change paths in Settings")
                    }
                }
            }
            if let agent {
                let files = store.configFiles.filter { $0.agent == agent && $0.exists }
                if !files.isEmpty {
                    Card("Config files", icon: .file) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                                if index > 0 { Divider().padding(.vertical, 6) }
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(abbreviatedPath(file.path)).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                                        Text(file.problem ?? (file.serverCount == 1 ? "1 MCP server" : "\(file.serverCount) MCP servers"))
                                            .font(.caption)
                                            .foregroundStyle(file.problem == nil ? DS.textSecondary : DS.warning)
                                    }
                                    Spacer(minLength: 8)
                                    revealButton(file.path)
                                }
                            }
                        }
                    }
                }
            }
            Card("Launch options", icon: .play) {
                VStack(alignment: .leading, spacing: 8) {
                    KeyValueRow("MCP per run", value: mcpRunText)
                    KeyValueRow("Local models", value: localModelText)
                    KeyValueRow("Sandbox", value: AgentSandboxRecipe.supports(tool.tool)
                                ? "Installs with \(installerName) on first start" : "Not yet")
                }
            }
        }
    }

    private var installerName: String {
        if case .pip = AgentSandboxRecipe.installer(tool.tool) { return "pip" }
        return "npm"
    }

    private var mcpRunText: String {
        switch AgentMCPRunSupport.of(tool.tool) {
        case .configFile: return "--mcp-config file for one run"
        case .configOverrides: return "-c overrides for one run"
        case .none: return "Not supported. Connect servers to its config."
        }
    }

    private var localModelText: String {
        let kinds: [(AgentModelEndpoint.Kind, String)] = [(.ollama, "Ollama"), (.lmStudio, "LM Studio"), (.mlx, "MLX")]
        let names = kinds.filter { LocalAgentRecipe.supports(tool.tool, kind: $0.0) }.map(\.1)
        return names.isEmpty ? "Not supported" : names.joined(separator: ", ")
    }

    private func pathRow(_ title: String, _ path: ResolvedAgentPath, reveal: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).foregroundStyle(DS.textSecondary).frame(width: 96, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(path.path.map(abbreviatedPath) ?? "Not found")
                    .font(.callout.monospaced())
                    .foregroundStyle(path.path == nil ? DS.warning : DS.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(sourceText(path)).font(.caption).foregroundStyle(path.exists ? DS.textTertiary : DS.warning)
            }
            Spacer(minLength: 8)
            if reveal, let file = path.path, path.exists { revealButton(file) }
        }
    }

    private func sourceText(_ path: ResolvedAgentPath) -> String {
        var text = path.source.title
        if let variable = path.variable { text += " (\(variable))" }
        if path.path != nil && !path.exists { text += ", does not exist yet" }
        return text
    }

    private func revealButton(_ path: String) -> some View {
        Button("Reveal") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        .controlSize(.small)
        .help("Show in Finder")
    }

    // MARK: MCP servers

    /// Servers known to the app that this agent does not have yet.
    private var connectable: [(name: String, entry: MCPServerEntry, managed: Bool)] {
        guard agent != nil else { return [] }
        let present = Set(servers.map(\.name))
        let rows = store.rows(containers: BackgroundServices.shared.containers, cliPath: cliPath)
        return rows.filter { !present.contains($0.name) }.compactMap { row in
            if let server = row.installed { return (row.name, MCPLaunch.entry(server, cliPath: cliPath), true) }
            guard var entry = row.entries.first?.entry else { return nil }
            entry.name = row.name
            return (row.name, entry, false)
        }
    }

    @ViewBuilder
    private var serversTab: some View {
        if let agent {
            DeckPage {
                SectionHeader("In \(agent.title)'s config", subtitle: "Servers this agent loads. Removing one shows the change first and keeps a backup.",
                              icon: .link)
                if servers.isEmpty {
                    Text("No MCP servers in this agent's config yet.").deckSecondaryText()
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .deckCard()
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(servers.enumerated()), id: \.element.id) { index, server in
                            if index > 0 { Divider().padding(.leading, 14) }
                            serverRow(server)
                        }
                    }
                    .deckCard()
                }
                SectionHeader("Connect a server", subtitle: "Servers from \(AppConfig.appName) and other agents. You see the change before it is written.",
                              icon: .add)
                let options = connectable
                if options.isEmpty {
                    Text("Every server known here is already connected.").deckSecondaryText()
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .deckCard()
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(options.enumerated()), id: \.element.name) { index, option in
                            if index > 0 { Divider().padding(.leading, 14) }
                            HStack(spacing: 10) {
                                DeckIcon(option.managed ? .containers : .agents, size: 14, color: DS.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.name).fontWeight(.medium)
                                    Text(option.entry.target).font(.caption.monospaced()).foregroundStyle(DS.textTertiary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer(minLength: 8)
                                Pill(option.entry.transport.title, tint: option.entry.transport.tint)
                                Button("Connect") { connectTarget = ConnectTarget(mode: .connect(option.entry, agent)) }
                                    .controlSize(.small)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        }
                    }
                    .deckCard()
                }
                Text("Each change keeps a backup and can be undone from Changes in the toolbar.")
                    .font(.caption)
                    .foregroundStyle(DS.textSecondary)
            }
        } else {
            EmptyState(icon: .agents, title: "\(tool.tool.title) keeps its own MCP setup",
                       message: "\(AppConfig.appName) does not edit this tool's config yet. Add servers in the tool itself.")
        }
    }

    private func serverRow(_ server: DiscoveredMCPServer) -> some View {
        HStack(spacing: 10) {
            DeckIcon(server.managedServer != nil ? .containers : .agents, size: 14, color: DS.accent)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(server.name).fontWeight(.medium)
                    if server.disabled { Pill("Off", tint: DS.stopped) }
                }
                Text(server.target).font(.caption.monospaced()).foregroundStyle(DS.textTertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Pill(server.scope.label, tint: DS.stopped)
            Pill(server.transport.title, tint: server.transport.tint)
            Button("Disconnect") { connectTarget = ConnectTarget(mode: .disconnect(server)) }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Running sessions

    @ViewBuilder
    private var sessionsTab: some View {
        if !work.sessionsLoaded {
            LoadingView("Looking for running sessions", style: .list)
        } else if sessions.isEmpty {
            EmptyState(icon: .terminal, title: "No running sessions",
                       message: "Sessions of \(tool.tool.title) started in any terminal show up here.")
        } else {
            DeckPage {
                ForEach(sessions) { session in
                    sessionCard(session)
                }
            }
        }
    }

    private func sessionCard(_ session: AgentSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle().fill(DS.running).frame(width: 8, height: 8)
                Text(session.folder.map(abbreviatedPath) ?? "Unknown folder")
                    .font(.headline.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text("PID " + String(session.pid)).font(.caption.monospaced()).foregroundStyle(DS.textTertiary)
            }
            HStack(spacing: 18) {
                metric(.clock, "Started \(Format.relative(session.started))")
                metric(.cpu, Format.percent(session.cpu))
                metric(.memory, Format.bytes(session.memoryBytes))
            }
            Text(session.command)
                .font(.caption.monospaced())
                .foregroundStyle(DS.textSecondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if !session.mcpServers.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(session.mcpServers.count == 1 ? "1 MCP server running" : "\(session.mcpServers.count) MCP servers running")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DS.textSecondary)
                    ForEach(session.mcpServers) { child in
                        HStack(spacing: 8) {
                            DeckIcon(.link, size: 11, color: DS.accent)
                            Text(child.name ?? "MCP server").font(.callout.weight(.medium))
                            Text(child.command).font(.caption.monospaced()).foregroundStyle(DS.textTertiary)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(Format.bytes(child.memoryBytes)).font(.caption.monospacedDigit()).foregroundStyle(DS.textTertiary)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: DS.smallRadius).fill(DS.surfaceSunken))
            }
            HStack(spacing: 8) {
                if let folder = session.folder {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)])
                    } label: {
                        DeckLabel("Reveal Folder", icon: .folder)
                    }
                    Button {
                        openTerminal("cd \(MCPLaunch.shellQuote(folder))")
                    } label: {
                        DeckLabel("Open Terminal", icon: .terminal)
                    }
                }
                Spacer(minLength: 0)
                Button(role: .destructive) {
                    stopping = session
                } label: {
                    DeckLabel(work.isStopping(session) ? "Stopping" : "Stop", icon: .stop)
                }
                .disabled(work.isStopping(session))
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .deckCard()
    }

    private func metric(_ icon: DeckIconName, _ text: String) -> some View {
        HStack(spacing: 5) {
            DeckIcon(icon, size: 12, color: DS.textTertiary)
                .environment(\.deckIconMonochrome, true)
            Text(text).font(.callout.monospacedDigit()).foregroundStyle(DS.textSecondary)
        }
    }

    private func stop(_ session: AgentSession) {
        Task {
            do {
                let outcome = try await work.stop(session)
                switch outcome {
                case .alreadyGone: state.showToast("That session had already ended", style: .info)
                case .terminated: state.showToast("Session stopped", style: .success)
                case .killed: state.showToast("Session did not quit, so it was force stopped", style: .info)
                }
            } catch {
                state.showError(error)
            }
        }
    }

    // MARK: Recent sessions

    @ViewBuilder
    private var historyTab: some View {
        if work.history[tool.tool] == nil {
            LoadingView("Reading saved sessions", style: .list)
        } else if history.isEmpty {
            EmptyState(icon: .clock, title: "No saved sessions",
                       message: "\(tool.tool.title) has not saved a session in \(store.resolver.sessionsFolder(tool.tool)?.path.map(abbreviatedPath) ?? "its folder") yet.")
        } else {
            VStack(spacing: 0) {
                Table(history) {
                    TableColumn("Session") { record in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.title ?? "Untitled session").fontWeight(.medium).lineLimit(1)
                            Text(record.sessionID).font(.caption.monospaced()).foregroundStyle(DS.textTertiary).lineLimit(1)
                        }
                    }
                    .width(min: 200, ideal: 260)
                    TableColumn("Folder") { record in
                        Text(record.folder.map(abbreviatedPath) ?? "Unknown")
                            .font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                    }
                    .width(min: 140, ideal: 200)
                    TableColumn("Messages") { record in
                        Text("\(record.messageCount)").monospacedDigit()
                    }
                    .width(70)
                    TableColumn("Last active") { record in
                        Text(Format.relative(record.lastActivity)).foregroundStyle(DS.textSecondary)
                    }
                    .width(min: 90, ideal: 110)
                    TableColumn("") { record in
                        HStack(spacing: 6) {
                            Button("Resume") { resume(record) }
                                .disabled(tool.path == nil)
                            if let folder = record.folder {
                                Button {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)])
                                } label: {
                                    DeckIcon(.folder, size: 12)
                                }
                                .help("Show the folder in Finder")
                            }
                        }
                        .controlSize(.small)
                    }
                    .width(min: 110, ideal: 120)
                }
                ListStatusBar("Only titles, folders and counts are read. Transcripts stay unread.") {
                    if work.historyLoading.contains(tool.tool) { ProgressView().controlSize(.small) }
                }
            }
        }
    }

    private func resume(_ record: AgentSessionRecord) {
        guard let path = tool.path, let command = AgentSessionHistory.resumeCommand(record, executable: path) else { return }
        openTerminal(command)
    }

    private func openTerminal(_ command: String) {
        do {
            try TerminalLauncher.open(command: command) { error in state.showError(error) }
        } catch {
            state.showError(error)
        }
    }
}
