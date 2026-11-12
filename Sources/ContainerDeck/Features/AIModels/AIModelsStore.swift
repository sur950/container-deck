import SwiftUI
import DeckCore

/// Tabs of the AI Models screen.
enum AITab: String, CaseIterable, Hashable {
    case servers, mlx, ollama, lmStudio, library, chat

    var title: String {
        switch self {
        case .servers: return "Servers"
        case .mlx: return "MLX"
        case .ollama: return "Ollama"
        case .lmStudio: return "LM Studio"
        case .library: return "Model Library"
        case .chat: return "Chat"
        }
    }
}

/// State for the AI Models screen. One for the app, so the MLX server, downloads and
/// a running chat keep going while other screens are open.
@MainActor
@Observable
final class AIModelsStore {
    static let shared = AIModelsStore()

    var tab: AITab = .servers

    /// Set by the screen. Errors and notices go through AppState.
    @ObservationIgnored var onError: ((Error) -> Void)?
    @ObservationIgnored var onNotice: ((String) -> Void)?

    let paths = AIPaths()

    // MARK: Discovery

    var endpoints: [ModelEndpoint] = []
    var hasDiscovered = false
    var isDiscovering = false
    @ObservationIgnored private var sequencer = PollSequencer()

    var runningEndpoints: [ModelEndpoint] { endpoints.filter(\.isRunning) }
    /// When the last discovery finished. Lets the Dashboard reuse a recent one.
    @ObservationIgnored private(set) var lastDiscovery: Date?

    /// Discovers again only when the last result is older than `maxAge` seconds.
    func discoverIfStale(maxAge: TimeInterval) async {
        guard !isDiscovering else { return }
        if let lastDiscovery, Date().timeIntervalSince(lastDiscovery) < maxAge { return }
        await discover(maxAge: maxAge)
    }

    /// Reads the shared probe. `maxAge` 0 probes now (after a start or stop). Polls pass the
    /// poll interval so views asking at the same time share one probe.
    func discover(maxAge: TimeInterval = 0) async {
        let token = sequencer.begin()
        isDiscovering = true
        var found = await ModelEndpoints.current(maxAge: maxAge)
        isDiscovering = false
        guard sequencer.accept(token) else { return }
        // LM Studio installed with only the lms command (or a stand in) still gets a card.
        if lmStatus?.isInstalled == true, !found.contains(where: { $0.kind == .lmStudio }) {
            found.append(LMStudioRuntime.installedEndpoint(port: lmStatus?.port ?? AIConfig.lmStudioPort))
        }
        if found != endpoints {
            withAnimation(.easeInOut(duration: 0.25)) { endpoints = found }
        }
        hasDiscovered = true
        lastDiscovery = Date()
        if serverState.isActive, case .starting = serverState, found.contains(where: { $0.isManaged && $0.isRunning }) {
            server.markRunning()
            serverState = server.state
        }
        if chatEndpointID == nil || !runningEndpoints.contains(where: { $0.id == chatEndpointID }) {
            chatEndpointID = runningEndpoints.first?.id
        }
        normalizeChatModel()
    }

    // MARK: MLX runtime

    var runtime: MLXRuntimeStatus?
    var runtimeBytes: UInt64 = 0
    var isInstalling = false
    var installLog: [String] = []
    @ObservationIgnored private var installTask: Task<Void, Never>?

    private var mlxRuntime: MLXRuntime { MLXRuntime(paths: paths) }

    func loadRuntime() async {
        let runtime = mlxRuntime
        let status = await runtime.status()
        let bytes = await Task.detached { runtime.runtimeBytes() }.value
        self.runtime = status
        runtimeBytes = bytes
        await loadMLXSupport()
    }

    // MARK: Model support

    /// Model types the installed mlx-lm can load, read from its files once per version.
    var mlxSupport: MLXModelSupport?
    /// config.json of library repos (by repo id) and downloaded models (by folder path).
    var modelConfigs: [String: MLXModelConfig] = [:]
    @ObservationIgnored private var configLookups: Set<String> = []

    func loadMLXSupport() async {
        guard let runtime, runtime.isOwnInstall else { mlxSupport = nil; return }
        if let mlxSupport, mlxSupport.version == runtime.mlxVersion { return }
        let paths = self.paths
        let version = runtime.mlxVersion
        mlxSupport = await Task.detached {
            MLXModelSupport.findPackage(paths: paths).flatMap { MLXModelSupport.load(package: $0, version: version) }
        }.value
    }

    /// Reads config.json from Hugging Face for repos not checked yet.
    func loadModelConfigs(_ repos: [String]) async {
        let missing = repos.filter { !configLookups.contains($0) }
        guard !missing.isEmpty else { return }
        configLookups.formUnion(missing)
        let hub = self.hub
        await withTaskGroup(of: (String, MLXModelConfig?).self) { group in
            for repo in missing {
                group.addTask { (repo, try? await hub.config(repo)) }
            }
            for await (repo, config) in group {
                if let config { modelConfigs[repo] = config } else { configLookups.remove(repo) }
            }
        }
    }

    /// The model type when the installed mlx-lm cannot load it. nil when it can, or when unknown.
    func unsupportedModelType(_ key: String) -> String? {
        guard let support = mlxSupport, let config = modelConfigs[key], !support.supports(config) else { return nil }
        return config.modelType
    }

    /// Same, for a downloaded model: its folder's config.json, else its repo's.
    func unsupportedModelType(local model: LocalModel) -> String? {
        unsupportedModelType(model.modelPath) ?? unsupportedModelType(model.repo)
    }

    /// Short warning for a model this mlx-lm cannot load.
    func unsupportedNote(_ type: String) -> String {
        if let version = mlxSupport?.version { return "mlx-lm \(version) can't load model type \(type) yet." }
        return "mlx-lm can't load model type \(type) yet."
    }

    /// One click: gets uv when there is none, then installs or upgrades mlx-lm.
    func installRuntime(upgrade: Bool = false) {
        guard !isInstalling else { return }
        isInstalling = true
        installLog = []
        installTask = Task {
            defer { isInstalling = false }
            do {
                let runtime = mlxRuntime
                var uv = runtime.findUV()
                if uv == nil {
                    installLog.append("Downloading uv")
                    uv = try await runtime.installUV()
                    installLog.append("uv is ready")
                }
                guard let uv else { return }
                installLog.append(upgrade ? "Updating mlx-lm" : "Installing mlx-lm and Python \(AIConfig.mlxPythonVersion). This takes a minute.")
                for try await line in runtime.install(uv: uv, upgrade: upgrade) {
                    ResourceLog.append(line, to: &installLog)
                }
                await loadRuntime()
                if runtime.paths.mlxServer.path == self.runtime?.serverPath {
                    onNotice?("MLX runtime is ready")
                }
            } catch is CancellationError {
                installLog.append("Stopped")
            } catch {
                installLog.append(error.localizedDescription)
                onError?(error)
            }
        }
    }

    func cancelInstall() {
        installTask?.cancel()
    }

    func removeRuntime() async {
        if serverState.isActive { await stopServer() }
        do {
            try mlxRuntime.uninstall()
            await loadRuntime()
            onNotice?("MLX runtime removed")
        } catch {
            onError?(error)
        }
    }

    // MARK: MLX server

    @ObservationIgnored let server = MLXServerController()
    var serverState: MLXServerState = .stopped
    var serverConfig: MLXServerConfig?
    var serverLog: [String] = []
    var lastCrash: String?
    /// The model failed to load. The process may still answer HTTP (generation thread died).
    var mlxLoadFailure: MLXModelLoadFailure?
    /// Newest mlx-lm on PyPI, to tell "update" from "not supported yet".
    var mlxLatestVersion: String?
    /// Set when Containers was chosen but the network's gateway is not on this Mac now.
    var bindNote: String?
    @ObservationIgnored private lazy var logTail = LogTail(url: paths.serverLog)
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var didAdopt = false

    // Form
    var serverModelPath: String = ""
    var bindToContainers = false
    var bindNetwork: String = "default"
    var serverPort: String = String(AIConfig.mlxDefaultPort)
    var networks: [NetworkSummary] = []

    /// Called once: picks up a server from an earlier session and watches for exits.
    func setUpServer() {
        guard !didAdopt else { return }
        didAdopt = true
        server.onExit = { [weak self] code, crashed in
            Task { @MainActor in self?.serverExited(code: code, crashed: crashed) }
        }
        if server.adopt() {
            serverState = server.state
            serverConfig = server.config
            if let config = server.config {
                serverModelPath = config.model
                serverPort = String(config.port)
                if case .containers = config.bind { bindToContainers = true }
            }
        }
        serverLog = []
        logTail.reset()
        readLog()
        startWatching()
    }

    var gatewayNetworks: [NetworkSummary] {
        networks.filter { ($0.gateway ?? "").isEmpty == false }
    }

    var selectedGateway: String? {
        gatewayNetworks.first { $0.name == bindNetwork }?.gateway ?? gatewayNetworks.first?.gateway
    }

    func loadNetworks(_ client: ContainerClient?) async {
        guard let client, let list = try? await client.listNetworks() else { return }
        networks = list
        if !gatewayNetworks.contains(where: { $0.name == bindNetwork }) {
            bindNetwork = gatewayNetworks.first(where: { $0.name == "default" })?.name ?? gatewayNetworks.first?.name ?? "default"
        }
    }

    var canStartServer: Bool {
        runtime?.serverPath != nil && !serverModelPath.isEmpty && Int(serverPort) != nil && !serverState.isActive
            && (!bindToContainers || selectedGateway != nil) && selectedModelUnsupportedType == nil
    }

    /// The chosen model's type when the installed mlx-lm cannot load it.
    var selectedModelUnsupportedType: String? {
        guard !serverModelPath.isEmpty else { return nil }
        if let local = localModels.first(where: { $0.modelPath == serverModelPath }) { return unsupportedModelType(local: local) }
        return unsupportedModelType(serverModelPath)
    }

    /// Plain words for a failed model load.
    var mlxFailureMessage: MLXFailureMessage? {
        mlxLoadFailure.map { MLXServerOutput.message($0, installed: runtime?.mlxVersion, latest: mlxLatestVersion) }
    }

    /// The process runs but its model did not load, so every chat fails.
    var serverModelBroken: Bool { serverState.isActive && mlxLoadFailure != nil }

    static let containerNetworkDownNote = "The container network isn't up, so containers can't reach this server. Start the container service, then restart the server."

    func startServer() {
        guard let serverPath = runtime?.serverPath, let port = Int(serverPort), (1...65535).contains(port) else { return }
        var bind: MLXBind
        if bindToContainers {
            guard let gateway = selectedGateway else { return }
            bind = .containers(gateway: gateway)
        } else {
            bind = .mac
        }
        // Never pass an address that is not on an interface now: mlx_lm.server would die with Errno 49.
        let resolved = bind.resolved(assigned: NetworkInterfaces.assignedAddresses())
        bind = resolved.bind
        bindNote = resolved.fellBack ? Self.containerNetworkDownNote : nil
        let config = MLXServerConfig(model: serverModelPath, bind: bind, port: port)
        do {
            try server.start(config, serverPath: serverPath)
            ModelLibraryStore.shared.recordUse(kind: .mlxLM, model: config.model)
            serverConfig = config
            serverState = server.state
            lastCrash = nil
            mlxLoadFailure = nil
            serverLog = []
            logTail.reset()
            startWatching()
            Task { await waitUntilAnswering(config) }
        } catch {
            ComponentHealth.report(component: .mlx, feature: "Starting the MLX server", error: error)
            onError?(error)
        }
    }

    func stopServer() async {
        await server.stop()
        serverState = server.state
        await discover()
    }

    /// The served model cannot load: stop the server and show the MLX tab, where the model picker is free again.
    func pickAnotherMLXModel() async {
        if serverState.isActive { await stopServer() }
        // Preselect a downloaded model this mlx-lm can load, when there is one.
        if selectedModelUnsupportedType != nil || mlxLoadFailure != nil,
           let other = localModels.first(where: { $0.isComplete && $0.modelPath != serverModelPath && unsupportedModelType(local: $0) == nil }) {
            serverModelPath = other.modelPath
        }
        tab = .mlx
    }

    /// Asks PyPI (cached) for the newest mlx-lm, so the message can say update or not supported yet.
    func refreshLatestMLXVersion() async {
        if let latest = await PyPILatestVersion.shared.latest() { mlxLatestVersion = latest }
    }

    func restartServer() async {
        await stopServer()
        try? await Task.sleep(for: .milliseconds(300))
        startServer()
    }

    private func waitUntilAnswering(_ config: MLXServerConfig) async {
        let url = config.baseURL.appendingPathComponent("models")
        let http = AIHTTPClient()
        for _ in 0..<240 {
            guard case .starting = server.state else { break }
            if let (_, status) = try? await http.get(url, timeout: 1), status == 200 {
                server.markRunning()
                serverState = server.state
                await discover()
                readLog()
                if mlxLoadFailure == nil { onNotice?("MLX server is running") }
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private func serverExited(code: Int32?, crashed: Bool) {
        serverState = server.state
        readLog()
        if crashed {
            let reason: String
            switch code {
            case .some(let value) where value < 0: reason = "Stopped by signal \(-value)."
            case .some(let value): reason = "Exit code \(value)."
            case .none: reason = "The process is gone."
            }
            if let message = mlxFailureMessage {
                lastCrash = message.text
            } else if MLXServerOutput.isBindFailure(serverLog) {
                lastCrash = Self.containerNetworkDownNote
            } else {
                let lastError = serverLog.last { $0.contains("Error") || $0.contains("error:") || $0.contains("Killed") }
                lastCrash = lastError.map { "\(reason) \($0)" } ?? reason
            }
            let summary = lastCrash ?? reason
            // An import error or an unknown flag means the installed mlx-lm changed.
            ComponentHealth.report(component: "mlx", feature: "Starting the MLX server", message: serverLog.suffix(20).joined(separator: "\n"))
            onError?(DeckError.commandFailed("The MLX server stopped. \(summary)"))
            Notifier.post(identifier: "mlx-server-crash", title: "MLX server stopped", body: summary)
        }
        Task { await discover() }
    }

    /// Reads new log lines and checks adopted servers while the server is active.
    private func startWatching() {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.readLog()
                self.server.checkAlive()
                if !self.server.state.isActive { break }
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
    }

    private func readLog() {
        let lines = logTail.read()
        guard !lines.isEmpty else { return }
        for line in lines { ResourceLog.append(line, to: &serverLog) }
        if serverLog.count > AIConfig.maxLogLines {
            serverLog.removeFirst(serverLog.count - AIConfig.maxLogLines)
        }
        // Kept once found: access lines keep coming and could push the error out of the log.
        if mlxLoadFailure == nil, let failure = MLXServerOutput.modelLoadFailure(serverLog) {
            mlxLoadFailure = failure
            Task { await refreshLatestMLXVersion() }
        }
    }

    // MARK: Ollama

    var ollamaInstalled = false
    var ollamaRunning = false
    var ollamaModels: [ModelEndpointModel] = []
    var ollamaLoaded = false
    var ollamaBusy: Set<String> = []
    var ollamaStarting = false
    var pullName = ""
    var pullProgress: OllamaPullProgress?
    var isPulling = false
    /// The name being pulled now, so the Model Library can show its progress too.
    var pullingName: String?
    @ObservationIgnored private var pullTask: Task<Void, Never>?

    private let ollama = OllamaClient()

    func loadOllama() async {
        ollamaInstalled = OllamaControl().isInstalled
        ollamaRunning = await ollama.isRunning()
        if ollamaRunning, let models = try? await ollama.models() {
            if models != ollamaModels { withAnimation(.easeInOut(duration: 0.25)) { ollamaModels = models } }
        } else if !ollamaRunning {
            ollamaModels = []
        }
        ollamaLoaded = true
    }

    func startOllama() async {
        ollamaStarting = true
        defer { ollamaStarting = false }
        do {
            try await OllamaControl().start()
            for _ in 0..<40 {
                if await ollama.isRunning() { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            await loadOllama()
            await discover()
            if ollamaRunning { onNotice?("Ollama is running") } else { onError?(DeckError.commandFailed("Ollama did not start. Open the Ollama app to see why.")) }
        } catch {
            ComponentHealth.report(component: .ollama, feature: "Starting the Ollama server", error: error)
            onError?(error)
        }
    }

    func stopOllama() async {
        try? await OllamaControl().stop()
        for _ in 0..<20 {
            if !(await ollama.isRunning()) { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        await loadOllama()
        await discover()
    }

    /// Loads a model into memory (start) or frees it (stop).
    func toggleOllamaModel(_ model: ModelEndpointModel) async {
        ollamaBusy.insert(model.id)
        defer { ollamaBusy.remove(model.id) }
        do {
            if model.isLoaded {
                try await ollama.unload(model.id)
            } else {
                try await ollama.load(model.id)
                ModelLibraryStore.shared.recordUse(.ollama, key: model.id)
            }
            await loadOllama()
            await discover()
        } catch {
            onError?(error)
        }
    }

    func deleteOllamaModel(_ model: ModelEndpointModel) async {
        ollamaBusy.insert(model.id)
        defer { ollamaBusy.remove(model.id) }
        do {
            try await ollama.delete(model.id)
            await loadOllama()
            await discover()
            onNotice?("Deleted \(model.id)")
        } catch {
            onError?(error)
        }
    }

    func pullOllamaModel() {
        let name = pullName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !isPulling else { return }
        isPulling = true
        pullingName = name
        pullProgress = OllamaPullProgress(status: "pulling manifest")
        pullTask = Task {
            defer { isPulling = false; pullingName = nil }
            do {
                for try await progress in ollama.pull(name) {
                    pullProgress = progress
                }
                if Task.isCancelled { pullProgress = nil; return }
                pullProgress = nil
                pullName = ""
                await loadOllama()
                await discover()
                await ModelLibraryStore.shared.loadInstalled(refreshRuntimes: false)
                onNotice?("Pulled \(name)")
            } catch {
                pullProgress = nil
                onError?(error)
            }
        }
    }

    func cancelPull() {
        pullTask?.cancel()
        pullProgress = nil
    }

    // MARK: LM Studio

    enum LMStudioInstallKind {
        case core, homebrew
    }

    var lmStatus: LMStudioStatus?
    var lmModels: [LMStudioModel] = []
    var lmLoaded = false
    var lmBusy: Set<String> = []
    var lmServerBusy = false
    var lmInstalling = false
    var lmInstallLog: [String] = []
    /// Which install is running or last ran, for the log title.
    var lmInstallKind: LMStudioInstallKind = .core
    /// The last Homebrew install failed because this Mac cannot open LM Studio's disk image.
    var lmDiskImageFailed = false
    @ObservationIgnored private var lmInstallTask: Task<Void, Never>?

    private var lmStudio: LMStudioRuntime { LMStudioRuntime() }

    func loadLMStudio() async {
        let runtime = lmStudio
        let status = await runtime.status()
        lmStatus = status
        if status.isInstalled, hasDiscovered, !endpoints.contains(where: { $0.kind == .lmStudio }) {
            endpoints.append(LMStudioRuntime.installedEndpoint(port: status.port))
        }
        if status.cliPath != nil, let models = try? await runtime.models() {
            if models != lmModels { withAnimation(.easeInOut(duration: 0.25)) { lmModels = models } }
        } else if status.cliPath == nil {
            lmModels = []
        }
        lmLoaded = true
    }

    func startLMStudio() async {
        lmServerBusy = true
        defer { lmServerBusy = false }
        do {
            try await lmStudio.startServer()
            for _ in 0..<40 {
                if await lmStudio.status().serverRunning { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            await loadLMStudio()
            await discover()
            if lmStatus?.serverRunning == true { onNotice?("LM Studio server is running") }
        } catch {
            ComponentHealth.report(component: .lmStudio, feature: "Starting the LM Studio server", error: error)
            onError?(error)
        }
    }

    func stopLMStudio() async {
        lmServerBusy = true
        defer { lmServerBusy = false }
        do {
            try await lmStudio.stopServer()
        } catch {
            onError?(error)
        }
        await loadLMStudio()
        await discover()
    }

    /// Loads a model into memory, or unloads it.
    func toggleLMStudioModel(_ model: LMStudioModel) async {
        lmBusy.insert(model.id)
        defer { lmBusy.remove(model.id) }
        do {
            if model.isLoaded {
                try await lmStudio.unload(model.id)
            } else {
                try await lmStudio.load(model.id)
                ModelLibraryStore.shared.recordUse(.lmStudio, key: model.id)
            }
            await loadLMStudio()
            await discover()
        } catch {
            onError?(error)
        }
    }

    func unloadAllLMStudio() async {
        lmServerBusy = true
        defer { lmServerBusy = false }
        do {
            try await lmStudio.unload(nil)
            await loadLMStudio()
            await discover()
        } catch {
            onError?(error)
        }
    }

    /// LM Studio's own headless installer (`lms` and the llmster service), only when the person presses the button.
    func installLMStudioCore() {
        let runtime = lmStudio
        runLMStudioInstall(.core, command: LMStudioRuntime.installCoreCommandLine) { try runtime.installCore() }
    }

    /// `brew install --cask lm-studio`, only when the person presses the button.
    func installLMStudioWithHomebrew() {
        let runtime = lmStudio
        runLMStudioInstall(.homebrew, command: LMStudioRuntime.brewInstallCommandLine) { try runtime.installWithHomebrew() }
    }

    private func runLMStudioInstall(_ kind: LMStudioInstallKind, command: String,
                                    stream: @escaping () throws -> AsyncThrowingStream<String, Error>) {
        guard !lmInstalling else { return }
        lmInstalling = true
        lmInstallKind = kind
        lmDiskImageFailed = false
        lmInstallLog = ["$ " + command]
        lmInstallTask = Task {
            defer { lmInstalling = false }
            do {
                for try await line in try stream() {
                    ResourceLog.append(line, to: &lmInstallLog)
                }
                if Task.isCancelled { lmInstallLog.append("Stopped"); return }
                await loadLMStudio()
                await discover()
                if let label = lmStatus?.installLabel { onNotice?("\(label) is installed") }
            } catch is CancellationError {
                lmInstallLog.append("Stopped")
            } catch {
                // A failed command reports its last line, which the log already shows.
                if lmInstallLog.last != ResourceLog.clean(error.localizedDescription) {
                    lmInstallLog.append(error.localizedDescription)
                }
                let output = lmInstallLog.joined(separator: "\n")
                if kind == .homebrew, LMStudioRuntime.isDiskImageFailure(output) {
                    // A plain message with the core install button replaces the raw hdiutil error.
                    lmDiskImageFailed = true
                } else {
                    onError?(error)
                }
            }
        }
    }

    func cancelLMStudioInstall() {
        lmInstallTask?.cancel()
    }

    // MARK: Model library

    var query = ""
    var results: [HFModel] = []
    var isSearching = false
    var searchError: String?
    var hasSearched = false
    /// Text of the last MLX search that finished.
    var lastSearchQuery: String?
    /// Selected Browse row: a Hugging Face repo, or a `LibraryModel.id` from another source.
    var selectedRepo: HFModel.ID?
    /// Download size per repo (needed files only).
    var sizes: [String: UInt64] = [:]
    var files: [String: [HFFile]] = [:]
    var localModels: [LocalModel] = []
    var localLoaded = false
    var downloads: [String: ModelDownloadProgress] = [:]
    var downloadErrors: [String: String] = [:]
    @ObservationIgnored private var downloadTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var searchSequencer = PollSequencer()

    private let hub = HuggingFaceClient()

    func search() async {
        let token = searchSequencer.begin()
        isSearching = true
        defer { isSearching = false }
        do {
            let found = try await hub.search(query)
            guard searchSequencer.accept(token) else { return }
            withAnimation(.easeInOut(duration: 0.2)) { results = found }
            lastSearchQuery = query
            // A new list keeps the selection only when that model is still in it. Rows from other sources keep theirs.
            if let selected = selectedRepo, HuggingFaceClient.isRepoID(selected), !found.contains(where: { $0.id == selected }) {
                selectedRepo = nil
            }
            searchError = nil
            hasSearched = true
            await loadSizes(found.map(\.id))
        } catch {
            guard searchSequencer.accept(token) else { return }
            searchError = error.localizedDescription
            hasSearched = true
        }
    }

    /// Fetches file lists (for the size) a few at a time.
    func loadSizes(_ repos: [String]) async {
        if mlxSupport != nil { Task { await loadModelConfigs(repos) } }
        let missing = repos.filter { sizes[$0] == nil }
        guard !missing.isEmpty else { return }
        let hub = self.hub
        await withTaskGroup(of: (String, [HFFile]?).self) { group in
            var iterator = missing.makeIterator()
            for _ in 0..<4 {
                guard let repo = iterator.next() else { break }
                group.addTask { (repo, try? await hub.files(repo)) }
            }
            while let (repo, list) = await group.next() {
                if let list {
                    files[repo] = list
                    sizes[repo] = list.reduce(0) { $0 + $1.size }
                }
                if let next = iterator.next() {
                    group.addTask { (next, try? await hub.files(next)) }
                }
            }
        }
    }

    func loadLocalModels() async {
        let store = LocalModelStore(paths: paths)
        let list = await Task.detached { store.list() }.value
        if list != localModels { withAnimation(.easeInOut(duration: 0.25)) { localModels = list } }
        localLoaded = true
        let unread = list.filter { $0.isComplete && modelConfigs[$0.modelPath] == nil }.map(\.modelPath)
        if !unread.isEmpty {
            let configs = await Task.detached { unread.compactMap { path in MLXModelConfig.load(modelFolder: path).map { (path, $0) } } }.value
            for (path, config) in configs { modelConfigs[path] = config }
        }
        if serverModelPath.isEmpty || !list.contains(where: { $0.modelPath == serverModelPath }) && !serverState.isActive {
            serverModelPath = list.first(where: \.isComplete)?.modelPath ?? serverModelPath
        }
    }

    func isDownloaded(_ repo: String) -> Bool {
        localModels.contains { $0.repo == repo && $0.isComplete }
    }

    func partialModel(_ repo: String) -> LocalModel? {
        localModels.first { $0.repo == repo && !$0.isComplete && $0.source == .library }
    }

    func download(_ repo: String) {
        guard downloads[repo] == nil else { return }
        downloadErrors[repo] = nil
        downloads[repo] = ModelDownloadProgress(completedBytes: 0, totalBytes: sizes[repo] ?? 0, currentFile: "", filesDone: 0, fileCount: files[repo]?.count ?? 0)
        let hub = self.hub
        let downloader = ModelDownloader(paths: paths)
        downloadTasks[repo] = Task {
            do {
                let list: [HFFile]
                if let known = files[repo] { list = known } else { list = try await hub.files(repo) }
                files[repo] = list
                sizes[repo] = list.reduce(0) { $0 + $1.size }
                try await downloader.download(repo: repo, files: list) { progress in
                    Task { @MainActor in
                        if AIModelsStore.shared.downloads[repo] != nil { AIModelsStore.shared.downloads[repo] = progress }
                    }
                }
                downloads[repo] = nil
                await loadLocalModels()
                onNotice?("Downloaded \(repo)")
            } catch is CancellationError {
                downloads[repo] = nil
                await loadLocalModels()
            } catch {
                downloads[repo] = nil
                downloadErrors[repo] = error.localizedDescription
                await loadLocalModels()
                onError?(error)
            }
            downloadTasks[repo] = nil
        }
    }

    func cancelDownload(_ repo: String) {
        downloadTasks[repo]?.cancel()
    }

    // MARK: Chat

    struct ChatEntry: Identifiable, Equatable {
        var id = UUID()
        var role: ChatMessage.Role
        var text: String
        var reasoning: String = ""
        var stats: ChatStats?
        var failed = false
        /// Raw error text behind a plain failure message, shown under Details.
        var details: String?
        /// The answer failed because the MLX server's model did not load. Offers Pick another model.
        var modelLoadFailed = false
        /// The server stopped the answer at its length limit.
        var cutOff = false
        /// Model and server that wrote an assistant answer, for its header.
        var model: String = ""
        var serverKind: ModelServerKind?
    }

    var chatEndpointID: ModelEndpoint.ID?
    var chatModel: String = ""
    var chatInput = ""
    var isStreaming = false
    /// Conversation the running answer belongs to.
    private(set) var streamingKey: String?
    /// One conversation per server and model, loaded from the cache the first time it is shown.
    private(set) var conversations: [String: [ChatEntry]] = [:]
    @ObservationIgnored private var loadedChats: Set<String> = []
    /// Conversations with messages kept only in memory (history off, no volume, service stopped).
    @ObservationIgnored private(set) var unsavedChats: Set<String> = []
    /// Messages that came from or went to the cache, so they can be dropped when history goes away.
    @ObservationIgnored private var savedIDs: Set<UUID> = []
    @ObservationIgnored private var chatTask: Task<Void, Never>?
    /// Cache of the `deck-chat-history` volume. Tests point it at a temporary folder.
    @ObservationIgnored var chatHistory = ChatHistory(directory: AIPaths().chats.appendingPathComponent("models", isDirectory: true))
    /// Where the "Save chat history" switch and the volume flag live. Tests use their own suite.
    @ObservationIgnored var chatDefaults: UserDefaults = .standard
    @ObservationIgnored var chatSync: ChatSyncCenter = .shared

    var chatEndpoint: ModelEndpoint? {
        runningEndpoints.first { $0.id == chatEndpointID }
    }

    /// Key of the conversation on screen: the chosen server and model.
    var chatKey: String? {
        guard let endpoint = chatEndpoint, !chatModel.isEmpty else { return nil }
        return ChatHistory.key(server: endpoint.kind, port: endpoint.port, model: chatModel)
    }

    /// The conversation on screen.
    var chat: [ChatEntry] {
        get { chatKey.flatMap { conversations[$0] } ?? [] }
        set { if let key = chatKey { conversations[key] = newValue } }
    }

    /// "Save chat history" in Settings, on unless turned off.
    var chatHistoryEnabled: Bool {
        chatDefaults.object(forKey: PrefKey.saveChatHistory) as? Bool ?? true
    }

    var chatSaveStatus: ChatSaveStatus { chatSync.status(ChatSyncCenter.modelsTarget) }

    /// Reads the conversation on screen from the cache once (instant), and checks the
    /// `deck-chat-history` volume in the background.
    func ensureChatLoaded() {
        connectChatSync()
        guard let key = chatKey, !loadedChats.contains(key) else { return }
        loadedChats.insert(key)
        guard chatSync.canWrite(ChatSyncCenter.modelsTarget) else { return }
        let saved = chatHistory.load(key).map(ChatEntry.init(saved:))
        savedIDs.formUnion(saved.map(\.id))
        if conversations[key]?.isEmpty ?? true { conversations[key] = saved }
    }

    /// Writes the cache now, and the volume a few seconds later. When history is not being
    /// saved the messages stay in memory, and are written if saving comes back while the app runs.
    func saveChat(_ key: String) {
        guard chatSync.canWrite(ChatSyncCenter.modelsTarget) else {
            if !(conversations[key] ?? []).isEmpty { unsavedChats.insert(key) }
            return
        }
        let entries = conversations[key] ?? []
        do {
            try chatHistory.save(key, messages: entries.map(\.saved))
            savedIDs.formUnion(entries.map(\.id))
            unsavedChats.remove(key)
            chatSync.changed(ChatSyncCenter.modelsTarget)
        } catch {
            onError?(error)
        }
    }

    func connectChatSync() {
        let id = ChatSyncCenter.modelsTarget
        if !chatSync.isRegistered(id) {
            moveLegacyChatFiles()
            chatSync.register(id, target: ChatSyncCenter.Target(
                history: chatHistory,
                isEnabled: { [weak self] in self?.chatHistoryEnabled ?? true },
                transport: { .helper(volume: ChatVolumeSync.volumeName, labels: ChatVolumeSync.modelVolumeLabels) },
                // The Settings switch decides. While it is on, a missing volume is made again
                // (a cleanup or the CLI removed it). Deleting it on the Volumes screen turns the switch off.
                mayCreateVolume: { true },
                didCreateVolume: { [weak self] in self?.chatDefaults.set(true, forKey: PrefKey.chatVolumeCreated) },
                missingStatus: .volumeMissing,
                onChange: { [weak self] files in self?.reloadChats(files) },
                onDropped: { [weak self] in self?.dropSavedChats() },
                onRecovered: { [weak self] in self?.saveUnsavedChats() }
            ))
        }
        chatSync.chatAppeared(id)
    }

    /// The notice's button: Turn On, Create Volume or Try Again.
    func chatNoticeAction() async {
        if chatSaveStatus == .off {
            chatDefaults.set(true, forKey: PrefKey.saveChatHistory)
            await chatSync.applyHistorySetting(ChatSyncCenter.modelsTarget)
        } else {
            await chatSync.performNoticeAction(ChatSyncCenter.modelsTarget)
        }
    }

    /// Before volumes, conversations were files right in the chats folder. They move into the
    /// cache folder, and the first sync copies them into the volume.
    private func moveLegacyChatFiles() {
        let root = AIPaths().chats
        guard chatHistory.directory.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else { return }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let legacy = names.filter { $0.hasPrefix("model-") && ChatVolumeSync.isSafeName($0) }
        guard !legacy.isEmpty else { return }
        try? FileManager.default.createDirectory(at: chatHistory.directory, withIntermediateDirectories: true)
        for name in legacy {
            let target = chatHistory.directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: target.path) { continue }
            try? FileManager.default.moveItem(at: root.appendingPathComponent(name), to: target)
        }
    }

    /// The volume had newer copies: reload those conversations (not one that is streaming or unsaved).
    func reloadChats(_ files: Set<String>) {
        for key in loadedChats where key != streamingKey && !unsavedChats.contains(key)
            && files.contains(chatHistory.url(for: key).lastPathComponent) {
            let saved = chatHistory.load(key).map(ChatEntry.init(saved:))
            savedIDs.formUnion(saved.map(\.id))
            conversations[key] = saved
        }
    }

    /// History went away (off, or the volume was removed): nothing shows from the cache.
    /// Messages of this session stay on screen, kept in memory.
    func dropSavedChats() {
        for key in conversations.keys {
            let kept = (conversations[key] ?? []).filter { !savedIDs.contains($0.id) || key == streamingKey && $0.id == conversations[key]?.last?.id }
            conversations[key] = kept
            if kept.isEmpty { unsavedChats.remove(key) } else { unsavedChats.insert(key) }
        }
        savedIDs = []
    }

    /// Saving is back: merge what was kept in memory with the volume's copy, then save it.
    func saveUnsavedChats() {
        for key in unsavedChats {
            let stored = chatHistory.load(key).map(ChatEntry.init(saved:))
            let storedIDs = Set(stored.map(\.id))
            conversations[key] = stored + (conversations[key] ?? []).filter { !storedIDs.contains($0.id) }
            loadedChats.insert(key)
        }
        for key in unsavedChats { saveChat(key) }
    }

    func normalizeChatModel() {
        guard let endpoint = chatEndpoint else { return }
        if !endpoint.models.contains(where: { $0.id == chatModel }) {
            chatModel = (endpoint.models.first(where: \.isLoaded) ?? endpoint.models.first)?.id ?? ""
        }
    }

    /// Opens the chat tab on an endpoint, optionally with a model.
    func openChat(_ endpoint: ModelEndpoint, model: String? = nil) {
        chatEndpointID = endpoint.id
        if let model { chatModel = model } else { normalizeChatModel() }
        tab = .chat
    }

    /// The conversation sent with a new question. Failed answers and empty ones (only thoughts,
    /// cut off) stay out: an empty assistant turn makes the model think it already answered.
    nonisolated static func requestMessages(_ entries: [ChatEntry]) -> [ChatMessage] {
        entries.filter { !$0.failed && !($0.role == .assistant && $0.text.isEmpty) }
            .map { ChatMessage(role: $0.role, content: $0.text) }
    }

    /// Sends the composer text. The answer keeps streaming into its own conversation when the
    /// person switches tabs, screens or models, and is saved when it ends.
    func sendChat() {
        let text = chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming, let endpoint = chatEndpoint, !chatModel.isEmpty, let key = chatKey else { return }
        ensureChatLoaded()
        chatInput = ""
        var entries = conversations[key] ?? []
        entries.append(ChatEntry(role: .user, text: text))
        let history = Self.requestMessages(entries)
        entries.append(ChatEntry(role: .assistant, text: "", stats: ChatStats(), model: chatModel, serverKind: endpoint.kind))
        let answerID = entries[entries.count - 1].id
        conversations[key] = entries
        saveChat(key)
        isStreaming = true
        streamingKey = key
        let model = chatModel
        ModelLibraryStore.shared.recordUse(kind: endpoint.kind, model: model)
        chatTask = Task {
            defer {
                isStreaming = false
                streamingKey = nil
                updateEntry(key, answerID) { entry in
                    if entry.stats?.finished == nil { entry.stats?.finished = Date() }
                }
                saveChat(key)
            }
            do {
                let stream = ChatClient().stream(baseURL: endpoint.baseURL, model: model, messages: history,
                                                 apiKey: endpoint.kind.placeholderAPIKey, maxTokens: endpoint.kind.chatMaxTokens)
                for try await event in stream {
                    let found = updateEntry(key, answerID) { entry in
                        entry.stats?.record(event)
                        switch event {
                        case .content(let piece): entry.text += piece
                        case .reasoning(let piece): entry.reasoning += piece
                        case .finished where event.isLengthStop: entry.cutOff = true
                        default: break
                        }
                    }
                    if !found { break }
                }
            } catch {
                let raw = error.localizedDescription
                if let failure = await mlxChatFailure(endpoint, errorText: raw) {
                    let message = MLXServerOutput.message(failure, installed: runtime?.mlxVersion, latest: mlxLatestVersion)
                    updateEntry(key, answerID) { entry in
                        entry.failed = true
                        entry.text = message.text
                        entry.details = failure.details.joined(separator: "\n")
                        entry.modelLoadFailed = true
                    }
                } else {
                    updateEntry(key, answerID) { entry in
                        entry.failed = true
                        entry.text = raw
                    }
                }
            }
        }
    }

    /// For the MLX server Container Deck runs: when a chat fails (often a 404 or "generation thread
    /// died"), its output tells whether the model failed to load.
    private func mlxChatFailure(_ endpoint: ModelEndpoint, errorText: String) async -> MLXModelLoadFailure? {
        guard endpoint.isManaged || (serverState.isActive && endpoint.port == serverConfig?.port) else { return nil }
        readLog()
        guard let failure = MLXServerOutput.chatFailure(errorText: errorText, serverLog: serverLog) else { return nil }
        if mlxLoadFailure == nil { mlxLoadFailure = MLXServerOutput.modelLoadFailure(serverLog) }
        await refreshLatestMLXVersion()
        return failure
    }

    /// Changes one message of a conversation in place. False when it is gone (cleared).
    @discardableResult
    private func updateEntry(_ key: String, _ id: ChatEntry.ID, _ change: (inout ChatEntry) -> Void) -> Bool {
        guard let index = conversations[key]?.firstIndex(where: { $0.id == id }) else { return false }
        change(&conversations[key]![index])
        return true
    }

    func stopChat() {
        chatTask?.cancel()
    }

    /// Clears the conversation on screen and deletes its saved file.
    func clearChat() {
        guard let key = chatKey else { return }
        if streamingKey == key { chatTask?.cancel() }
        conversations[key] = []
        unsavedChats.remove(key)
        chatHistory.clear(key)
        chatSync.changed(ChatSyncCenter.modelsTarget)
    }

    #if DEBUG
    /// Marks the conversation on screen as streaming, for snapshots of that state.
    func setDebugStreaming(_ on: Bool) {
        isStreaming = on
        streamingKey = on ? chatKey : nil
    }
    #endif
}

extension AIModelsStore.ChatEntry {
    init(saved: SavedChatMessage) {
        var stats: ChatStats?
        if let started = saved.started {
            var value = ChatStats(started: started)
            value.firstToken = saved.firstToken
            value.finished = saved.finished
            value.completionTokens = saved.tokens
            stats = value
        }
        self.init(id: saved.id, role: saved.role == .user ? .user : .assistant, text: saved.text, reasoning: saved.reasoning ?? "",
                  stats: stats, failed: saved.failed ?? false, cutOff: saved.cutOff ?? false, model: saved.model ?? "",
                  serverKind: saved.server.flatMap(ModelServerKind.init(rawValue:)))
    }

    var saved: SavedChatMessage {
        SavedChatMessage(id: id, role: role == .user ? .user : .assistant, text: text,
                         reasoning: reasoning.isEmpty ? nil : reasoning, failed: failed ? true : nil,
                         model: model.isEmpty ? nil : model, server: serverKind?.rawValue,
                         started: stats?.started, firstToken: stats?.firstToken, finished: stats?.finished,
                         tokens: stats.map(\.tokens), cutOff: cutOff ? true : nil)
    }
}
