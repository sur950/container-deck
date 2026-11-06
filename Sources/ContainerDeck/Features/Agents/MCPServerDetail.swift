import SwiftUI
import AppKit
import DeckCore

/// Detail pane for one MCP server: how it runs, which agents use it, health, connect and remove.
struct MCPServerDetail: View {
    @Environment(AppState.self) private var state
    let store: AgentsStore
    let row: MCPOverviewRow
    @State private var connectTarget: ConnectTarget?
    @State private var confirmRemove = false

    private var cliPath: String { state.client?.cliPath ?? "/usr/local/bin/container" }

    /// The entry agents get for this row: ours, or the first config entry (copied as is).
    private var entry: MCPServerEntry? {
        if let server = row.installed { return MCPLaunch.entry(server, cliPath: cliPath) }
        return row.entries.first?.entry.map { found in
            var copy = found
            copy.name = row.name
            return copy
        }
    }

    private var healthKey: String { row.installed?.name ?? row.id }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.cardSpacing) {
                header
                actions
                healthCard
                if let server = row.installed { setupCard(server) }
                agentsCard
                if let entry { connectCard(entry) }
            }
            .padding(Layout.pagePadding - 4)
        }
        .sheet(item: $connectTarget) { target in
            MCPConnectSheet(store: store, target: target)
                .environment(state)
        }
        .onDeckDebugCommand { name, value in
            if name == "agents-connect-open", let agent = AgentKind(rawValue: value), let entry {
                connectTarget = ConnectTarget(mode: .connect(entry, agent))
            }
            if name == "agents-check" { Task { await check() } }
            if name == "agents-remove-now", value == row.name { remove() }
        }
        .confirmationDialog("Remove \(row.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove Server", role: .destructive) { remove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Stops its container and deletes its saved secrets. Agent configs that use it keep their entry until you remove it there.")
        }
    }

    // MARK: Parts

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            IconBadge(row.isManaged ? .containers : .agents, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.name).font(.title3.weight(.semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    Pill(row.transport.title, tint: row.transport.tint)
                    if row.isManaged {
                        Pill(AppConfig.appName, tint: DS.accent)
                    } else {
                        Pill("Agent config", tint: DS.stopped)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            if let server = row.installed, server.isLongRunning {
                if row.status == .running {
                    Button { run { try await store.stop(server, client: $0) } } label: { DeckLabel("Stop", icon: .stop) }
                } else {
                    Button { run { try await store.start(server, client: $0) } } label: { DeckLabel("Start", icon: .play) }
                        .deckPrimary()
                }
            }
            Button {
                Task { await check() }
            } label: {
                DeckLabel("Check", icon: .checklist)
            }
            .disabled(store.health[healthKey] == .checking || entry == nil)
            .help(row.transport == .stdio ? "Start it once like an agent would and run the MCP handshake" : "Run the MCP handshake")
            if let name = row.containers.first {
                Button {
                    state.openContainer(name, tab: .logs)
                } label: {
                    DeckLabel("Logs", icon: .logs)
                }
            }
            Spacer(minLength: 0)
            if row.installed != nil {
                Button(role: .destructive) { confirmRemove = true } label: { DeckLabel("Remove", icon: .trash) }
                    .help("Remove this server from \(AppConfig.appName)")
            }
        }
        .controlSize(.regular)
        .disabled(store.isBusy(row.name))
    }

    private var healthCard: some View {
        Card("Health", icon: .shield) {
            VStack(alignment: .leading, spacing: 8) {
                switch row.status == .stopped ? nil : store.health[healthKey] {
                case .checking:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(row.transport == .stdio ? "Starting the server for a handshake" : "Running the MCP handshake")
                            .deckSecondaryText()
                    }
                case .healthy(let result, let date):
                    Label {
                        Text("Answers MCP").fontWeight(.medium)
                    } icon: {
                        DeckIcon(.success, size: 14, color: DS.running)
                    }
                    KeyValueRow("Server", value: result.serverName)
                    if !result.serverVersion.isEmpty { KeyValueRow("Version", value: result.serverVersion) }
                    KeyValueRow("Protocol", value: result.protocolVersion)
                    if let tools = result.toolCount { KeyValueRow("Tools", value: "\(tools)") }
                    KeyValueRow("Checked", value: "\(date.formatted(date: .omitted, time: .shortened)), \(result.milliseconds) ms")
                case .failed(let message, let date):
                    Label {
                        Text(message).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        DeckIcon(.error, size: 14, color: DS.danger)
                    }
                    Text("Checked \(date.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(DS.textSecondary)
                case nil:
                    Text(row.status == .stopped ? "Start the server, then check it." : "Not checked yet.")
                        .deckSecondaryText()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func setupCard(_ server: MCPInstalledServer) -> some View {
        Card("Setup", icon: .inspect) {
            VStack(alignment: .leading, spacing: 8) {
                if server.kind == .container {
                    KeyValueRow("Image", value: server.image, monospaced: true, copyable: true)
                }
                if let url = MCPLaunch.url(server) {
                    KeyValueRow("URL", value: url, monospaced: true, copyable: true)
                }
                if !server.env.isEmpty {
                    KeyValueRow("Settings", value: server.env.map(\.key).joined(separator: ", "))
                }
                if !server.secretKeys.isEmpty {
                    KeyValueRow("Secrets") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(server.secretKeys, id: \.self) { key in
                                HStack(spacing: 6) {
                                    Text(key).font(.callout.monospaced())
                                    Pill(store.hasSecret(server, key: key) ? "In Keychain" : "Missing",
                                         tint: store.hasSecret(server, key: key) ? DS.running : DS.danger)
                                }
                            }
                        }
                    }
                }
                ForEach(server.mounts) { mount in
                    KeyValueRow("Folder", value: "\(abbreviatedPath(mount.source)) at \(mount.destination)\(mount.readOnly ? ", read only" : "")")
                }
                if let entry {
                    CommandHint(MCPLaunch.commandLine(entry))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var agentsCard: some View {
        Card("Set up in", icon: .link) {
            VStack(alignment: .leading, spacing: 10) {
                if row.entries.isEmpty {
                    Text("No agent uses this server yet.").deckSecondaryText()
                }
                ForEach(row.entries) { found in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(found.agent.title).fontWeight(.medium)
                                Text(found.scope.label).font(.caption).foregroundStyle(DS.textSecondary)
                                if found.disabled { Pill("Off", tint: DS.stopped) }
                            }
                            Text(abbreviatedPath(found.file))
                                .font(.caption.monospaced())
                                .foregroundStyle(DS.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if !found.envKeys.isEmpty || !found.headerKeys.isEmpty {
                                Text("Uses " + (found.envKeys + found.headerKeys).joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(DS.textTertiary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 4)
                        Button("Remove…") {
                            connectTarget = ConnectTarget(mode: .disconnect(found))
                        }
                        .controlSize(.small)
                        .help("Preview removing this entry from \(found.agent.title)")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func connectCard(_ entry: MCPServerEntry) -> some View {
        let connected = Set(row.entries.filter { $0.scope == .user }.map(\.agent))
        let agents = store.installedAgents.filter { !connected.contains($0) }
        return Card("Connect to", icon: .add) {
            VStack(alignment: .leading, spacing: 10) {
                if agents.isEmpty {
                    Text("Every agent found on this Mac already has it.").deckSecondaryText()
                }
                ForEach(agents) { agent in
                    HStack(spacing: 8) {
                        Text(agent.title)
                        if AgentEntryFormat.needsBridge(entry, for: agent) {
                            Pill("via mcp-remote", tint: DS.warning)
                                .help("\(agent.title) cannot reach \(entry.transport.title) servers directly. It runs npx mcp-remote, which needs Node.js.")
                        }
                        Spacer(minLength: 4)
                        Button("Connect…") {
                            connectTarget = ConnectTarget(mode: .connect(entry, agent))
                        }
                        .controlSize(.small)
                    }
                }
                Text("You see the change before anything is written. The old file is backed up.")
                    .font(.caption)
                    .foregroundStyle(DS.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Actions

    private func run(_ work: @escaping (ContainerClient) async throws -> Void) {
        guard let client = state.client else { return }
        Task {
            do {
                try await work(client)
                state.resourcesChanged()
            } catch {
                state.showError(error)
            }
        }
    }

    private func check() async {
        if let server = row.installed {
            await store.check(server, cliPath: cliPath)
        } else if let found = row.entries.first {
            await store.check(found, key: healthKey)
        }
    }

    private func remove() {
        guard let server = row.installed else { return }
        Task {
            do {
                try await store.remove(server, client: state.client)
                state.showToast("Removed \(server.name)", style: .success)
                state.resourcesChanged()
            } catch {
                state.showError(error)
            }
        }
    }
}

/// What the connect sheet should preview.
struct ConnectTarget: Identifiable {
    enum Mode {
        case connect(MCPServerEntry, AgentKind)
        case disconnect(DiscoveredMCPServer)
    }
    let id = UUID()
    let mode: Mode
}
