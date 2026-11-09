import Foundation

/// Small file system wrapper so checks can be tested without a real Mac.
public struct FileSystem: Sendable {
    public var fileExists: @Sendable (String) -> Bool
    public var isExecutable: @Sendable (String) -> Bool
    public var contentsOfDirectory: @Sendable (String) -> [String]
    /// Target of a symbolic link, nil when the path is not one. Tests replace it.
    public var symlinkDestination: @Sendable (String) -> String? = { try? FileManager.default.destinationOfSymbolicLink(atPath: $0) }

    public init(
        fileExists: @escaping @Sendable (String) -> Bool,
        isExecutable: @escaping @Sendable (String) -> Bool,
        contentsOfDirectory: @escaping @Sendable (String) -> [String]
    ) {
        self.fileExists = fileExists
        self.isExecutable = isExecutable
        self.contentsOfDirectory = contentsOfDirectory
    }

    public static let live = FileSystem(
        fileExists: { FileManager.default.fileExists(atPath: $0) },
        isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
        contentsOfDirectory: { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] }
    )
}

/// Finds the `container` binary.
public struct ContainerCLILocator: Sendable {
    public static let defaultCandidates = [
        "/usr/local/bin/container",
        "/opt/homebrew/bin/container"
    ]

    let files: FileSystem
    let pathEnv: String

    public init(files: FileSystem, pathEnv: String) {
        self.files = files
        self.pathEnv = pathEnv
    }

    /// Debug builds only: `DECK_CONTAINER_CLI=<path>` points the app at another `container`,
    /// for example an unpacked newer release started with its own `--app-root`. Release
    /// builds never read it.
    public static let debugOverrideVariable = "DECK_CONTAINER_CLI"

    /// Order: the debug override (debug builds), custom path from Settings, known install spots, then PATH.
    public func locate(customPath: String?) -> String? {
        var candidates: [String] = []
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment[Self.debugOverrideVariable], !override.isEmpty {
            candidates.append(override)
        }
        #endif
        if let customPath, !customPath.isEmpty {
            candidates.append(customPath)
        }
        candidates.append(contentsOf: Self.defaultCandidates)
        for dir in pathEnv.split(separator: ":") where !dir.isEmpty {
            candidates.append(String(dir) + "/container")
        }
        return candidates.first { files.isExecutable($0) }
    }
}

/// Thin wrapper over the `container` command line tool.
public struct ContainerCLI: Sendable {
    public let path: String
    let runner: any CommandRunning

    public init(path: String, runner: any CommandRunning) {
        self.path = path
        self.runner = runner
    }

    public func run(_ arguments: [String]) async throws -> CommandResult {
        try await runner.run(path, arguments)
    }

    public func version() async throws -> SemanticVersion? {
        let result = try await run(["--version"])
        guard result.succeeded else { return nil }
        return SemanticVersion.firstMatch(in: result.stdout + " " + result.stderr)
    }

    public func isServiceRunning() async throws -> Bool {
        let result = try await run(["system", "status"])
        guard result.succeeded else { return false }
        let text = (result.stdout + " " + result.stderr).lowercased()
        return !text.contains("not running") && !text.contains("not registered")
    }

    /// Starts the service. The kernel is installed as its own step,
    /// so we turn off the interactive kernel prompt here.
    public func startService() async throws -> CommandResult {
        try await run(["system", "start", "--disable-kernel-install"])
    }

    public func stopService() async throws -> CommandResult {
        try await run(["system", "stop"])
    }

    public func dnsDomains() async throws -> [String] {
        let result = try await run(["system", "dns", "list"])
        guard result.succeeded else { return [] }
        return result.stdout
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.uppercased() != "DOMAIN" }
    }
}
