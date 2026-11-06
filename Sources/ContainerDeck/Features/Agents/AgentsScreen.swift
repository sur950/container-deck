import SwiftUI
import DeckCore

/// Agents and MCP: every MCP server on this Mac, a catalog of servers that run as containers,
/// one click connect to agent configs (with preview and undo), local agent tools and API keys.
struct AgentsScreen: View {
    @Environment(AppState.self) private var state
    @AppStorage(PrefKey.agentsTab) private var tabRaw = AgentsTab.servers.rawValue
    @State private var store = AgentsStore()
    @State private var installRequest: MCPInstallRequest?
    @State private var showHistory = false

    private var tab: AgentsTab { AgentsTab(rawValue: tabRaw) ?? .servers }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            Group {
                switch tab {
                case .servers: MCPServersPane(store: store, onInstall: { installRequest = MCPInstallRequest(item: nil) })
                case .catalog: MCPCatalogPane(store: store) { installRequest = MCPInstallRequest(item: $0) }
                case .agents: AgentToolsPane(store: store)
                case .keys: ProviderKeysPane(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DS.surface, ignoresSafeAreaEdges: [])
        .navigationTitle(SidebarItem.agents.title)
        .toolbar { toolbarContent }
        .task { await store.load() }
        .task { await store.loadTools() }
        .autoRefresh(every: 15) { await store.load() }
        .sheet(item: $installRequest) { request in
            MCPInstallSheet(store: store, item: request.item)
                .environment(state)
        }
        .sheet(isPresented: $showHistory) {
            ConfigHistorySheet(store: store)
                .environment(state)
        }
        .onDeckDebugCommand { name, value in
            guard name == "agents" else { return }
            if let tab = AgentsTab(rawValue: value) { tabRaw = tab.rawValue }
            switch value {
            case "history": showHistory = true
            case "custom": installRequest = MCPInstallRequest(item: nil)
            default:
                if value.hasPrefix("install-"), let item = MCPCatalog.item(String(value.dropFirst(8))) {
                    installRequest = MCPInstallRequest(item: item)
                }
            }
        }
    }

    private var tabBar: some View {
        HStack {
            SegmentedFilter(selection: Binding(get: { tab }, set: { tabRaw = $0.rawValue }), options: AgentsTab.allCases,
                            label: { $0.title }, count: { count(for: $0) })
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Layout.pagePadding)
        .padding(.vertical, 10)
    }

    private func count(for tab: AgentsTab) -> Int? {
        switch tab {
        case .servers:
            guard store.hasLoaded else { return nil }
            return store.rows(containers: BackgroundServices.shared.containers, cliPath: state.client?.cliPath ?? "container").count
        case .catalog: return MCPCatalog.items.count
        case .agents: return store.toolsLoaded ? store.tools.filter(\.installed).count : nil
        case .keys: return store.savedProviders.count
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                showHistory = true
            } label: {
                DeckLabel("Changes", icon: .clock)
            }
            .help("Config changes made here, with undo")

            RefreshButton(help: "Read agent configs again", isBusy: store.isLoading) {
                await store.load()
                await store.loadTools()
            }

            Button {
                installRequest = MCPInstallRequest(item: nil)
            } label: {
                DeckLabel("Add Server", icon: .add)
            }
            .help("Add an MCP server from an image or a command")
        }
    }
}

/// Opens the install sheet for a catalog item, or for a custom server when `item` is nil.
struct MCPInstallRequest: Identifiable {
    let id = UUID()
    let item: MCPCatalogItem?
}

extension MCPTransport {
    var tint: Color {
        switch self {
        case .stdio: return DS.stopped
        case .http: return DS.running
        case .sse: return DS.warning
        }
    }
}

extension AgentConfigScope {
    /// "User", or "Project: app" with the folder name.
    var label: String {
        switch self {
        case .user: return "User"
        case .project(let folder): return "Project " + (folder as NSString).lastPathComponent
        case .local(let folder): return "Local " + (folder as NSString).lastPathComponent
        }
    }
}

/// Shortens paths under the home folder to ~/...
func abbreviatedPath(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
}
