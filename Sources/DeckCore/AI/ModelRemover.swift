import Foundation

/// How a model is removed, in the runtime's own way.
public enum ModelRemovalAction: Sendable, Hashable {
    /// `DELETE /api/delete` while Ollama runs, else `ollama rm <name>`.
    case ollama(String)
    /// A folder inside LM Studio's models folder. lms has no remove command (checked with lms 0.4, CLI commit 43d4b26).
    case lmStudioFolder(URL)
    /// One file, when its folder holds other models too.
    case lmStudioFile(URL)
    /// A folder in the app's MLX library or the Hugging Face cache.
    case mlx(LocalModel)
}

/// What a delete does, shown in the confirmation before anything is removed.
public struct ModelRemovalPlan: Sendable, Hashable, Identifiable {
    public var model: InstalledModel
    public var action: ModelRemovalAction
    public var bytes: UInt64

    public var id: String { model.id }

    /// What the confirmation names: the command, or the folder.
    public var target: String {
        switch action {
        case .ollama(let name): return "ollama rm \(name)"
        case .lmStudioFolder(let url), .lmStudioFile(let url): return url.path
        case .mlx(let local): return local.folder.path
        }
    }

    /// True when files are deleted directly (the confirmation names the folder).
    public var deletesFiles: Bool {
        if case .ollama = action { return false }
        return true
    }
}

public enum ModelRemovalError: Error, LocalizedError, Equatable {
    case loaded(String)
    case builtIn(String)
    case unsafePath(String)
    case ollamaNotRunning

    public var errorDescription: String? {
        switch self {
        case .loaded(let name): return "\(name) is loaded. Unload it first."
        case .builtIn(let name): return "\(name) comes with LM Studio and can't be deleted here."
        case .unsafePath(let path): return "\(path) is not inside LM Studio's models folder."
        case .ollamaNotRunning: return "Start Ollama to delete its models."
        }
    }
}

/// Deletes downloaded models for every runtime. The Model Library and Free Up Space both use it.
public struct ModelRemover: Sendable {
    let runner: CommandRunning
    let ollama: OllamaClient
    /// `ollama` command for `ollama rm`, used when the API does not answer.
    let ollamaCLI: String?
    let lmStudioFolder: URL
    let mlxStore: LocalModelStore

    public init(runner: CommandRunning = ProcessRunner(), ollama: OllamaClient = OllamaClient(), ollamaCLI: String? = ModelRemover.defaultOllamaCLI(),
                lmStudioFolder: URL = LMStudioRuntime().modelsDirectory(), mlxStore: LocalModelStore = LocalModelStore()) {
        self.runner = runner
        self.ollama = ollama
        self.ollamaCLI = ollamaCLI
        self.lmStudioFolder = lmStudioFolder
        self.mlxStore = mlxStore
    }

    /// The `ollama` command: the stand in tools folder in debug runs, else the usual places.
    public static func defaultOllamaCLI() -> String? {
        if let tools = AIConfig.ollamaToolsDirectory {
            let path = tools + "/ollama"
            return FileManager.default.isExecutableFile(atPath: path) ? path : nil
        }
        return OllamaControl().binary
    }

    public static func ollamaRemoveArguments(_ name: String) -> [String] { ["rm", name] }

    /// Works out what a delete does. Throws for loaded and built in models, and for paths outside LM Studio's folder.
    /// `among` is every model on this Mac, to see whether an LM Studio folder holds more than one model.
    public func plan(_ model: InstalledModel, among: [InstalledModel] = []) throws -> ModelRemovalPlan {
        if model.isLoaded { throw ModelRemovalError.loaded(model.name) }
        switch model.source {
        case .ollama:
            guard OllamaLibraryParser.isPullName(model.key) else { throw DeckError.commandFailed("\(model.key) is not an Ollama model name.") }
            return ModelRemovalPlan(model: model, action: .ollama(model.key), bytes: model.sizeBytes)
        case .lmStudio:
            guard !model.isBuiltIn, let path = model.lmStudioPath else { throw ModelRemovalError.builtIn(model.name) }
            if model.filesMissing { throw DeckError.commandFailed("The files of \(model.name) are already gone. LM Studio drops it from its list soon.") }
            let parts = path.split(separator: "/").map(String.init)
            guard Self.isSafeRelativePath(path), parts.count >= 2 else { throw ModelRemovalError.unsafePath(path) }
            let folder = lmStudioFolder.appendingPathComponent(parts[0], isDirectory: true).appendingPathComponent(parts[1], isDirectory: true)
            // Another model in the same publisher/repo folder: remove only this model's file.
            let shared = among.contains { other in
                other.source == .lmStudio && other.id != model.id && !other.isBuiltIn
                    && (other.lmStudioPath?.split(separator: "/").prefix(2).map(String.init) ?? []) == Array(parts.prefix(2))
            }
            if shared && parts.count > 2 {
                let file = lmStudioFolder.appendingPathComponent(path)
                return ModelRemovalPlan(model: model, action: .lmStudioFile(file), bytes: model.sizeBytes)
            }
            return ModelRemovalPlan(model: model, action: .lmStudioFolder(folder), bytes: model.sizeBytes)
        case .mlx:
            guard let local = model.local else { throw DeckError.commandFailed("\(model.name) has no folder to delete.") }
            return ModelRemovalPlan(model: model, action: .mlx(local), bytes: model.sizeBytes)
        }
    }

    /// Removes the model. Returns the bytes freed.
    @discardableResult
    public func remove(_ plan: ModelRemovalPlan) async throws -> UInt64 {
        if plan.model.isLoaded { throw ModelRemovalError.loaded(plan.model.name) }
        switch plan.action {
        case .ollama(let name):
            if await ollama.isRunning() {
                try await ollama.delete(name)
            } else if let cli = ollamaCLI {
                let result = try await runner.run(cli, Self.ollamaRemoveArguments(name))
                guard result.succeeded else {
                    let detail = [result.stderr, result.stdout].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
                    if let detail, detail.lowercased().contains("connect") { throw ModelRemovalError.ollamaNotRunning }
                    throw DeckError.commandFailed(detail.map { "ollama rm: \($0)" } ?? "ollama rm \(name) failed.")
                }
            } else {
                throw ModelRemovalError.ollamaNotRunning
            }
            return plan.bytes
        case .lmStudioFolder(let url), .lmStudioFile(let url):
            try checkInsideLMStudio(url)
            let fm = FileManager.default
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
            let bytes = isDir.boolValue ? LocalModelStore.folderSize(url) : ((try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? plan.bytes)
            try fm.removeItem(at: url)
            // Remove an empty publisher folder left behind.
            var parent = url.deletingLastPathComponent()
            while parent.standardizedFileURL.path != lmStudioFolder.standardizedFileURL.path,
                  parent.standardizedFileURL.path.hasPrefix(lmStudioFolder.standardizedFileURL.path + "/"),
                  ((try? fm.contentsOfDirectory(atPath: parent.path)) ?? ["x"]).filter({ $0 != ".DS_Store" }).isEmpty {
                try? fm.removeItem(at: parent)
                parent = parent.deletingLastPathComponent()
            }
            return bytes
        case .mlx(let local):
            let bytes = LocalModelStore.folderSize(local.folder)
            try mlxStore.delete(local)
            return bytes > 0 ? bytes : plan.bytes
        }
    }

    /// The path must sit at least two levels inside LM Studio's models folder.
    func checkInsideLMStudio(_ url: URL) throws {
        let root = lmStudioFolder.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(root + "/") else { throw ModelRemovalError.unsafePath(url.path) }
        let depth = path.dropFirst(root.count + 1).split(separator: "/").count
        guard depth >= 2 else { throw ModelRemovalError.unsafePath(url.path) }
    }

    /// A relative path with no "..", no leading slash and no empty parts.
    public static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
