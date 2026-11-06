import Foundation


/// Docker Hub search and tags over the public HTTPS API. No account needed.
public struct DockerHubClient: Sendable {
    let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public static let searchPageSize = 25
    public static let tagsPageSize = 50

    /// Searches repositories. Pages start at 1.
    /// An empty query lists the official images, most pulled first.
    public func search(_ query: String, page: Int = 1) async throws -> HubPage<HubRepository> {
        let page = max(page, 1)
        let data = try await fetch(Self.searchURL(query, page: page))
        return try Self.parseSearch(data, page: page, pageSize: Self.searchPageSize)
    }

    /// Lists tags for "nginx" or "grafana/grafana". Pages start at 1.
    public func tags(_ repository: String, page: Int = 1) async throws -> HubPage<HubTag> {
        let page = max(page, 1)
        guard let url = Self.tagsURL(repository, page: page) else {
            throw DeckError.network("\(repository) is not a Docker Hub repository name.")
        }
        let data = try await fetch(url)
        return try Self.parseTags(data, page: page, pageSize: Self.tagsPageSize)
    }

    // MARK: - URLs

    static func searchURL(_ query: String, page: Int) -> URL {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var components = URLComponents()
        components.scheme = "https"
        components.host = "hub.docker.com"
        if trimmed.isEmpty {
            components.path = "/v2/repositories/library/"
            components.queryItems = [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "page_size", value: String(searchPageSize)),
                // Docker Hub sorts this list backwards: "pull_count" gives the most pulled first.
                URLQueryItem(name: "ordering", value: "pull_count")
            ]
        } else {
            components.path = "/v2/search/repositories/"
            components.queryItems = [
                URLQueryItem(name: "query", value: trimmed),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "page_size", value: String(searchPageSize))
            ]
        }
        return components.url ?? URL(fileURLWithPath: "/")
    }

    static func tagsURL(_ repository: String, page: Int) -> URL? {
        guard let path = repositoryPath(repository) else { return nil }
        let namespace = path.0
        let name = path.1
        var components = URLComponents()
        components.scheme = "https"
        components.host = "hub.docker.com"
        components.path = "/v2/repositories/\(namespace)/\(name)/tags"
        components.queryItems = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "page_size", value: String(tagsPageSize))
        ]
        return components.url
    }

    /// ("library", "nginx") for "nginx", "docker.io/library/nginx:1.27" or "library/nginx".
    /// ("grafana", "grafana") for "grafana/grafana". nil for other registries.
    static func repositoryPath(_ repository: String) -> (String, String)? {
        var name = repository.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let at = name.firstIndex(of: "@") { name = String(name[..<at]) }
        if let colon = name.lastIndex(of: ":"), !name[colon...].contains("/") { name = String(name[..<colon]) }
        for prefix in ["https://", "docker.io/", "index.docker.io/", "registry-1.docker.io/", "hub.docker.com/r/", "hub.docker.com/_/"]
        where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
        }
        let parts = name.split(separator: "/").map { String($0) }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        guard parts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy { allowed.contains($0) } }) else { return nil }
        switch parts.count {
        case 1: return ("library", parts[0])
        case 2:
            // Docker Hub namespaces have no dots. "ghcr.io/x" is another registry.
            guard !parts[0].contains(".") else { return nil }
            return (parts[0], parts[1])
        default: return nil
        }
    }

    // MARK: - Network

    func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
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
            case 404: throw DeckError.network("Docker Hub has no repository by that name.")
            case 429: throw DeckError.network("Docker Hub is limiting requests. Try again in a minute.")
            default: throw DeckError.network("Docker Hub answered with status \(http.statusCode).")
            }
        }
        return data
    }

    // MARK: - Parsing (pure, tested without network)

    /// Reads `/v2/search/repositories/` results, and `/v2/repositories/<namespace>/` lists.
    public static func parseSearch(_ data: Data, page: Int, pageSize: Int = DockerHubClient.searchPageSize) throws -> HubPage<HubRepository> {
        let response: HubListResponse<HubRepositoryDTO>
        do {
            response = try JSONDecoder().decode(HubListResponse<HubRepositoryDTO>.self, from: data)
        } catch {
            throw DeckError.parse("Docker Hub search")
        }
        var seen = Set<String>()
        let items: [HubRepository] = response.results.compactMap { dto in
            guard let repository = dto.repository, seen.insert(repository.fullName).inserted else { return nil }
            return repository
        }
        return HubPage(items: items, nextPage: response.nextPage(current: page, pageSize: pageSize))
    }

    /// Reads `/v2/repositories/<namespace>/<name>/tags`.
    public static func parseTags(_ data: Data, page: Int, pageSize: Int = DockerHubClient.tagsPageSize) throws -> HubPage<HubTag> {
        let response: HubListResponse<HubTagDTO>
        do {
            response = try JSONDecoder().decode(HubListResponse<HubTagDTO>.self, from: data)
        } catch {
            throw DeckError.parse("Docker Hub tags")
        }
        let items = response.results.compactMap { $0.tag }
        return HubPage(items: items, nextPage: response.nextPage(current: page, pageSize: pageSize))
    }
}

// MARK: - Docker Hub JSON

struct HubListResponse<Item: Decodable>: Decodable {
    var count: Int?
    var next: String?
    var results: [Item]

    private enum CodingKeys: String, CodingKey { case count, next, results }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        count = c.laxInt(.count)
        next = c.laxString(.next)
        results = c.laxList(Item.self, .results)
    }

    func nextPage(current page: Int, pageSize: Int) -> Int? {
        if let next = CLIText.nonEmpty(next) {
            // Use the page number Docker Hub gives when it has one.
            if let value = URLComponents(string: next)?.queryItems?.first(where: { $0.name == "page" })?.value,
               let number = Int(value), number > page {
                return number
            }
            return page + 1
        }
        if next == nil, let count, !results.isEmpty, page * pageSize < count {
            return page + 1
        }
        return nil
    }
}

struct HubRepositoryDTO: Decodable {
    var repository: HubRepository?

    private enum CodingKeys: String, CodingKey {
        case repoName = "repo_name", name, namespace
        case shortDescription = "short_description", description
        case starCount = "star_count", pullCount = "pull_count", isOfficial = "is_official"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var fullName: String
        let namespace = CLIText.nonEmpty(c.laxString(.namespace))
        if let repoName = CLIText.nonEmpty(c.laxString(.repoName)) {
            fullName = repoName
        } else if let name = CLIText.nonEmpty(c.laxString(.name)) {
            fullName = namespace.map { "\($0)/\(name)" } ?? name
        } else {
            repository = nil
            return
        }
        if fullName.hasPrefix("library/") { fullName = String(fullName.dropFirst("library/".count)) }
        let official = c.laxBool(.isOfficial) ?? (namespace == "library" || !fullName.contains("/"))
        repository = HubRepository(
            fullName: fullName,
            description: c.laxString([.shortDescription, .description]) ?? "",
            starCount: c.laxInt(.starCount) ?? 0,
            pullCount: c.laxInt(.pullCount) ?? 0,
            isOfficial: official
        )
    }
}

struct HubTagDTO: Decodable {
    var tag: HubTag?

    private enum CodingKeys: String, CodingKey {
        case name, fullSize = "full_size", lastUpdated = "last_updated", lastPushed = "tag_last_pushed", images
    }

    private struct Image: Decodable {
        var os: String?
        var architecture: String?
        var variant: String?
        var size: UInt64?

        private enum CodingKeys: String, CodingKey { case os, architecture, variant, size }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            os = c.laxString(.os)
            architecture = c.laxString(.architecture)
            variant = c.laxString(.variant)
            size = c.laxUInt64(.size)
        }

        var platform: String? {
            guard let os = CLIText.nonEmpty(os), let arch = CLIText.nonEmpty(architecture),
                  os != "unknown", arch != "unknown" else { return nil }
            if let variant = CLIText.nonEmpty(variant) { return "\(os)/\(arch)/\(variant)" }
            return "\(os)/\(arch)"
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let name = CLIText.nonEmpty(c.laxString(.name)) else {
            tag = nil
            return
        }
        let images = c.laxList(Image.self, .images)
        var platforms: [String] = []
        for image in images {
            if let platform = image.platform, !platforms.contains(platform) { platforms.append(platform) }
        }
        let size = c.laxUInt64(.fullSize) ?? images.compactMap { $0.size }.max() ?? 0
        tag = HubTag(
            name: name,
            sizeBytes: size,
            lastUpdated: c.laxDate([.lastUpdated, .lastPushed]),
            platforms: platforms
        )
    }
}
