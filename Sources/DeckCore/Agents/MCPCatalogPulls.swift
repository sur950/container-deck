import Foundation

/// Docker Hub pull counts for the featured MCP servers, keyed by repository ("mcp/playwright").
public struct MCPPullCounts: Sendable, Codable, Equatable {
    public var counts: [String: Int]
    public var fetched: Date

    public init(counts: [String: Int], fetched: Date) {
        self.counts = counts
        self.fetched = fetched
    }
}

/// Keeps the last counts in a small JSON file so the app asks Docker Hub at most once a day.
public struct MCPPullCountCache: Sendable {
    public static let lifetime: TimeInterval = 24 * 60 * 60
    public var file: URL

    public init(file: URL? = nil) {
        if let file {
            self.file = file
        } else {
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
            self.file = base.appendingPathComponent(AppConfig.dataID, isDirectory: true).appendingPathComponent("mcp-pull-counts.json")
        }
    }

    public func load() -> MCPPullCounts? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MCPPullCounts.self, from: data)
    }

    public func save(_ counts: MCPPullCounts) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(counts) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// True while the counts are younger than a day (and not from the future, if the clock moved).
    public static func isFresh(_ counts: MCPPullCounts, now: Date) -> Bool {
        let age = now.timeIntervalSince(counts.fetched)
        return age >= 0 && age < lifetime
    }
}

/// Reads pull counts from Docker Hub's public API. No account needed. Never throws: when Docker Hub
/// cannot be reached the last saved counts are used, and without those the bundled snapshot.
public struct MCPPullCountClient: Sendable {
    public typealias Fetch = @Sendable (URL) async throws -> Data

    /// The `mcp/` namespace, most pulled first. One page of 100 covers every featured server.
    public static let listURL = URL(string: "https://hub.docker.com/v2/namespaces/mcp/repositories?page_size=100&ordering=pull_count")!

    let cache: MCPPullCountCache
    let fetch: Fetch

    public init(cache: MCPPullCountCache = MCPPullCountCache(), fetch: Fetch? = nil) {
        self.cache = cache
        self.fetch = fetch ?? { url in try await MCPPullCountClient.download(url) }
    }

    /// One repository: `/v2/namespaces/mcp/repositories/<name>`. nil for names outside Docker Hub.
    public static func repositoryURL(_ repository: String) -> URL? {
        let parts = repository.split(separator: "/").map(String.init)
        guard parts.count == 2, !parts[0].contains("."),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) } }) else { return nil }
        return URL(string: "https://hub.docker.com/v2/namespaces/\(parts[0])/repositories/\(parts[1])")
    }

    /// Counts for `repositories`. Uses the cache when it is less than a day old, else asks Docker Hub.
    /// Repositories Docker Hub did not report keep their last known count.
    public func counts(for repositories: [String] = MCPCatalog.pullRepositories, now: Date = Date()) async -> MCPPullCounts? {
        let saved = cache.load()
        if let saved, MCPPullCountCache.isFresh(saved, now: now), repositories.allSatisfy({ saved.counts[$0] != nil }) {
            return saved
        }
        var found: [String: Int] = [:]
        if let data = try? await fetch(Self.listURL), let list = try? Self.parseList(data) {
            found = list
        }
        // Anything outside the first page, one by one. Few or none in practice.
        for repository in repositories where found[repository] == nil {
            guard !Task.isCancelled, let url = Self.repositoryURL(repository),
                  let data = try? await fetch(url), let one = try? Self.parseRepository(data) else { continue }
            found[one.repository] = one.pulls
        }
        let wanted = found.filter { repositories.contains($0.key) }
        guard !wanted.isEmpty else { return saved }
        var merged = saved?.counts ?? [:]
        merged.merge(wanted) { _, new in new }
        let result = MCPPullCounts(counts: merged.filter { repositories.contains($0.key) }, fetched: now)
        cache.save(result)
        return result
    }

    // MARK: Parsing (pure, tested with recorded JSON)

    /// `{"results": [{"name": "fetch", "namespace": "mcp", "pull_count": 1978687}, ...]}`.
    public static func parseList(_ data: Data) throws -> [String: Int] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else { throw DeckError.parse("Docker Hub") }
        var counts: [String: Int] = [:]
        for item in results {
            if let entry = entry(item) { counts[entry.repository] = entry.pulls }
        }
        return counts
    }

    /// One repository object.
    public static func parseRepository(_ data: Data) throws -> (repository: String, pulls: Int) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let entry = entry(root) else {
            throw DeckError.parse("Docker Hub")
        }
        return entry
    }

    static func entry(_ item: [String: Any]) -> (repository: String, pulls: Int)? {
        guard let name = item["name"] as? String, !name.isEmpty,
              let pulls = (item["pull_count"] as? NSNumber)?.intValue, pulls >= 0 else { return nil }
        let namespace = item["namespace"] as? String ?? "mcp"
        return (namespace + "/" + name, pulls)
    }

    static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(AppConfig.appName, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DeckError.network("Docker Hub answered with status \(http.statusCode).")
        }
        return data
    }
}
