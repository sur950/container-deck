import Foundation
import CryptoKit

/// What an update reports while it runs.
public enum ComponentUpdateEvent: Sendable, Equatable {
    case step(index: Int, label: String, cancellable: Bool)
    case log(String)
    /// Download fraction 0...1, nil while the size is unknown.
    case progress(Double?)
    /// Done. The row read again afterwards, when it could be read.
    case finished(ComponentInfo?)
    /// The health checks after the change.
    case health(ComponentHealthReport)
}

/// Runs a `ComponentUpdatePlan` step by step and streams its log.
///
/// Steps that are not safe to stop halfway (installing, Homebrew, uv) run to the end even when
/// the stream is cancelled. When something fails after the container service was stopped, the
/// service is started again so the Mac is never left without it.
///
/// With a stand in tools folder (debug builds) nothing outside that folder and the app's AI folder
/// runs: no password prompt, no network installs, no pulls, no stopping real servers.
public struct ComponentUpdater: Sendable {
    let runner: any CommandRunning
    let streamer: any CommandStreaming
    let toolsDirectory: String?
    let aiPaths: AIPaths
    let client: ContainerClient?
    let secrets: any SecretStore
    let mcpServers: [MCPInstalledServer]
    let workRoot: URL
    let recheck: @Sendable () async -> ComponentInfo?
    let health: @Sendable (ComponentInfo?) async -> ComponentHealthReport?

    public init(runner: any CommandRunning = ProcessRunner(), streamer: any CommandStreaming = ProcessRunner(),
                toolsDirectory: String? = ComponentChecker.debugToolsDirectory, aiPaths: AIPaths = AIPaths(),
                client: ContainerClient? = nil, secrets: any SecretStore = KeychainSecretStore(),
                mcpServers: [MCPInstalledServer] = [], workRoot: URL = FileManager.default.temporaryDirectory,
                recheck: @escaping @Sendable () async -> ComponentInfo? = { nil },
                health: @escaping @Sendable (ComponentInfo?) async -> ComponentHealthReport? = { _ in nil }) {
        self.runner = runner
        self.streamer = streamer
        self.toolsDirectory = toolsDirectory
        self.aiPaths = aiPaths
        self.client = client
        self.secrets = secrets
        self.mcpServers = mcpServers
        self.workRoot = workRoot
        self.recheck = recheck
        self.health = health
    }

    /// Shared between steps of one run.
    final class RunState: @unchecked Sendable {
        var packageFile: URL?
        var package: PackageRef?
        var serviceStopped = false
        /// Real runs: the uninstall waits for the install, so both share one password prompt.
        var pendingUninstall: String?
        /// The uninstall ran (alone or with the install). A failure after it cannot start the old version.
        var uninstalled = false
        /// Containers running before a downgrade, by id.
        var runningContainers: [String] = []
        /// The row from the last `recheck`.
        var rechecked: ComponentInfo?
    }

    public func run(_ plan: ComponentUpdatePlan, containerPath: String?) -> AsyncThrowingStream<ComponentUpdateEvent, Error> {
        AsyncThrowingStream { continuation in
            let state = RunState()
            let task = Task {
                do {
                    for (index, step) in plan.steps.enumerated() {
                        try Task.checkCancellation()
                        continuation.yield(.step(index: index, label: step.label, cancellable: step.isCancellable))
                        if step.isCancellable {
                            try await perform(step, plan: plan, containerPath: containerPath, state: state, emit: { continuation.yield($0) })
                        } else {
                            // Not cut short by a cancel: an unstructured task does not inherit it.
                            let work = Task {
                                try await perform(step, plan: plan, containerPath: containerPath, state: state, emit: { continuation.yield($0) })
                            }
                            try await work.value
                        }
                    }
                    cleanUp(state)
                    continuation.finish()
                } catch {
                    await recover(state, containerPath: containerPath, emit: { continuation.yield($0) })
                    cleanUp(state)
                    continuation.finish(throwing: Self.friendly(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Steps

    func perform(_ step: ComponentUpdatePlan.Step, plan: ComponentUpdatePlan, containerPath: String?, state: RunState,
                 emit: @escaping @Sendable (ComponentUpdateEvent) -> Void) async throws {
        switch step {
        case .downloadPackage(let package):
            let folder = workRoot.appendingPathComponent("\(AppConfig.bundleID).component-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            state.packageFile = folder.appendingPathComponent(package.name)
            state.package = package
            emit(.log("Downloading \(package.url.absoluteString)"))
            emit(.progress(0))
            _ = try await UpdateInstaller(runner: runner).download(package.url, to: state.packageFile!) { fraction in
                emit(.progress(fraction))
            }
            emit(.progress(1))

        case .verifyPackage:
            guard let file = state.packageFile else { throw DeckError.commandFailed("Nothing was downloaded.") }
            if let digest = state.package?.digest, digest.hasPrefix("sha256:") {
                let actual = try Self.sha256(of: file)
                guard actual == String(digest.dropFirst(7)).lowercased() else {
                    throw DeckError.signatureInvalid("The download does not match GitHub's checksum.")
                }
                emit(.log("Checksum matches GitHub (sha256 \(actual.prefix(12)))."))
            }
            let pkgutil = toolsDirectory.map { $0 + "/pkgutil" } ?? "/usr/sbin/pkgutil"
            let result = try await runner.run(pkgutil, ["--check-signature", file.path])
            result.stdout.split(whereSeparator: \.isNewline).prefix(6).forEach { emit(.log(String($0))) }
            guard result.succeeded, result.stdout.contains("Status: signed"), result.stdout.contains("Apple Inc.") else {
                throw DeckError.signatureInvalid(result.failureMessage)
            }

        case .stopContainerService:
            let cli = try containerCLI(containerPath)
            state.serviceStopped = true
            let result = try await cli.stopService()
            log(result, emit)
            try result.orThrow()

        case .installPackage:
            guard let file = state.packageFile else { throw DeckError.commandFailed("Nothing was downloaded.") }
            let arguments = ["-pkg", file.path, "-target", "/"]
            let result: CommandResult
            if let toolsDirectory {
                result = try await runner.run(toolsDirectory + "/installer", arguments)
            } else if let script = state.pendingUninstall {
                // One password prompt for both: Apple's uninstall keeping data, then the older package.
                state.pendingUninstall = nil
                state.uninstalled = true
                result = try await PrivilegedRunner(runner: runner).run([[script, "-k"], ["/usr/sbin/installer"] + arguments])
            } else {
                result = try await PrivilegedRunner(runner: runner).run("/usr/sbin/installer", arguments)
            }
            log(result, emit)
            try result.orThrow()

        case .startContainerService:
            let cli = try containerCLI(containerPath)
            let result = try await cli.startService()
            log(result, emit)
            try result.orThrow()
            state.serviceStopped = false
            for _ in 0..<20 {
                if (try? await cli.isServiceRunning()) == true { break }
                try? await Task.sleep(for: .seconds(1))
            }

        case .stopMLXServer:
            guard toolsDirectory == nil else { emit(.log("Stand in tools: the MLX server is left alone.")); return }
            let controller = MLXServerController(paths: aiPaths)
            if controller.adopt() {
                await controller.stop()
                emit(.log("MLX server stopped."))
            } else {
                emit(.log("No MLX server was running."))
            }

        case .stopOllama:
            guard toolsDirectory == nil else { emit(.log("Stand in tools: Ollama is left alone.")); return }
            try await OllamaControl(runner: runner).stop()
            try? await Task.sleep(for: .seconds(1))
            emit(.log("Ollama stopped."))

        case .startOllama:
            guard toolsDirectory == nil else { emit(.log("Stand in tools: Ollama is left alone.")); return }
            try await OllamaControl(runner: runner).start()
            emit(.log("Ollama started."))

        case .run(let executable, let arguments):
            if toolsDirectory != nil, !standInAllows(executable, arguments) {
                throw DeckError.commandFailed("Stand in tools: \(executable) is outside the stand in folder, so it did not run.")
            }
            emit(.log("$ " + ComponentUpdatePlanner.shortCommand(executable, arguments)))
            for try await line in streamer.stream(executable, arguments) {
                emit(.log(line))
            }

        case .downloadCloudflared:
            guard toolsDirectory == nil else { emit(.log("Stand in tools: download skipped.")); return }
            let path = try await CloudflaredInstaller(runner: runner).installDirect()
            emit(.log("Installed \(path)"))

        case .downloadCloudflaredVersion(let version):
            guard toolsDirectory == nil else { emit(.log("Stand in tools: download of cloudflared \(version) skipped.")); return }
            let path = try await CloudflaredInstaller(runner: runner).installVersion(version)
            emit(.log("Installed \(path)"))

        case .downloadUV:
            guard toolsDirectory == nil else { emit(.log("Stand in tools: download skipped.")); return }
            let path = try await MLXRuntime(paths: aiPaths, runner: runner).installUV()
            emit(.log("Installed \(path)"))

        case .pullImage(let image):
            guard toolsDirectory == nil else {
                emit(.log("Stand in tools: pull of \(image) skipped."))
                return
            }
            guard let client else { throw DeckError.notInstalled }
            for try await line in client.pullImage(image) {
                emit(.log(line))
            }

        case .recreateMCPServer(let name):
            guard toolsDirectory == nil else { emit(.log("Stand in tools: \(name) is left alone.")); return }
            guard let client, let server = mcpServers.first(where: { $0.name == name }) else { throw DeckError.notInstalled }
            var values: [String: String] = [:]
            for key in server.secretKeys {
                if let value = try await secrets.value(service: AgentsConfig.secretService,
                                                       account: MCPLaunch.secretAccount(server: server.name, key: key)) {
                    values[key] = value
                }
            }
            let id = try await client.startMCPServer(server, secrets: values)
            emit(.log("Started \(id)."))

        case .recheck:
            let info = await recheck()
            state.rechecked = info
            if let installed = info?.installed { emit(.log("Installed version: \(installed)")) }
            emit(.finished(info))

        case .recordRunningContainers:
            let cli = try containerCLI(containerPath)
            if let result = try? await cli.run(["list", "--format", "json"]), result.succeeded,
               let list = try? ContainerOutputParser.containers(result.stdout) {
                state.runningContainers = list.filter(\.isRunning).map(\.id)
            }
            emit(.log(state.runningContainers.isEmpty ? "No containers are running."
                      : "Running now: " + state.runningContainers.joined(separator: ", ")))

        case .uninstallKeepingData(let script):
            if let toolsDirectory {
                let result = try await runner.run(toolsDirectory + "/" + (script as NSString).lastPathComponent, ["-k"])
                state.uninstalled = true
                log(result, emit)
                try result.orThrow()
            } else {
                state.pendingUninstall = script
                emit(.log("\((script as NSString).lastPathComponent) -k runs with the install, behind one password prompt."))
            }

        case .healthCheck:
            guard let report = await health(state.rechecked) else {
                emit(.log("No checks for this tool."))
                return
            }
            for check in report.checks {
                let mark: String
                switch check.outcome {
                case .passed: mark = "Passed"
                case .failed: mark = "Failed"
                case .skipped: mark = "Skipped"
                }
                emit(.log("\(mark): \(check.text)" + (check.detail.map { " (\($0))" } ?? "")))
            }
            emit(.health(report))

        case .backupContainerData(let folder):
            let home = toolsDirectory.map { $0 + "/home" } ?? NSHomeDirectory()
            let data = home + "/Library/Application Support/com.apple.container"
            let config = home + "/.config/container"
            try await runner.run("/bin/mkdir", ["-p", folder]).orThrow()
            // -c clones on APFS: no extra space, no time. The service is stopped, so the copy is consistent.
            let copied = try await runner.run("/bin/cp", ["-cR", data, folder + "/com.apple.container"])
            log(copied, emit)
            try copied.orThrow()
            if FileManager.default.fileExists(atPath: config) {
                try await runner.run("/bin/cp", ["-cR", config, folder + "/config-container"]).orThrow()
            }
            emit(.log("Backed up to \(folder)"))

        case .restartContainers:
            guard !state.runningContainers.isEmpty else { emit(.log("Nothing to start.")); return }
            let cli = try containerCLI(containerPath)
            var failed: [String] = []
            for id in state.runningContainers {
                let result = try await cli.run(["start", id])
                if result.succeeded { emit(.log("Started \(id).")) } else { failed.append(id); log(result, emit) }
            }
            if !failed.isEmpty {
                throw DeckError.commandFailed("These containers did not start: \(failed.joined(separator: ", ")). Start them from Containers.")
            }
        }
    }

    /// After a failure: never leave the container service stopped.
    func recover(_ state: RunState, containerPath: String?, emit: @escaping @Sendable (ComponentUpdateEvent) -> Void) async {
        if state.uninstalled, state.serviceStopped {
            emit(.log("Apple container was removed but the older version did not install. Your data is kept. Install it from \(VersionCompatibility.releasesURL.absoluteString)."))
        }
        guard state.serviceStopped, let cli = try? containerCLI(containerPath) else { return }
        emit(.log("Starting the container service again."))
        let result = try? await cli.startService()
        if let result { log(result, emit) }
        state.serviceStopped = false
    }

    func cleanUp(_ state: RunState) {
        if let file = state.packageFile {
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
    }

    func containerCLI(_ path: String?) throws -> ContainerCLI {
        if let toolsDirectory { return ContainerCLI(path: toolsDirectory + "/container", runner: runner) }
        guard let path else { throw DeckError.notInstalled }
        return ContainerCLI(path: path, runner: runner)
    }

    /// Stand in runs: only programs in the stand in folder or the app's AI folder.
    func standInAllows(_ executable: String, _ arguments: [String]) -> Bool {
        guard let toolsDirectory else { return true }
        let allowed = [toolsDirectory, aiPaths.base.path]
        func inside(_ path: String) -> Bool { allowed.contains { path.hasPrefix($0 + "/") } }
        switch (executable as NSString).lastPathComponent {
        case "env":
            guard let tool = arguments.first(where: { !$0.contains("=") }) else { return false }
            return inside(tool)
        case "bash", "sh":
            guard let script = arguments.first, !script.hasPrefix("-") else { return false }
            return inside(script)
        default:
            return inside(executable)
        }
    }

    func log(_ result: CommandResult, _ emit: (ComponentUpdateEvent) -> Void) {
        for line in (result.stdout + "\n" + result.stderr).split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { emit(.log(text)) }
        }
    }

    /// SHA-256 of a file, read in pieces.
    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The password prompt's Cancel reads as a plain sentence.
    static func friendly(_ error: Error) -> Error {
        let text = error.localizedDescription
        if text.contains("-128") || text.lowercased().contains("user canceled") {
            return DeckError.commandFailed("The password prompt was closed. Nothing was installed.")
        }
        return error
    }
}
