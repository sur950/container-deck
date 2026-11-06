import Foundation

/// A model LM Studio has on disk (`lms ls --json`).
public struct LMStudioModel: Sendable, Hashable, Identifiable {
    /// Model key used by `lms load`, like "qwen/qwen3-4b".
    public var id: String
    public var displayName: String
    /// "llm" or "embedding".
    public var type: String?
    public var format: String?
    public var sizeBytes: UInt64?
    /// "4B", "0.6B".
    public var parameters: String?
    public var architecture: String?
    public var isLoaded: Bool

    public init(id: String, displayName: String? = nil, type: String? = nil, format: String? = nil, sizeBytes: UInt64? = nil,
                parameters: String? = nil, architecture: String? = nil, isLoaded: Bool = false) {
        self.id = id
        self.displayName = displayName ?? id
        self.type = type
        self.format = format
        self.sizeBytes = sizeBytes
        self.parameters = parameters
        self.architecture = architecture
        self.isLoaded = isLoaded
    }

    public var isEmbedding: Bool { type == "embedding" }
}

/// What is installed and running for LM Studio.
public struct LMStudioStatus: Sendable, Equatable {
    public var appPath: String?
    /// The `lms` command.
    public var cliPath: String?
    /// Homebrew, for the install button. nil when Homebrew is not on this Mac.
    public var brewPath: String?
    public var serverRunning: Bool
    public var port: Int

    public init(appPath: String? = nil, cliPath: String? = nil, brewPath: String? = nil, serverRunning: Bool = false, port: Int = AIConfig.lmStudioPort) {
        self.appPath = appPath
        self.cliPath = cliPath
        self.brewPath = brewPath
        self.serverRunning = serverRunning
        self.port = port
    }

    public var isInstalled: Bool { appPath != nil || cliPath != nil }
}

/// Finds LM Studio and drives its `lms` command: server start and stop, models on disk,
/// load and unload, and a Homebrew install when the person asks for one.
public struct LMStudioRuntime: Sendable {
    let runner: CommandRunning
    let streamer: CommandStreaming
    let http: AIHTTPFetching
    let fileExists: @Sendable (String) -> Bool
    /// When set, `lms`, `brew` and the app are looked up only in this folder (stand in tools for tests and debug runs).
    let toolsDirectory: String?

    public init(runner: CommandRunning = ProcessRunner(), streamer: CommandStreaming = ProcessRunner(), http: AIHTTPFetching = AIHTTPClient(),
                toolsDirectory: String? = LMStudioRuntime.debugToolsDirectory,
                fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: AIConfig.expand($0)) }) {
        self.runner = runner
        self.streamer = streamer
        self.http = http
        self.toolsDirectory = toolsDirectory
        self.fileExists = fileExists
    }

    /// The stand in tools folder from DECK_LMSTUDIO_TOOLS_DIR. Debug builds only.
    public static var debugToolsDirectory: String? {
        #if DEBUG
        if let dir = ProcessInfo.processInfo.environment[AIConfig.lmStudioDebugToolsVariable], !dir.isEmpty { return dir }
        #endif
        return nil
    }

    // MARK: Finding

    public func findApp() -> String? {
        if let toolsDirectory { return [toolsDirectory + "/LM Studio.app"].first(where: fileExists) }
        return AIConfig.lmStudioApps.map(AIConfig.expand).first(where: fileExists)
    }

    public func findCLI() -> String? {
        if let toolsDirectory { return [toolsDirectory + "/lms"].first(where: fileExists) }
        return AIConfig.lmStudioCLIPaths.map(AIConfig.expand).first(where: fileExists)
    }

    public func findBrew() -> String? {
        if let toolsDirectory { return [toolsDirectory + "/brew"].first(where: fileExists) }
        return AIConfig.homebrewPaths.first(where: fileExists)
    }

    public func status() async -> LMStudioStatus {
        var status = LMStudioStatus(appPath: findApp(), cliPath: findCLI(), brewPath: findBrew())
        if let cli = status.cliPath, let result = try? await runner.run(cli, ["server", "status", "--json"]), result.succeeded,
           let server = Self.parseServerStatus(result.stdout) {
            status.serverRunning = server.running
            status.port = server.port ?? status.port
        }
        if !status.serverRunning {
            status.serverRunning = await answers(port: status.port)
        }
        return status
    }

    /// True when the server answers `GET /v1/models`.
    public func answers(port: Int) async -> Bool {
        guard let url = AIHTTP.url(host: "127.0.0.1", port: port, path: "/v1/models") else { return false }
        guard let (_, code) = try? await http.get(url, timeout: AIConfig.probeTimeout) else { return false }
        return code == 200
    }

    // MARK: Commands

    public static func startArguments(port: Int? = nil) -> [String] {
        var args = ["server", "start"]
        if let port, port != AIConfig.lmStudioPort { args += ["--port", String(port)] }
        return args
    }

    public static let stopArguments = ["server", "stop"]
    public static let listArguments = ["ls", "--json"]
    public static let loadedArguments = ["ps", "--json"]

    /// `lms load <key> --yes`. `--yes` skips the questions lms asks in a terminal.
    public static func loadArguments(_ model: String) -> [String] { ["load", model, "--yes"] }

    /// `lms unload <key>`, or `lms unload --all`.
    public static func unloadArguments(_ model: String?) -> [String] {
        if let model { return ["unload", model] }
        return ["unload", "--all"]
    }

    public static let brewInstallArguments = ["install", "--cask", AIConfig.lmStudioCask]

    public func startServer(port: Int? = nil) async throws {
        try await runCLI(Self.startArguments(port: port))
    }

    public func stopServer() async throws {
        try await runCLI(Self.stopArguments)
    }

    /// Models on disk, marked when loaded.
    public func models() async throws -> [LMStudioModel] {
        let cli = try requireCLI()
        let list = try await runner.run(cli, Self.listArguments)
        try list.orThrow()
        var models = Self.parseModels(list.stdout)
        if let loaded = try? await runner.run(cli, Self.loadedArguments), loaded.succeeded {
            let keys = Self.parseLoaded(loaded.stdout)
            for index in models.indices where keys.contains(models[index].id) {
                models[index].isLoaded = true
            }
        }
        return models
    }

    public func load(_ model: String) async throws {
        try await runCLI(Self.loadArguments(model))
    }

    public func unload(_ model: String?) async throws {
        try await runCLI(Self.unloadArguments(model))
    }

    /// `brew install --cask lm-studio`, with its output. Only runs when the person presses Install.
    public func installWithHomebrew() throws -> AsyncThrowingStream<String, Error> {
        guard let brew = findBrew() else { throw DeckError.commandFailed("Homebrew is not installed.") }
        return streamer.stream(brew, Self.brewInstallArguments)
    }

    /// The command people can run themselves.
    public static var brewInstallCommandLine: String { "brew " + brewInstallArguments.joined(separator: " ") }

    /// Where an endpoint card points before discovery sees the server.
    public static func installedEndpoint(port: Int = AIConfig.lmStudioPort) -> ModelEndpoint {
        ModelDiscoveryParser.installedEndpoint(.lmStudio, port: port)
    }

    private func requireCLI() throws -> String {
        guard let cli = findCLI() else {
            throw DeckError.commandFailed("The lms command was not found. Open LM Studio once so it sets up lms.")
        }
        return cli
    }

    private func runCLI(_ arguments: [String]) async throws {
        let cli = try requireCLI()
        let result = try await runner.run(cli, arguments)
        guard result.succeeded else {
            let detail = [result.stderr, result.stdout].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
            throw DeckError.commandFailed(detail.map { "lms \(arguments.first ?? ""): \($0)" } ?? "lms \(arguments.joined(separator: " ")) failed.")
        }
    }

    // MARK: Parsing

    /// `lms ls --json`: an array of models with `modelKey`, `displayName`, `type`, `sizeBytes`, `paramsString`.
    public static func parseModels(_ text: String) -> [LMStudioModel] {
        guard let list = jsonArray(text) else { return [] }
        return list.compactMap { item in
            guard let key = (item["modelKey"] as? String) ?? (item["path"] as? String) ?? (item["identifier"] as? String) else { return nil }
            return LMStudioModel(
                id: key,
                displayName: item["displayName"] as? String,
                type: item["type"] as? String,
                format: item["format"] as? String,
                sizeBytes: ModelDiscoveryParser.uint64(item["sizeBytes"]),
                parameters: item["paramsString"] as? String,
                architecture: item["architecture"] as? String
            )
        }
        .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    /// `lms ps --json`: loaded models. Gives their model keys (and identifiers, which can differ).
    public static func parseLoaded(_ text: String) -> Set<String> {
        guard let list = jsonArray(text) else { return [] }
        var keys = Set<String>()
        for item in list {
            for field in ["modelKey", "identifier", "path"] {
                if let value = item[field] as? String { keys.insert(value) }
            }
        }
        return keys
    }

    /// `lms server status --json`: `{"running": true, "port": 1234}`. Plain text from older versions works too.
    public static func parseServerStatus(_ text: String) -> (running: Bool, port: Int?)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let running = object["running"] as? Bool {
            return (running, object["port"] as? Int)
        }
        let lower = trimmed.lowercased()
        guard lower.contains("running") else { return nil }
        if lower.contains("not running") { return (false, nil) }
        let port = lower.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.first { $0 > 0 && $0 < 65536 }
        return (true, port)
    }

    private static func jsonArray(_ text: String) -> [[String: Any]]? {
        // lms can print a line of notice text before the JSON.
        guard let start = text.firstIndex(of: "["), let data = String(text[start...]).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    }
}
