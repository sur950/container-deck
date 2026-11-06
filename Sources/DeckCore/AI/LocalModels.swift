import Foundation

/// A model on disk that the MLX server can run.
public struct LocalModel: Identifiable, Sendable, Hashable {
    public enum Source: String, Sendable, Hashable {
        /// Downloaded by Container Deck into Application Support.
        case library
        /// Found in the shared Hugging Face cache (~/.cache/huggingface/hub).
        case huggingFaceCache
    }

    /// Folder path. Unique.
    public var id: String { folder.path }
    /// "mlx-community/SmolLM-135M-Instruct-4bit".
    public var repo: String
    /// Folder to delete.
    public var folder: URL
    /// Path to pass as `--model` (the snapshot folder for the Hugging Face cache).
    public var modelPath: String
    public var sizeBytes: UInt64
    /// False while a download is unfinished.
    public var isComplete: Bool
    public var modified: Date?
    public var source: Source

    public init(repo: String, folder: URL, modelPath: String, sizeBytes: UInt64, isComplete: Bool, modified: Date?, source: Source) {
        self.repo = repo
        self.folder = folder
        self.modelPath = modelPath
        self.sizeBytes = sizeBytes
        self.isComplete = isComplete
        self.modified = modified
        self.source = source
    }

    public var name: String { repo.split(separator: "/").last.map(String.init) ?? repo }
}

/// Saved next to a library download so it can be resumed and checked.
struct ModelManifest: Codable, Equatable {
    var repo: String
    var files: [HFFile]
    var complete: Bool

    static let fileName = ".deck-model.json"

    static func load(_ folder: URL) -> ModelManifest? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode(ModelManifest.self, from: data)
    }

    func save(_ folder: URL) throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }
}

/// Lists and deletes local models: the library folder plus the shared Hugging Face cache.
public struct LocalModelStore: Sendable {
    public let paths: AIPaths
    public let huggingFaceCache: URL

    public init(paths: AIPaths = AIPaths(), huggingFaceCache: URL = URL(fileURLWithPath: AIConfig.expand(AIConfig.huggingFaceCache), isDirectory: true)) {
        self.paths = paths
        self.huggingFaceCache = huggingFaceCache
    }

    /// Every local model, library first, then by name. Reads folder sizes, so call it off the main thread.
    public func list() -> [LocalModel] {
        libraryModels().sorted { $0.repo.lowercased() < $1.repo.lowercased() }
            + cacheModels().sorted { $0.repo.lowercased() < $1.repo.lowercased() }
    }

    func libraryModels() -> [LocalModel] {
        let fm = FileManager.default
        var models: [LocalModel] = []
        for org in (try? fm.contentsOfDirectory(atPath: paths.models.path)) ?? [] where !org.hasPrefix(".") {
            let orgURL = paths.models.appendingPathComponent(org, isDirectory: true)
            for name in (try? fm.contentsOfDirectory(atPath: orgURL.path)) ?? [] where !name.hasPrefix(".") {
                let folder = orgURL.appendingPathComponent(name, isDirectory: true)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { continue }
                let manifest = ModelManifest.load(folder)
                let complete = manifest?.complete ?? fm.fileExists(atPath: folder.appendingPathComponent("config.json").path)
                models.append(LocalModel(
                    repo: manifest?.repo ?? "\(org)/\(name)",
                    folder: folder,
                    modelPath: folder.path,
                    sizeBytes: Self.folderSize(folder),
                    isComplete: complete,
                    modified: Self.modified(folder),
                    source: .library
                ))
            }
        }
        return models
    }

    /// MLX models in the Hugging Face cache: `models--<org>--<name>` folders with "mlx" in the name.
    func cacheModels() -> [LocalModel] {
        let fm = FileManager.default
        var models: [LocalModel] = []
        for entry in (try? fm.contentsOfDirectory(atPath: huggingFaceCache.path)) ?? [] {
            guard let repo = Self.repo(fromCacheFolder: entry), repo.lowercased().contains("mlx") else { continue }
            let folder = huggingFaceCache.appendingPathComponent(entry, isDirectory: true)
            guard let snapshot = Self.snapshot(folder) else { continue }
            models.append(LocalModel(
                repo: repo,
                folder: folder,
                modelPath: snapshot.path,
                sizeBytes: Self.folderSize(folder),
                isComplete: fm.fileExists(atPath: snapshot.appendingPathComponent("config.json").path),
                modified: Self.modified(folder),
                source: .huggingFaceCache
            ))
        }
        return models
    }

    /// "models--mlx-community--SmolLM-135M" gives "mlx-community/SmolLM-135M".
    public static func repo(fromCacheFolder name: String) -> String? {
        guard name.hasPrefix("models--") else { return nil }
        let parts = name.dropFirst("models--".count).components(separatedBy: "--")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return parts.joined(separator: "/")
    }

    /// The snapshot `refs/main` points at, else the newest one.
    static func snapshot(_ folder: URL) -> URL? {
        let snapshots = folder.appendingPathComponent("snapshots", isDirectory: true)
        if let ref = try? String(contentsOf: folder.appendingPathComponent("refs/main"), encoding: .utf8) {
            let url = snapshots.appendingPathComponent(ref.trimmingCharacters(in: .whitespacesAndNewlines), isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: snapshots.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }
            .map { snapshots.appendingPathComponent($0, isDirectory: true) }
            .max { (modified($0) ?? .distantPast) < (modified($1) ?? .distantPast) }
    }

    /// Deletes a model folder. Only folders inside the library or the Hugging Face cache.
    public func delete(_ model: LocalModel) throws {
        let path = model.folder.standardizedFileURL.path
        let allowed = [paths.models.standardizedFileURL.path, huggingFaceCache.standardizedFileURL.path]
        guard allowed.contains(where: { path.hasPrefix($0 + "/") }) else {
            throw DeckError.commandFailed("That folder is not a model folder.")
        }
        try FileManager.default.removeItem(at: model.folder)
        // Remove an empty organisation folder left behind in the library.
        let parent = model.folder.deletingLastPathComponent()
        if model.source == .library, parent.standardizedFileURL.path != paths.models.standardizedFileURL.path,
           ((try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? ["x"]).isEmpty {
            try? FileManager.default.removeItem(at: parent)
        }
    }

    /// Total bytes of all local models.
    public static func totalSize(_ models: [LocalModel]) -> UInt64 {
        models.reduce(0) { $0 + $1.sizeBytes }
    }

    /// Allocated bytes of the files in a folder. Symlinks are not followed, so the
    /// Hugging Face cache (snapshots link to blobs) is counted once.
    public static func folderSize(_ url: URL) -> UInt64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: []) else { return 0 }
        var total: UInt64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
            total += UInt64(max(size, 0))
        }
        return total
    }

    static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Free bytes on the volume that holds `url` (or its nearest existing parent).
    public static func freeSpace(at url: URL) -> UInt64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" {
            probe = probe.deletingLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage.map { UInt64(max($0, 0)) }
    }
}
