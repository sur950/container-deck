import SwiftUI
import DeckCore

/// AI Models: local model servers on this Mac, the MLX runtime and server, Ollama,
/// a Hugging Face model library and a chat tester.
struct AIModelsScreen: View {
    @Environment(AppState.self) private var state
    private var store: AIModelsStore { AIModelsStore.shared }

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                SegmentedFilter(selection: $store.tab, options: AITab.allCases, label: \.title) { tab in
                    switch tab {
                    case .servers: return store.hasDiscovered ? store.runningEndpoints.count : nil
                    case .library: return store.localLoaded ? store.localModels.count : nil
                    default: return nil
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Layout.pagePadding)
            .padding(.vertical, 10)
            .background(DS.surface)
            Divider()
            Group {
                switch store.tab {
                case .servers: AIServersView()
                case .mlx: AIMLXView()
                case .ollama: AIOllamaView()
                case .library: AILibraryView()
                case .chat: AIChatView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DS.surface, ignoresSafeAreaEdges: [])
        .navigationTitle(SidebarItem.aiModels.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                RefreshButton(isBusy: store.isDiscovering) { await refreshAll() }
            }
        }
        .task {
            store.onError = { [weak state] error in state?.showError(error) }
            store.onNotice = { [weak state] message in state?.showToast(message, style: .success) }
            store.setUpServer()
            await refreshAll()
        }
        .autoRefresh(every: 8) {
            await store.discover()
            if store.tab == .ollama { await store.loadOllama() }
        }
        .onDeckDebugCommand { name, value in
            switch name {
            case "ai-tab":
                if let tab = AITab(rawValue: value) { store.tab = tab }
            case "ai-search":
                store.query = value
                store.tab = .library
                Task { await store.search() }
            case "ai-chat":
                store.chatInput = value
                store.tab = .chat
                store.sendChat()
            case "ai-install":
                store.installRuntime()
            case "ai-download":
                store.download(value)
            case "ai-select":
                store.selectedRepo = value
                Task { await store.loadSizes([value]) }
            case "ai-serve":
                // value: "mac" or "containers"
                store.bindToContainers = value == "containers"
                store.startServer()
            case "ai-stop":
                Task { await store.stopServer() }
            case "ai-chat-endpoint":
                if let endpoint = store.runningEndpoints.first(where: { $0.id == value || $0.kind.rawValue == value }) {
                    store.openChat(endpoint)
                }
            default:
                break
            }
        }
    }

    private func refreshAll() async {
        async let discovery: Void = store.discover()
        async let runtime: Void = store.loadRuntime()
        async let ollama: Void = store.loadOllama()
        async let local: Void = store.loadLocalModels()
        async let networks: Void = store.loadNetworks(state.client)
        _ = await (discovery, runtime, ollama, local, networks)
    }
}
