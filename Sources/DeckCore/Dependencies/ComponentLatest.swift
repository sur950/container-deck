import Foundation

/// Where the newest version of a tool is read from. All public, no tokens.
public enum LatestSource: Sendable, Hashable {
    /// GitHub `GET /repos/<repo>/releases` (Apple container: every release, so a safe patch can be
    /// picked while a newer minor is out).
    case githubReleases(String)
    /// GitHub `GET /repos/<repo>/releases/latest`.
    case githubLatest(String)
    /// PyPI `GET /pypi/<package>/json`.
    case pypi(String)
    /// formulae.brew.sh `api/formula/<name>.json`.
    case homebrewFormula(String)
    /// formulae.brew.sh `api/cask/<name>.json`.
    case homebrewCask(String)
    /// LM Studio's install script (`APP_VERSION=`).
    case lmStudioScript
    /// npm registry `GET /<package>/latest`.
    case npm(String)
    /// npm registry `GET /<package>` (abbreviated metadata): every published version, for downgrades.
    case npmVersions(String)

    /// Cache key, also the key in a stand in `latest.json`.
    public var key: String {
        switch self {
        case .githubReleases(let repo): return "github:\(repo)"
        case .githubLatest(let repo): return "github-latest:\(repo)"
        case .pypi(let name): return "pypi:\(name)"
        case .homebrewFormula(let name): return "formula:\(name)"
        case .homebrewCask(let name): return "cask:\(name)"
        case .lmStudioScript: return "lmstudio-script"
        case .npm(let name): return "npm:\(name)"
        case .npmVersions(let name): return "npm-versions:\(name)"
        }
    }

    public var url: URL {
        switch self {
        case .githubReleases(let repo): return URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=30")!
        case .githubLatest(let repo): return URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        case .pypi(let name): return URL(string: "https://pypi.org/pypi/\(name)/json")!
        case .homebrewFormula(let name): return URL(string: "https://formulae.brew.sh/api/formula/\(name).json")!
        case .homebrewCask(let name): return URL(string: "https://formulae.brew.sh/api/cask/\(name).json")!
        case .lmStudioScript: return URL(string: AIConfig.lmStudioInstallScript)!
        case .npm(let name): return URL(string: "https://registry.npmjs.org/\(name)/latest")!
        case .npmVersions(let name): return URL(string: "https://registry.npmjs.org/\(name)")!
        }
    }

    var isGitHub: Bool {
        switch self {
        case .githubReleases, .githubLatest: return true
        default: return false
        }
    }
}

/// A downloadable installer for one version (Apple's signed package).
public struct PackageRef: Sendable, Codable, Equatable {
    public var name: String
    public var url: URL
    /// "sha256:<hex>" from GitHub, when published.
    public var digest: String?
    public var size: Int?

    public init(name: String, url: URL, digest: String? = nil, size: Int? = nil) {
        self.name = name
        self.url = url
        self.digest = digest
        self.size = size
    }
}

/// What a source says is published.
public struct LatestReleases: Sendable, Codable, Equatable {
    public var versions: [ToolVersion]
    /// Release page per version (`ToolVersion.description`).
    public var notes: [String: URL]
    /// Installer per version (Apple container).
    public var packages: [String: PackageRef]
    /// Homebrew casks that update themselves.
    public var autoUpdates: Bool
    /// Registry digest an image tag points to (MCP servers).
    public var digest: String?
    /// Short release notes per version (GitHub releases).
    public var summaries: [String: [String]]?

    public init(versions: [ToolVersion], notes: [String: URL] = [:], packages: [String: PackageRef] = [:], autoUpdates: Bool = false,
                digest: String? = nil) {
        self.versions = versions
        self.notes = notes
        self.packages = packages
        self.autoUpdates = autoUpdates
        self.digest = digest
        self.summaries = nil
    }

    public var newest: ToolVersion? { versions.filter { !$0.isPrerelease }.max() }

    /// Reads one source's answer.
    public static func parse(_ data: Data, source: LatestSource) throws -> LatestReleases {
        switch source {
        case .githubReleases, .githubLatest:
            let releases = try ComponentParsers.githubReleases(data).filter { !$0.isPrerelease }
            var notes: [String: URL] = [:]
            var packages: [String: PackageRef] = [:]
            var summaries: [String: [String]] = [:]
            for release in releases {
                notes[release.version.description] = release.pageURL
                let summary = ComponentParsers.notesSummary(release.body)
                if !summary.isEmpty { summaries[release.version.description] = summary }
                if let pkg = release.signedPackage {
                    packages[release.version.description] = PackageRef(name: pkg.name, url: pkg.url, digest: pkg.digest, size: pkg.size)
                }
            }
            var parsed = LatestReleases(versions: releases.map(\.version), notes: notes, packages: packages)
            parsed.summaries = summaries.isEmpty ? nil : summaries
            return parsed
        case .pypi:
            let parsed = try ComponentParsers.pypiVersions(data)
            return LatestReleases(versions: parsed.all.filter { !$0.isPrerelease })
        case .homebrewFormula:
            return LatestReleases(versions: [try ComponentParsers.homebrewFormulaVersion(data)])
        case .homebrewCask:
            let cask = try ComponentParsers.homebrewCaskVersion(data)
            return LatestReleases(versions: [cask.version], autoUpdates: cask.autoUpdates)
        case .lmStudioScript:
            guard let text = String(data: data, encoding: .utf8), let version = ComponentParsers.lmStudioScriptVersion(text) else {
                throw DeckError.parse("LM Studio's install script")
            }
            return LatestReleases(versions: [version])
        case .npm:
            return LatestReleases(versions: [try ComponentParsers.npmLatestVersion(data)])
        case .npmVersions:
            return LatestReleases(versions: try ComponentParsers.npmVersions(data))
        }
    }
}

/// Newest version answers, kept for `AppConfig.updateCheckInterval` (6 hours) in memory and in a
/// small JSON file, so a relaunch does not ask GitHub again. Old answers stay as a fallback when
/// a check fails (offline, rate limited).
public final class ComponentLatestCache: @unchecked Sendable {
    struct Entry: Codable, Equatable {
        var releases: LatestReleases
        var fetched: Date
    }

    public let file: URL?
    public let lifetime: TimeInterval
    let now: @Sendable () -> Date
    private let lock = NSLock()
    private var entries: [String: Entry]

    public init(file: URL? = ComponentLatestCache.defaultFile(), lifetime: TimeInterval = AppConfig.updateCheckInterval,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.file = file
        self.lifetime = lifetime
        self.now = now
        if let file, let data = try? Data(contentsOf: file) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            entries = (try? decoder.decode([String: Entry].self, from: data)) ?? [:]
        } else {
            entries = [:]
        }
    }

    /// Application Support/<bundle id>/components-cache.json.
    public static func defaultFile() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let id = Bundle.main.bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? AppConfig.bundleID
        return base.appendingPathComponent(id, isDirectory: true).appendingPathComponent("components-cache.json")
    }

    /// The answer when it is younger than `lifetime`.
    public func fresh(_ key: String) -> LatestReleases? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[key], now().timeIntervalSince(entry.fetched) < lifetime else { return nil }
        return entry.releases
    }

    /// The last answer of any age.
    public func any(_ key: String) -> LatestReleases? {
        lock.lock(); defer { lock.unlock() }
        return entries[key]?.releases
    }

    public func fetchedAt(_ key: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return entries[key]?.fetched
    }

    public func store(_ releases: LatestReleases, for key: String) {
        lock.lock()
        entries[key] = Entry(releases: releases, fetched: now())
        let snapshot = entries
        lock.unlock()
        save(snapshot)
    }

    /// Forgets every answer (Check Now).
    public func expireAll() {
        lock.lock()
        for key in entries.keys { entries[key]?.fetched = .distantPast }
        let snapshot = entries
        lock.unlock()
        save(snapshot)
    }

    private func save(_ snapshot: [String: Entry]) {
        guard let file else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}

/// Reads newest versions through the cache. Never throws: a failed source gives the last known
/// answer or nil.
public struct ComponentLatestFetcher: Sendable {
    let http: any ComponentHTTPFetching
    let cache: ComponentLatestCache
    /// Debug builds: a `latest.json` with stand in answers keyed by `LatestSource.key`. No network then.
    let standIn: URL?

    public init(http: any ComponentHTTPFetching = URLSessionComponentHTTP(), cache: ComponentLatestCache = ComponentLatestCache(),
                standIn: URL? = nil) {
        self.http = http
        self.cache = cache
        self.standIn = standIn
    }

    public func releases(_ source: LatestSource, force: Bool = false) async -> LatestReleases? {
        if let standIn {
            guard let data = try? Data(contentsOf: standIn),
                  let all = try? JSONDecoder().decode([String: LatestReleases].self, from: data) else { return nil }
            return all[source.key]
        }
        if !force, let hit = cache.fresh(source.key) { return hit }
        var headers: [String: String] = [:]
        if source.isGitHub {
            headers["Accept"] = "application/vnd.github+json"
            headers["X-GitHub-Api-Version"] = "2022-11-28"
        }
        if case .npmVersions = source {
            // The short form: versions only, a fraction of the full document.
            headers["Accept"] = "application/vnd.npm.install-v1+json"
        }
        do {
            let reply = try await http.get(source.url, headers: headers)
            guard reply.status == 200 else { return cache.any(source.key) }
            let releases = try LatestReleases.parse(reply.body, source: source)
            cache.store(releases, for: source.key)
            return releases
        } catch {
            return cache.any(source.key)
        }
    }

    /// The digest an image tag points to in its registry, cached like the version answers.
    public func registryDigest(_ image: String, force: Bool = false) async -> String? {
        let key = "registry:\(image)"
        if let standIn {
            guard let data = try? Data(contentsOf: standIn),
                  let all = try? JSONDecoder().decode([String: LatestReleases].self, from: data) else { return nil }
            return all[key]?.digest
        }
        if !force, let hit = cache.fresh(key) { return hit.digest }
        do {
            let digest = try await RegistryDigestReader(http: http).digest(of: image)
            cache.store(LatestReleases(versions: [], digest: digest), for: key)
            return digest
        } catch {
            return cache.any(key)?.digest
        }
    }
}
