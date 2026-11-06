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
        await discover()
    }

    func discover() async {
        let token = sequencer.begin()
        isDiscovering = true
        var found = await ModelEndpoints.discover()
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

    // MARK: LM Studio

    var lmStatus: LMStudioStatus?
    var lmModels: [LMStudioModel] = []
    var lmLoaded = false
    var lmBusy: Set<String> = []
    var lmServerBusy = false
    var lmInstalling = false
    var lmInstallLog: [String] = []
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

    /// `brew install --cask lm-studio`, only when the person presses the button.
    func installLMStudioWithHomebrew() {
        guard !lmInstalling else { return }
        lmInstalling = true
        lmInstallLog = ["$ " + LMStudioRuntime.brewInstallCommandLine]
        let runtime = lmStudio
        lmInstallTask = Task {
            defer { lmInstalling = false }
            do {
                for try await line in try runtime.installWithHomebrew() {
                    ResourceLog.append(line, to: &lmInstallLog)
                }
                if Task.isCancelled { lmInstallLog.append("Stopped"); return }
                await loadLMStudio()
                await discover()
                if lmStatus?.isInstalled == true { onNotice?("LM Studio is installed") }
            } catch is CancellationError {
                lmInstallLog.append("Stopped")
            } catch {
                lmInstallLog.append(error.localizedDescription)
                onError?(error)
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
            // A new list keeps the selection only when that model is still in it.
            if let selected = selectedRepo, !found.contains(where: { $0.id == selected }) {
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
        var id = UUID()
        var role: ChatMessage.Role
        var text: String
        var reasoning: String = ""
        var stats: ChatStats?
        var failed = false
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
                mayCreateVolume: { [weak self] in !(self?.chatDefaults.bool(forKey: PrefKey.chatVolumeCreated) ?? true) },
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

    /// Sends the composer text. The answer keeps streaming into its own conversation when the
    /// person switches tabs, screens or models, and is saved when it ends.
    func sendChat() {
        let text = chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming, let endpoint = chatEndpoint, !chatModel.isEmpty, let key = chatKey else { return }
        ensureChatLoaded()
        chatInput = ""
        var entries = conversations[key] ?? []
        entries.append(ChatEntry(role: .user, text: text))
        let history = entries.filter { !$0.failed }.map { ChatMessage(role: $0.role, content: $0.text) }
        entries.append(ChatEntry(role: .assistant, text: "", stats: ChatStats(), model: chatModel, serverKind: endpoint.kind))
        let answerID = entries[entries.count - 1].id
        conversations[key] = entries
        saveChat(key)
        isStreaming = true
        streamingKey = key
        let model = chatModel
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
                let stream = ChatClient().stream(baseURL: endpoint.baseURL, model: model, messages: history, apiKey: endpoint.kind.placeholderAPIKey)
                for try await event in stream {
                    let found = updateEntry(key, answerID) { entry in
                        entry.stats?.record(event)
                        switch event {
                        case .content(let piece): entry.text += piece
                        case .reasoning(let piece): entry.reasoning += piece
                        default: break
                        }
                    }
                    if !found { break }
                }
            } catch {
                updateEntry(key, answerID) { entry in
                    entry.failed = true
                    entry.text = error.localizedDescription
                }
            }
        }
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
                  stats: stats, failed: saved.failed ?? false, model: saved.model ?? "",
                  serverKind: saved.server.flatMap(ModelServerKind.init(rawValue:)))
    }

    var saved: SavedChatMessage {
        SavedChatMessage(id: id, role: role == .user ? .user : .assistant, text: text,
                         reasoning: reasoning.isEmpty ? nil : reasoning, failed: failed ? true : nil,
                         model: model.isEmpty ? nil : model, server: serverKind?.rawValue,
                         started: stats?.started, firstToken: stats?.firstToken, finished: stats?.finished,
                         tokens: stats.map(\.tokens))
    }
}
