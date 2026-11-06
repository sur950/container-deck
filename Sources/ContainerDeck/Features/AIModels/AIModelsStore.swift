import SwiftUI
import DeckCore

/// Tabs of the AI Models screen.
enum AITab: String, CaseIterable, Hashable {
    case servers, mlx, ollama, library, chat

    var title: String {
        switch self {
        case .servers: return "Servers"
        case .mlx: return "MLX"
        case .ollama: return "Ollama"
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

    func discover() async {
        let token = sequencer.begin()
        isDiscovering = true
        let found = await ModelEndpoints.discover()
        isDiscovering = false
        guard sequencer.accept(token) else { return }
        if found != endpoints {
            withAnimation(.easeInOut(duration: 0.25)) { endpoints = found }
        }
        hasDiscovered = true
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
            && (!bindToContainers || selectedGateway != nil)
    }

    func startServer() {
        guard let serverPath = runtime?.serverPath, let port = Int(serverPort), (1...65535).contains(port) else { return }
        let bind: MLXBind
        if bindToContainers {
            guard let gateway = selectedGateway else { return }
            bind = .containers(gateway: gateway)
        } else {
            bind = .mac
        }
        let config = MLXServerConfig(model: serverModelPath, bind: bind, port: port)
        do {
            try server.start(config, serverPath: serverPath)
            serverConfig = config
            serverState = server.state
            lastCrash = nil
            serverLog = []
            logTail.reset()
            startWatching()
            Task { await waitUntilAnswering(config) }
        } catch {
            onError?(error)
        }
    }

    func stopServer() async {
        await server.stop()
        serverState = server.state
        await discover()
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
                onNotice?("MLX server is running")
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
            let lastError = serverLog.last { $0.contains("Error") || $0.contains("error:") || $0.contains("Killed") }
            lastCrash = lastError.map { "\(reason) \($0)" } ?? reason
            onError?(DeckError.commandFailed("The MLX server stopped unexpectedly. \(reason)"))
            Notifier.post(identifier: "mlx-server-crash", title: "MLX server stopped", body: "The MLX server stopped unexpectedly. \(reason)")
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
        pullProgress = OllamaPullProgress(status: "pulling manifest")
        pullTask = Task {
            defer { isPulling = false }
            do {
                for try await progress in ollama.pull(name) {
                    pullProgress = progress
                }
                if Task.isCancelled { pullProgress = nil; return }
                pullProgress = nil
                pullName = ""
                await loadOllama()
                await discover()
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

    // MARK: Model library

    var query = ""
    var results: [HFModel] = []
    var isSearching = false
    var searchError: String?
    var hasSearched = false
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

    func deleteLocalModel(_ model: LocalModel) async {
        if serverState.isActive, serverConfig?.model == model.modelPath {
            onError?(DeckError.commandFailed("Stop the MLX server before deleting the model it runs."))
            return
        }
        let store = LocalModelStore(paths: paths)
        do {
            try await Task.detached { try store.delete(model) }.value
            await loadLocalModels()
            onNotice?("Deleted \(model.name)")
        } catch {
            onError?(error)
        }
    }

    // MARK: Chat

    struct ChatEntry: Identifiable, Equatable {
        let id = UUID()
        var role: ChatMessage.Role
        var text: String
        var reasoning: String = ""
        var stats: ChatStats?
        var failed = false
    }

    var chatEndpointID: ModelEndpoint.ID?
    var chatModel: String = ""
    var chatInput = ""
    var chat: [ChatEntry] = []
    var isStreaming = false
    @ObservationIgnored private var chatTask: Task<Void, Never>?

    var chatEndpoint: ModelEndpoint? {
        runningEndpoints.first { $0.id == chatEndpointID }
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

    func sendChat() {
        let text = chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming, let endpoint = chatEndpoint, !chatModel.isEmpty else { return }
        chatInput = ""
        chat.append(ChatEntry(role: .user, text: text))
        let history = chat.filter { !$0.failed }.map { ChatMessage(role: $0.role, content: $0.text) }
        chat.append(ChatEntry(role: .assistant, text: "", stats: ChatStats()))
        let index = chat.count - 1
        isStreaming = true
        let model = chatModel
        chatTask = Task {
            defer {
                isStreaming = false
                if chat.indices.contains(index), chat[index].stats?.finished == nil {
                    chat[index].stats?.finished = Date()
                }
            }
            do {
                let stream = ChatClient().stream(baseURL: endpoint.baseURL, model: model, messages: history, apiKey: endpoint.kind.placeholderAPIKey)
                for try await event in stream {
                    guard chat.indices.contains(index) else { break }
                    chat[index].stats?.record(event)
                    switch event {
                    case .content(let piece): chat[index].text += piece
                    case .reasoning(let piece): chat[index].reasoning += piece
                    default: break
                    }
                }
            } catch {
                if chat.indices.contains(index) {
                    chat[index].failed = true
                    chat[index].text = error.localizedDescription
                }
            }
        }
    }

    func stopChat() {
        chatTask?.cancel()
    }

    func clearChat() {
        chatTask?.cancel()
        chat = []
    }
}
