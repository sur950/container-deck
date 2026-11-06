import Foundation

/// Folders the Local AI feature owns. Everything lives under Application Support, no sudo.
public struct AIPaths: Sendable, Equatable {
    public let base: URL

    public init(base: URL = AIConfig.baseDirectory) {
        self.base = base
    }

    /// uv's tool launchers (`mlx_lm.server`) and our own uv when we downloaded it.
    public var bin: URL { base.appendingPathComponent("bin", isDirectory: true) }
    /// uv tool environments (`UV_TOOL_DIR`).
    public var tools: URL { base.appendingPathComponent("uv-tools", isDirectory: true) }
    /// Python builds uv downloads (`UV_PYTHON_INSTALL_DIR`).
    public var python: URL { base.appendingPathComponent("python", isDirectory: true) }
    /// Models the library downloads: models/<org>/<name>.
    public var models: URL { base.appendingPathComponent("models", isDirectory: true) }
    public var logs: URL { base.appendingPathComponent("logs", isDirectory: true) }
    public var serverLog: URL { logs.appendingPathComponent("mlx-server.log") }
    public var serverRecord: URL { base.appendingPathComponent("mlx-server.json") }
    /// Saved chat conversations (ChatHistory).
    public var chats: URL { base.appendingPathComponent("chats", isDirectory: true) }

    public var ownUV: URL { bin.appendingPathComponent("uv") }
    public var mlxServer: URL { bin.appendingPathComponent("mlx_lm.server") }

    /// Folder for one library model ("mlx-community/SmolLM-135M-Instruct-4bit").
    public func modelFolder(_ repo: String) -> URL {
        repo.split(separator: "/").reduce(models) { $0.appendingPathComponent(String($1), isDirectory: true) }
    }
}

/// What is installed for the MLX runtime.
public struct MLXRuntimeStatus: Sendable, Equatable {
    /// uv used for installs. nil when none was found.
    public var uvPath: String?
    public var uvVersion: String?
    /// `mlx_lm.server` to run, ours first, else one on a usual path.
    public var serverPath: String?
    /// mlx-lm version from `uv tool list`, when ours is installed.
    public var mlxVersion: String?
    /// True when mlx-lm is installed in our own folder (so Remove and Update apply).
    public var isOwnInstall: Bool

    public init(uvPath: String? = nil, uvVersion: String? = nil, serverPath: String? = nil, mlxVersion: String? = nil, isOwnInstall: Bool = false) {
        self.uvPath = uvPath
        self.uvVersion = uvVersion
        self.serverPath = serverPath
        self.mlxVersion = mlxVersion
        self.isOwnInstall = isOwnInstall
    }

    public var isReady: Bool { serverPath != nil }
}

/// Checks and installs the MLX runtime (uv plus mlx-lm) in Application Support.
public struct MLXRuntime: Sendable {
    public let paths: AIPaths
    let runner: CommandRunning
    let streamer: CommandStreaming
    let isExecutable: @Sendable (String) -> Bool

    public init(paths: AIPaths = AIPaths(), runner: CommandRunning = ProcessRunner(), streamer: CommandStreaming = ProcessRunner(),
                isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: AIConfig.expand($0)) }) {
        self.paths = paths
        self.runner = runner
        self.streamer = streamer
        self.isExecutable = isExecutable
    }

    /// uv to use: our own copy first, then the usual install places.
    public func findUV() -> String? {
        ([paths.ownUV.path] + AIConfig.uvSearchPaths.map(AIConfig.expand)).first(where: isExecutable)
    }

    /// Other places mlx_lm.server may be installed (pip, pipx, uv tool in the home folder).
    static let otherServerPaths = ["~/.local/bin/mlx_lm.server", "/opt/homebrew/bin/mlx_lm.server", "/usr/local/bin/mlx_lm.server"]

    public func status() async -> MLXRuntimeStatus {
        var status = MLXRuntimeStatus()
        status.uvPath = findUV()
        if let uv = status.uvPath, let result = try? await runner.run(uv, ["--version"]), result.succeeded {
            status.uvVersion = Self.parseUVVersion(result.stdout)
        }
        if isExecutable(paths.mlxServer.path) {
            status.serverPath = paths.mlxServer.path
            status.isOwnInstall = true
            if let uv = status.uvPath, let result = try? await runner.run("/usr/bin/env", environmentArguments() + [uv, "tool", "list"]), result.succeeded {
                status.mlxVersion = Self.parseToolList(result.stdout)[AIConfig.mlxPackage]
            }
        } else {
            status.serverPath = Self.otherServerPaths.map(AIConfig.expand).first(where: isExecutable)
        }
        return status
    }

    /// `KEY=value` pairs that keep uv inside our folder.
    public func environment() -> [String: String] {
        [
            "UV_TOOL_DIR": paths.tools.path,
            "UV_TOOL_BIN_DIR": paths.bin.path,
            "UV_PYTHON_INSTALL_DIR": paths.python.path,
            // Our own Python build, never one from pyenv or Homebrew that could change under us.
            "UV_PYTHON_PREFERENCE": "only-managed",
            // Slow or filtered networks: uv gives up after 30 s by default, and the Python build
            // alone is about 18 MB from GitHub. Wait longer and retry before failing.
            "UV_HTTP_TIMEOUT": String(AIConfig.mlxInstallHTTPTimeoutSeconds),
            "UV_HTTP_RETRIES": String(AIConfig.mlxInstallHTTPRetries),
            // No cache left behind. mlx-lm and its wheels are about 400 MB.
            "UV_NO_CACHE": "1",
            "UV_NO_MODIFY_PATH": "1"
        ]
    }

    func environmentArguments() -> [String] {
        environment().sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    }

    /// `/usr/bin/env ... uv tool install --python 3.12 mlx-lm`.
    public func installArguments(uv: String, upgrade: Bool = false) -> [String] {
        var args = environmentArguments() + [uv, "tool", "install", "--python", AIConfig.mlxPythonVersion]
        if upgrade { args += ["--upgrade"] }
        return args + [AIConfig.mlxPackage]
    }

    /// The command people can run themselves, for the CommandHint.
    public func installCommandLine(uv: String) -> String {
        installArguments(uv: uv).map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
    }

    /// Installs (or upgrades) mlx-lm. Streams uv's output.
    public func install(uv: String, upgrade: Bool = false) -> AsyncThrowingStream<String, Error> {
        try? FileManager.default.createDirectory(at: paths.bin, withIntermediateDirectories: true)
        return streamer.stream("/usr/bin/env", installArguments(uv: uv, upgrade: upgrade))
    }

    /// Downloads uv into our bin folder when none is installed. Returns its path.
    public func installUV(session: URLSession = .shared) async throws -> String {
        let (file, response) = try await session.download(from: AIConfig.uvDownloadURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw DeckError.network("Could not download uv.")
        }
        try FileManager.default.createDirectory(at: paths.bin, withIntermediateDirectories: true)
        let result = try await runner.run("/usr/bin/tar", ["-xzf", file.path, "-C", paths.bin.path, "--strip-components", "1"])
        try? FileManager.default.removeItem(at: file)
        try result.orThrow()
        guard isExecutable(paths.ownUV.path) else { throw DeckError.commandFailed("uv was downloaded but could not be unpacked.") }
        return paths.ownUV.path
    }

    /// Removes mlx-lm, its Python and our uv. Downloaded models stay.
    public func uninstall() throws {
        for url in [paths.tools, paths.python, paths.bin] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Bytes the runtime uses on disk (without models).
    public func runtimeBytes() -> UInt64 {
        [paths.tools, paths.python, paths.bin].reduce(0) { $0 + LocalModelStore.folderSize($1) }
    }

    // MARK: Parsing

    /// "uv 0.9.28 (Homebrew 2026-01-29)" gives "0.9.28".
    public static func parseUVVersion(_ text: String) -> String? {
        let parts = text.split(separator: " ")
        guard parts.count >= 2, parts[0] == "uv" else { return nil }
        return String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `uv tool list`: "mlx-lm v0.32.2" lines, executables on "- name" lines. Gives name to version.
    public static func parseToolList(_ text: String) -> [String: String] {
        var tools: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("-"), !line.isEmpty else { continue }
            let parts = line.split(separator: " ")
            guard parts.count >= 2, parts[1].hasPrefix("v") else { continue }
            tools[String(parts[0])] = String(parts[1].dropFirst())
        }
        return tools
    }
}
