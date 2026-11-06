import Foundation

/// The head of one request sent to the allow list proxy. Pure parsing, no I/O.
public struct ProxyRequest: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// `CONNECT host:port` (HTTPS and other TLS).
        case tunnel
        /// `GET http://host/path` (plain HTTP).
        case http
    }

    public var kind: Kind
    public var method: String
    public var host: String
    public var port: Int
    /// Path and query for plain HTTP (origin form). Empty for tunnels.
    public var path: String
    public var version: String
    /// Header lines as sent, in order.
    public var headers: [(name: String, value: String)]
    /// Bytes of the head including the blank line.
    public var headLength: Int

    public static func == (lhs: ProxyRequest, rhs: ProxyRequest) -> Bool {
        lhs.kind == rhs.kind && lhs.method == rhs.method && lhs.host == rhs.host && lhs.port == rhs.port
            && lhs.path == rhs.path && lhs.version == rhs.version && lhs.headLength == rhs.headLength
            && lhs.headers.map { "\($0.name):\($0.value)" } == rhs.headers.map { "\($0.name):\($0.value)" }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(method)
        hasher.combine(host)
        hasher.combine(port)
        hasher.combine(path)
    }

    public enum ParseResult: Sendable {
        /// The blank line was not seen yet. Read more.
        case incomplete
        case request(ProxyRequest)
        /// Status code and short reason to send back.
        case invalid(Int, String)
    }

    private static let terminator = Data("\r\n\r\n".utf8)

    /// Parses the bytes read so far.
    public static func parse(_ data: Data, maxHead: Int = SandboxConfig.maxRequestHead) -> ParseResult {
        guard let end = data.range(of: terminator) else {
            return data.count > maxHead ? .invalid(431, "Request Header Fields Too Large") : .incomplete
        }
        let headLength = end.upperBound - data.startIndex
        guard headLength <= maxHead else { return .invalid(431, "Request Header Fields Too Large") }
        guard let text = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else {
            return .invalid(400, "Bad Request")
        }
        var lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/") else { return .invalid(400, "Bad Request") }
        let method = parts[0].uppercased()
        let target = parts[1]
        var headers: [(String, String)] = []
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .invalid(400, "Bad Request") }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }

        if method == "CONNECT" {
            guard let (host, port) = splitHostPort(target), let port else { return .invalid(400, "Bad Request") }
            return .request(ProxyRequest(kind: .tunnel, method: method, host: host, port: port, path: "",
                                         version: parts[2], headers: headers, headLength: headLength))
        }
        guard let url = URLComponents(string: target), url.scheme?.lowercased() == "http",
              let host = url.host, !host.isEmpty else {
            // Origin form ("GET /x") means the client did not treat us as a proxy, and
            // https:// targets must come as CONNECT.
            return .invalid(400, "Bad Request")
        }
        var path = url.percentEncodedPath.isEmpty ? "/" : url.percentEncodedPath
        if let query = url.percentEncodedQuery { path += "?" + query }
        return .request(ProxyRequest(kind: .http, method: method, host: host.lowercased(), port: url.port ?? 80, path: path,
                                     version: parts[2], headers: headers, headLength: headLength))
    }

    /// The head to send to the origin for plain HTTP: origin form target, proxy headers
    /// removed, one request per connection.
    public func originHead() -> Data {
        let dropped: Set<String> = ["proxy-connection", "proxy-authorization", "connection", "keep-alive"]
        var lines = ["\(method) \(path) \(version)"]
        var hasHost = false
        for header in headers where !dropped.contains(header.name.lowercased()) {
            if header.name.lowercased() == "host" { hasHost = true }
            lines.append("\(header.name): \(header.value)")
        }
        if !hasHost { lines.append("Host: \(port == 80 ? host : "\(host):\(port)")") }
        lines.append("Connection: close")
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    /// A small response the proxy sends itself (errors, blocked hosts, tunnel ready).
    public static func response(_ status: Int, _ reason: String, body: String? = nil) -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        if let body {
            head += "Content-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
        } else {
            head += "\r\n"
        }
        return Data(head.utf8)
    }

    static func splitHostPort(_ value: String) -> (String, Int?)? {
        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]") else { return nil }
            let host = String(value[value.index(after: value.startIndex)..<close])
            let rest = value[value.index(after: close)...]
            guard rest.hasPrefix(":") else { return (host.lowercased(), nil) }
            return (host.lowercased(), Int(rest.dropFirst()))
        }
        guard let colon = value.lastIndex(of: ":") else { return (value.lowercased(), nil) }
        let host = String(value[..<colon])
        guard !host.isEmpty, let port = Int(value[value.index(after: colon)...]), (1...65535).contains(port) else { return nil }
        return (host.lowercased(), port)
    }
}
