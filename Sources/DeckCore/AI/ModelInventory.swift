import Foundation

/// One downloaded model on this Mac, from any runtime.
public struct InstalledModel: Identifiable, Hashable, Sendable {
    public var source: ModelSource
    /// Ollama name ("qwen3:0.6b"), LM Studio model key, MLX repo.
    public var key: String
    public var name: String
    public var sizeBytes: UInt64
    /// When it was downloaded (or last changed on disk).
    public var downloaded: Date?
    /// Last time the app chatted with it, loaded it or served it, or saw it loaded.
    public var lastUsed: Date?
    /// In memory now, or being served.
    public var isLoaded: Bool
    /// Folder or file to reveal in Finder.
    public var location: URL?
    /// "7.2B, Q4_K_M".
    public var detail: String?
    /// False while an MLX download is unfinished.
    public var isComplete: Bool
    /// LM Studio keeps it in its own app files (a bundled model). It can't be deleted here.
    public var isBuiltIn: Bool
    /// LM Studio lists it, but its files are gone from the models folder.
    public var filesMissing: Bool = false
    /// LM Studio: path inside its models folder.
    public var lmStudioPath: String?
    /// MLX: the folder record, for serving and deleting.
    public var local: LocalModel?

    public init(source: ModelSource, key: String, name: String? = nil, sizeBytes: UInt64, downloaded: Date? = nil, lastUsed: Date? = nil,
                isLoaded: Bool = false, location: URL? = nil, detail: String? = nil, isComplete: Bool = true, isBuiltIn: Bool = false,
                lmStudioPath: String? = nil, local: LocalModel? = nil) {
        self.source = source
        self.key = key
        self.name = name ?? key
        self.sizeBytes = sizeBytes
        self.downloaded = downloaded
        self.lastUsed = lastUsed
        self.isLoaded = isLoaded
        self.location = location
        self.detail = detail
        self.isComplete = isComplete
        self.isBuiltIn = isBuiltIn
        self.lmStudioPath = lmStudioPath
        self.local = local
    }

    /// Unique: MLX models can sit both in the app's folder and in the Hugging Face cache.
    public var id: String {
        if source == .mlx, let local { return "mlx:" + local.folder.path }
        return "\(source.rawValue):\(key)"
    }

    /// Key in the usage log.
    public var usageKey: String { ModelUsageLog.key(source, key) }

    /// "Container Deck", "Hugging Face cache", "Ollama", "LM Studio".
    public var whereText: String {
        switch source {
        case .ollama: return "Ollama"
        case .lmStudio: return isBuiltIn ? "LM Studio, built in" : (filesMissing ? "LM Studio, files missing" : "LM Studio")
        case .mlx: return local?.source == .huggingFaceCache ? "Hugging Face cache" : AppConfig.appName
        }
    }

    /// The folder the model lives in: Ollama's models folder, the LM Studio model folder, the MLX folder.
    public var folder: URL? {
        guard let location else { return nil }
        switch source {
        case .ollama:
            // .../models/manifests/registry.ollama.ai/library/qwen3/latest lives in .../models.
            if let range = location.path.range(of: "/manifests/") {
                return URL(fileURLWithPath: String(location.path[..<range.lowerBound]), isDirectory: true)
            }
            return location
        case .lmStudio:
            // A GGUF file sits in its repo folder. MLX models are folders already.
            return location.pathExtension.lowercased() == "gguf" ? location.deletingLastPathComponent() : location
        case .mlx:
            return location
        }
    }

    /// The folder with ~ for the home folder: "~/.ollama/models".
    public var folderText: String? {
        folder.map { ($0.standardizedFileURL.path as NSString).abbreviatingWithTildeInPath }
    }

    /// The newest of last used and downloaded: how long the model has sat idle.
    public var lastActivity: Date? {
        [lastUsed, downloaded].compactMap { $0 }.max()
    }

    /// The app can delete it.
    public var isDeletable: Bool { !isBuiltIn && !filesMissing }
}

/// When each model was last used in the app: chats, loads, server starts, and models seen loaded.
/// A small JSON file in the AI folder ("ollama:qwen3:0.6b" to a date).
public struct ModelUsageLog: Sendable {
    public let url: URL
    private static let lock = NSLock()

    public init(url: URL = AIPaths().modelUsage) {
        self.url = url
    }

    public static func key(_ source: ModelSource, _ key: String) -> String { "\(source.rawValue):\(key)" }

    public func load() -> [String: Date] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return read()
    }

    /// Records use now (or at `date`). Older dates never replace newer ones.
    public func record(_ source: ModelSource, key: String, at date: Date = Date()) {
        record([(source, key)], at: date)
    }

    public func record(_ models: [(ModelSource, String)], at date: Date = Date()) {
        guard !models.isEmpty else { return }
        Self.lock.lock(); defer { Self.lock.unlock() }
        var log = read()
        var changed = false
        for (source, key) in models where !key.isEmpty {
            let id = Self.key(source, key)
            // Writes at most once a minute per model, so polling never rewrites the file.
            if let old = log[id], old >= date.addingTimeInterval(-60) { continue }
            log[id] = date
            changed = true
        }
        guard changed else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(log) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Forgets a deleted model.
    public func forget(_ source: ModelSource, key: String) {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var log = read()
        guard log.removeValue(forKey: Self.key(source, key)) != nil else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        if let data = try? encoder.encode(log) { try? data.write(to: url, options: .atomic) }
    }

    private func read() -> [String: Date] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: Date].self, from: data)) ?? [:]
    }
}

/// Bytes per source, for the Dashboard.
public struct ModelDiskTotals: Sendable, Equatable {
    public var bySource: [ModelSource: UInt64]
    public var count: Int

    public init(bySource: [ModelSource: UInt64] = [:], count: Int = 0) {
        self.bySource = bySource
        self.count = count
    }

    public var total: UInt64 { bySource.values.reduce(0, +) }

    /// "Ollama 5.5 GB, LM Studio 2.5 GB", largest first. Sources with nothing are left out.
    public func breakdown(_ format: (UInt64) -> String) -> String {
        ModelSource.allCases
            .compactMap { source in bySource[source].flatMap { $0 > 0 ? (source, $0) : nil } }
            .sorted { $0.1 > $1.1 }
            .map { "\($0.0.displayName) \(format($0.1))" }
            .joined(separator: ", ")
    }
}

/// Builds the one list of models on this Mac and decides which ones look unused.
public enum ModelInventory {
    /// Days without use before a model is suggested for removal.
    public static let unusedDays = 30

    /// Ollama, LM Studio and MLX models in one list, largest first.
    /// - Parameters:
    ///   - lmStudioFolder: LM Studio's models folder. Models whose files are not in it are built in.
    ///   - fileDate: modification date of a file, nil when it does not exist.
    public static func merge(ollama: [ModelEndpointModel], ollamaFolder: URL? = nil,
                             lmStudio: [LMStudioModel], lmStudioFolder: URL?, lmStudioBundledFolder: URL? = nil,
                             mlx: [LocalModel], servingMLXPath: String?,
                             usage: [String: Date],
                             fileDate: (URL) -> Date? = ModelInventory.fileDate) -> [InstalledModel] {
        var models: [InstalledModel] = []
        for model in ollama {
            let detail = [model.parameterSize, model.quantization].compactMap { $0 }.joined(separator: ", ")
            models.append(InstalledModel(
                source: .ollama, key: model.id, sizeBytes: model.sizeBytes ?? 0, downloaded: model.modifiedAt,
                lastUsed: usage[ModelUsageLog.key(.ollama, model.id)], isLoaded: model.isLoaded,
                location: ollamaFolder.map { ollamaManifest(model.id, in: $0) },
                detail: detail.isEmpty ? nil : detail
            ))
        }
        for model in lmStudio {
            var location: URL?
            var downloaded: Date?
            var builtIn = true
            var missing = false
            if let folder = lmStudioFolder, let path = model.path, ModelRemover.isSafeRelativePath(path) {
                let url = folder.appendingPathComponent(path)
                if let date = fileDate(url) {
                    location = url
                    downloaded = date
                    builtIn = false
                } else if let bundled = lmStudioBundledFolder {
                    // Not in the models folder: built in when LM Studio bundles it, else its files are gone.
                    let bundledURL = bundled.appendingPathComponent(path)
                    if fileDate(bundledURL) != nil {
                        location = bundledURL
                    } else {
                        builtIn = false
                        missing = true
                    }
                }
            }
            let detail = [model.parameters, model.quantization, model.format?.uppercased()].compactMap { $0 }.joined(separator: ", ")
            models.append(InstalledModel(
                source: .lmStudio, key: model.id, name: model.displayName, sizeBytes: model.sizeBytes ?? 0, downloaded: downloaded,
                lastUsed: usage[ModelUsageLog.key(.lmStudio, model.id)], isLoaded: model.isLoaded, location: location,
                detail: detail.isEmpty ? nil : detail, isBuiltIn: builtIn, lmStudioPath: model.path
            ))
            models[models.count - 1].filesMissing = missing
        }
        for model in mlx {
            models.append(InstalledModel(
                source: .mlx, key: model.repo, name: model.name, sizeBytes: model.sizeBytes, downloaded: model.modified,
                lastUsed: usage[ModelUsageLog.key(.mlx, model.repo)], isLoaded: servingMLXPath != nil && servingMLXPath == model.modelPath,
                location: model.folder, detail: HFModel(id: model.repo).quantization, isComplete: model.isComplete, local: model
            ))
        }
        return models.sorted { a, b in
            if a.sizeBytes != b.sizeBytes { return a.sizeBytes > b.sizeBytes }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Unused: not loaded, can be deleted, and nothing happened for `days` days: no chat, load or
    /// server start in the app, and no download in that time either. A model the app never used
    /// counts from the day it was downloaded. One with no dates at all counts as unused.
    public static func isUnused(_ model: InstalledModel, now: Date = Date(), days: Int = unusedDays) -> Bool {
        guard !model.isLoaded, model.isDeletable else { return false }
        guard let last = model.lastActivity else { return true }
        return now.timeIntervalSince(last) >= Double(days) * 86_400
    }

    /// IDs picked for you in Free Up Space.
    public static func suggested(_ models: [InstalledModel], now: Date = Date(), days: Int = unusedDays) -> Set<InstalledModel.ID> {
        Set(models.filter { isUnused($0, now: now, days: days) }.map(\.id))
    }

    public static func totals(_ models: [InstalledModel]) -> ModelDiskTotals {
        var bySource: [ModelSource: UInt64] = [:]
        for model in models { bySource[model.source, default: 0] += model.sizeBytes }
        return ModelDiskTotals(bySource: bySource, count: models.count)
    }

    /// Bytes of the picked models.
    public static func size(of ids: Set<InstalledModel.ID>, in models: [InstalledModel]) -> UInt64 {
        models.filter { ids.contains($0.id) }.reduce(0) { $0 + $1.sizeBytes }
    }

    /// Models seen loaded right now, to record as used.
    public static func loadedNow(_ models: [InstalledModel]) -> [(ModelSource, String)] {
        models.filter(\.isLoaded).map { ($0.source, $0.key) }
    }

    /// Ollama's manifest file for "qwen3:0.6b" (or the models folder when the name is unusual).
    public static func ollamaManifest(_ name: String, in folder: URL) -> URL {
        let parts = name.split(separator: ":", maxSplits: 1).map(String.init)
        let model = parts.first ?? name
        let tag = parts.count > 1 ? parts[1] : "latest"
        let path = model.contains("/") ? model : "library/\(model)"
        guard OllamaLibraryParser.isPullName(name) else { return folder }
        return folder.appendingPathComponent("manifests/registry.ollama.ai/\(path)/\(tag)")
    }

    public static func fileDate(_ url: URL) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return attributes[.modificationDate] as? Date
    }
}

/// Reads Ollama's models folder when its server is not running, so sizes still show.
public struct OllamaManifestReader: Sendable {
    public let root: URL

    public init(root: URL = AIConfig.ollamaModelsDirectory) {
        self.root = root
    }

    /// Models from `manifests/registry.ollama.ai/<namespace>/<model>/<tag>`, with the size of their layers.
    public func list() -> [ModelEndpointModel] {
        let fm = FileManager.default
        let registry = root.appendingPathComponent("manifests/registry.ollama.ai", isDirectory: true)
        var models: [ModelEndpointModel] = []
        for namespace in (try? fm.contentsOfDirectory(atPath: registry.path)) ?? [] where !namespace.hasPrefix(".") {
            let nsURL = registry.appendingPathComponent(namespace, isDirectory: true)
            for model in (try? fm.contentsOfDirectory(atPath: nsURL.path)) ?? [] where !model.hasPrefix(".") {
                let modelURL = nsURL.appendingPathComponent(model, isDirectory: true)
                for tag in (try? fm.contentsOfDirectory(atPath: modelURL.path)) ?? [] where !tag.hasPrefix(".") {
                    let file = modelURL.appendingPathComponent(tag)
                    guard let data = try? Data(contentsOf: file), let size = OllamaLibraryParser.manifestSize(data) else { continue }
                    let name = (namespace == "library" ? model : "\(namespace)/\(model)") + ":" + tag
                    models.append(ModelEndpointModel(id: name, sizeBytes: size, modifiedAt: ModelInventory.fileDate(file)))
                }
            }
        }
        return models.sorted { $0.id < $1.id }
    }
}
