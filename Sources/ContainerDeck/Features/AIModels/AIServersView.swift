import SwiftUI
import AppKit
import DeckCore

/// Every model server found on this Mac, with its OpenAI compatible endpoint and models.
struct AIServersView: View {
    private var store: AIModelsStore { AIModelsStore.shared }

    var body: some View {
        if !store.hasDiscovered {
            LoadingView("Looking for model servers", style: .logo)
        } else {
            DeckPage {
                metrics
                SectionHeader("Model servers", subtitle: "Found on this Mac. Each one speaks the OpenAI API at the address shown.", icon: .registry)
                if store.endpoints.isEmpty {
                    emptyCard
                } else {
                    ForEach(store.endpoints) { endpoint in
                        AIEndpointCard(endpoint: endpoint)
                    }
                }
                CommandHint("curl \(store.runningEndpoints.first?.baseURL.absoluteString ?? "http://127.0.0.1:11434/v1")/models")
            }
        }
    }

    private var metrics: some View {
        let running = store.runningEndpoints
        let models = Set(running.flatMap { $0.models.map(\.id) }).count
        let disk = LocalModelStore.totalSize(store.localModels)
        return EqualHeightRow {
            MetricTile(title: "Servers running", value: "\(running.count)",
                       subtitle: running.isEmpty ? "None answering" : running.map(\.name).joined(separator: ", "),
                       icon: .registry, tint: running.isEmpty ? DS.stopped : DS.running)
            MetricTile(title: "Models served", value: "\(models)", subtitle: "Across all servers", icon: .aiModels)
            MetricTile(title: "MLX server", value: serverValue, subtitle: serverSubtitle, icon: .cpu,
                       tint: store.serverState.isActive ? DS.running : DS.stopped)
            MetricTile(title: "MLX models on disk", value: Format.bytes(disk),
                       subtitle: "\(store.localModels.count) \(store.localModels.count == 1 ? "model" : "models")", icon: .disk)
        }
    }

    private var serverValue: String {
        switch store.serverState {
        case .running: return "Running"
        case .starting: return "Starting"
        case .crashed: return "Stopped"
        case .stopped: return store.runtime?.isReady == true ? "Ready" : "Not set up"
        }
    }

    private var serverSubtitle: String {
        if let config = store.serverConfig, store.serverState.isActive {
            return "\(config.bind.host):\(config.port)"
        }
        return store.runtime?.isReady == true ? "Start it on the MLX tab" : "Install it on the MLX tab"
    }

    private var emptyCard: some View {
        Card {
            HStack(spacing: 14) {
                IconBadge(.aiModels, size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text("No model servers found").font(.headline)
                    Text("Start Ollama, LM Studio or the MLX server and it shows up here.")
                        .font(.callout)
                        .foregroundStyle(DS.textSecondary)
                }
                Spacer(minLength: 0)
                Button {
                    store.tab = .mlx
                } label: {
                    DeckLabel("Set Up MLX", icon: .cpu)
                }
                .deckPrimary()
            }
        }
    }
}

/// One server: status, endpoint with copy, container address, models and actions.
struct AIEndpointCard: View {
    let endpoint: ModelEndpoint
    @State private var showAllModels = false
    private var store: AIModelsStore { AIModelsStore.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if endpoint.status != .installed {
                VStack(alignment: .leading, spacing: 10) {
                    AIRow("OpenAI endpoint") { AICopyField(text: endpoint.baseURL.absoluteString, help: "Copy the base URL") }
                    AIRow("From containers") { containerAddress }
                    if let native = endpoint.nativeURL {
                        AIRow("\(endpoint.kind.displayName) API") { AICopyField(text: native.absoluteString) }
                    }
                }
                if endpoint.isManaged && store.serverModelBroken {
                    AIModelLoadNotice(compact: true)
                }
                if !endpoint.models.isEmpty { models }
            } else {
                Text(installedNote)
                    .font(.callout)
                    .foregroundStyle(DS.textSecondary)
            }
        }
        .padding(DS.pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .deckCard()
    }

    private var header: some View {
        HStack(spacing: 12) {
            IconBadge(endpoint.kind.deckIcon, tint: endpoint.isRunning ? DS.accent : DS.stopped, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(endpoint.name).font(.headline)
                    AIStatusPill(text: endpoint.status.label, tint: endpoint.status.tint)
                    if endpoint.isRunning {
                        Pill(AIFormat.bindText(endpoint), tint: endpoint.reachableFromContainers ? DS.accent : DS.stopped)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            actions
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if endpoint.status != .installed { parts.append("Port \(endpoint.port)") }
        if let version = endpoint.version { parts.append("Version \(version)") }
        if endpoint.isRunning { parts.append(endpoint.models.count == 1 ? "1 model" : "\(endpoint.models.count) models") }
        if endpoint.kind == .lmStudio, let label = store.lmStatus?.installLabel {
            parts.append(endpoint.status == .installed ? "\(label) installed" : label)
        } else if endpoint.status == .installed {
            parts.append("Installed")
        }
        return parts.joined(separator: ", ")
    }

    private var installedNote: String {
        switch endpoint.kind {
        case .ollama: return "Ollama is installed. Start it to serve models at \(endpoint.baseURL.absoluteString)."
        case .lmStudio:
            if store.lmStatus?.isCoreOnly == true {
                return "LM Studio core is installed. Start its server to use it here. The background service starts with it."
            }
            return "LM Studio is installed. Start its server to use it here."
        default: return "Installed but not running."
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            if endpoint.isRunning && !endpoint.models.isEmpty && !(endpoint.isManaged && store.serverModelBroken) {
                Button {
                    store.openChat(endpoint)
                } label: {
                    DeckLabel("Chat", icon: .chat)
                }
            }
            if endpoint.kind == .ollama {
                if endpoint.status == .installed {
                    Button {
                        Task { await store.startOllama() }
                    } label: {
                        DeckLabel(store.ollamaStarting ? "Starting" : "Start", icon: .play)
                    }
                    .deckPrimary()
                    .disabled(store.ollamaStarting)
                } else {
                    Button {
                        store.tab = .ollama
                    } label: {
                        DeckLabel("Manage", icon: .settings)
                    }
                }
            } else if endpoint.kind == .lmStudio {
                if endpoint.status == .installed && store.lmStatus?.cliPath != nil && store.lmStatus?.serverRunning != true {
                    Button {
                        Task { await store.startLMStudio() }
                    } label: {
                        DeckLabel(store.lmServerBusy ? "Starting" : "Start", icon: .play)
                    }
                    .deckPrimary()
                    .disabled(store.lmServerBusy)
                }
                Button {
                    store.tab = .lmStudio
                } label: {
                    DeckLabel("Manage", icon: .settings)
                }
            } else if endpoint.isManaged {
                Button {
                    store.tab = .mlx
                } label: {
                    DeckLabel("Manage", icon: .settings)
                }
            }
        }
        .controlSize(.regular)
    }

    @ViewBuilder
    private var containerAddress: some View {
        let gateway = store.gatewayNetworks.first { $0.name == "default" }?.gateway ?? store.gatewayNetworks.first?.gateway ?? "192.168.64.1"
        if let url = endpoint.containerBaseURL(gateway: gateway) {
            AICopyField(text: url.absoluteString, help: "Copy the address containers use")
        } else {
            HStack(spacing: 6) {
                DeckIcon(.lock, size: 12, color: DS.textSecondary)
                Text(containerHelp)
                    .font(.callout)
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var containerHelp: String {
        switch endpoint.kind {
        case .ollama: return "Listens on this Mac only. Set OLLAMA_HOST=0.0.0.0 and restart Ollama so containers can reach it."
        case .lmStudio: return "Listens on this Mac only. Turn on Serve on Local Network in LM Studio so containers can reach it."
        default: return endpoint.isManaged ? "Listens on this Mac only. Choose Containers on the MLX tab." : "Listens on this Mac only."
        }
    }

    private var models: some View {
        let shown = showAllModels ? endpoint.models : Array(endpoint.models.prefix(6))
        return VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.bottom, 8)
            ForEach(shown) { model in
                HStack(spacing: 10) {
                    Circle()
                        .fill(model.isLoaded ? DS.running : DS.stopped.opacity(0.4))
                        .frame(width: 7, height: 7)
                        .help(model.isLoaded ? "In memory" : "On disk")
                    Text(model.displayName)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(model.id)
                    if model.isLoaded { Pill("Loaded", tint: DS.running) }
                    Spacer(minLength: 8)
                    Text([model.parameterSize, model.quantization, model.sizeBytes.map { Format.bytes($0) }].compactMap { $0 }.joined(separator: "  "))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(DS.textSecondary)
                    Button {
                        store.openChat(endpoint, model: model.id)
                    } label: {
                        DeckIcon(.chat, size: 13)
                    }
                    .buttonStyle(.borderless)
                    .help("Chat with this model")
                    Button {
                        ResourceUsage.copyToPasteboard(model.id)
                    } label: {
                        DeckIcon(.copy, size: 13)
                    }
                    .buttonStyle(.borderless)
                    .help("Copy the model id")
                }
                .padding(.vertical, 5)
            }
            if endpoint.models.count > 6 {
                Button(showAllModels ? "Show fewer" : "Show all \(endpoint.models.count) models") {
                    withAnimation(.easeInOut(duration: 0.2)) { showAllModels.toggle() }
                }
                .deckLink()
                .font(.caption)
                .padding(.top, 4)
            }
        }
    }
}
