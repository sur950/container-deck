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
    /// Path inside LM Studio's models folder, like "lmstudio-community/Qwen3-4B-GGUF/Qwen3-4B-Q4_K_M.gguf".
    public var path: String?
    /// "Q4_K_M", "4bit".
    public var quantization: String?

    public init(id: String, displayName: String? = nil, type: String? = nil, format: String? = nil, sizeBytes: UInt64? = nil,
                parameters: String? = nil, architecture: String? = nil, isLoaded: Bool = false, path: String? = nil, quantization: String? = nil) {
        self.id = id
        self.displayName = displayName ?? id
        self.type = type
        self.format = format
        self.sizeBytes = sizeBytes
        self.parameters = parameters
        self.architecture = architecture
        self.isLoaded = isLoaded
        self.path = path
        self.quantization = quantization
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

    /// Only `lms` and the llmster service, no app (LM Studio's headless install).
    public var isCoreOnly: Bool { appPath == nil && cliPath != nil }

    /// "LM Studio app" or "LM Studio core". nil when nothing is installed.
    public var installLabel: String? {
        if appPath != nil { return "LM Studio app" }
        if cliPath != nil { return "LM Studio core" }
        return nil
    }
}

/// The llmster background service, from `lms daemon status --json`.
public enum LMStudioDaemonState: Sendable, Equatable {
    case running
    case notRunning
    /// No answer we understand, for example an `lms` older than 0.4 without `daemon`.
    case unknown
}

/// Finds LM Studio and drives its `lms` command: the llmster service, server start and stop,
/// models on disk, load and unload, and an install when the person asks for one.
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

    public static let daemonUpArguments = ["daemon", "up"]
    public static let daemonDownArguments = ["daemon", "down"]
    public static let daemonStatusArguments = ["daemon", "status", "--json"]

    /// Starts the server. A headless install needs its llmster service up first, so when
    /// `lms daemon status` says it is not running, this runs `lms daemon up` before `lms server start`.
    public func startServer(port: Int? = nil) async throws {
        _ = try requireCLI()
        if await daemonStatus() == .notRunning {
            try await daemonUp()
        }
        try await runCLI(Self.startArguments(port: port))
    }

    public func stopServer() async throws {
        try await runCLI(Self.stopArguments)
    }

    /// `lms daemon status --json`. Never throws: anything unclear is `.unknown`.
    public func daemonStatus() async -> LMStudioDaemonState {
        guard let cli = findCLI(), let result = try? await runner.run(cli, Self.daemonStatusArguments) else { return .unknown }
        let text = result.stdout + "\n" + result.stderr
        return Self.parseDaemonStatus(text)
    }

    /// `lms daemon up`. Its output goes to a file, not to our pipe, so the service it leaves
    /// running never holds the pipe open and this call returns once lms is done.
    public func daemonUp() async throws {
        let cli = try requireCLI()
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("deck-lms-daemon-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        let result = try await runner.run("/bin/sh", Self.detachedArguments(cli: cli, Self.daemonUpArguments, log: log.path))
        guard result.succeeded else {
            let output = ((try? String(contentsOf: log, encoding: .utf8)) ?? "") + result.stderr
            let detail = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
            throw DeckError.commandFailed(detail.map { "lms daemon up: \($0)" } ?? "lms daemon up failed.")
        }
    }

    /// `lms daemon down`. Stops the llmster service and unloads its models.
    public func daemonDown() async throws {
        try await runCLI(Self.daemonDownArguments)
    }

    /// `/bin/sh -c "'lms' daemon up > 'log' 2>&1 < /dev/null"`.
    static func detachedArguments(cli: String, _ arguments: [String], log: String) -> [String] {
        ["-c", ([cli] + arguments).map(quote).joined(separator: " ") + " > " + quote(log) + " 2>&1 < /dev/null"]
    }

    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
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

    // MARK: Install LM Studio core

    /// LM Studio's documented headless install, as people type it in Terminal.
    public static var installCoreCommandLine: String { "curl -fsSL \(AIConfig.lmStudioInstallScript) | bash" }

    /// What runs for Install LM Studio core: `/bin/bash -c "set -o pipefail; curl -fsSL https://lmstudio.ai/install.sh | bash"`.
    /// This is LM Studio's own installer, not ours. It downloads a tar archive (no disk image, so it
    /// works on Macs that cannot mount LM Studio's HFS+ image) and puts `lms` and the llmster service
    /// in ~/.lmstudio. `pipefail` makes a failed download fail the install instead of looking done.
    /// With a stand in tools folder it runs `install.sh` from that folder and never the real script.
    public func installCoreCommand() -> (executable: String, arguments: [String]) {
        if let toolsDirectory { return ("/bin/bash", [toolsDirectory + "/install.sh"]) }
        return ("/bin/bash", ["-c", "set -o pipefail; " + Self.installCoreCommandLine])
    }

    /// Runs LM Studio's installer and streams its output. Only runs when the person presses Install.
    public func installCore() throws -> AsyncThrowingStream<String, Error> {
        let command = installCoreCommand()
        if toolsDirectory != nil, let script = command.arguments.first, !fileExists(script) {
            throw DeckError.commandFailed("No stand in installer at \(script).")
        }
        return streamer.stream(command.executable, command.arguments)
    }

    /// Shown when a Homebrew (or any disk image) install fails because this Mac cannot mount LM Studio's image.
    public static let diskImageFailureMessage = "This Mac can't open LM Studio's disk image. Use Install LM Studio core instead."

    /// True when install output shows the disk image could not be opened, like
    /// `hdiutil: attach failed - no mountable file systems`. LM Studio's image is HFS+, and some Macs cannot mount it.
    public static func isDiskImageFailure(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("no mountable file systems") || lower.contains("attach failed")
    }

    /// Where an endpoint card points before discovery sees the server.
    public static func installedEndpoint(port: Int = AIConfig.lmStudioPort) -> ModelEndpoint {
        ModelDiscoveryParser.installedEndpoint(.lmStudio, port: port)
    }

    private func requireCLI() throws -> String {
        guard let cli = findCLI() else {
            throw DeckError.commandFailed("The lms command was not found. Install LM Studio core, or open the LM Studio app once so it sets up lms.")
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
                architecture: item["architecture"] as? String,
                path: item["path"] as? String,
                // Newer lms prints {"name":"Q4_K_M","bits":4}, older a plain string.
                quantization: (item["quantization"] as? [String: Any])?["name"] as? String ?? item["quantization"] as? String
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

    /// `lms daemon status --json`: `{"status":"running","pid":123,"isDaemon":true}` or `{"status":"not-running"}`.
    public static func parseDaemonStatus(_ text: String) -> LMStudioDaemonState {
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
           let data = String(text[start...end]).data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let status = object["status"] as? String {
            switch status.lowercased() {
            case "running": return .running
            case "not-running", "not_running", "stopped": return .notRunning
            default: return .unknown
            }
        }
        let lower = text.lowercased()
        if lower.contains("not running") || lower.contains("not-running") { return .notRunning }
        if lower.contains("running") { return .running }
        return .unknown
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
