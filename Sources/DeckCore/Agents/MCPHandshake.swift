import Foundation

/// What a server said in the MCP initialize handshake.
public struct MCPHandshakeResult: Sendable, Equatable {
    public var serverName: String
    public var serverVersion: String
    public var protocolVersion: String
    public var toolCount: Int?
    public var milliseconds: Int

    public init(serverName: String, serverVersion: String, protocolVersion: String, toolCount: Int?, milliseconds: Int) {
        self.serverName = serverName
        self.serverVersion = serverVersion
        self.protocolVersion = protocolVersion
        self.toolCount = toolCount
        self.milliseconds = milliseconds
    }

    public var summary: String {
        var text = "\(serverName) \(serverVersion)".trimmingCharacters(in: .whitespaces)
        if let toolCount { text += ", \(toolCount) \(toolCount == 1 ? "tool" : "tools")" }
        return text
    }
}

public enum MCPHandshakeError: Error, LocalizedError, Equatable {
    case timeout
    case http(Int)
    case badResponse(String)
    case serverError(String)
    case exited(String)

    public var errorDescription: String? {
        switch self {
        case .timeout: return "The server did not answer in time."
        case .http(let code): return "The server answered HTTP \(code)."
        case .badResponse(let detail): return "The answer was not an MCP initialize result. \(detail)"
        case .serverError(let message): return "The server returned an error: \(message)"
        case .exited(let detail): return detail.isEmpty ? "The server stopped before it answered." : "The server stopped before it answered. \(detail)"
        }
    }
}

/// Runs the MCP initialize handshake (then `tools/list`) over HTTP, SSE or stdio.
public enum MCPHandshake {
    static let clientInfo: [String: Any] = ["name": AppConfig.appName, "version": "2"]

    public static func initializeMessage(id: Int = 1) -> Data {
        let message: [String: Any] = [
            "jsonrpc": "2.0", "id": id, "method": "initialize",
            "params": ["protocolVersion": AgentsConfig.protocolVersion, "capabilities": [String: Any](), "clientInfo": clientInfo],
        ]
        return (try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])) ?? Data()
    }

    static let initializedNotification = Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
    static func toolsListMessage(id: Int = 2) -> Data { Data(#"{"jsonrpc":"2.0","id":\#(id),"method":"tools/list","params":{}}"#.utf8) }

    /// Reads the JSON-RPC message with this id from a JSON body or an SSE body.
    static func message(id: Int, in body: Data, contentType: String?) -> [String: Any]? {
        let candidates: [Data]
        if (contentType ?? "").contains("text/event-stream") {
            candidates = sseDataPayloads(String(decoding: body, as: UTF8.self)).map { Data($0.utf8) }
        } else {
            candidates = [body]
        }
        for data in candidates {
            guard let object = try? JSONSerialization.jsonObject(with: data) else { continue }
            let messages = (object as? [[String: Any]]) ?? [(object as? [String: Any]) ?? [:]]
            if let match = messages.first(where: { ($0["id"] as? Int) == id || ($0["id"] as? String) == String(id) }) {
                return match
            }
        }
        return nil
    }

    /// `data:` payloads of each event in an SSE text.
    public static func sseDataPayloads(_ text: String) -> [String] {
        var payloads: [String] = []
        var current: [String] = []
        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.isEmpty {
                if !current.isEmpty { payloads.append(current.joined(separator: "\n")); current = [] }
            } else if line.hasPrefix("data:") {
                current.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
        }
        if !current.isEmpty { payloads.append(current.joined(separator: "\n")) }
        return payloads
    }

    /// Server name, version and protocol from an initialize response.
    public static func parseInitialize(_ message: [String: Any]) throws -> (String, String, String) {
        if let error = message["error"] as? [String: Any] {
            throw MCPHandshakeError.serverError(error["message"] as? String ?? "unknown")
        }
        guard let result = message["result"] as? [String: Any],
              let protocolVersion = result["protocolVersion"] as? String else {
            throw MCPHandshakeError.badResponse("No result.")
        }
        let info = result["serverInfo"] as? [String: Any] ?? [:]
        return (info["name"] as? String ?? "MCP server", info["version"] as? String ?? "", protocolVersion)
    }

    static func toolCount(_ message: [String: Any]?) -> Int? {
        ((message?["result"] as? [String: Any])?["tools"] as? [Any])?.count
    }

    // MARK: Streamable HTTP

    public static func http(url: URL, headers: [String: String] = [:], timeout: TimeInterval = AgentsConfig.httpHandshakeTimeout,
                            session: URLSession = .shared) async throws -> MCPHandshakeResult {
        let start = Date()
        func post(_ body: Data, sessionID: String?, protocolVersion: String?) async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: url, timeoutInterval: timeout)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
            if let protocolVersion { request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw MCPHandshakeError.badResponse("No HTTP response.") }
            return (data, http)
        }
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await post(initializeMessage(), sessionID: nil, protocolVersion: nil)
        } catch let error as URLError where error.code == .timedOut {
            throw MCPHandshakeError.timeout
        }
        guard (200..<300).contains(response.statusCode) else { throw MCPHandshakeError.http(response.statusCode) }
        guard let message = message(id: 1, in: data, contentType: response.value(forHTTPHeaderField: "Content-Type")) else {
            throw MCPHandshakeError.badResponse(String(decoding: data.prefix(120), as: UTF8.self))
        }
        let (name, version, protocolVersion) = try parseInitialize(message)
        let sessionID = response.value(forHTTPHeaderField: "Mcp-Session-Id")
        var tools: Int?
        if let (_, ack) = try? await post(initializedNotification, sessionID: sessionID, protocolVersion: protocolVersion),
           ack.statusCode < 300,
           let (body, listResponse) = try? await post(toolsListMessage(), sessionID: sessionID, protocolVersion: protocolVersion) {
            tools = toolCount(self.message(id: 2, in: body, contentType: listResponse.value(forHTTPHeaderField: "Content-Type")))
        }
        if let sessionID {
            var close = URLRequest(url: url, timeoutInterval: 3)
            close.httpMethod = "DELETE"
            close.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
            _ = try? await session.data(for: close)
        }
        return MCPHandshakeResult(serverName: name, serverVersion: version, protocolVersion: protocolVersion,
                                  toolCount: tools, milliseconds: Int(Date().timeIntervalSince(start) * 1000))
    }

    // MARK: SSE (older HTTP transport)

    public static func sse(url: URL, headers: [String: String] = [:], timeout: TimeInterval = AgentsConfig.httpHandshakeTimeout) async throws -> MCPHandshakeResult {
        try await withTimeout(timeout) {
            try await sseHandshake(url: url, headers: headers)
        }
    }

    static func sseHandshake(url: URL, headers: [String: String]) async throws -> MCPHandshakeResult {
        let start = Date()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw MCPHandshakeError.badResponse("No HTTP response.") }
        guard http.statusCode == 200 else { throw MCPHandshakeError.http(http.statusCode) }

        var event = ""
        var data: [String] = []
        var endpoint: URL?
        var initialize: (String, String, String)?
        func post(_ body: Data, to target: URL) async throws {
            var post = URLRequest(url: target, timeoutInterval: 10)
            post.httpMethod = "POST"
            post.httpBody = body
            post.setValue("application/json", forHTTPHeaderField: "Content-Type")
            for (key, value) in headers { post.setValue(value, forHTTPHeaderField: key) }
            let (_, answer) = try await session.data(for: post)
            if let code = (answer as? HTTPURLResponse)?.statusCode, code >= 300 { throw MCPHandshakeError.http(code) }
        }
        for try await line in bytes.lines {
            if line.hasPrefix("event:") { event = line.dropFirst(6).trimmingCharacters(in: .whitespaces); continue }
            if line.hasPrefix("data:") {
                data.append(line.dropFirst(5).trimmingCharacters(in: .whitespaces))
                // URLSession's line reader drops blank lines, so handle each data line as one event.
            } else {
                continue
            }
            let payload = data.joined(separator: "\n")
            data = []
            if event == "endpoint", endpoint == nil {
                guard let target = URL(string: payload, relativeTo: url)?.absoluteURL else {
                    throw MCPHandshakeError.badResponse("Bad endpoint event.")
                }
                endpoint = target
                try await post(initializeMessage(), to: target)
                continue
            }
            guard let target = endpoint,
                  let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
            if initialize == nil, (object["id"] as? Int) == 1 {
                initialize = try parseInitialize(object)
                try await post(initializedNotification, to: target)
                try await post(toolsListMessage(), to: target)
            } else if let initialize, (object["id"] as? Int) == 2 {
                return MCPHandshakeResult(serverName: initialize.0, serverVersion: initialize.1, protocolVersion: initialize.2,
                                          toolCount: toolCount(object), milliseconds: Int(Date().timeIntervalSince(start) * 1000))
            }
            event = ""
        }
        if let initialize {
            return MCPHandshakeResult(serverName: initialize.0, serverVersion: initialize.1, protocolVersion: initialize.2,
                                      toolCount: nil, milliseconds: Int(Date().timeIntervalSince(start) * 1000))
        }
        throw MCPHandshakeError.exited("The event stream closed.")
    }

    // MARK: stdio

    /// Starts the command, sends initialize and tools/list on stdin, reads answers on stdout, then closes it.
    public static func stdio(executable: String, arguments: [String], environment: [String: String] = [:],
                             timeout: TimeInterval = AgentsConfig.stdioHandshakeTimeout) async throws -> MCPHandshakeResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try stdioBlocking(executable: executable, arguments: arguments, environment: environment, timeout: timeout) })
            }
        }
    }

    static func stdioBlocking(executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval) throws -> MCPHandshakeResult {
        let start = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment { env[key] = value }
        process.environment = env
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let errBox = HandshakeBuffer()
        errors.fileHandleForReading.readabilityHandler = { handle in
            errBox.append(handle.availableData)
        }
        do {
            try process.run()
        } catch {
            throw DeckError.launchFailed(executable, error.localizedDescription)
        }
        let timedOut = HandshakeFlag()
        let killer = DispatchWorkItem {
            timedOut.set()
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        defer {
            killer.cancel()
            errors.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            if process.isRunning {
                // Closing stdin ends a `container run -i --rm`. Give it a moment, then stop it.
                let deadline = Date().addingTimeInterval(3)
                while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
                if process.isRunning { process.terminate() }
            }
        }

        func send(_ data: Data) {
            try? input.fileHandleForWriting.write(contentsOf: data + Data("\n".utf8))
        }
        send(initializeMessage())

        var buffer = Data()
        var initialize: (String, String, String)?
        let reader = output.fileHandleForReading
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                let id = object["id"] as? Int
                if initialize == nil, id == 1 {
                    initialize = try parseInitialize(object)
                    send(initializedNotification)
                    send(toolsListMessage())
                } else if let initialize, id == 2 {
                    return MCPHandshakeResult(serverName: initialize.0, serverVersion: initialize.1, protocolVersion: initialize.2,
                                              toolCount: toolCount(object), milliseconds: Int(Date().timeIntervalSince(start) * 1000))
                }
            }
        }
        if let initialize {
            return MCPHandshakeResult(serverName: initialize.0, serverVersion: initialize.1, protocolVersion: initialize.2,
                                      toolCount: nil, milliseconds: Int(Date().timeIntervalSince(start) * 1000))
        }
        if timedOut.value { throw MCPHandshakeError.timeout }
        let tail = errBox.text.split(separator: "\n").filter { !$0.hasPrefix("[") }.suffix(2).joined(separator: " ")
        throw MCPHandshakeError.exited(String(tail.prefix(300)))
    }

    // MARK: Helpers

    static func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw MCPHandshakeError.timeout
            }
            guard let first = try await group.next() else { throw MCPHandshakeError.timeout }
            group.cancelAll()
            return first
        }
    }
}

private final class HandshakeBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

private final class HandshakeFlag: @unchecked Sendable {
    private var flag = false
    private let lock = NSLock()
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
