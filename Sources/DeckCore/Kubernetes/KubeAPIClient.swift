import Foundation
import Security

/// Sends HTTP requests to a Kubernetes API server. Swapped for a mock in tests.
public protocol KubeTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// Lines of a streaming response (pod logs with follow).
    func lines(_ request: URLRequest) -> AsyncThrowingStream<String, Error>
}

/// A small Kubernetes REST client. Reads with the cluster's kubeconfig credentials:
/// the cluster CA, the client certificate or a bearer token.
public struct KubeAPIClient: Sendable {
    public let server: URL
    public let token: String?
    public let transport: any KubeTransport

    public init(server: URL, token: String? = nil, transport: any KubeTransport) {
        self.server = server
        self.token = token
        self.transport = transport
    }

    /// A client for one context of a kubeconfig, with TLS set up from it.
    public static func make(_ file: KubeConfigFile, context: String? = nil) async throws -> KubeAPIClient {
        guard let credentials = file.credentials(context: context) else {
            throw DeckError.commandFailed("The kubeconfig has no context for this cluster.")
        }
        let hasClientCertificate = credentials.clientCertificatePEM != nil && credentials.clientKeyPEM != nil
        guard hasClientCertificate || !(credentials.token ?? "").isEmpty else {
            throw DeckError.commandFailed("The kubeconfig has no credentials yet. The cluster may still be starting.")
        }
        let tls = try await KubeTLS.make(credentials)
        return KubeAPIClient(server: credentials.server, token: credentials.token, transport: URLSessionKubeTransport(tls: tls))
    }

    // MARK: - Requests

    func request(_ path: String, query: [URLQueryItem] = [], method: String = "GET", body: Data? = nil, contentType: String? = nil) -> URLRequest {
        var components = URLComponents(url: server, resolvingAgainstBaseURL: false) ?? URLComponents()
        // Paths come escaped already (see escape), so set them as encoded.
        let base = components.percentEncodedPath.hasSuffix("/") ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath
        components.percentEncodedPath = base + path
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url ?? server)
        request.httpMethod = method
        request.timeoutInterval = KubernetesConfig.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue(contentType ?? "application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    @discardableResult
    func call(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw KubeAPIError.http(response.statusCode, KubeParser.statusMessage(data))
        }
        return data
    }

    /// "/api/v1/pods" or "/api/v1/namespaces/<ns>/pods".
    static func path(_ prefix: String, _ resource: String, namespace: String?) -> String {
        guard let namespace, !namespace.isEmpty else { return "\(prefix)/\(resource)" }
        return "\(prefix)/namespaces/\(escape(namespace))/\(resource)"
    }

    static func escape(_ part: String) -> String {
        part.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? part
    }

    // MARK: - Reads

    public func version() async throws -> String? {
        KubeParser.version(try await call(request("/version")))
    }

    public func namespaces() async throws -> [KubeNamespace] {
        try KubeParser.namespaces(try await call(request("/api/v1/namespaces")))
    }

    public func nodes() async throws -> [KubeNodeStatus] {
        try KubeParser.nodes(try await call(request("/api/v1/nodes")))
    }

    /// nil namespace means all namespaces.
    public func pods(namespace: String? = nil) async throws -> [KubePod] {
        try KubeParser.pods(try await call(request(Self.path("/api/v1", "pods", namespace: namespace))))
    }

    public func deployments(namespace: String? = nil) async throws -> [KubeDeployment] {
        try KubeParser.deployments(try await call(request(Self.path("/apis/apps/v1", "deployments", namespace: namespace))))
    }

    public func services(namespace: String? = nil) async throws -> [KubeService] {
        try KubeParser.services(try await call(request(Self.path("/api/v1", "services", namespace: namespace))))
    }

    public func events(namespace: String? = nil) async throws -> [KubeEvent] {
        try KubeParser.events(try await call(request(Self.path("/api/v1", "events", namespace: namespace))))
    }

    // MARK: - Logs

    func logRequest(namespace: String, pod: String, container: String?, follow: Bool, tail: Int?, sinceTime: String? = nil, timestamps: Bool = false) -> URLRequest {
        var query: [URLQueryItem] = []
        if let container, !container.isEmpty { query.append(URLQueryItem(name: "container", value: container)) }
        if follow { query.append(URLQueryItem(name: "follow", value: "true")) }
        if let tail { query.append(URLQueryItem(name: "tailLines", value: String(tail))) }
        if let sinceTime { query.append(URLQueryItem(name: "sinceTime", value: sinceTime)) }
        query.append(URLQueryItem(name: "timestamps", value: timestamps ? "true" : "false"))
        var req = request("/api/v1/namespaces/\(Self.escape(namespace))/pods/\(Self.escape(pod))/log", query: query)
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        if follow { req.timeoutInterval = 60 * 60 * 24 }
        return req
    }

    /// Log lines of a pod: the last `tail` lines, then with follow every new line the moment
    /// the pod writes it, until cancelled. A dropped connection is opened again without
    /// repeating lines (the stream asks for timestamps and takes them off).
    public func podLogs(namespace: String, pod: String, container: String? = nil, follow: Bool = true, tail: Int? = KubernetesConfig.logTailLines) -> AsyncThrowingStream<String, Error> {
        guard follow else {
            return transport.lines(logRequest(namespace: namespace, pod: pod, container: container, follow: false, tail: tail))
        }
        let transport = self.transport
        let client = self
        return KubeLogFollower.follow { since in
            transport.lines(client.logRequest(
                namespace: namespace, pod: pod, container: container, follow: true,
                tail: since == nil ? tail : nil, sinceTime: since, timestamps: true
            ))
        }
    }

    // MARK: - Changes

    /// Deletes a pod. A pod owned by a deployment or replica set comes back as a new pod,
    /// which is how a single pod is restarted.
    public func deletePod(namespace: String, name: String) async throws {
        try await call(request("/api/v1/namespaces/\(Self.escape(namespace))/pods/\(Self.escape(name))", method: "DELETE"))
    }

    /// Same patch as `kubectl rollout restart deployment/<name>`.
    static func restartPatch(at date: Date) -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: date)
        let json = #"{"spec":{"template":{"metadata":{"annotations":{"kubectl.kubernetes.io/restartedAt":"\#(stamp)"}}}}}"#
        return Data(json.utf8)
    }

    public func restartDeployment(namespace: String, name: String, at date: Date = Date()) async throws {
        try await call(request(
            "/apis/apps/v1/namespaces/\(Self.escape(namespace))/deployments/\(Self.escape(name))",
            method: "PATCH",
            body: Self.restartPatch(at: date),
            contentType: "application/strategic-merge-patch+json"
        ))
    }
}

public enum KubeAPIError: LocalizedError, Equatable {
    case http(Int, String?)
    case unreachable(String)

    public var errorDescription: String? {
        switch self {
        case .http(let code, let message):
            let detail = message.map { " \($0)" } ?? ""
            switch code {
            case 401: return "The cluster did not accept the credentials.\(detail)"
            case 403: return "Not allowed.\(detail)"
            case 404: return "Not found.\(detail)"
            default: return "The Kubernetes API answered \(code).\(detail)"
            }
        case .unreachable(let reason):
            return "Could not reach the Kubernetes API. \(reason)"
        }
    }
}

// MARK: - URLSession transport

/// URLSession with the cluster CA and the client identity for plain requests, and
/// `KubeHTTPStream` for streams.
public final class URLSessionKubeTransport: NSObject, KubeTransport, URLSessionDelegate, @unchecked Sendable {
    private let tls: KubeTLS
    private var sessionMade = false
    private lazy var session: URLSession = {
        sessionMade = true
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = KubernetesConfig.requestTimeout
        config.timeoutIntervalForResource = 60 * 60 * 24
        config.httpMaximumConnectionsPerHost = 8
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    public init(tls: KubeTLS) {
        self.tls = tls
    }

    deinit {
        // Making the lazy session here would hand a dying self to URLSession as its delegate.
        if sessionMade { session.invalidateAndCancel() }
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw KubeAPIError.unreachable("No HTTP response.")
            }
            return (data, http)
        } catch let error as KubeAPIError {
            throw error
        } catch {
            throw KubeAPIError.unreachable(error.localizedDescription)
        }
    }

    /// Streams go over Network.framework, not URLSession, so each line arrives the moment
    /// the server sends it (URLSession holds back the first 512 bytes of text/plain).
    public func lines(_ request: URLRequest) -> AsyncThrowingStream<String, Error> {
        KubeHTTPStream(tls: tls).lines(request)
    }

    public func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard let trust = challenge.protectionSpace.serverTrust,
                  tls.evaluate(trust, host: challenge.protectionSpace.host) else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        case NSURLAuthenticationMethodClientCertificate:
            guard let identity = tls.identity else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
