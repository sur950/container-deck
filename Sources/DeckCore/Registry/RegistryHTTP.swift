import Foundation

/// A registry answer: status, headers (keys lower cased) and body.
public struct RegistryHTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var data: Data

    public init(status: Int, headers: [String: String] = [:], data: Data = Data()) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        self.data = data
    }

    public var isSuccess: Bool { (200..<300).contains(status) }
    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

/// GET requests for registry search. Tests swap in a scripted fake.
public protocol RegistryHTTP: Sendable {
    func get(_ url: URL, headers: [String: String]) async throws -> RegistryHTTPResponse
}

/// URLSession without cookies, cache or saved credentials, so an auth header
/// never outlives the request it was made for.
public struct URLSessionRegistryHTTP: RegistryHTTP {
    let session: URLSession
    let timeout: TimeInterval

    public init(timeout: TimeInterval = 10) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = timeout
        config.httpAdditionalHeaders = ["User-Agent": "ContainerDeck"]
        self.session = URLSession(configuration: config, delegate: RedirectGuard(), delegateQueue: nil)
        self.timeout = timeout
    }

    public func get(_ url: URL, headers: [String: String]) async throws -> RegistryHTTPResponse {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw DeckError.network("The registry did not answer in time.")
        } catch {
            throw DeckError.network(error.localizedDescription)
        }
        guard let http = result.1 as? HTTPURLResponse else {
            throw DeckError.network("The registry sent an answer that is not HTTP.")
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key.lowercased()] = value }
        }
        return RegistryHTTPResponse(status: http.statusCode, headers: headers, data: result.0)
    }
}

/// Drops the Authorization header when a redirect leaves the host, so a login
/// or token is only ever sent where it was meant to go.
final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var next = request
        if let from = task.originalRequest?.url?.host?.lowercased(), from != request.url?.host?.lowercased() {
            next.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(next)
    }
}

// MARK: - Auth challenge

/// A parsed `WWW-Authenticate` header from a registry.
public struct RegistryAuthChallenge: Sendable, Equatable {
    public enum Scheme: String, Sendable { case bearer, basic }

    public var scheme: Scheme
    public var realm: String?
    public var service: String?
    public var scope: String?

    public init(scheme: Scheme, realm: String? = nil, service: String? = nil, scope: String? = nil) {
        self.scheme = scheme
        self.realm = realm
        self.service = service
        self.scope = scope
    }

    /// Parses `Bearer realm="https://auth.docker.io/token",service="registry.docker.io",scope="repository:a/b:pull"`
    /// and `Basic realm="Registry"`. Quoted values may hold commas.
    public static func parse(_ header: String) -> RegistryAuthChallenge? {
        let text = header.trimmingCharacters(in: .whitespacesAndNewlines)
        let split = text.split(separator: " ", maxSplits: 1).map(String.init)
        guard let word = split.first?.lowercased(), let scheme = Scheme(rawValue: word) else { return nil }
        var values: [String: String] = [:]
        if split.count > 1 {
            let rest = Array(split[1])
            var index = 0
            while index < rest.count {
                while index < rest.count, rest[index] == "," || rest[index] == " " { index += 1 }
                var key = ""
                while index < rest.count, rest[index] != "=" { key.append(rest[index]); index += 1 }
                index += 1
                var value = ""
                if index < rest.count, rest[index] == "\"" {
                    index += 1
                    while index < rest.count, rest[index] != "\"" {
                        if rest[index] == "\\", index + 1 < rest.count { index += 1 }
                        value.append(rest[index])
                        index += 1
                    }
                    index += 1
                } else {
                    while index < rest.count, rest[index] != "," { value.append(rest[index]); index += 1 }
                }
                let name = key.trimmingCharacters(in: .whitespaces).lowercased()
                if !name.isEmpty { values[name] = value.trimmingCharacters(in: .whitespaces) }
            }
        }
        return RegistryAuthChallenge(scheme: scheme, realm: values["realm"], service: values["service"], scope: values["scope"])
    }

    /// The token endpoint with service and scope. nil for Basic or a bad realm.
    public func tokenURL(scope fallbackScope: String?) -> URL? {
        guard scheme == .bearer, let realm, var components = URLComponents(string: realm),
              let urlScheme = components.scheme?.lowercased(), urlScheme == "https" || urlScheme == "http" else { return nil }
        var items = components.queryItems ?? []
        if let service, !service.isEmpty { items.append(URLQueryItem(name: "service", value: service)) }
        if let value = scope ?? fallbackScope, !value.isEmpty {
            // Several scopes are sent as several "scope" parameters.
            for part in value.split(separator: " ") { items.append(URLQueryItem(name: "scope", value: String(part))) }
        }
        components.queryItems = items.isEmpty ? nil : items
        return components.url
    }

    /// Reads `{"token": ...}` or `{"access_token": ...}` from a token endpoint.
    public static func parseToken(_ data: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let token = object["token"] as? String ?? object["access_token"] as? String
        return CLIText.nonEmpty(token)
    }
}

// MARK: - Registry API session

/// Makes registry API calls with the standard auth flow:
/// try without auth, read the `WWW-Authenticate` challenge on a 401, then
/// fetch a bearer token (with basic credentials when signed in) or send basic
/// credentials, and try again. Credentials stay in memory for one call and are
/// never logged.
public struct RegistryAPISession: Sendable {
    let http: any RegistryHTTP
    let credential: RegistryCredential?

    public init(http: any RegistryHTTP, credential: RegistryCredential?) {
        self.http = http
        self.credential = credential
    }

    /// GET `url`. `scope` is the token scope to ask for when the challenge has none,
    /// like "repository:org/app:pull" or "registry:catalog:*".
    public func get(_ url: URL, scope: String?, accept: String = "application/json") async throws -> RegistryHTTPResponse {
        let first = try await http.get(url, headers: ["Accept": accept])
        guard first.status == 401, let header = first.header("www-authenticate"),
              let challenge = RegistryAuthChallenge.parse(header) else {
            return first
        }
        switch challenge.scheme {
        case .basic:
            guard let credential else { return first }
            return try await http.get(url, headers: ["Accept": accept, "Authorization": credential.basicHeader])
        case .bearer:
            guard let tokenURL = challenge.tokenURL(scope: scope) else { return first }
            var tokenHeaders = ["Accept": "application/json"]
            if let credential { tokenHeaders["Authorization"] = credential.basicHeader }
            let tokenReply = try await http.get(tokenURL, headers: tokenHeaders)
            guard tokenReply.isSuccess, let token = RegistryAuthChallenge.parseToken(tokenReply.data) else {
                // The token service said no: report it like the registry did.
                return RegistryHTTPResponse(status: tokenReply.status == 200 ? 401 : tokenReply.status, headers: first.headers, data: tokenReply.data)
            }
            return try await http.get(url, headers: ["Accept": accept, "Authorization": "Bearer \(token)"])
        }
    }

    /// The `rel="next"` target of a `Link` header, made absolute against `base`.
    public static func nextLink(_ header: String?, base: URL) -> URL? {
        guard let header else { return nil }
        for part in header.split(separator: ",") {
            let text = String(part)
            guard text.contains("rel=\"next\"") || text.contains("rel=next"),
                  let open = text.firstIndex(of: "<"), let close = text.firstIndex(of: ">"), open < close else { continue }
            let target = String(text[text.index(after: open)..<close])
            return URL(string: target, relativeTo: base)?.absoluteURL
        }
        return nil
    }
}
