import Foundation

/// One HTTP answer with its headers. Registry digests come only in a header.
public struct HTTPReply: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// Header lookup without caring about case.
    public func header(_ name: String) -> String? {
        let lower = name.lowercased()
        return headers.first { $0.key.lowercased() == lower }?.value
    }
}

/// Small HTTP seam for the component checks, so tests never touch the network.
public protocol ComponentHTTPFetching: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPReply
}

public extension ComponentHTTPFetching {
    func get(_ url: URL, headers: [String: String] = [:], timeout: TimeInterval = 15) async throws -> HTTPReply {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("ContainerDeck", forHTTPHeaderField: "User-Agent")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return try await send(request)
    }
}

/// URLSession, ephemeral (no cookies, no cache on disk), no tokens.
public struct URLSessionComponentHTTP: ComponentHTTPFetching {
    let session: URLSession

    public init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> HTTPReply {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DeckError.network("No HTTP answer.") }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        return HTTPReply(status: http.statusCode, headers: headers, body: data)
    }
}

/// Reads the digest an image tag points to in its registry, the way `container image pull` would
/// resolve it: a HEAD on the manifest (no pull counted on Docker Hub), with an anonymous token
/// when the registry asks for one. Public images only, no stored logins.
public struct RegistryDigestReader: Sendable {
    let http: any ComponentHTTPFetching

    public init(http: any ComponentHTTPFetching = URLSessionComponentHTTP()) {
        self.http = http
    }

    static let acceptHeader = [
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.docker.distribution.manifest.v2+json"
    ].joined(separator: ", ")

    /// Manifest URL for a reference, like https://registry-1.docker.io/v2/library/nginx/manifests/latest.
    public static func manifestURL(_ reference: PullReference) -> URL? {
        var host = reference.effectiveRegistry
        var path = reference.repository
        if reference.isDockerHub {
            host = "registry-1.docker.io"
            if !path.contains("/") { path = "library/" + path }
        }
        let tag = reference.digest ?? reference.tag ?? "latest"
        return URL(string: "https://\(host)/v2/\(path)/manifests/\(tag)")
    }

    /// `Bearer realm="https://auth.docker.io/token",service="registry.docker.io",scope="repository:x:pull"`.
    public static func bearerChallenge(_ header: String) -> (realm: URL, service: String?, scope: String?)? {
        guard header.lowercased().hasPrefix("bearer ") else { return nil }
        var values: [String: String] = [:]
        let body = header.dropFirst("bearer ".count)
        guard let regex = try? NSRegularExpression(pattern: #"(\w+)="([^"]*)""#) else { return nil }
        let text = String(body)
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            values[ns.substring(with: match.range(at: 1)).lowercased()] = ns.substring(with: match.range(at: 2))
        }
        guard let realmText = values["realm"], let realm = URL(string: realmText) else { return nil }
        return (realm, values["service"], values["scope"])
    }

    /// The token URL for a challenge.
    public static func tokenURL(realm: URL, service: String?, scope: String?) -> URL? {
        guard var components = URLComponents(url: realm, resolvingAgainstBaseURL: false) else { return nil }
        var items = components.queryItems ?? []
        if let service { items.append(URLQueryItem(name: "service", value: service)) }
        if let scope { items.append(URLQueryItem(name: "scope", value: scope)) }
        components.queryItems = items.isEmpty ? nil : items
        return components.url
    }

    /// `{"token": "..."}` or `{"access_token": "..."}`.
    public static func token(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (object["token"] as? String) ?? (object["access_token"] as? String)
    }

    /// The digest the tag points to now, like "sha256:1a7a...". Throws when the registry cannot be read.
    public func digest(of image: String) async throws -> String {
        guard let reference = PullReference.parse(image), let url = Self.manifestURL(reference) else {
            throw DeckError.parse("the image name \(image)")
        }
        if let digest = reference.digest { return digest }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "HEAD"
        request.setValue(Self.acceptHeader, forHTTPHeaderField: "Accept")
        var reply = try await http.send(request)
        if reply.status == 401, let challenge = reply.header("WWW-Authenticate").flatMap(Self.bearerChallenge),
           let tokenURL = Self.tokenURL(realm: challenge.realm, service: challenge.service, scope: challenge.scope) {
            let tokenReply = try await http.get(tokenURL)
            guard tokenReply.status == 200, let token = Self.token(tokenReply.body) else {
                throw DeckError.network("The registry did not give a token for \(image).")
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            reply = try await http.send(request)
        }
        guard reply.status == 200, let digest = reply.header("Docker-Content-Digest"), digest.hasPrefix("sha256:") else {
            throw DeckError.network("The registry answered \(reply.status) for \(image).")
        }
        return digest
    }
}
