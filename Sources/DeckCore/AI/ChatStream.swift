import Foundation

/// One chat message in the OpenAI shape.
public struct ChatMessage: Codable, Sendable, Hashable {
    public enum Role: String, Codable, Sendable { case system, user, assistant }
    public var role: Role
    public var content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

/// One piece of a streamed answer.
public enum ChatStreamEvent: Sendable, Equatable {
    /// Answer text.
    case content(String)
    /// Thinking text some models send apart from the answer (`reasoning` or `reasoning_content`).
    case reasoning(String)
    /// Token counts, sent at the end when the server supports `stream_options.include_usage`.
    case usage(promptTokens: Int?, completionTokens: Int?)
    /// Why the model stopped ("stop", "length").
    case finished(String)
    /// The server sent an error inside the stream.
    case failed(String)
    /// The stream is over (`data: [DONE]`).
    case done

    /// True when the server stopped the answer at its length limit, not because it was done.
    public var isLengthStop: Bool {
        guard case .finished(let reason) = self else { return false }
        return reason == "length" || reason == "max_tokens"
    }
}

/// Reads Server Sent Events lines of `/v1/chat/completions` with `stream: true`.
public enum ChatStreamParser {
    /// Events in one SSE line. Comments (": keepalive"), blank lines and other fields give none.
    public static func parse(line raw: String) -> [ChatStreamEvent] {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return [.done] }
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

        if let error = object["error"] {
            let message = (error as? [String: Any])?["message"] as? String ?? (error as? String) ?? "The server sent an error."
            return [.failed(message)]
        }
        var events: [ChatStreamEvent] = []
        for choice in object["choices"] as? [[String: Any]] ?? [] {
            if let delta = choice["delta"] as? [String: Any] {
                let thinking = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String)
                if let thinking, !thinking.isEmpty { events.append(.reasoning(thinking)) }
                if let text = delta["content"] as? String, !text.isEmpty { events.append(.content(text)) }
            }
            if let reason = choice["finish_reason"] as? String {
                events.append(.finished(reason))
            }
        }
        if let usage = object["usage"] as? [String: Any] {
            events.append(.usage(promptTokens: usage["prompt_tokens"] as? Int, completionTokens: usage["completion_tokens"] as? Int))
        }
        return events
    }

    /// Request body for a streamed chat.
    public static func requestBody(model: String, messages: [ChatMessage], maxTokens: Int?, temperature: Double?) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "stream_options": ["include_usage": true],
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        ]
        if let maxTokens { body["max_tokens"] = maxTokens }
        if let temperature { body["temperature"] = temperature }
        return body
    }
}

/// Speed of one answer.
public struct ChatStats: Sendable, Equatable {
    public var started: Date
    public var firstToken: Date?
    public var finished: Date?
    /// Streamed pieces with text. Close to the token count on most servers.
    public var chunks = 0
    /// Exact count from the server, when it sends usage.
    public var completionTokens: Int?
    public var promptTokens: Int?

    public init(started: Date = Date()) {
        self.started = started
    }

    public var tokens: Int { completionTokens ?? chunks }

    /// Seconds until the first piece came back.
    public var timeToFirstToken: TimeInterval? {
        firstToken.map { $0.timeIntervalSince(started) }
    }

    /// Tokens per second while generating (from the first token on).
    public func tokensPerSecond(now: Date = Date()) -> Double? {
        guard let firstToken, tokens > 1 else { return nil }
        let elapsed = (finished ?? now).timeIntervalSince(firstToken)
        guard elapsed > 0.05 else { return nil }
        // The first token arrives at firstToken, so the rate counts the ones after it.
        return Double(tokens - 1) / elapsed
    }

    public mutating func record(_ event: ChatStreamEvent, at date: Date = Date()) {
        switch event {
        case .content, .reasoning:
            if firstToken == nil { firstToken = date }
            chunks += 1
        case .usage(let prompt, let completion):
            promptTokens = prompt ?? promptTokens
            completionTokens = completion ?? completionTokens
        case .finished, .done, .failed:
            if finished == nil { finished = date }
        }
    }
}

/// Streams chat answers from any OpenAI compatible endpoint.
public struct ChatClient: Sendable {
    let session: URLSession

    public init(session: URLSession = AIHTTP.session) {
        self.session = session
    }

    /// Streams the answer. Cancel the consuming task to stop it.
    public func stream(baseURL: URL, model: String, messages: [ChatMessage], apiKey: String? = nil,
                       maxTokens: Int? = nil, temperature: Double? = nil) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let session = self.session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"), timeoutInterval: 300)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue("Bearer \(apiKey ?? "local")", forHTTPHeaderField: "Authorization")
                    request.httpBody = try JSONSerialization.data(withJSONObject: ChatStreamParser.requestBody(
                        model: model, messages: messages, maxTokens: maxTokens, temperature: temperature))

                    let (bytes, response) = try await session.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status) else {
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count > 4000 { break }
                        }
                        throw DeckError.commandFailed(AIHTTP.errorMessage(body, status: status))
                    }
                    for try await line in bytes.lines {
                        for event in ChatStreamParser.parse(line: line) {
                            if case .failed(let message) = event {
                                throw DeckError.commandFailed(message)
                            }
                            continuation.yield(event)
                            if event == .done {
                                continuation.finish()
                                return
                            }
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
