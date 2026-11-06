import SwiftUI
import DeckCore

/// Every MCP server on this Mac: ours (run as containers) and the ones in agent configs.
struct MCPServersPane: View {
    @Environment(AppState.self) private var state
    let store: AgentsStore
    let onInstall: () -> Void
    @State private var selection: MCPOverviewRow.ID?
    @State private var search = ""

    private var cliPath: String { state.client?.cliPath ?? "/usr/local/bin/container" }

    private var rows: [MCPOverviewRow] {
        let all = store.rows(containers: BackgroundServices.shared.containers, cliPath: cliPath)
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return all }
        return all.filter { row in
            row.name.lowercased().contains(query) || row.target.lowercased().contains(query)
                || row.agents.contains { $0.title.lowercased().contains(query) }
        }
    }

    var body: some View {
        content
            .searchable(text: $search, placement: .toolbar, prompt: "Search servers")
            .onDeckDebugCommand { name, value in
                guard name == "agents-select" else { return }
                selection = rows.first { $0.name == value }?.id
            }
    }

    @ViewBuilder
    private var content: some View {
        if !store.hasLoaded {
            LoadingView("Reading agent configs", style: .logo)
        } else if store.installed.isEmpty && store.discovered.isEmpty {
            EmptyState(
                icon: .agents,
                title: "No MCP servers yet",
                message: "None of your agent configs list an MCP server. Add one from the catalog and run it in a container.",
                actionTitle: "Add Server",
                action: onInstall
            )
        } else {
            let rows = self.rows
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    table(rows)
                    ListStatusBar(statusText(rows)) {
                        if store.isLoading { ProgressView().controlSize(.small) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                Group {
                    if let row = rows.first(where: { $0.id == selection }) {
                        MCPServerDetail(store: store, row: row)
                            .id(row.id)
                    } else {
                        overview(rows)
                    }
                }
                .frame(width: 380)
                .frame(maxHeight: .infinity)
                .background(DS.surface, ignoresSafeAreaEdges: [])
            }
        }
    }

    private func table(_ rows: [MCPOverviewRow]) -> some View {
        Table(rows, selection: $selection) {
            TableColumn("Name") { row in
                HStack(spacing: 8) {
                    DeckIcon(row.isManaged ? .containers : .agents, size: 14, color: DS.accent)
                    Text(row.name).fontWeight(.medium).lineLimit(1)
                }
            }
            .width(min: 140, ideal: 140)

            TableColumn("Type") { row in
                Pill(row.transport.title, tint: row.transport.tint)
            }
            .width(min: 60, ideal: 60)

            TableColumn("Agents") { row in
                Text(row.agents.isEmpty ? "Not connected" : row.agents.map(\.title).joined(separator: ", "))
                    .deckSecondaryText()
                    .lineLimit(1)
                    .help(row.agents.map(\.title).joined(separator: ", "))
            }
            .width(min: 120, ideal: 120)

            TableColumn("Status") { row in
                MCPStatusLabel(row: row, health: store.health[row.name])
            }
            .width(min: 95, ideal: 95)

            TableColumn("Runs") { row in
                Text(row.target)
                    .font(.callout.monospaced())
                    .deckSecondaryText()
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.target)
            }
            .width(min: 130, ideal: 130)
        }
        .scrollContentBackground(.hidden)
    }

    private func statusText(_ rows: [MCPOverviewRow]) -> String {
        let ours = rows.filter(\.isManaged).count
        let count = rows.count == 1 ? "1 server" : "\(rows.count) servers"
        let files = store.configFiles.filter(\.exists).count
        return "\(count), \(ours) run by \(AppConfig.appName), \(files) agent config \(files == 1 ? "file" : "files") read"
    }

    /// Shown when nothing is selected: summary tiles and config files.
    private func overview(_ rows: [MCPOverviewRow]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.cardSpacing) {
                EqualHeightRow(spacing: 12) {
                    MetricTile(title: "Servers", value: "\(rows.count)", subtitle: "on this Mac", icon: .agents)
                    MetricTile(title: "Running", value: "\(rows.filter { $0.status == .running }.count)",
                               subtitle: "in containers", icon: .containers, tint: DS.running)
                }
                Card("Agent configs", icon: .file) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(store.configFiles.filter(\.exists)) { file in
                            ConfigFileRow(file: file)
                        }
                        if store.configFiles.allSatisfy({ !$0.exists }) {
                            Text("No agent config files found.").deckSecondaryText()
                        }
                    }
                }
                Text("Select a server to see where it is set up, check it, or connect it to another agent.")
                    .font(.callout)
                    .foregroundStyle(DS.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Layout.pagePadding - 4)
        }
    }
}

/// Status cell: running, stopped, on demand or in config, with the last check.
struct MCPStatusLabel: View {
    let row: MCPOverviewRow
    let health: MCPHealth?

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).deckSecondaryText().lineLimit(1)
        }
        .help(help)
    }

    private var title: String {
        switch row.status {
        case .running: return "Running"
        case .stopped: return "Stopped"
        case .onDemand: return row.containers.isEmpty ? "On demand" : "In use (\(row.containers.count))"
        case .external: return row.entries.allSatisfy(\.disabled) ? "Turned off" : "In config"
        }
    }

    private var color: Color {
        if case .failed = health { return DS.danger }
        switch row.status {
        case .running: return DS.running
        case .stopped: return DS.stopped
        case .onDemand: return row.containers.isEmpty ? DS.running.opacity(0.45) : DS.running
        case .external: return DS.textTertiary
        }
    }

    private var help: String {
        switch row.status {
        case .onDemand: return "The agent starts this server in a container when it needs it."
        case .external: return "Set up in an agent config. Not run by \(AppConfig.appName)."
        default: return ""
        }
    }
}

/// One config file line: agent, path, server count or problem.
struct ConfigFileRow: View {
    let file: AgentConfigFileStatus

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.agent.title).fontWeight(.medium)
                Text(abbreviatedPath(file.path))
                    .font(.caption.monospaced())
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let problem = file.problem {
                    Text(problem).font(.caption).foregroundStyle(DS.danger).lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            Pill(file.serverCount == 1 ? "1 server" : "\(file.serverCount) servers",
                 tint: file.problem == nil ? (file.serverCount > 0 ? DS.accent : DS.stopped) : DS.danger)
        }
        .contextMenu {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
            } label: {
                DeckLabel("Show in Finder", icon: .folder)
            }
        }
    }
}
