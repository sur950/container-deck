import Foundation

/// How one registry's part of a search went.
public enum RegistrySearchStatus: Sendable, Equatable {
    case ok
    /// The registry has no search. A full name still shows its tags.
    case lookupOnly(String)
    /// The catalog call was refused.
    case listingRefused
    /// Signed in, but macOS asks before the app may read the saved login.
    case needsKeychainAccess
    case failed(String)

    public var isProblem: Bool {
        switch self {
        case .ok: return false
        default: return true
        }
    }
}

/// One registry's results.
public struct RegistrySearchResult: Sendable, Identifiable {
    public var source: RegistrySource
    public var images: [RegistryImage]
    public var status: RegistrySearchStatus
    public var nextPage: Int?

    public var id: String { source.id }

    public init(source: RegistrySource, images: [RegistryImage] = [], status: RegistrySearchStatus = .ok, nextPage: Int? = nil) {
        self.source = source
        self.images = images
        self.status = status
        self.nextPage = nextPage
    }
}

/// An exact name looked up in one registry, with its tags.
public struct RegistryLookup: Sendable {
    public var image: RegistryImage
    public var tags: HubPage<HubTag>
}

/// Copy shown per registry. Short, plain words.
public enum RegistrySearchCopy {
    public static let listingRefused = "This registry does not allow listing. Enter a full image name to see its tags."
    public static let needsKeychain = "Signed in registries need keychain access to search. Public images still show by full name."

    public static func lookupNote(for kind: RegistryKind) -> String {
        switch kind {
        case .github: return "GitHub has no public search. Enter a full name like ghcr.io/owner/image to see its tags."
        case .amazon: return "Amazon ECR has no search here. Enter a full image name to see its tags."
        case .google: return "Google Artifact Registry has no search here. Enter a full image name to see its tags."
        default: return "This registry has no search. Enter a full image name to see its tags."
        }
    }
}

/// Merging results from several registries into one list.
public enum RegistrySearchMerge {
    /// 0 exact name, 1 name starts with the query, 2 path contains it, 3 anything else.
    public static func tier(repository: String, query: String) -> Int {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return 3 }
        let path = repository.lowercased()
        let name = path.split(separator: "/").last.map(String.init) ?? path
        if name == q || path == q { return 0 }
        if name.hasPrefix(q) { return 1 }
        if path.contains(q) { return 2 }
        return 3
    }

    /// One list: best name match first, then each registry's own order within
    /// that match level, taking turns between registries so one registry never
    /// buries the others.
    /// Duplicates (same registry and path) are dropped.
    public static func merge(_ results: [RegistrySearchResult], query: String) -> [RegistryImage] {
        struct Entry { let image: RegistryImage; let tier: Int; let rank: Int; let order: Int }
        var seen = Set<String>()
        var entries: [Entry] = []
        for (order, result) in results.enumerated() {
            // Rank counts within the same tier of the same registry.
            var ranks: [Int: Int] = [:]
            for image in result.images where seen.insert(image.id).inserted {
                let level = tier(repository: image.repository, query: query)
                let rank = ranks[level, default: 0]
                ranks[level] = rank + 1
                entries.append(Entry(image: image, tier: level, rank: rank, order: order))
            }
        }
        return entries.sorted { a, b in
            if a.tier != b.tier { return a.tier < b.tier }
            if a.rank != b.rank { return a.rank < b.rank }
            if a.order != b.order { return a.order < b.order }
            return a.image.id < b.image.id
        }.map(\.image)
    }
}

/// Searches every registry at once. Each registry has its own time limit, so a
/// slow or broken one never holds up the rest. Network only, no processes.
public actor RegistrySearchService {
    let http: any RegistryHTTP
    let credentials: any RegistryCredentialReading
    let hub: DockerHubClient
    let timeout: Duration
    let cacheLife: TimeInterval

    /// Catalog names per host, Harbor or not per host, GitHub packages per user.
    /// Names only, never secrets.
    private var catalogs: [String: (names: [String], at: Date)] = [:]
    private var harborHosts: [String: Bool] = [:]
    private var githubPackages: [String: (images: [RegistryImage], at: Date)] = [:]
    /// Logins the person allowed through the macOS prompt, kept in memory for a
    /// short while so the next search does not prompt again.
    private var allowed: [String: (credential: RegistryCredential, at: Date)] = [:]

    public init(http: any RegistryHTTP = URLSessionRegistryHTTP(),
                credentials: any RegistryCredentialReading = ContainerRegistryKeychain(),
                hub: DockerHubClient = DockerHubClient(),
                timeout: Duration = .seconds(12),
                cacheLife: TimeInterval = 300) {
        self.http = http
        self.credentials = credentials
        self.hub = hub
        self.timeout = timeout
        self.cacheLife = cacheLife
    }

    // MARK: Search

    /// Searches each source in parallel. Results come back in source order.
    public func search(_ query: String, in sources: [RegistrySource], page: Int = 1) async -> [RegistrySearchResult] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = timeout
        return await withTaskGroup(of: (Int, RegistrySearchResult).self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask {
                    do {
                        let result = try await Self.withTimeout(limit) {
                            try await self.searchOne(text, source: source, page: page)
                        }
                        return (index, result)
                    } catch is RegistryTimeout {
                        return (index, RegistrySearchResult(source: source, status: .failed("No answer in time.")))
                    } catch is CancellationError {
                        return (index, RegistrySearchResult(source: source, status: .failed("Stopped.")))
                    } catch {
                        return (index, RegistrySearchResult(source: source, status: .failed(Self.message(error))))
                    }
                }
            }
            var collected: [(Int, RegistrySearchResult)] = []
            for await item in group { collected.append(item) }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    func searchOne(_ query: String, source: RegistrySource, page: Int) async throws -> RegistrySearchResult {
        switch source.kind {
        case .dockerHub:
            let found = try await hub.search(query, page: page)
            return RegistrySearchResult(source: source, images: found.items.map(RegistryImage.init(hub:)), nextPage: found.nextPage)
        case .quay:
            guard let url = QuaySearch.url(query, page: page) else { throw DeckError.network("Bad search text.") }
            let reply = try await http.get(url, headers: ["Accept": "application/json"])
            guard reply.isSuccess else { throw Self.statusError(reply.status, registry: "Quay.io") }
            let parsed = try QuaySearch.parse(reply.data)
            return RegistrySearchResult(source: source, images: parsed.images, nextPage: parsed.hasMore ? page + 1 : nil)
        case .github:
            return try await searchGitHub(query, source: source, page: page)
        case .amazon, .google:
            return RegistrySearchResult(source: source, status: .lookupOnly(RegistrySearchCopy.lookupNote(for: source.kind)))
        case .generic:
            return try await searchGeneric(query, source: source, page: page)
        }
    }

    private func searchGitHub(_ query: String, source: RegistrySource, page: Int) async throws -> RegistrySearchResult {
        guard page == 1 else { return RegistrySearchResult(source: source) }
        let lookup = await credential(for: source)
        switch lookup {
        case .found(let credential):
            let all = try await packages(for: credential)
            return RegistrySearchResult(source: source, images: GitHubPackages.filter(all, query: query))
        case .needsPermission:
            return RegistrySearchResult(source: source, status: .needsKeychainAccess)
        case .none, .failed:
            return RegistrySearchResult(source: source, status: .lookupOnly(RegistrySearchCopy.lookupNote(for: .github)))
        }
    }

    private func packages(for credential: RegistryCredential) async throws -> [RegistryImage] {
        let key = credential.username.lowercased()
        if let cached = githubPackages[key], Date().timeIntervalSince(cached.at) < cacheLife { return cached.images }
        let headers = GitHubPackages.headers(token: credential.secret)
        guard let userURL = GitHubPackages.userPackagesURL() else { return [] }
        var images = try await githubPages(userURL, headers: headers)
        if let orgsURL = GitHubPackages.userOrgsURL(),
           let reply = try? await http.get(orgsURL, headers: headers), reply.isSuccess {
            for org in GitHubPackages.parseOrgs(reply.data).prefix(20) {
                guard let url = GitHubPackages.orgPackagesURL(org) else { continue }
                // One org that hides its packages should not hide the rest.
                if let more = try? await githubPages(url, headers: headers) { images += more }
            }
        }
        var seen = Set<String>()
        images = images.filter { seen.insert($0.id).inserted }
        githubPackages[key] = (images, Date())
        return images
    }

    private func githubPages(_ first: URL, headers: [String: String]) async throws -> [RegistryImage] {
        var url: URL? = first
        var images: [RegistryImage] = []
        var pages = 0
        while let next = url, pages < GitHubPackages.maxPages {
            let reply = try await http.get(next, headers: headers)
            guard reply.isSuccess else {
                if reply.status == 401 || reply.status == 403 {
                    throw DeckError.network("GitHub did not accept the saved token for listing packages. Enter a full name to see its tags.")
                }
                throw Self.statusError(reply.status, registry: "GitHub")
            }
            images += try GitHubPackages.parsePackages(reply.data)
            url = RegistryAPISession.nextLink(reply.header("link"), base: next)
            pages += 1
        }
        return images
    }

    private func searchGeneric(_ query: String, source: RegistrySource, page: Int) async throws -> RegistrySearchResult {
        guard page == 1 else { return RegistrySearchResult(source: source) }
        let lookup = source.isSignedIn ? await credential(for: source) : RegistryCredentialLookup.none
        var credential: RegistryCredential?
        if case .found(let value) = lookup { credential = value }
        let blocked = lookup == .needsPermission

        if harborHosts[source.host] != false, let url = HarborSearch.url(source: source, query: query) {
            var headers = ["Accept": "application/json"]
            if let credential { headers["Authorization"] = credential.basicHeader }
            if let reply = try? await http.get(url, headers: headers) {
                if reply.isSuccess, let images = HarborSearch.parse(reply.data, registry: source.host) {
                    harborHosts[source.host] = true
                    return RegistrySearchResult(source: source, images: images, status: blocked && images.isEmpty ? .needsKeychainAccess : .ok)
                }
                if reply.status == 404 || (reply.isSuccess && HarborSearch.parse(reply.data, registry: source.host) == nil) {
                    harborHosts[source.host] = false
                }
            }
        }

        switch try await catalog(source: source, credential: credential) {
        case .names(let names):
            let picked = RegistryCatalog.filter(names, query: query)
            return RegistrySearchResult(source: source, images: picked.map { RegistryImage(registry: source.host, repository: $0) })
        case .refused:
            return RegistrySearchResult(source: source, status: blocked ? .needsKeychainAccess : .listingRefused)
        }
    }

    private enum CatalogAnswer { case names([String]), refused }

    private func catalog(source: RegistrySource, credential: RegistryCredential?) async throws -> CatalogAnswer {
        if let cached = catalogs[source.host], Date().timeIntervalSince(cached.at) < cacheLife { return .names(cached.names) }
        guard let first = RegistryCatalog.url(source: source) else { return .refused }
        let session = RegistryAPISession(http: http, credential: credential)
        var url: URL? = first
        var names: [String] = []
        var pages = 0
        while let next = url, pages < RegistryCatalog.maxPages {
            let reply = try await session.get(next, scope: "registry:catalog:*")
            if [400, 401, 403, 404, 405].contains(reply.status) { return .refused }
            guard reply.isSuccess else { throw Self.statusError(reply.status, registry: source.displayName) }
            guard let page = RegistryCatalog.parse(reply.data) else { return .refused }
            names += page
            url = page.isEmpty ? nil : RegistryAPISession.nextLink(reply.header("link"), base: next)
            pages += 1
        }
        catalogs[source.host] = (names, Date())
        return .names(names)
    }

    // MARK: Credentials

    /// Reads the saved login quietly. Never prompts.
    func credential(for source: RegistrySource) async -> RegistryCredentialLookup {
        guard let server = source.keychainServer else { return .none }
        if let kept = allowed[server], Date().timeIntervalSince(kept.at) < cacheLife * 2 { return .found(kept.credential) }
        return await credentials.credential(server: server, interactive: false)
    }

    /// Reads the saved login and lets macOS ask the person. Only call this from a
    /// button the person pressed.
    public func requestAccess(_ source: RegistrySource) async -> RegistryCredentialLookup {
        guard let server = source.keychainServer else { return .none }
        let lookup = await credentials.credential(server: server, interactive: true)
        if case .found(let credential) = lookup {
            allowed[server] = (credential, Date())
            githubPackages = [:]
            catalogs[source.host] = nil
        }
        return lookup
    }

    /// Drops every cached name and allowed login, for example after the
    /// registry list changed.
    public func reset() {
        catalogs = [:]
        harborHosts = [:]
        githubPackages = [:]
        allowed = [:]
    }

    // MARK: Lookup and tags

    /// Looks up an exact name. `name` is a full reference ("ghcr.io/owner/app:1")
    /// or a path in `source` ("owner/app").
    public func lookup(_ name: String, in source: RegistrySource?) async throws -> RegistryLookup {
        guard let parsed = PullReference.parse(name) else {
            throw DeckError.network("That is not an image name. Use lower case, like owner/app.")
        }
        let host = parsed.registry.map { DockerConfigFile.registryHost(from: $0) } ?? source?.host ?? "docker.io"
        var repository = parsed.repository
        if host == "docker.io", repository.hasPrefix("library/") { repository = String(repository.dropFirst("library/".count)) }
        let image = RegistryImage(registry: host, repository: repository, isOfficial: host == "docker.io" && !repository.contains("/"))
        let resolved = source.flatMap { $0.host == host ? $0 : nil } ?? RegistrySource(host: host)
        let tags = try await Self.withTimeout(timeout) { try await self.tags(image, in: resolved, page: 1) }
        return RegistryLookup(image: image, tags: tags)
    }

    /// Tags for an image. Docker Hub and Quay page with dates and sizes. Other
    /// registries return every tag name at once (up to 5000).
    public func tags(_ image: RegistryImage, in source: RegistrySource? = nil, page: Int = 1) async throws -> HubPage<HubTag> {
        let source = source ?? RegistrySource(host: image.registry)
        switch source.kind {
        case .dockerHub:
            return try await hub.tags(image.repository, page: page)
        case .quay:
            if let url = QuaySearch.tagsURL(image.repository, page: page),
               let reply = try? await http.get(url, headers: ["Accept": "application/json"]), reply.isSuccess,
               let parsed = try? QuaySearch.parseTags(reply.data, page: page) {
                return parsed
            }
            guard page == 1 else { return HubPage(items: [], nextPage: nil) }
            return try await v2Tags(image, source: source)
        default:
            guard page == 1 else { return HubPage(items: [], nextPage: nil) }
            return try await v2Tags(image, source: source)
        }
    }

    private func v2Tags(_ image: RegistryImage, source: RegistrySource) async throws -> HubPage<HubTag> {
        var credential: RegistryCredential?
        if case .found(let value) = await self.credential(for: source) { credential = value }
        let session = RegistryAPISession(http: http, credential: credential)
        guard var url = RegistryTagList.url(source: source, repository: image.apiRepository) else {
            throw DeckError.network("That is not an image name.")
        }
        var names: [String] = []
        for _ in 0..<RegistryTagList.maxPages {
            let reply = try await session.get(url, scope: "repository:\(image.apiRepository):pull")
            switch reply.status {
            case 200..<300: break
            case 401, 403:
                throw DeckError.network(credential == nil
                    ? "This image needs a sign in. Sign in under Settings, Registries."
                    : "The registry did not allow reading this image's tags.")
            case 404: throw DeckError.network("\(source.displayName) has no image named \(image.repository).")
            default: throw Self.statusError(reply.status, registry: source.displayName)
            }
            guard let page = RegistryTagList.parse(reply.data) else { throw DeckError.parse("\(source.displayName) tags") }
            names += page
            guard !page.isEmpty, let next = RegistryAPISession.nextLink(reply.header("link"), base: url) else { break }
            url = next
        }
        return HubPage(items: RegistryTagList.sorted(names).map { HubTag(name: $0) }, nextPage: nil)
    }

    // MARK: Helpers

    static func statusError(_ status: Int, registry: String) -> DeckError {
        switch status {
        case 429: return .network("\(registry) is limiting requests. Try again in a minute.")
        case 500...599: return .network("\(registry) is having trouble (status \(status)).")
        default: return .network("\(registry) answered with status \(status).")
        }
    }

    static func message(_ error: Error) -> String {
        if let deck = error as? DeckError, case .network(let text) = deck { return text }
        return error.localizedDescription
    }

    struct RegistryTimeout: LocalizedError {
        var errorDescription: String? { "No answer in time." }
    }

    static func withTimeout<T: Sendable>(_ limit: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw RegistryTimeout()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw RegistryTimeout() }
            return first
        }
    }
}
