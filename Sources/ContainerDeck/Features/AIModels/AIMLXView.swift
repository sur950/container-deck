import SwiftUI
import AppKit
import DeckCore

/// MLX runtime (uv plus mlx-lm in Application Support) and the MLX server.
struct AIMLXView: View {
    private var store: AIModelsStore { AIModelsStore.shared }
    @State private var confirmRemove = false

    var body: some View {
        if store.runtime == nil {
            LoadingView("Checking the MLX runtime", style: .logo)
        } else {
            DeckPage {
                EqualHeightRow {
                    runtimeCard
                    serverCard
                }
                logCard
            }
            .confirmDelete(isPresented: $confirmRemove, title: "Remove the MLX runtime?",
                           message: "mlx-lm and its Python are deleted from Application Support. Downloaded models stay.",
                           actionTitle: "Remove") {
                Task { await store.removeRuntime() }
            }
        }
    }

    // MARK: Runtime

    private var runtimeCard: some View {
        let runtime = store.runtime ?? MLXRuntimeStatus()
        return Card("Runtime", icon: .kernel) {
            VStack(alignment: .leading, spacing: 10) {
                AIRow("uv") {
                    if let path = runtime.uvPath {
                        statusLine(ok: true, text: "uv \(runtime.uvVersion ?? "") at \(path)")
                    } else {
                        statusLine(ok: false, text: "Not found. Install gets it for you.")
                    }
                }
                AIRow("mlx-lm") {
                    if runtime.isOwnInstall {
                        statusLine(ok: true, text: "Version \(runtime.mlxVersion ?? "unknown")")
                    } else if let path = runtime.serverPath {
                        statusLine(ok: true, text: "Found at \(path)")
                    } else {
                        statusLine(ok: false, text: "Not installed")
                    }
                }
                AIRow("Location") {
                    HStack(spacing: 6) {
                        Text(store.paths.base.path)
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(DS.textSecondary)
                            .help(store.paths.base.path)
                        if runtime.isOwnInstall {
                            Text(Format.bytes(store.runtimeBytes))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(DS.textTertiary)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                if store.isInstalling {
                    ProgressView().controlSize(.small)
                    Text("Installing").font(.callout).foregroundStyle(DS.textSecondary)
                    Spacer(minLength: 0)
                    Button("Stop") { store.cancelInstall() }
                } else if runtime.isOwnInstall {
                    Button {
                        store.installRuntime(upgrade: true)
                    } label: {
                        DeckLabel("Update", icon: .download)
                    }
                    Button {
                        ResourceUsage.revealInFinder(store.paths.base.path)
                    } label: {
                        DeckLabel("Show in Finder", icon: .folder)
                    }
                    Spacer(minLength: 0)
                    Button(role: .destructive) {
                        confirmRemove = true
                    } label: {
                        DeckLabel("Remove", icon: .trash)
                    }
                } else {
                    Button {
                        store.installRuntime()
                    } label: {
                        DeckLabel("Install MLX Runtime", icon: .download)
                    }
                    .deckPrimary()
                    Text("About 400 MB, no admin password")
                        .font(.caption)
                        .foregroundStyle(DS.textSecondary)
                    Spacer(minLength: 0)
                }
            }
            if let uv = runtime.uvPath, !runtime.isOwnInstall {
                CommandHint(MLXRuntime(paths: store.paths).installCommandLine(uv: uv))
            }
        }
    }

    private func statusLine(ok: Bool, text: String) -> some View {
        HStack(spacing: 6) {
            DeckIcon(ok ? .success : .pending, size: 13, color: ok ? DS.running : DS.stopped)
            Text(text)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(text)
        }
    }

    // MARK: Server

    private var serverCard: some View {
        @Bindable var store = store
        let active = store.serverState.isActive
        let complete = store.localModels.filter(\.isComplete)
        return Card("Server", icon: .registry) {
            VStack(alignment: .leading, spacing: 10) {
                AIRow("Status") {
                    HStack(spacing: 8) {
                        AIStatusPill(text: statusText, tint: statusTint)
                        if let pid = store.serverState.pid {
                            Text(verbatim: "PID \(pid)").font(.caption.monospacedDigit()).foregroundStyle(DS.textSecondary)
                        }
                    }
                }
                AIRow("Model") {
                    Picker("", selection: $store.serverModelPath) {
                        if complete.isEmpty {
                            Text("No models yet").tag("")
                        }
                        ForEach(complete) { model in
                            Text(ModelDisplayName.short(model.repo)).tag(model.modelPath)
                        }
                        if !store.serverModelPath.isEmpty, !complete.contains(where: { $0.modelPath == store.serverModelPath }) {
                            Text(ModelDisplayName.short(store.serverModelPath)).tag(store.serverModelPath)
                        }
                    }
                    .labelsHidden()
                    .disabled(active)
                    .help(store.serverModelPath)
                    .popUpAppearanceRefresh()
                }
                AIRow("Reachable from") {
                    Picker("", selection: $store.bindToContainers) {
                        Text("This Mac only").tag(false)
                        Text("Containers").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .disabled(active)
                }
                if store.bindToContainers {
                    AIRow("Network") {
                        Picker("", selection: $store.bindNetwork) {
                            ForEach(store.gatewayNetworks) { network in
                                Text("\(network.name) (\(network.gateway ?? ""))").tag(network.name)
                            }
                        }
                        .labelsHidden()
                        .disabled(active || store.gatewayNetworks.isEmpty)
                        .popUpAppearanceRefresh()
                    }
                }
                AIRow("Port") {
                    TextField("", text: $store.serverPort)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .disabled(active)
                }
                if let config = store.serverConfig, active {
                    AIRow("Endpoint") { AICopyField(text: config.baseURL.absoluteString) }
                } else if store.mlxLoadFailure != nil {
                    EmptyView()
                } else if let crash = store.lastCrash {
                    AIRow("Last exit") {
                        Text(crash).font(.caption).foregroundStyle(DS.danger).lineLimit(2)
                    }
                }
            }
            if store.mlxLoadFailure != nil && (active || store.lastCrash != nil) {
                AIModelLoadNotice()
            } else if !active, let type = store.selectedModelUnsupportedType {
                HStack(alignment: .top, spacing: 6) {
                    DeckIcon(.warning, size: 12, color: DS.warning)
                    Text("\(store.unsupportedNote(type)) Pick another model.")
                        .font(.caption)
                        .foregroundStyle(DS.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                if active {
                    Button {
                        Task { await store.stopServer() }
                    } label: {
                        DeckLabel("Stop", icon: .stop)
                    }
                    Button {
                        Task { await store.restartServer() }
                    } label: {
                        DeckLabel("Restart", icon: .restart)
                    }
                    if case .running = store.serverState, !store.serverModelBroken, let endpoint = store.endpoints.first(where: \.isManaged) {
                        Button {
                            store.openChat(endpoint)
                        } label: {
                            DeckLabel("Chat", icon: .chat)
                        }
                    }
                } else {
                    Button {
                        store.startServer()
                    } label: {
                        DeckLabel("Start Server", icon: .play)
                    }
                    .deckPrimary()
                    .disabled(!store.canStartServer)
                    if complete.isEmpty {
                        Button("Get a Model") { store.tab = .library }
                            .deckLink()
                    }
                }
                Spacer(minLength: 0)
            }
            if active, let note = store.bindNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(DS.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else if store.runtime?.serverPath == nil {
                Text("Install the MLX runtime first.")
                    .font(.caption)
                    .foregroundStyle(DS.textSecondary)
            } else if store.bindToContainers && store.gatewayNetworks.isEmpty {
                Text("No container network with a gateway was found. Start the container service first.")
                    .font(.caption)
                    .foregroundStyle(DS.warning)
            } else if store.bindToContainers {
                Text("Listens on the network's gateway, not on your Wi-Fi. If macOS asks to accept incoming connections, click Allow.")
                    .font(.caption)
                    .foregroundStyle(DS.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusText: String {
        if store.serverModelBroken { return "Running, but the model could not load" }
        switch store.serverState {
        case .stopped: return "Stopped"
        case .starting: return "Starting"
        case .running: return "Running"
        case .crashed: return store.mlxLoadFailure != nil ? "Stopped" : "Stopped unexpectedly"
        }
    }

    private var statusTint: Color {
        if store.serverModelBroken { return DS.warning }
        switch store.serverState {
        case .stopped: return DS.stopped
        case .starting: return DS.warning
        case .running: return DS.running
        case .crashed: return DS.danger
        }
    }

    // MARK: Logs

    private var logCard: some View {
        // Install output while installing, and after it until the server first runs.
        let showInstall = store.isInstalling || (store.serverLog.isEmpty && !store.installLog.isEmpty && store.serverState == .stopped)
        let lines = showInstall ? store.installLog : store.serverLog
        let title = showInstall ? "Install output" : "Server log"
        return Card(title, icon: .logs) {
            ResourceLogView(lines: lines, placeholder: "Server output shows here once it starts.")
                .frame(minHeight: 220, idealHeight: 300)
            HStack {
                Text(store.paths.serverLog.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(DS.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button {
                    NSWorkspace.shared.open(store.paths.serverLog)
                } label: {
                    DeckLabel("Open Log File", icon: .openExternal)
                }
                .controlSize(.small)
                .disabled(!FileManager.default.fileExists(atPath: store.paths.serverLog.path))
            }
        }
    }
}
