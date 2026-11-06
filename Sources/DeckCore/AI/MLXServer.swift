import Foundation
import Darwin

/// Where the MLX server listens.
public enum MLXBind: Sendable, Hashable, Codable {
    /// 127.0.0.1. Only apps on this Mac can reach it.
    case mac
    /// A container network's gateway address ("192.168.64.1"). Containers on that network
    /// reach it there. The Mac reaches it too. Nothing else on the LAN does.
    case containers(gateway: String)

    public var host: String {
        switch self {
        case .mac: return "127.0.0.1"
        case .containers(let gateway): return gateway
        }
    }
}

/// How to start the server.
public struct MLXServerConfig: Sendable, Hashable, Codable {
    /// A model folder path or a Hugging Face repo id in the shared cache.
    public var model: String
    public var bind: MLXBind
    public var port: Int

    public init(model: String, bind: MLXBind = .mac, port: Int = AIConfig.mlxDefaultPort) {
        self.model = model
        self.bind = bind
        self.port = port
    }

    /// OpenAI compatible base URL on this Mac.
    public var baseURL: URL {
        AIHTTP.url(host: bind.host, port: port, path: "/v1") ?? URL(fileURLWithPath: "/")
    }
}

/// The server Container Deck started, saved so a new app session can find and stop it.
public struct MLXServerRecord: Codable, Sendable, Equatable {
    public var pid: Int32
    public var config: MLXServerConfig
    public var started: Date

    public init(pid: Int32, config: MLXServerConfig, started: Date = Date()) {
        self.pid = pid
        self.config = config
        self.started = started
    }

    public static func load(paths: AIPaths = AIPaths()) -> MLXServerRecord? {
        guard let data = try? Data(contentsOf: paths.serverRecord) else { return nil }
        return try? JSONDecoder().decode(MLXServerRecord.self, from: data)
    }

    func save(paths: AIPaths) {
        try? FileManager.default.createDirectory(at: paths.base, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: paths.serverRecord, options: .atomic)
        }
    }

    static func clear(paths: AIPaths) {
        try? FileManager.default.removeItem(at: paths.serverRecord)
    }
}

/// Builds the server command. Pure, unit tested.
public enum MLXServerPlan {
    public static func arguments(_ config: MLXServerConfig) -> [String] {
        ["--model", config.model, "--host", config.bind.host, "--port", String(config.port)]
    }

    /// Environment for the server process. Uses the shared Hugging Face cache (made when
    /// missing, mlx_lm's model list fails without it) and never phones home for a model folder.
    public static func environment(base: [String: String], model: String) -> [String: String] {
        var env = base
        let cache = AIConfig.expand(AIConfig.huggingFaceCache)
        try? FileManager.default.createDirectory(atPath: cache, withIntermediateDirectories: true)
        env["HF_HUB_CACHE"] = cache
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        if model.hasPrefix("/") { env["HF_HUB_OFFLINE"] = "1" }
        env["PYTHONUNBUFFERED"] = "1"
        return env
    }

    /// True when a process command line is an mlx_lm server.
    public static func isServerCommand(_ command: String) -> Bool {
        let lower = command.lowercased()
        return lower.contains("mlx_lm.server") || lower.contains("mlx_lm server")
    }
}

/// What the managed server is doing.
public enum MLXServerState: Sendable, Equatable {
    case stopped
    /// Process is up, the HTTP port does not answer yet.
    case starting(pid: Int32)
    case running(pid: Int32)
    /// Exited without being asked. `code` is the exit code, minus the signal number when a signal
    /// stopped it, nil when the app did not start it (found from an earlier session).
    case crashed(code: Int32?)

    public var pid: Int32? {
        switch self {
        case .starting(let pid), .running(let pid): return pid
        default: return nil
        }
    }

    public var isActive: Bool { pid != nil }
}

/// Starts, stops and watches one `mlx_lm.server`. Output goes to a log file, so the server
/// keeps running when the app quits. A later session adopts it through `MLXServerRecord`.
public final class MLXServerController: @unchecked Sendable {
    public let paths: AIPaths
    private let lock = NSLock()
    private var process: Process?
    private var stopRequested = false
    private var _state: MLXServerState = .stopped
    private var _config: MLXServerConfig?

    /// Called on any thread when the server exits. `crashed` is true when nobody asked it to stop.
    /// `code` follows `MLXServerState.crashed`.
    public var onExit: (@Sendable (_ code: Int32?, _ crashed: Bool) -> Void)?

    public init(paths: AIPaths = AIPaths()) {
        self.paths = paths
    }

    public var state: MLXServerState {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    public var config: MLXServerConfig? {
        lock.lock(); defer { lock.unlock() }
        return _config
    }

    private func set(_ state: MLXServerState) {
        lock.lock(); _state = state; lock.unlock()
    }

    /// Picks up a server started in an earlier session, when its process still runs.
    @discardableResult
    public func adopt(commandOf: (Int32) -> String? = MLXServerController.command(of:)) -> Bool {
        guard let record = MLXServerRecord.load(paths: paths) else { return false }
        guard Self.isAlive(record.pid), let command = commandOf(record.pid), MLXServerPlan.isServerCommand(command) else {
            MLXServerRecord.clear(paths: paths)
            return false
        }
        lock.lock()
        _config = record.config
        _state = .running(pid: record.pid)
        stopRequested = false
        lock.unlock()
        return true
    }

    /// Starts the server. Throws when one is already running or the binary cannot start.
    public func start(_ config: MLXServerConfig, serverPath: String, environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        if state.isActive { throw DeckError.commandFailed("The MLX server is already running.") }
        try FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        // Fresh log per start, the last one is kept as .1 for crash reports.
        let log = paths.serverLog
        let previous = log.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: log, to: previous)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: serverPath)
        process.arguments = MLXServerPlan.arguments(config)
        process.environment = MLXServerPlan.environment(base: environment, model: config.model)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        process.terminationHandler = { [weak self] finished in
            try? handle.close()
            // A signal (kill -9, out of memory) is reported as a negative code.
            let code = finished.terminationReason == .uncaughtSignal ? -finished.terminationStatus : finished.terminationStatus
            self?.processEnded(code)
        }
        do {
            try process.run()
        } catch {
            try? handle.close()
            throw DeckError.launchFailed(serverPath, error.localizedDescription)
        }
        lock.lock()
        self.process = process
        stopRequested = false
        _config = config
        _state = .starting(pid: process.processIdentifier)
        lock.unlock()
        MLXServerRecord(pid: process.processIdentifier, config: config).save(paths: paths)
    }

    /// Call when the HTTP port answers.
    public func markRunning() {
        lock.lock(); defer { lock.unlock() }
        if case .starting(let pid) = _state { _state = .running(pid: pid) }
    }

    /// Stops the server: SIGTERM, then SIGKILL after `grace` seconds.
    public func stop(grace: TimeInterval = 4) async {
        guard let pid = requestStop() else { return }
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(grace)
        while Self.isAlive(pid) && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if Self.isAlive(pid) { kill(pid, SIGKILL) }
        MLXServerRecord.clear(paths: paths)
        markAdoptedStopped()
    }

    private func requestStop() -> Int32? {
        lock.lock(); defer { lock.unlock() }
        stopRequested = true
        return _state.pid
    }

    /// Adopted servers have no termination handler, so the state is set here.
    private func markAdoptedStopped() {
        lock.lock(); defer { lock.unlock() }
        if process == nil { _state = .stopped }
    }

    /// For adopted servers: checks the pid. Reports a crash once when it is gone.
    public func checkAlive() {
        lock.lock()
        guard process == nil, let pid = _state.pid, !Self.isAlive(pid) else { lock.unlock(); return }
        let requested = stopRequested
        _state = requested ? .stopped : .crashed(code: nil)
        lock.unlock()
        MLXServerRecord.clear(paths: paths)
        onExit?(nil, !requested)
    }

    private func processEnded(_ code: Int32) {
        lock.lock()
        let requested = stopRequested
        process = nil
        _state = requested ? .stopped : .crashed(code: code)
        lock.unlock()
        MLXServerRecord.clear(paths: paths)
        onExit?(code, !requested)
    }

    // MARK: Helpers

    public static func isAlive(_ pid: Int32) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    /// Full command line of a process, from `ps`. Blocking, quick.
    public static func command(of pid: Int32) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "command=", "-p", String(pid)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

/// Reads new lines appended to a log file since the last read.
public final class LogTail: @unchecked Sendable {
    public let url: URL
    private var offset: UInt64 = 0
    private var partial = ""
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
    }

    /// Starts from the beginning again (a new server run made a new file).
    public func reset() {
        lock.lock(); offset = 0; partial = ""; lock.unlock()
    }

    /// New complete lines. Handles a file that was replaced or truncated.
    public func read(maxBytes: Int = 512 * 1024) -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset { offset = 0; partial = "" }
        if size - offset > UInt64(maxBytes) { offset = size - UInt64(maxBytes) }
        guard size > offset else { return [] }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.read(upToCount: Int(size - offset))) ?? Data()
        offset += UInt64(data.count)
        let text = partial + String(decoding: data, as: UTF8.self)
        var lines = text.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
        partial = lines.removeLast()
        return lines.filter { !$0.isEmpty }
    }
}
