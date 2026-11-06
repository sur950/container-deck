import Foundation
import Network
import Security

// Streaming reads from the Kubernetes API (pod logs with follow) without URLSession.
//
// URLSession holds back the first 512 bytes of a text/plain response before it hands any
// data to the app (content sniffing), so a quiet pod's new log lines showed up late or
// not at all. This speaks HTTP/1.1 over Network.framework with the cluster's TLS setup
// and hands every chunk on as soon as it arrives.

public enum KubeStreamError: LocalizedError, Equatable {
    /// The connection closed before the response was complete.
    case truncated
    /// The server sent something that is not HTTP/1.1.
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .truncated: return "The connection to the Kubernetes API closed early."
        case .malformed(let detail): return "The Kubernetes API sent a reply the app could not read. \(detail)"
        }
    }
}

// MARK: - HTTP/1.1 response decoder

/// Status line and headers of a response. Header names are lowercased.
public struct KubeHTTPHead: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]

    public var isSuccess: Bool { (200..<300).contains(status) }
}

public enum KubeHTTPEvent: Sendable, Equatable {
    case head(KubeHTTPHead)
    case body(Data)
    /// The response is complete (last chunk, full length, or close for bodies without a length).
    case end
}

/// Reads an HTTP/1.1 response from bytes that arrive in any split: the head, then the body
/// as chunked, fixed length or until close. Pure, so it is easy to test.
public struct KubeHTTPDecoder: Sendable {
    private enum Mode: Sendable {
        case head
        case chunkSize
        case chunkData(Int)
        case chunkDataEnd
        case trailers
        case fixed(Int)
        case untilClose
        case done
    }

    private var mode: Mode = .head
    private var buffer: [UInt8] = []
    /// Largest head or chunk size line accepted.
    static let maxLine = 64 * 1024

    public init() {}

    public var isDone: Bool {
        if case .done = mode { return true }
        return false
    }

    /// Feeds bytes and returns what they completed.
    public mutating func feed(_ data: Data) throws -> [KubeHTTPEvent] {
        guard !data.isEmpty else { return [] }
        buffer.append(contentsOf: data)
        var events: [KubeHTTPEvent] = []
        var index = 0
        loop: while index < buffer.count {
            switch mode {
            case .done:
                index = buffer.count
            case .head:
                guard let end = Self.find([13, 10, 13, 10], in: buffer, from: index) else {
                    if buffer.count - index > Self.maxLine { throw KubeStreamError.malformed("The reply head is too long.") }
                    break loop
                }
                let head = try Self.parseHead(Array(buffer[index..<end]))
                index = end + 4
                // 1xx answers come before the real one.
                if (100..<200).contains(head.status) { continue }
                events.append(.head(head))
                if let encoding = head.headers["transfer-encoding"], encoding.lowercased().contains("chunked") {
                    mode = .chunkSize
                } else if let lengthText = head.headers["content-length"] {
                    guard let length = Int(lengthText.trimmingCharacters(in: .whitespaces)), length >= 0 else {
                        throw KubeStreamError.malformed("Bad content length.")
                    }
                    if length == 0 {
                        mode = .done
                        events.append(.end)
                    } else {
                        mode = .fixed(length)
                    }
                } else if head.status == 204 || head.status == 304 {
                    mode = .done
                    events.append(.end)
                } else {
                    mode = .untilClose
                }
            case .chunkSize:
                guard let end = Self.find([13, 10], in: buffer, from: index) else {
                    if buffer.count - index > Self.maxLine { throw KubeStreamError.malformed("Bad chunk size.") }
                    break loop
                }
                let line = String(decoding: buffer[index..<end], as: UTF8.self)
                index = end + 2
                let sizeText = line.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
                guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else {
                    throw KubeStreamError.malformed("Bad chunk size \"\(line)\".")
                }
                mode = size == 0 ? .trailers : .chunkData(size)
            case .chunkData(let remaining):
                let take = min(remaining, buffer.count - index)
                if take > 0 {
                    events.append(.body(Data(buffer[index..<(index + take)])))
                    index += take
                }
                mode = remaining - take == 0 ? .chunkDataEnd : .chunkData(remaining - take)
            case .chunkDataEnd:
                guard buffer.count - index >= 2 else { break loop }
                guard buffer[index] == 13, buffer[index + 1] == 10 else {
                    throw KubeStreamError.malformed("A chunk did not end with CRLF.")
                }
                index += 2
                mode = .chunkSize
            case .trailers:
                guard let end = Self.find([13, 10], in: buffer, from: index) else {
                    if buffer.count - index > Self.maxLine { throw KubeStreamError.malformed("Trailers are too long.") }
                    break loop
                }
                let empty = end == index
                index = end + 2
                if empty {
                    mode = .done
                    events.append(.end)
                }
            case .fixed(let remaining):
                let take = min(remaining, buffer.count - index)
                if take > 0 {
                    events.append(.body(Data(buffer[index..<(index + take)])))
                    index += take
                }
                if remaining - take == 0 {
                    mode = .done
                    events.append(.end)
                } else {
                    mode = .fixed(remaining - take)
                }
            case .untilClose:
                events.append(.body(Data(buffer[index...])))
                index = buffer.count
            }
        }
        buffer.removeFirst(min(index, buffer.count))
        return events
    }

    /// The connection closed. A body read until close ends here, anything else unfinished
    /// is an early close.
    public mutating func finish() throws -> [KubeHTTPEvent] {
        switch mode {
        case .done:
            return []
        case .untilClose:
            mode = .done
            return [.end]
        default:
            throw KubeStreamError.truncated
        }
    }

    static func find(_ needle: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
        guard bytes.count >= needle.count, start <= bytes.count - needle.count else { return nil }
        var i = start
        let last = bytes.count - needle.count
        while i <= last {
            if bytes[i] == needle[0] {
                var match = true
                for j in 1..<needle.count where bytes[i + j] != needle[j] {
                    match = false
                    break
                }
                if match { return i }
            }
            i += 1
        }
        return nil
    }

    static func parseHead(_ bytes: [UInt8]) throws -> KubeHTTPHead {
        let text = String(decoding: bytes, as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw KubeStreamError.malformed("Empty reply.") }
        let statusLine = lines.removeFirst()
        let parts = statusLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), let status = Int(parts[1]) else {
            throw KubeStreamError.malformed("Bad status line \"\(statusLine.prefix(80))\".")
        }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }
        return KubeHTTPHead(status: status, headers: headers)
    }
}

// MARK: - Line splitting

/// Splits bytes into lines on "\n" as they arrive. A line split across chunks (even
/// inside a multi byte character) comes out whole.
public struct KubeLineSplitter: Sendable {
    private var pending: [UInt8] = []

    public init() {}

    public mutating func feed(_ data: Data) -> [String] {
        var lines: [String] = []
        for byte in data {
            if byte == 10 {
                lines.append(Self.text(pending))
                pending.removeAll(keepingCapacity: true)
            } else {
                pending.append(byte)
            }
        }
        return lines
    }

    /// What is left after the last newline, at the end of the stream.
    public mutating func flush() -> String? {
        guard !pending.isEmpty else { return nil }
        defer { pending.removeAll() }
        return Self.text(pending)
    }

    private static func text(_ bytes: [UInt8]) -> String {
        var slice = bytes[...]
        if slice.last == 13 { slice = slice.dropLast() }
        return String(decoding: slice, as: UTF8.self)
    }
}

// MARK: - Network.framework connection

/// One streaming HTTP/1.1 request over Network.framework, with the cluster CA and the
/// client identity from `KubeTLS`. Lines are handed on the moment their chunk arrives.
public final class KubeHTTPStream: @unchecked Sendable {
    private let tls: KubeTLS?
    private let connectTimeout: TimeInterval

    /// nil TLS only for plain http URLs (tests).
    public init(tls: KubeTLS?, connectTimeout: TimeInterval = KubernetesConfig.requestTimeout) {
        self.tls = tls
        self.connectTimeout = connectTimeout
    }

    /// The bytes of the request head and body.
    static func requestData(_ request: URLRequest) -> Data? {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = url.host else { return nil }
        var target = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery, !query.isEmpty { target += "?" + query }
        let method = request.httpMethod ?? "GET"
        let hostHeader: String = {
            let bracketed = host.contains(":") ? "[\(host)]" : host
            guard let port = url.port else { return bracketed }
            return "\(bracketed):\(port)"
        }()
        var headers: [(String, String)] = [("Host", hostHeader)]
        var seen: Set<String> = ["host"]
        for (name, value) in (request.allHTTPHeaderFields ?? [:]).sorted(by: { $0.key < $1.key }) {
            let lower = name.lowercased()
            guard !seen.contains(lower), !value.contains("\r"), !value.contains("\n") else { continue }
            seen.insert(lower)
            headers.append((name, value))
        }
        for (name, value) in [("User-Agent", AppConfig.appName), ("Accept-Encoding", "identity"), ("Connection", "close")]
        where !seen.contains(name.lowercased()) {
            headers.append((name, value))
        }
        if let body = request.httpBody {
            headers.append(("Content-Length", String(body.count)))
        }
        var text = "\(method) \(target) HTTP/1.1\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        text += "\r\n"
        var data = Data(text.utf8)
        if let body = request.httpBody { data.append(body) }
        return data
    }

    /// TCP and TLS settings: the cluster CA as the only trust anchor, the client identity
    /// when the kubeconfig has one, HTTP/1.1 only, no proxies.
    static func parameters(tls: KubeTLS?, host: String, queue: DispatchQueue) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        let parameters: NWParameters
        if let tls {
            let options = NWProtocolTLS.Options()
            let sec = options.securityProtocolOptions
            sec_protocol_options_add_tls_application_protocol(sec, "http/1.1")
            if let identity = tls.identity, let secIdentity = sec_identity_create(identity) {
                sec_protocol_options_set_local_identity(sec, secIdentity)
            }
            sec_protocol_options_set_verify_block(sec, { _, trust, complete in
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                complete(tls.evaluate(secTrust, host: host))
            }, queue)
            parameters = NWParameters(tls: options, tcp: tcp)
        } else {
            parameters = NWParameters(tls: nil, tcp: tcp)
        }
        parameters.preferNoProxies = true
        return parameters
    }

    /// Raw body bytes of a response, as they arrive. Throws `KubeAPIError.http` for an
    /// error status, with the API's message.
    public func bytes(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            guard let url = request.url, let host = url.host,
                  let payload = Self.requestData(request) else {
                continuation.finish(throwing: KubeAPIError.unreachable("Bad request address."))
                return
            }
            let secure = url.scheme?.lowercased() != "http"
            let port = url.port ?? (secure ? 443 : 80)
            guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
                continuation.finish(throwing: KubeAPIError.unreachable("Bad port \(port)."))
                return
            }
            let queue = DispatchQueue(label: "\(AppConfig.bundleID).kube-stream")
            let parameters = Self.parameters(tls: secure ? (tls ?? KubeTLS(anchor: nil, identity: nil, insecure: false)) : nil, host: host, queue: queue)
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
            let session = StreamSession(connection: connection, continuation: continuation, queue: queue)
            continuation.onTermination = { _ in session.cancel() }
            session.start(payload: payload, connectTimeout: connectTimeout)
        }
    }

    /// Body lines of a response, one per "\n", handed on as soon as each one is complete.
    public func lines(_ request: URLRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var splitter = KubeLineSplitter()
                do {
                    for try await data in bytes(request) {
                        for line in splitter.feed(data) { continuation.yield(line) }
                    }
                    if let rest = splitter.flush() { continuation.yield(rest) }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// State of one connection. Every handler runs on `queue`.
private final class StreamSession: @unchecked Sendable {
    let connection: NWConnection
    let continuation: AsyncThrowingStream<Data, Error>.Continuation
    let queue: DispatchQueue
    private var decoder = KubeHTTPDecoder()
    private var head: KubeHTTPHead?
    private var errorBody = Data()
    private var finished = false
    private var ready = false

    init(connection: NWConnection, continuation: AsyncThrowingStream<Data, Error>.Continuation, queue: DispatchQueue) {
        self.connection = connection
        self.continuation = continuation
        self.queue = queue
    }

    func start(payload: Data, connectTimeout: TimeInterval) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.ready = true
                self.connection.send(content: payload, completion: .contentProcessed { [weak self] error in
                    if let error { self?.fail(KubeAPIError.unreachable(error.localizedDescription)) }
                })
                self.receive()
            case .waiting(let error), .failed(let error):
                self.fail(KubeAPIError.unreachable(Self.describe(error)))
            case .cancelled:
                self.complete(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + connectTimeout) { [weak self] in
            guard let self, !self.ready, !self.finished else { return }
            self.fail(KubeAPIError.unreachable("The connection timed out."))
        }
    }

    static func describe(_ error: NWError) -> String {
        switch error {
        case .tls(let status): return "TLS failed (\(status)). The cluster certificate may have changed."
        case .posix(let code) where code == .ECONNREFUSED: return "Connection refused. The cluster may be stopped."
        default: return error.localizedDescription
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.finished else { return }
            do {
                if let data, !data.isEmpty {
                    try self.handle(self.decoder.feed(data))
                }
                if self.finished { return }
                if isComplete {
                    try self.handle(self.decoder.finish())
                    return
                }
                if let error {
                    self.fail(KubeAPIError.unreachable(Self.describe(error)))
                    return
                }
                self.receive()
            } catch {
                self.fail(error)
            }
        }
    }

    private func handle(_ events: [KubeHTTPEvent]) throws {
        for event in events {
            switch event {
            case .head(let value):
                head = value
            case .body(let data):
                if head?.isSuccess == true {
                    continuation.yield(data)
                } else if errorBody.count < 64_000 {
                    errorBody.append(data)
                }
            case .end:
                if let head, !head.isSuccess {
                    let message = KubeParser.statusMessage(errorBody)
                        ?? String(decoding: errorBody, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    fail(KubeAPIError.http(head.status, message.isEmpty ? nil : message))
                } else {
                    complete(nil)
                }
                return
            }
        }
    }

    private func fail(_ error: Error) {
        complete(error)
    }

    private func complete(_ error: Error?) {
        guard !finished else { return }
        finished = true
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    func cancel() {
        queue.async { [weak self] in self?.complete(nil) }
    }
}

// MARK: - Follow with reconnect

/// Keeps a follow stream going when the connection drops: opens it again with
/// `sinceTime` set to the last line's timestamp and skips lines already shown.
/// Lines come with Kubernetes timestamps ("2026-11-06T05:04:56.099105123Z text"),
/// which are taken off before they are handed on.
public enum KubeLogFollower {
    /// Tries after a dropped connection before giving up. Reset by every line.
    public static let maxRetries = 5

    /// Splits "2026-11-06T05:04:56.099105123Z text" into the timestamp and the text.
    /// A line without a timestamp comes back as is.
    public static func split(_ line: String) -> (stamp: String?, text: String) {
        guard let space = line.firstIndex(of: " ") else {
            return normalized(line) != nil ? (line, "") : (nil, line)
        }
        let stamp = String(line[..<space])
        guard normalized(stamp) != nil else { return (nil, line) }
        return (stamp, String(line[line.index(after: space)...]))
    }

    /// RFC 3339 time with the fraction padded to 9 digits, so stamps sort as text.
    /// nil when it is not a timestamp.
    public static func normalized(_ stamp: String) -> String? {
        guard stamp.count >= 20, stamp.hasSuffix("Z") else { return nil }
        let body = stamp.dropLast()
        let parts = body.split(separator: ".", maxSplits: 1)
        let seconds = String(parts[0])
        guard seconds.count == 19,
              seconds.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$"#, options: .regularExpression) != nil else { return nil }
        var fraction = parts.count > 1 ? String(parts[1]) : ""
        guard fraction.count <= 9, fraction.allSatisfy(\.isNumber) else { return nil }
        fraction += String(repeating: "0", count: 9 - fraction.count)
        return "\(seconds).\(fraction)Z"
    }

    /// True for errors where opening the stream again can help.
    public static func isRetryable(_ error: Error) -> Bool {
        if let stream = error as? KubeStreamError { return stream == .truncated }
        if let api = error as? KubeAPIError {
            if case .unreachable = api { return true }
            return false
        }
        if let url = error as? URLError {
            return [.networkConnectionLost, .timedOut, .cannotConnectToHost, .notConnectedToInternet].contains(url.code)
        }
        return false
    }

    /// Follows a log. `open(since)` opens the stream, with nil the first time.
    public static func follow(
        maxRetries: Int = maxRetries,
        delay: @escaping @Sendable (Int) async throws -> Void = { attempt in
            try await Task.sleep(for: .milliseconds(min(8000, 500 << max(0, attempt - 1))))
        },
        open: @escaping @Sendable (String?) -> AsyncThrowingStream<String, Error>
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var lastStamp: String?
                var lastKey: String?
                /// Texts already shown with the last timestamp, skipped once after a reconnect.
                var shownAtLast: [String] = []
                var failures = 0
                while !Task.isCancelled {
                    var toSkip = shownAtLast
                    var skipping = lastKey != nil
                    do {
                        for try await line in open(lastStamp) {
                            let (stamp, text) = split(line)
                            guard let stamp, let key = normalized(stamp) else {
                                continuation.yield(line)
                                continue
                            }
                            if skipping, let lastKey {
                                if key < lastKey { continue }
                                if key == lastKey, let index = toSkip.firstIndex(of: text) {
                                    toSkip.remove(at: index)
                                    continue
                                }
                                skipping = false
                            }
                            failures = 0
                            if key != lastKey {
                                lastKey = key
                                lastStamp = stamp
                                shownAtLast = []
                            }
                            shownAtLast.append(text)
                            continuation.yield(text)
                        }
                        continuation.finish()
                        return
                    } catch is CancellationError {
                        continuation.finish()
                        return
                    } catch {
                        if Task.isCancelled {
                            continuation.finish()
                            return
                        }
                        failures += 1
                        guard isRetryable(error), failures <= maxRetries else {
                            continuation.finish(throwing: error)
                            return
                        }
                        do { try await delay(failures) } catch {
                            continuation.finish()
                            return
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
