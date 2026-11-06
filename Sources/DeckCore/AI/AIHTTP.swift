import Foundation

/// Small HTTP layer for the Local AI feature. Swapped for a fake in tests.
public protocol AIHTTPFetching: Sendable {
    /// Sends a request and returns the body and status code. Throws on connection errors and time outs.
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

public extension AIHTTPFetching {
    func get(_ url: URL, timeout: TimeInterval) async throws -> (Data, Int) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        return try await send(request)
    }

    /// POSTs a JSON body. Throws on a non 2xx answer with the server's error text.
    @discardableResult
    func postJSON(_ url: URL, body: [String: Any], timeout: TimeInterval = 30) async throws -> Data {
        try await sendJSON(url, method: "POST", body: body, timeout: timeout)
    }

    @discardableResult
    func sendJSON(_ url: URL, method: String, body: [String: Any], timeout: TimeInterval = 30) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, status) = try await send(request)
        guard (200..<300).contains(status) else {
            throw DeckError.commandFailed(AIHTTP.errorMessage(data, status: status))
        }
        return data
    }
}

/// URLSession based fetcher. Its own session, so local probes never wait on the shared one.
public struct AIHTTPClient: AIHTTPFetching {
    let session: URLSession

    public init(session: URLSession = AIHTTP.session) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

public enum AIHTTP {
    /// Ephemeral session: no cookies, no cache, no proxies for local addresses.
    public static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.httpMaximumConnectionsPerHost = 8
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// Best error text from a JSON error body ({"error": "..."} or {"error": {"message": "..."}}).
    public static func errorMessage(_ data: Data, status: Int) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let text = object["error"] as? String, !text.isEmpty { return text }
            if let inner = object["error"] as? [String: Any], let text = inner["message"] as? String, !text.isEmpty { return text }
            if let text = object["message"] as? String, !text.isEmpty { return text }
            if let text = object["detail"] as? String, !text.isEmpty { return text }
        }
        let text = String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "The server answered with status \(status)." : text
    }

    /// "http://127.0.0.1:8585" plus a path.
    static func url(host: String, port: Int, path: String) -> URL? {
        let shownHost = host.contains(":") ? "[\(host)]" : host
        return URL(string: "http://\(shownHost):\(port)\(path)")
    }
}
