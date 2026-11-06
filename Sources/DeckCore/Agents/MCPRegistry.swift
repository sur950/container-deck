import Foundation

// MARK: - Models

/// Where a browsed MCP server comes from.
public enum MCPRegistrySource: String, Sendable, Hashable, CaseIterable, Identifiable {
    /// The official MCP Registry (registry.modelcontextprotocol.io).
    case registry
    /// Docker's MCP catalog: the `mcp/` namespace on Docker Hub.
    case docker

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .registry: return "MCP Registry"
        case .docker: return "Docker"
        }
    }
}

/// An environment variable or header a server asks for.
public struct MCPRegistryInput: Sendable, Hashable, Identifiable {
    public var name: String
    public var description: String
    public var isRequired: Bool
    public var isSecret: Bool
    public var placeholder: String
    public var defaultValue: String?
    public var id: String { name }

    public init(name: String, description: String = "", isRequired: Bool = false, isSecret: Bool = false,
                placeholder: String = "", defaultValue: String? = nil) {
        self.name = name
        self.description = description
        self.isRequired = isRequired
        self.isSecret = isSecret
        self.placeholder = placeholder
        self.defaultValue = defaultValue
    }
}

/// One way to run a server: a package from npm, PyPI or an OCI registry.
public struct MCPRegistryPackage: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case npm, pypi, oci, other

        public var title: String {
            switch self {
            case .npm: return "npm"
            case .pypi: return "PyPI"
            case .oci: return "Container"
            case .other: return "Other"
            }
        }
    }

    public var registryType: String
    public var identifier: String
    public var version: String?
    public var transport: MCPTransport
    /// URL the server listens on inside the container (HTTP transports).
    public var transportURL: String?
    public var runtimeArguments: [String]
    public var packageArguments: [String]
    public var environment: [MCPRegistryInput]

    public var id: String { registryType + ":" + identifier }

    public init(registryType: String, identifier: String, version: String? = nil, transport: MCPTransport = .stdio,
                transportURL: String? = nil, runtimeArguments: [String] = [], packageArguments: [String] = [],
                environment: [MCPRegistryInput] = []) {
        self.registryType = registryType
        self.identifier = identifier
        self.version = version
        self.transport = transport
        self.transportURL = transportURL
        self.runtimeArguments = runtimeArguments
        self.packageArguments = packageArguments
        self.environment = environment
    }

    public var kind: Kind {
        switch registryType.lowercased() {
        case "npm": return .npm
        case "pypi": return .pypi
        case "oci", "docker": return .oci
        default: return .other
        }
    }

    /// npm, PyPI and OCI packages run here, each in a container.
    public var isSupported: Bool { kind != .other }
}

/// A server reached over the network by URL.
public struct MCPRegistryRemote: Sendable, Hashable, Identifiable {
    public var transport: MCPTransport
    public var url: String
    public var headers: [MCPRegistryInput]
    public var id: String { url }

    public init(transport: MCPTransport, url: String, headers: [MCPRegistryInput] = []) {
        self.transport = transport
        self.url = url
        self.headers = headers
    }
}

/// A server found by browsing.
public struct MCPRegistryServer: Sendable, Hashable, Identifiable {
    public var source: MCPRegistrySource
    /// Registry name (`io.github.owner/server`) or Docker image (`mcp/fetch`).
    public var name: String
    public var title: String?
    public var description: String
    public var version: String?
    public var packages: [MCPRegistryPackage]
    public var remotes: [MCPRegistryRemote]
    public var repositoryURL: String?
    public var websiteURL: String?
    /// Docker Hub pulls.
    public var pullCount: Int?
    /// When the registry entry or the Docker image last changed.
    public var updated: Date?

    public var id: String { source.rawValue + ":" + name }

    public init(source: MCPRegistrySource, name: String, title: String? = nil, description: String = "", version: String? = nil,
                packages: [MCPRegistryPackage] = [], remotes: [MCPRegistryRemote] = [], repositoryURL: String? = nil,
                websiteURL: String? = nil, pullCount: Int? = nil, updated: Date? = nil) {
        self.source = source
        self.name = name
        self.title = title
        self.description = description
        self.version = version
        self.packages = packages
        self.remotes = remotes
        self.repositoryURL = repositoryURL
        self.websiteURL = websiteURL
        self.pullCount = pullCount
        self.updated = updated
    }

    /// The title, or the last part of the name.
    public var displayTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty { return title }
        return String(name.split(separator: "/").last ?? Substring(name))
    }

    /// Owner part of the name (`io.github.owner`), shown under the title.
    public var publisher: String {
        if source == .docker { return "Docker MCP catalog" }
        return name.split(separator: "/").first.map(String.init) ?? name
    }

    public var transports: [MCPTransport] {
        var seen = Set<MCPTransport>()
        return (packages.map(\.transport) + remotes.map(\.transport)).filter { seen.insert($0).inserted }
    }

    /// The best page for people: website, then repository, then the source's own page.
    public var homepage: String? {
        if let websiteURL, !websiteURL.isEmpty { return websiteURL }
        if let repositoryURL, !repositoryURL.isEmpty { return repositoryURL }
        if source == .docker { return "https://hub.docker.com/r/\(name)" }
        return nil
    }

    /// Ways to install, best first: a container image, npm, PyPI, then a remote URL.
    public var installOptions: [MCPRegistryInstallOption] {
        let order: [MCPRegistryPackage.Kind] = [.oci, .npm, .pypi]
        let packages = order.flatMap { kind in self.packages.filter { $0.kind == kind } }
        return packages.map { .package($0) } + remotes.map { .remote($0) }
    }

    public var isInstallable: Bool { !installOptions.isEmpty }
}

public enum MCPRegistryInstallOption: Sendable, Hashable, Identifiable {
    case package(MCPRegistryPackage)
    case remote(MCPRegistryRemote)

    public var id: String {
        switch self {
        case .package(let package): return package.id
        case .remote(let remote): return "remote:" + remote.url
        }
    }

    public var title: String {
        switch self {
        case .package(let package): return package.kind.title
        case .remote: return "Remote"
        }
    }

    public var transport: MCPTransport {
        switch self {
        case .package(let package): return package.transport
        case .remote(let remote): return remote.transport
        }
    }

    public var inputs: [MCPRegistryInput] {
        switch self {
        case .package(let package): return package.environment
        case .remote(let remote): return remote.headers
        }
    }
}

/// One page of results. `cursor` is the registry cursor or a Docker Hub page number.
public struct MCPRegistryPage: Sendable {
    public var servers: [MCPRegistryServer]
    public var nextCursor: String?
    /// Total matches, when the source says (Docker Hub does, the registry does not).
    public var total: Int?

    public init(servers: [MCPRegistryServer], nextCursor: String?, total: Int? = nil) {
        self.servers = servers
        self.nextCursor = nextCursor
        self.total = total
    }
}

// MARK: - Client

/// Short lived cache of responses, so typing, paging back and opening details do not hit the network again.
public actor MCPRegistryCache {
    public static let shared = MCPRegistryCache()
    private var items: [String: (date: Date, data: Data)] = [:]
    public var lifetime: TimeInterval = 300

    public init() {}

    func data(for key: String) -> Data? {
        guard let item = items[key], Date().timeIntervalSince(item.date) < lifetime else { return nil }
        return item.data
    }

    func store(_ data: Data, for key: String) {
        if items.count > 200 { items = items.filter { Date().timeIntervalSince($0.value.date) < lifetime } }
        items[key] = (Date(), data)
    }
}

/// Searches the official MCP Registry (API v0.1, checked 6 Nov 2026 against registry 1.8.7)
/// and Docker's `mcp/` namespace on Docker Hub. No account needed.
public struct MCPRegistryClient: Sendable {
    public static let registryBase = "https://registry.modelcontextprotocol.io/v0.1/servers"
    public static let pageSize = 30
    /// The registry needs at least this many letters to search.
    public static let minimumSearchLength = 3

    let session: URLSession
    let cache: MCPRegistryCache

    public init(session: URLSession = .shared, cache: MCPRegistryCache = .shared) {
        self.session = session
        self.cache = cache
    }

    public func search(_ query: String, source: MCPRegistrySource, cursor: String? = nil, limit: Int = pageSize) async throws -> MCPRegistryPage {
        switch source {
        case .registry:
            let data = try await fetch(Self.registryURL(query, cursor: cursor, limit: limit), service: "The MCP Registry")
            return try Self.parseRegistry(data)
        case .docker:
            let page = Int(cursor ?? "") ?? 1
            let data = try await fetch(Self.dockerURL(query, page: page, pageSize: limit), service: "Docker Hub")
            return try Self.parseDocker(data, page: page, pageSize: limit)
        }
    }

    static func registryURL(_ query: String, cursor: String?, limit: Int = pageSize) -> URL {
        var components = URLComponents(string: registryBase) ?? URLComponents()
        var items = [URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "version", value: "latest")]
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= minimumSearchLength { items.append(URLQueryItem(name: "search", value: trimmed)) }
        if let cursor, !cursor.isEmpty { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        components.queryItems = items
        return components.url ?? URL(fileURLWithPath: "/")
    }

    static func dockerURL(_ query: String, page: Int, pageSize: Int = pageSize) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "hub.docker.com"
        components.path = "/v2/repositories/mcp/"
        var items = [URLQueryItem(name: "page", value: String(max(page, 1))),
                     URLQueryItem(name: "page_size", value: String(min(max(pageSize, 1), 100))),
                     URLQueryItem(name: "ordering", value: "pull_count")]
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { items.append(URLQueryItem(name: "name", value: trimmed)) }
        components.queryItems = items
        return components.url ?? URL(fileURLWithPath: "/")
    }

    func fetch(_ url: URL, service: String) async throws -> Data {
        let key = url.absoluteString
        if let cached = await cache.data(for: key) { return cached }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("\(AppConfig.appName)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DeckError.network(error.localizedDescription)
        }
        let (data, response) = result
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            switch http.statusCode {
            case 429: throw DeckError.network("\(service) is limiting requests. Try again in a minute.")
            case 400, 422: throw DeckError.network("\(service) did not accept that search.")
            default: throw DeckError.network("\(service) answered with status \(http.statusCode).")
            }
        }
        await cache.store(data, for: key)
        return data
    }

    // MARK: Parsing (pure, tested with recorded JSON)

    /// Reads `/v0.1/servers` (and `/v0/servers`): `{"servers": [{"server": {...}, "_meta": {...}}], "metadata": {"nextCursor"}}`.
    public static func parseRegistry(_ data: Data) throws -> MCPRegistryPage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DeckError.parse("MCP Registry") }
        let list = root["servers"] as? [[String: Any]] ?? []
        var seen = Set<String>()
        let servers = list.compactMap { item -> MCPRegistryServer? in
            let body = item["server"] as? [String: Any] ?? item
            guard var server = parseServer(body), seen.insert(server.name).inserted else { return nil }
            let official = (item["_meta"] as? [String: Any])?["io.modelcontextprotocol.registry/official"] as? [String: Any]
            server.updated = date((official?["updatedAt"] as? String) ?? (official?["publishedAt"] as? String))
            return server
        }
        let metadata = root["metadata"] as? [String: Any]
        let cursor = (metadata?["nextCursor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return MCPRegistryPage(servers: servers, nextCursor: servers.isEmpty ? nil : cursor)
    }

    /// One `server.json` object.
    public static func parseServer(_ body: [String: Any]) -> MCPRegistryServer? {
        guard let name = body["name"] as? String, !name.isEmpty else { return nil }
        let packages = (body["packages"] as? [[String: Any]] ?? []).compactMap(parsePackage)
        let remotes = (body["remotes"] as? [[String: Any]] ?? []).compactMap { remote -> MCPRegistryRemote? in
            guard let url = remote["url"] as? String, !url.isEmpty else { return nil }
            return MCPRegistryRemote(transport: transport(remote["type"] as? String), url: url,
                                     headers: (remote["headers"] as? [[String: Any]] ?? []).compactMap(parseInput))
        }
        let repository = (body["repository"] as? [String: Any])?["url"] as? String
        return MCPRegistryServer(source: .registry, name: name, title: body["title"] as? String,
                                 description: (body["description"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                 version: body["version"] as? String, packages: packages, remotes: remotes,
                                 repositoryURL: repository, websiteURL: body["websiteUrl"] as? String)
    }

    static func parsePackage(_ item: [String: Any]) -> MCPRegistryPackage? {
        guard let type = item["registryType"] as? String, let identifier = item["identifier"] as? String, !identifier.isEmpty else { return nil }
        let transportInfo = item["transport"] as? [String: Any]
        return MCPRegistryPackage(
            registryType: type, identifier: identifier, version: item["version"] as? String,
            transport: transport(transportInfo?["type"] as? String), transportURL: transportInfo?["url"] as? String,
            runtimeArguments: arguments(item["runtimeArguments"]), packageArguments: arguments(item["packageArguments"]),
            environment: (item["environmentVariables"] as? [[String: Any]] ?? []).compactMap(parseInput)
        )
    }

    static func parseInput(_ item: [String: Any]) -> MCPRegistryInput? {
        guard let name = item["name"] as? String, !name.isEmpty else { return nil }
        return MCPRegistryInput(name: name, description: item["description"] as? String ?? "",
                                isRequired: item["isRequired"] as? Bool ?? false, isSecret: item["isSecret"] as? Bool ?? false,
                                placeholder: item["placeholder"] as? String ?? "", defaultValue: item["default"] as? String)
    }

    /// Fixed argument values. Arguments that need a value from the person (no `value`) are left out.
    static func arguments(_ value: Any?) -> [String] {
        var out: [String] = []
        for item in value as? [[String: Any]] ?? [] {
            let fixed = (item["value"] as? String) ?? (item["default"] as? String)
            switch item["type"] as? String {
            case "named":
                guard let name = item["name"] as? String, !name.isEmpty else { continue }
                if let fixed {
                    if !fixed.contains("{") { out += [name, fixed] }
                } else if item["isRequired"] as? Bool == true, item["valueHint"] == nil {
                    // A required flag with no value, like `--stdio`.
                    out.append(name)
                }
            default:
                if let fixed, !fixed.contains("{") { out.append(fixed) }
            }
        }
        return out
    }

    static func transport(_ type: String?) -> MCPTransport {
        switch (type ?? "stdio").lowercased() {
        case "streamable-http", "streamable_http", "http": return .http
        case "sse": return .sse
        default: return .stdio
        }
    }

    /// Repositories in Docker's `mcp/` namespace that are not servers (image signatures, the catalog itself).
    static let dockerHelperRepositories: Set<String> = ["signatures", "docker-mcp-catalog"]

    /// Docker Hub `/v2/repositories/mcp/` list. Every image there is a stdio server.
    public static func parseDocker(_ data: Data, page: Int, pageSize: Int = pageSize) throws -> MCPRegistryPage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else { throw DeckError.parse("Docker Hub") }
        var seen = Set<String>()
        let servers = results.compactMap { item -> MCPRegistryServer? in
            guard let name = item["name"] as? String, !name.isEmpty, !dockerHelperRepositories.contains(name) else { return nil }
            let namespace = item["namespace"] as? String ?? "mcp"
            let image = namespace + "/" + name
            guard seen.insert(image).inserted else { return nil }
            return MCPRegistryServer(source: .docker, name: image,
                                     description: (item["description"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                     packages: [MCPRegistryPackage(registryType: "oci", identifier: image)],
                                     pullCount: (item["pull_count"] as? NSNumber)?.intValue, updated: date(item["last_updated"] as? String))
        }
        let total = (root["count"] as? NSNumber)?.intValue
        let hasNext = (root["next"] as? String).map { !$0.isEmpty } ?? (total.map { page * pageSize < $0 } ?? false)
        return MCPRegistryPage(servers: servers, nextCursor: hasNext && !servers.isEmpty ? String(page + 1) : nil, total: total)
    }

    static func date(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = fractional.date(from: text) { return value }
        return ISO8601DateFormatter().date(from: text)
    }
}

// MARK: - Install

/// Turns a browsed server into what the install form needs. Every package runs in a container:
/// OCI images as they are, npm with `npx -y <package>@<version>` in a Node image, PyPI with
/// `uvx <package>==<version>` in a Python image with uv. Remote servers are reached by URL.
public enum MCPRegistryInstall {
    public static let nodeImage = "node:22-slim"
    public static let pythonImage = "ghcr.io/astral-sh/uv:python3.12-bookworm-slim"

    /// Image and arguments for a package. nil for package types that cannot run here.
    public static func run(_ package: MCPRegistryPackage) -> (image: String, command: [String])? {
        switch package.kind {
        case .oci:
            var image = package.identifier
            if let version = package.version, !version.isEmpty, !image.contains("@"),
               !(image.split(separator: "/").last ?? "").contains(":") {
                image += ":" + version
            }
            return (image, package.packageArguments)
        case .npm:
            let spec = package.version.map { "\(package.identifier)@\($0)" } ?? package.identifier
            return (nodeImage, ["npx", "-y"] + package.runtimeArguments.filter { $0 != "-y" && $0 != "--yes" } + [spec] + package.packageArguments)
        case .pypi:
            let spec = package.version.map { "\(package.identifier)==\($0)" } ?? package.identifier
            return (pythonImage, ["uvx"] + package.runtimeArguments + [spec] + package.packageArguments)
        case .other:
            return nil
        }
    }

    /// Port and path inside the container for HTTP packages, from the transport URL.
    static func port(_ package: MCPRegistryPackage) -> (Int, String) {
        guard let text = package.transportURL, let url = URLComponents(string: text.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")) else {
            return (8080, package.transport == .sse ? "/sse" : "/mcp")
        }
        let path = url.path.isEmpty ? (package.transport == .sse ? "/sse" : "/mcp") : url.path
        return (url.port ?? 8080, path)
    }

    static func fields(_ inputs: [MCPRegistryInput]) -> [MCPCatalogField] {
        inputs.map { input in
            MCPCatalogField(key: input.name, label: label(input.name), secret: input.isSecret, required: input.isRequired,
                            placeholder: input.placeholder.isEmpty ? (input.defaultValue ?? "") : input.placeholder)
        }
    }

    /// "GHCARD_API_KEY" becomes "Ghcard API key" for the form label.
    static func label(_ name: String) -> String {
        let upper: Set<String> = ["api", "url", "id", "mcp", "db", "ssl", "tls", "aws", "gcp", "sql", "http", "https", "jwt", "oauth"]
        let words = name.split(whereSeparator: { $0 == "_" || $0 == "-" }).map { $0.lowercased() }
        guard !words.isEmpty else { return name }
        return words.enumerated().map { index, word in
            if upper.contains(word) { return word.uppercased() }
            return index == 0 ? word.prefix(1).uppercased() + word.dropFirst() : word
        }.joined(separator: " ")
    }

    /// A catalog item for the install form. nil when the option cannot run here.
    public static func catalogItem(_ server: MCPRegistryServer, option: MCPRegistryInstallOption) -> MCPCatalogItem? {
        let id = server.source.rawValue + ":" + server.name
        let summary = server.description.isEmpty ? server.name : server.description
        let homepage = server.homepage ?? ""
        switch option {
        case .package(let package):
            guard let run = run(package) else { return nil }
            let http = package.transport != .stdio
            let (port, path) = port(package)
            return MCPCatalogItem(id: id, title: server.displayTitle, summary: summary, image: run.image, transport: package.transport,
                                  command: run.command, containerPort: http ? port : nil, path: http ? path : nil,
                                  fields: fields(package.environment), homepage: homepage, publisher: server.publisher)
        case .remote(let remote):
            return MCPCatalogItem(id: id, title: server.displayTitle, summary: summary, image: "", transport: remote.transport,
                                  fields: fields(remote.headers), homepage: homepage, publisher: server.publisher,
                                  remoteURL: remote.url)
        }
    }
}
