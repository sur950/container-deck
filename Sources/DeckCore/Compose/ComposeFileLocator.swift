import Foundation

/// Finds the compose file for a folder, the same way `docker compose` does.
public struct ComposeFileLocator: Sendable {
    /// Checked in this order in each folder.
    public static let fileNames = ["compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml"]
    public static let overrideNames = ["compose.override.yaml", "compose.override.yml", "docker-compose.override.yml", "docker-compose.override.yaml"]

    public var fileExists: @Sendable (String) -> Bool

    public init(fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        self.fileExists = fileExists
    }

    /// Compose files to use, main file first. `COMPOSE_FILE` wins when set.
    /// Otherwise walks up from `directory` to the root and stops at the first folder
    /// with a compose file.
    public func locate(from directory: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        if let list = environment["COMPOSE_FILE"], !list.trimmingCharacters(in: .whitespaces).isEmpty {
            let separator = environment["COMPOSE_PATH_SEPARATOR"].flatMap { $0.first } ?? ":"
            let files = list.split(separator: separator).map { part -> URL in
                let path = String(part).trimmingCharacters(in: .whitespaces)
                if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
                return directory.appendingPathComponent(path).standardizedFileURL
            }
            if !files.isEmpty { return files }
        }

        var dir = directory.standardizedFileURL
        while true {
            for name in Self.fileNames {
                let candidate = dir.appendingPathComponent(name)
                if fileExists(candidate.path) {
                    var files = [candidate]
                    if let extra = overrideFile(in: dir) { files.append(extra) }
                    return files
                }
            }
            let parent = dir.deletingLastPathComponent().standardizedFileURL
            if parent.path == dir.path || dir.path == "/" { break }
            dir = parent
        }
        return []
    }

    /// `compose.override.yaml` and friends in the same folder, when present.
    public func overrideFile(in directory: URL) -> URL? {
        for name in Self.overrideNames {
            let candidate = directory.appendingPathComponent(name)
            if fileExists(candidate.path) { return candidate }
        }
        return nil
    }
}

/// Recently opened compose files, newest first. Each entry is keyed by its main
/// file and remembers the files merged on top of it (more `-f` files).
public struct ComposeRecents {
    public static let defaultsKey = "composeRecentFiles"
    /// Main file path to the paths of the files merged on top, in order.
    public static let extraFilesKey = "composeRecentExtraFiles"
    public static let limit = 12

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Main files, newest first.
    public var files: [URL] {
        (defaults.stringArray(forKey: Self.defaultsKey) ?? []).map { URL(fileURLWithPath: $0) }
    }

    /// Files picked together with `file`, merged on top of it. Empty for a single file.
    public func extraFiles(for file: URL) -> [URL] {
        let map = defaults.dictionary(forKey: Self.extraFilesKey) as? [String: [String]] ?? [:]
        return (map[file.path] ?? []).map { URL(fileURLWithPath: $0) }
    }

    /// Every file of the entry, main file first.
    public func fileList(for file: URL) -> [URL] {
        [file] + extraFiles(for: file)
    }

    public func add(_ file: URL, extraFiles: [URL] = []) {
        var paths = defaults.stringArray(forKey: Self.defaultsKey) ?? []
        paths.removeAll { $0 == file.path }
        paths.insert(file.path, at: 0)
        let kept = Array(paths.prefix(Self.limit))
        defaults.set(kept, forKey: Self.defaultsKey)

        var map = defaults.dictionary(forKey: Self.extraFilesKey) as? [String: [String]] ?? [:]
        let extra = extraFiles.map(\.path).filter { $0 != file.path }
        map[file.path] = extra.isEmpty ? nil : extra
        map = map.filter { kept.contains($0.key) }
        defaults.set(map, forKey: Self.extraFilesKey)
    }

    public func remove(_ file: URL) {
        var paths = defaults.stringArray(forKey: Self.defaultsKey) ?? []
        paths.removeAll { $0 == file.path }
        defaults.set(paths, forKey: Self.defaultsKey)
        var map = defaults.dictionary(forKey: Self.extraFilesKey) as? [String: [String]] ?? [:]
        map[file.path] = nil
        defaults.set(map, forKey: Self.extraFilesKey)
    }
}

/// Puts compose files picked together in merge order: main files first, override
/// files last, the rest in between in the order given.
public enum ComposeFileOrder {
    public static func sorted(_ files: [URL]) -> [URL] {
        func rank(_ url: URL) -> Int {
            let name = url.lastPathComponent.lowercased()
            if ComposeFileLocator.fileNames.contains(name) { return 0 }
            if ComposeFileLocator.overrideNames.contains(name) || name.contains(".override.") { return 2 }
            return 1
        }
        return files.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }
}
