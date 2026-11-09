import SwiftUI
import DeckCore

/// Which runtimes the Browse list shows.
enum LibrarySourceFilter: String, CaseIterable, Hashable {
    case all, mlx, ollama, lmStudio

    var title: String {
        switch self {
        case .all: return "All"
        case .mlx: return "MLX"
        case .ollama: return "Ollama"
        case .lmStudio: return "LM Studio"
        }
    }

    var source: ModelSource? {
        switch self {
        case .all: return nil
        case .mlx: return .mlx
        case .ollama: return .ollama
        case .lmStudio: return .lmStudio
        }
    }

    func includes(_ source: ModelSource) -> Bool { self.source == nil || self.source == source }
}

/// Why a runtime can't download right now, with the tab that fixes it.
struct LibraryBlocker: Equatable {
    var reason: String
    var tab: AITab
    var buttonTitle: String
}

/// The Model Library across MLX, Ollama and LM Studio: search, details, downloads, the models on
/// this Mac and deleting them. MLX search and downloads stay in `AIModelsStore`.
@MainActor
@Observable
final class ModelLibraryStore {
    static let shared = ModelLibraryStore()

    private var ai: AIModelsStore { AIModelsStore.shared }
    @ObservationIgnored private let paths = AIPaths()
    @ObservationIgnored private lazy var usageLog = ModelUsageLog(url: paths.modelUsage)

    // MARK: Browse

    var filter: LibrarySourceFilter = .all
    var ollamaResults: [OllamaLibraryModel] = []
    var ollamaOrigin: LibrarySearchOrigin?
    var lmResults: [LMStudioCatalogModel] = []
    var lmOrigin: LibrarySearchOrigin?
    var lmError: String?
    var isSearchingOllama = false
    var isSearchingLM = false
    var hasSearchedOllama = false
    var hasSearchedLM = false
    @ObservationIgnored private var ollamaSequencer = PollSequencer()
    @ObservationIgnored private var lmSequencer = PollSequencer()
    @ObservationIgnored private var lastOllamaQuery: String?
    @ObservationIgnored private var lastLMQuery: String?

    /// Exact name typed in the Ollama pull box ("qwen3:0.6b").
    var exactName = ""

    // Details
    var ollamaTags: [String: [OllamaLibraryTag]] = [:]
    var ollamaTagErrors: [String: String] = [:]
    var ollamaPickedTag: [String: String] = [:]
    var lmDetails: [String: LMStudioModelDetail] = [:]
    var lmDetailErrors: [String: String] = [:]
    /// Download size per variant repo. For GGUF repos, the files with their sizes.
    var variantSizes: [String: UInt64] = [:]
    var ggufFiles: [String: [HFFile]] = [:]

    // LM Studio downloads
    var lmDownloads: [String: LMStudioDownloadProgress] = [:]
    var lmDownloadErrors: [String: String] = [:]
    @ObservationIgnored private var lmDownloadTasks: [String: Task<Void, Never>] = [:]

    @ObservationIgnored private let ollamaLibrary = OllamaLibraryClient()
    @ObservationIgnored private let lmCatalog = LMStudioCatalogClient()
    @ObservationIgnored private let hub = HuggingFaceClient()

    var isSearching: Bool { ai.isSearching || isSearchingOllama || isSearchingLM }

    /// Rows for the table, by filter.
    var rows: [LibraryModel] {
        var list: [LibraryModel] = []
        if filter.includes(.mlx) { list += ai.results.map(LibraryModel.init(huggingFace:)) }
        if filter.includes(.ollama) { list += ollamaResults.map(\.libraryModel) }
        if filter.includes(.lmStudio) { list += lmResults.map(\.libraryModel) }
        return list
    }

    /// True once every shown source has answered at least once.
    var hasSearched: Bool {
        (!filter.includes(.mlx) || ai.hasSearched)
            && (!filter.includes(.ollama) || hasSearchedOllama)
            && (!filter.includes(.lmStudio) || hasSearchedLM)
    }

    /// Searches every source the filter shows. Sources skip a search they already ran for this text.
    /// Size lookups for the old rows stop first, then the rows on screen ask again.
    func search(force: Bool = false) async {
        let query = ai.query
        let queue = sizeQueue
        await queue.cancelAll()
        sizeLoading = []
        sizeMissing = []
        async let mlx: Void = searchMLX(query, force: force)
        async let ollama: Void = searchOllama(query, force: force)
        async let lm: Void = searchLM(query, force: force)
        _ = await (mlx, ollama, lm)
        let shown = Set(rows.map(\.id))
        for id in visibleRows where shown.contains(id) { await requestSize(id) }
    }

    // MARK: Row sizes

    /// Sizes for Ollama rows (the default tag) and LM Studio rows (the smallest option), by row id.
    var rowSizes: [String: LibrarySize] = [:]
    var sizeLoading: Set<String> = []
    /// Rows whose size could not be found.
    var sizeMissing: Set<String> = []
    @ObservationIgnored private var visibleRows: Set<String> = []
    @ObservationIgnored private let sizeHTTP = CountingHTTPFetcher()
    @ObservationIgnored private lazy var sizeQueue: LibrarySizeQueue = makeSizeQueue()

    private func makeSizeQueue() -> LibrarySizeQueue {
        let http = sizeHTTP
        let ollama = OllamaLibraryClient(http: http, cache: LibraryCache(directory: paths.libraryCache))
        let catalog = LMStudioCatalogClient(http: http, cache: LibraryCache(directory: paths.libraryCache))
        let hub = HuggingFaceClient(http: http)
        return LibrarySizeQueue(maxConcurrent: 4, cache: LibraryCache(directory: paths.libraryCache), lookup: { id in
            if id.hasPrefix("ollama:") { return await ollama.defaultSize(String(id.dropFirst("ollama:".count))) }
            if id.hasPrefix("lmStudio:") { return await catalog.smallestDownload(String(id.dropFirst("lmStudio:".count)), hub: hub) }
            return nil
        }, report: { id, size in
            await MainActor.run {
                ModelLibraryStore.shared.sizeArrived(id, size)
                DebugAutomation.log("library sizes: \(id) \(size.map { String($0.bytes) } ?? "none"), \(http.count) HTTP requests so far")
            }
        })
    }

    /// A Browse row came on screen: look up its size when the list does not have one.
    func rowAppeared(_ model: LibraryModel) {
        guard model.source != .mlx else { return }
        visibleRows.insert(model.id)
        Task { await requestSize(model.id) }
    }

    /// The row scrolled away: drop its lookup if it has not started.
    func rowDisappeared(_ model: LibraryModel) {
        guard model.source != .mlx else { return }
        visibleRows.remove(model.id)
        let queue = sizeQueue
        Task {
            await queue.withdraw(model.id)
            if await !queue.isRunning(model.id) { sizeLoading.remove(model.id) }
        }
    }

    private func requestSize(_ id: String) async {
        guard rowSizes[id] == nil, !sizeMissing.contains(id), !sizeLoading.contains(id) else { return }
        sizeLoading.insert(id)
        await sizeQueue.request(id)
    }

    func sizeArrived(_ id: String, _ size: LibrarySize?) {
        sizeLoading.remove(id)
        if let size { rowSizes[id] = size } else { sizeMissing.insert(id) }
    }

    private func searchMLX(_ query: String, force: Bool) async {
        guard filter.includes(.mlx) else { return }
        if !force, ai.hasSearched, ai.lastSearchQuery == query { return }
        await ai.search()
    }

    private func searchOllama(_ query: String, force: Bool) async {
        guard filter.includes(.ollama) else { return }
        if !force, hasSearchedOllama, lastOllamaQuery == query { return }
        let token = ollamaSequencer.begin()
        isSearchingOllama = true
        defer { isSearchingOllama = false }
        let result = await ollamaLibrary.search(query)
        guard ollamaSequencer.accept(token) else { return }
        withAnimation(.easeInOut(duration: 0.2)) { ollamaResults = result.models }
        ollamaOrigin = result.origin
        lastOllamaQuery = query
        hasSearchedOllama = true
    }

    private func searchLM(_ query: String, force: Bool) async {
        guard filter.includes(.lmStudio) else { return }
        if !force, hasSearchedLM, lastLMQuery == query { return }
        let token = lmSequencer.begin()
        isSearchingLM = true
        defer { isSearchingLM = false }
        do {
            let result = try await lmCatalog.search(query)
            guard lmSequencer.accept(token) else { return }
            withAnimation(.easeInOut(duration: 0.2)) { lmResults = result.models }
            lmOrigin = result.origin
            lmError = nil
        } catch {
            guard lmSequencer.accept(token) else { return }
            lmError = error.localizedDescription
        }
        lastLMQuery = query
        hasSearchedLM = true
    }

    /// Loads what the details pane needs for a row.
    func loadDetail(_ model: LibraryModel) async {
        switch model.source {
        case .mlx:
            await ai.loadSizes([model.key])
        case .ollama:
            await loadOllamaTags(model.key)
        case .lmStudio:
            await loadLMDetail(model.key)
        }
    }

    func loadOllamaTags(_ name: String) async {
        guard ollamaTags[name] == nil else { return }
        do {
            let tags = try await ollamaLibrary.tags(name)
            ollamaTags[name] = tags
            ollamaTagErrors[name] = nil
            if ollamaPickedTag[name] == nil { ollamaPickedTag[name] = tags.first { $0.tag == "latest" }?.tag ?? tags.first?.tag }
        } catch {
            ollamaTagErrors[name] = error.localizedDescription
        }
    }

    func loadLMDetail(_ identifier: String) async {
        guard lmDetails[identifier] == nil else { return }
        do {
            let detail = try await lmCatalog.detail(identifier)
            lmDetails[identifier] = detail
            lmDetailErrors[identifier] = nil
            await loadVariantSizes(detail.variants)
        } catch {
            lmDetailErrors[identifier] = error.localizedDescription
        }
    }

    /// Sizes of each download option from Hugging Face: MLX repos as a whole, GGUF repos per file.
    private func loadVariantSizes(_ variants: [LMStudioVariant]) async {
        let hub = self.hub
        let wanted = variants.compactMap(\.repo).filter { variantSizes[$0] == nil && ggufFiles[$0] == nil }
        let found = await withTaskGroup(of: (String, [HFFile]?).self) { group in
            for repo in wanted.prefix(6) { group.addTask { (repo, try? await hub.allFiles(repo)) } }
            var result: [(String, [HFFile]?)] = []
            for await item in group { result.append(item) }
            return result
        }
        for (repo, files) in found {
            guard let files else { continue }
            let gguf = files.filter { $0.path.lowercased().hasSuffix(".gguf") && !$0.path.lowercased().contains("mmproj") }
            if gguf.isEmpty {
                variantSizes[repo] = files.filter { HuggingFaceClient.isNeeded($0.path) }.reduce(0) { $0 + $1.size }
            } else {
                ggufFiles[repo] = gguf.sorted { $0.size < $1.size }
            }
        }
    }

    // MARK: Downloads

    /// The reason a source can't download now, or nil when it can.
    func blocker(_ source: ModelSource) -> LibraryBlocker? {
        switch source {
        case .mlx:
            return nil
        case .ollama:
            guard ai.ollamaLoaded else { return nil }
            if !ai.ollamaInstalled { return LibraryBlocker(reason: "Ollama is not installed.", tab: .ollama, buttonTitle: "Open Ollama Tab") }
            if !ai.ollamaRunning { return LibraryBlocker(reason: "Start Ollama to download.", tab: .ollama, buttonTitle: "Open Ollama Tab") }
            return nil
        case .lmStudio:
            guard ai.lmLoaded else { return nil }
            if ai.lmStatus?.isInstalled != true { return LibraryBlocker(reason: "LM Studio is not installed.", tab: .lmStudio, buttonTitle: "Open LM Studio Tab") }
            if ai.lmStatus?.cliPath == nil { return LibraryBlocker(reason: "Open LM Studio once so it sets up lms.", tab: .lmStudio, buttonTitle: "Open LM Studio Tab") }
            return nil
        }
    }

    /// Makes sure the runtime checks ran, so `blocker` knows.
    func checkRuntimes() async {
        if !ai.ollamaLoaded { await ai.loadOllama() }
        if !ai.lmLoaded { await ai.loadLMStudio() }
    }

    /// The name an Ollama row pulls: the picked tag, else the plain name.
    func ollamaPullName(_ name: String) -> String {
        guard let tag = ollamaPickedTag[name], tag != "latest" else { return name }
        return "\(name):\(tag)"
    }

    func isDownloading(_ model: LibraryModel) -> Bool {
        switch model.source {
        case .mlx: return ai.downloads[model.key] != nil
        case .ollama: return ai.isPulling && (ai.pullingName?.split(separator: ":").first.map(String.init) == model.key)
        case .lmStudio: return lmDownloads[model.key] != nil
        }
    }

    /// True when the model (any tag or variant) is on this Mac.
    func isOnThisMac(_ model: LibraryModel) -> Bool {
        switch model.source {
        case .mlx: return ai.isDownloaded(model.key)
        case .ollama:
            return ai.ollamaModels.contains { $0.id == model.key || $0.id.hasPrefix(model.key + ":") }
                || installed.contains { $0.source == .ollama && ($0.key == model.key || $0.key.hasPrefix(model.key + ":")) }
        case .lmStudio:
            let name = model.name.lowercased()
            return ai.lmModels.contains { $0.id.lowercased() == model.key.lowercased() || $0.id.lowercased() == name }
                || installed.contains { $0.source == .lmStudio && ($0.key.lowercased() == model.key.lowercased() || $0.key.lowercased() == name) }
        }
    }

    /// Starts the download in the right runtime.
    func download(_ model: LibraryModel) {
        guard blocker(model.source) == nil else { return }
        switch model.source {
        case .mlx:
            ai.download(model.key)
        case .ollama:
            pullOllama(ollamaPullName(model.key))
        case .lmStudio:
            downloadLM(model.key)
        }
    }

    func cancelDownload(_ model: LibraryModel) {
        switch model.source {
        case .mlx: ai.cancelDownload(model.key)
        case .ollama: ai.cancelPull()
        case .lmStudio: lmDownloadTasks[model.key]?.cancel()
        }
    }

    /// Pulls an exact Ollama name through the Ollama tab's pull, so both show the same progress.
    func pullOllama(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !ai.isPulling else { return }
        guard OllamaLibraryParser.isPullName(trimmed) else {
            ai.onError?(DeckError.commandFailed("\(trimmed) is not an Ollama model name. Use name or name:tag."))
            return
        }
        ai.pullName = trimmed
        ai.pullOllamaModel()
    }

    /// `lms get <model> --yes` with progress.
    func downloadLM(_ identifier: String) {
        guard lmDownloads[identifier] == nil else { return }
        lmDownloadErrors[identifier] = nil
        lmDownloads[identifier] = LMStudioDownloadProgress(message: "Starting")
        let runtime = LMStudioRuntime()
        lmDownloadTasks[identifier] = Task {
            var lastLines: [String] = []
            do {
                for try await line in try runtime.download(identifier) {
                    guard let progress = LMStudioDownloadProgress.parse(line) else { continue }
                    if let message = progress.message { lastLines = Array((lastLines + [message]).suffix(4)) }
                    var current = lmDownloads[identifier] ?? LMStudioDownloadProgress()
                    if progress.fraction != nil {
                        current.fraction = progress.fraction
                        current.completedBytes = progress.completedBytes ?? current.completedBytes
                        current.totalBytes = progress.totalBytes ?? current.totalBytes
                    }
                    if let message = progress.message { current.message = message }
                    if lmDownloads[identifier] != nil { lmDownloads[identifier] = current }
                }
                let cancelled = Task.isCancelled
                lmDownloads[identifier] = nil
                lmDownloadTasks[identifier] = nil
                await ai.loadLMStudio()
                await loadInstalled()
                if !cancelled { ai.onNotice?("Downloaded \(identifier)") }
            } catch {
                lmDownloads[identifier] = nil
                lmDownloadTasks[identifier] = nil
                lmDownloadErrors[identifier] = error.localizedDescription
                ai.onError?(error)
            }
        }
    }

    // MARK: On this Mac

    var installed: [InstalledModel] = []
    var installedLoaded = false
    var isLoadingInstalled = false
    @ObservationIgnored private var lastInstalledLoad: Date?
    @ObservationIgnored private var installedSequencer = PollSequencer()

    var totals: ModelDiskTotals { ModelInventory.totals(installed) }

    /// Unused models Free Up Space picks for you. Ollama models only while Ollama runs, since it deletes them.
    var cleanupSuggestions: Set<InstalledModel.ID> {
        let ollamaUp = ai.ollamaRunning
        return ModelInventory.suggested(installed.filter { $0.source != .ollama || ollamaUp })
    }

    /// Reloads only when the last load is older than `maxAge` seconds.
    func loadInstalledIfStale(maxAge: TimeInterval) async {
        if let lastInstalledLoad, Date().timeIntervalSince(lastInstalledLoad) < maxAge { return }
        await loadInstalled(refreshRuntimes: true, quiet: true)
    }

    /// Reads every runtime's models and merges them.
    /// - Parameters:
    ///   - refreshRuntimes: ask Ollama, LM Studio and the MLX folder again first.
    ///   - quiet: for the Dashboard. LM Studio's `lms ls` wakes its background service, so when that
    ///     service is not running, its models folder is read instead.
    func loadInstalled(refreshRuntimes: Bool = true, quiet: Bool = false) async {
        let token = installedSequencer.begin()
        isLoadingInstalled = true
        defer { isLoadingInstalled = false }
        var lmModels = ai.lmModels
        var lmFolderOnly = false
        if refreshRuntimes {
            async let ollama: Void = ai.loadOllama()
            async let local: Void = ai.loadLocalModels()
            _ = await (ollama, local)
            if quiet && !ai.lmLoaded {
                let runtime = LMStudioRuntime()
                if runtime.findCLI() != nil, await runtime.daemonStatus() == .running {
                    await ai.loadLMStudio()
                    lmModels = ai.lmModels
                } else if runtime.findCLI() != nil || runtime.findApp() != nil {
                    lmFolderOnly = true
                }
            } else {
                await ai.loadLMStudio()
                lmModels = ai.lmModels
            }
        }
        let ollamaRunning = ai.ollamaRunning
        let ollamaModels = ai.ollamaModels
        let mlx = ai.localModels
        let serving = ai.serverState.isActive ? ai.serverConfig?.model : nil
        let log = usageLog
        let lmFolder = LMStudioRuntime().modelsDirectory()
        let lmBundled = LMStudioRuntime().bundledModelsDirectory()
        let ollamaFolder = AIConfig.ollamaModelsDirectory
        let installedOllama = ai.ollamaInstalled
        let list: [InstalledModel] = await Task.detached {
            let ollama = ollamaRunning ? ollamaModels : (installedOllama ? OllamaManifestReader(root: ollamaFolder).list() : [])
            let lms = lmFolderOnly ? Self.scanLMStudioFolder(lmFolder) : lmModels
            let merged = ModelInventory.merge(ollama: ollama, ollamaFolder: ollamaFolder, lmStudio: lms, lmStudioFolder: lmFolder, lmStudioBundledFolder: lmBundled,
                                              mlx: mlx, servingMLXPath: serving, usage: log.load())
            // Models in memory now count as used now.
            log.record(ModelInventory.loadedNow(merged))
            return ModelInventory.merge(ollama: ollama, ollamaFolder: ollamaFolder, lmStudio: lms, lmStudioFolder: lmFolder, lmStudioBundledFolder: lmBundled,
                                        mlx: mlx, servingMLXPath: serving, usage: log.load())
        }.value
        guard installedSequencer.accept(token) else { return }
        if list != installed { withAnimation(.easeInOut(duration: 0.25)) { installed = list } }
        installedLoaded = true
        lastInstalledLoad = Date()
    }

    /// LM Studio models from its folder, one per publisher/repo folder, when `lms` should not be woken.
    nonisolated static func scanLMStudioFolder(_ folder: URL) -> [LMStudioModel] {
        let fm = FileManager.default
        var models: [LMStudioModel] = []
        for publisher in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where !publisher.hasPrefix(".") {
            let publisherURL = folder.appendingPathComponent(publisher, isDirectory: true)
            for repo in (try? fm.contentsOfDirectory(atPath: publisherURL.path)) ?? [] where !repo.hasPrefix(".") {
                let url = publisherURL.appendingPathComponent(repo, isDirectory: true)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
                models.append(LMStudioModel(id: "\(publisher)/\(repo)", displayName: repo, sizeBytes: LocalModelStore.folderSize(url),
                                            path: "\(publisher)/\(repo)"))
            }
        }
        return models
    }

    /// Records that the app used a model now (chat, load, server start).
    func recordUse(_ source: ModelSource, key: String) {
        guard !key.isEmpty else { return }
        let log = usageLog
        Task.detached { log.record(source, key: key) }
        if let index = installed.firstIndex(where: { $0.source == source && $0.key == key }) { installed[index].lastUsed = Date() }
    }

    /// Records a chat or load on a server: maps the server's model id to the library key.
    func recordUse(kind: ModelServerKind, model: String) {
        guard let source = ModelSource(kind: kind) else { return }
        if source == .mlx {
            let match = ai.localModels.first { $0.modelPath == model || $0.repo == model || model.hasSuffix("/" + $0.repo) }
            recordUse(.mlx, key: match?.repo ?? model)
        } else {
            recordUse(source, key: model)
        }
    }

    // MARK: Delete

    /// What the delete sheet shows.
    struct PendingDelete: Identifiable, Equatable {
        var model: InstalledModel
        /// nil while the model is loaded (the sheet asks to unload first).
        var plan: ModelRemovalPlan?
        var id: String { model.id }
    }

    var pendingDelete: PendingDelete?
    var deleting: Set<InstalledModel.ID> = []

    func remover() -> ModelRemover { ModelRemover() }

    /// Opens the delete sheet. Loaded models get the unload question first.
    func askToDelete(_ model: InstalledModel) {
        if model.isLoaded {
            pendingDelete = PendingDelete(model: model, plan: nil)
            return
        }
        do {
            pendingDelete = PendingDelete(model: model, plan: try remover().plan(model, among: installed))
        } catch {
            ai.onError?(error)
        }
    }

    /// Unloads (or stops the MLX server), then shows the delete plan.
    func unloadForDelete(_ model: InstalledModel) async {
        do {
            switch model.source {
            case .ollama: try await OllamaClient().unload(model.key)
            case .lmStudio: try await LMStudioRuntime().unload(model.key)
            case .mlx: await ai.stopServer()
            }
        } catch {
            ai.onError?(error)
            return
        }
        await loadInstalled()
        guard let fresh = installed.first(where: { $0.id == model.id }) else { pendingDelete = nil; return }
        if fresh.isLoaded {
            ai.onError?(DeckError.commandFailed("\(fresh.name) is still loaded. Try again in a moment."))
            return
        }
        do {
            pendingDelete = PendingDelete(model: fresh, plan: try remover().plan(fresh, among: installed))
        } catch {
            pendingDelete = nil
            ai.onError?(error)
        }
    }

    /// Runs a confirmed delete. Returns the bytes freed, nil on failure.
    @discardableResult
    func delete(_ plan: ModelRemovalPlan, notify: Bool = true) async -> UInt64? {
        deleting.insert(plan.model.id)
        defer { deleting.remove(plan.model.id) }
        let remover = remover()
        do {
            let freed = try await remover.remove(plan)
            usageLog.forget(plan.model.source, key: plan.model.key)
            if notify {
                await afterDelete()
                ai.onNotice?("Deleted \(plan.model.name). Freed \(Format.bytes(freed)).")
            }
            return freed
        } catch {
            ai.onError?(error)
            return nil
        }
    }

    /// Reloads every list a delete touches.
    func afterDelete() async {
        await loadInstalled()
        await ai.discover()
    }

    /// Plans for many models at once (Free Up Space). Models that can't be planned are skipped.
    func plans(for ids: Set<InstalledModel.ID>) -> [ModelRemovalPlan] {
        let remover = remover()
        return installed.filter { ids.contains($0.id) }.compactMap { try? remover.plan($0, among: installed) }
    }

    // MARK: Actions

    /// Load or Use: Ollama and LM Studio load into memory, MLX opens the server form with it.
    func use(_ model: InstalledModel) async {
        switch model.source {
        case .ollama:
            if let entry = ai.ollamaModels.first(where: { $0.id == model.key }) {
                if !model.isLoaded { await ai.toggleOllamaModel(entry) }
            }
            openChat(model)
        case .lmStudio:
            if let entry = ai.lmModels.first(where: { $0.id == model.key }), !entry.isLoaded {
                await ai.toggleLMStudioModel(entry)
            }
            openChat(model)
        case .mlx:
            if let local = model.local, !ai.serverState.isActive { ai.serverModelPath = local.modelPath }
            if model.isLoaded {
                openChat(model)
            } else {
                ai.tab = .mlx
            }
        }
        await loadInstalled(refreshRuntimes: false)
    }

    /// Opens the chat tab on the model's server when it runs.
    func openChat(_ model: InstalledModel) {
        let kind: [ModelServerKind]
        switch model.source {
        case .ollama: kind = [.ollama]
        case .lmStudio: kind = [.lmStudio]
        case .mlx: kind = [.mlxLM, .oMLX]
        }
        guard let endpoint = ai.runningEndpoints.first(where: { kind.contains($0.kind) && (model.source != .mlx || $0.isManaged) })
            ?? ai.runningEndpoints.first(where: { kind.contains($0.kind) }) else {
            ai.tab = model.source == .ollama ? .ollama : (model.source == .lmStudio ? .lmStudio : .mlx)
            return
        }
        // The MLX server serves one model: chat with the one it has loaded.
        let id = model.source == .mlx ? endpoint.models.first(where: \.isLoaded)?.id : model.key
        ai.openChat(endpoint, model: id)
    }

    /// Can the model be loaded or used now?
    func canUse(_ model: InstalledModel) -> Bool {
        switch model.source {
        case .ollama: return ai.ollamaRunning
        case .lmStudio: return ai.lmStatus?.cliPath != nil && !model.isBuiltIn || model.isLoaded
        case .mlx: return model.isComplete
        }
    }

    func useTitle(_ model: InstalledModel) -> String {
        switch model.source {
        case .mlx: return model.isLoaded ? "Chat" : "Serve with MLX"
        default: return model.isLoaded ? "Chat" : "Load"
        }
    }
}
