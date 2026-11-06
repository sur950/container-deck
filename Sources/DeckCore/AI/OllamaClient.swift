import Foundation

/// One progress line of `POST /api/pull`.
public struct OllamaPullProgress: Sendable, Equatable {
    public var status: String
    public var digest: String?
    public var total: UInt64?
    public var completed: UInt64?
    public var error: String?

    public init(status: String, digest: String? = nil, total: UInt64? = nil, completed: UInt64? = nil, error: String? = nil) {
        self.status = status
        self.digest = digest
        self.total = total
        self.completed = completed
        self.error = error
    }

    /// 0...1 for layer downloads, nil for other steps.
    public var fraction: Double? {
        guard let total, total > 0, let completed else { return nil }
        return min(1, Double(completed) / Double(total))
    }

    public var isSuccess: Bool { status == "success" }

    /// Reads one NDJSON line. nil for blank or broken lines.
    public static func parse(_ line: String) -> OllamaPullProgress? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = object["error"] as? String {
            return OllamaPullProgress(status: "error", error: error)
        }
        guard let status = object["status"] as? String else { return nil }
        return OllamaPullProgress(
            status: status,
            digest: object["digest"] as? String,
            total: ModelDiscoveryParser.uint64(object["total"]),
            completed: ModelDiscoveryParser.uint64(object["completed"])
        )
    }

    /// Short step text for people: "Downloading 3a1c2b", "Checking", "Done".
    public var stepText: String {
        if let error { return error }
        if status.hasPrefix("pulling "), digest != nil {
            return "Downloading " + String(status.dropFirst("pulling ".count).prefix(12))
        }
        switch status {
        case "pulling manifest": return "Reading manifest"
        case "verifying sha256 digest": return "Checking"
        case "writing manifest": return "Saving"
        case "success": return "Done"
        default: return status.prefix(1).uppercased() + status.dropFirst()
        }
    }
}

/// Talks to a local Ollama server. Models are pulled, loaded into memory (start)
/// and unloaded (stop) through its HTTP API.
public struct OllamaClient: Sendable {
    public let baseURL: URL
    let http: AIHTTPFetching
    let session: URLSession

    public init(baseURL: URL = URL(string: "http://127.0.0.1:11434")!, http: AIHTTPFetching = AIHTTPClient(), session: URLSession = AIHTTP.session) {
        self.baseURL = baseURL
        self.http = http
        self.session = session
    }

    private func url(_ path: String) -> URL { baseURL.appendingPathComponent(path) }

    public func isRunning() async -> Bool {
        guard let (data, status) = try? await http.get(url("api/version"), timeout: AIConfig.probeTimeout) else { return false }
        return status == 200 && ModelDiscoveryParser.parseOllamaVersion(data) != nil
    }

    /// Models on disk, with loaded state.
    public func models() async throws -> [ModelEndpointModel] {
        let (data, status) = try await http.get(url("api/tags"), timeout: 10)
        guard status == 200, let models = ModelDiscoveryParser.parseOllamaTags(data) else {
            throw DeckError.parse("Ollama's model list")
        }
        let loaded = (try? await http.get(url("api/ps"), timeout: 10)).map { ModelDiscoveryParser.parseOllamaLoaded($0.0) } ?? []
        return ModelDiscoveryParser.markLoaded(models, loaded: Set(loaded))
    }

    /// Loads a model into memory and keeps it there until `unload`.
    public func load(_ model: String) async throws {
        try await http.postJSON(url("api/generate"), body: Self.loadBody(model), timeout: 600)
    }

    /// Frees the memory a model uses. Ollama answers before the model is out of `/api/ps`,
    /// so this waits (up to 5 s) until it is gone.
    public func unload(_ model: String) async throws {
        try await http.postJSON(url("api/generate"), body: Self.unloadBody(model), timeout: 60)
        for _ in 0..<20 {
            guard let (data, _) = try? await http.get(url("api/ps"), timeout: 5),
                  ModelDiscoveryParser.parseOllamaLoaded(data).contains(model) else { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Deletes a model from disk.
    public func delete(_ model: String) async throws {
        try await http.sendJSON(url("api/delete"), method: "DELETE", body: ["model": model, "name": model], timeout: 60)
    }

    static func loadBody(_ model: String) -> [String: Any] { ["model": model, "keep_alive": -1] }
    static func unloadBody(_ model: String) -> [String: Any] { ["model": model, "keep_alive": 0] }

    /// Pulls a model ("qwen3:0.6b"). Ollama resumes a pull that was stopped half way.
    public func pull(_ model: String) -> AsyncThrowingStream<OllamaPullProgress, Error> {
        let request: URLRequest? = {
            var request = URLRequest(url: url("api/pull"), timeoutInterval: 3600)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
            return request
        }()
        let session = self.session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let request else { throw DeckError.parse("the pull request") }
                    let (bytes, response) = try await session.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        var body = Data()
                        for try await byte in bytes { body.append(byte); if body.count > 4000 { break } }
                        throw DeckError.commandFailed(AIHTTP.errorMessage(body, status: status))
                    }
                    for try await line in bytes.lines {
                        guard let progress = OllamaPullProgress.parse(line) else { continue }
                        if let error = progress.error { throw DeckError.commandFailed(error) }
                        continuation.yield(progress)
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

/// Starts and stops the Ollama server itself.
public struct OllamaControl: Sendable {
    let runner: CommandRunning
    let fileExists: @Sendable (String) -> Bool

    public init(runner: CommandRunning = ProcessRunner(),
                fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: AIConfig.expand($0)) }) {
        self.runner = runner
        self.fileExists = fileExists
    }

    public var hasApp: Bool { fileExists(AIConfig.ollamaApp) }
    public var binary: String? { AIConfig.ollamaSearchPaths.first(where: fileExists) }
    public var isInstalled: Bool { hasApp || binary != nil }

    /// A command line install (Homebrew or the official script), not the copy inside the app.
    public var cliBinary: String? {
        AIConfig.ollamaSearchPaths.first { !$0.hasPrefix(AIConfig.ollamaApp) && fileExists($0) }
    }

    /// Commands that start the server: `ollama serve` in the background when the command line
    /// tool is installed (Homebrew keeps it newer than an old app copy), else the app, hidden.
    public func startCommand(logFile: String) -> (String, [String])? {
        guard let binary = cliBinary else {
            return hasApp ? ("/usr/bin/open", ["-g", "-j", "-a", AIConfig.ollamaApp]) : nil
        }
        let script = "nohup " + Self.quote(binary) + " serve >> " + Self.quote(logFile) + " 2>&1 &"
        return ("/bin/sh", ["-c", script])
    }

    public func start() async throws {
        let log = AIConfig.baseDirectory.appendingPathComponent("logs/ollama.log").path
        try? FileManager.default.createDirectory(atPath: (log as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard let (tool, args) = startCommand(logFile: log) else { throw DeckError.commandFailed("Ollama is not installed.") }
        try await runner.run(tool, args).orThrow()
    }

    /// Quits the Ollama app and stops any `ollama serve`.
    public func stop() async throws {
        // SIGTERM lets the app and the server shut down cleanly. No AppleScript, which could launch the app.
        if hasApp {
            _ = try? await runner.run("/usr/bin/pkill", ["-x", "Ollama"])
        }
        _ = try? await runner.run("/usr/bin/pkill", ["-f", "ollama serve"])
    }

    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
