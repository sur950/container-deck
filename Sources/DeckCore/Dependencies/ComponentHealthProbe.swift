import Foundation

/// Quick read only checks of the features Container Deck needs from each tool. Runs when a tool's
/// version changes (updated in the app, in Terminal or with Homebrew), after every in-app update
/// or switch, and on Check Now. Screens add real failures with `ComponentHealth.report`.
///
/// Never starts, stops or changes anything: only version and list commands, `--help` text,
/// GET requests to servers that already run, and reading config files. A server that is not
/// running makes its checks "skipped", never "failed".
public struct ComponentHealthProbe: Sendable {
    /// What a direct API ping to the container service said.
    public enum DirectPing: Sendable, Equatable {
        case answered(version: String)
        case stopped
        case failed(String)
        /// Not available here (stand in tools without a stand in answer).
        case unavailable
    }

    public var system: ComponentSystem
    public var http: any ComponentHTTPFetching
    public var ollamaURL: URL
    public var aiPaths: AIPaths
    /// ~/Library/Application Support/com.apple.container, where the kernel lives.
    public var containerAppRoot: String
    public var agentResolver: AgentPathResolver
    public var directPing: @Sendable () async -> DirectPing

    public init(system: ComponentSystem = .live(), http: any ComponentHTTPFetching = URLSessionComponentHTTP(),
                ollamaURL: URL = AIConfig.ollamaURL, aiPaths: AIPaths = AIPaths(),
                containerAppRoot: String = NSHomeDirectory() + "/Library/Application Support/com.apple.container",
                agentResolver: AgentPathResolver = .standard(),
                directPing: @escaping @Sendable () async -> DirectPing = ComponentHealthProbe.liveDirectPing) {
        self.system = system
        self.http = http
        self.ollamaURL = ollamaURL
        self.aiPaths = aiPaths
        self.containerAppRoot = containerAppRoot
        self.agentResolver = agentResolver
        self.directPing = directPing
    }

    /// Pings Apple's container service over XPC, like the backend selector.
    public static let liveDirectPing: @Sendable () async -> DirectPing = {
        do {
            let health = try await DirectAPIClient().ping()
            return .answered(version: health.version)
        } catch APIError.serviceUnavailable {
            return .stopped
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// The tools this probe knows. MCP images have no checks.
    public static func hasChecks(_ kind: ComponentKind) -> Bool { kind != .mcp }

    /// The checks for one row. nil for rows without checks or without an installed tool.
    public func probe(_ row: ComponentInfo) async -> ComponentHealthReport? {
        guard Self.hasChecks(row.kind), row.status != .notInstalled else { return nil }
        let checks: [HealthCheck]
        switch row.kind {
        case .container: checks = await container(row)
        case .ollama: checks = await ollama(row)
        case .mlx: checks = await mlx(row)
        case .lmStudio: checks = await lmStudio(row)
        case .uv: checks = await uv(row)
        case .cloudflared: checks = await cloudflared(row)
        case .ngrok: checks = await ngrok(row)
        case .tailscale: checks = await tailscale(row)
        case .kubectl: checks = await kubectl(row)
        case .helm: checks = await helm(row)
        case .agent: checks = await agent(row)
        case .mcp: return nil
        }
        guard !checks.isEmpty else { return nil }
        return ComponentHealthReport(componentID: row.id, version: row.installed, checks: checks)
    }

    // MARK: Running

    func run(_ executable: String, _ arguments: [String]) async -> CommandResult? {
        try? await system.runner.run(executable, arguments)
    }

    /// stdout and stderr together, whatever the exit code (help text often goes to stderr).
    func text(_ executable: String, _ arguments: [String]) async -> String? {
        guard let result = await run(executable, arguments) else { return nil }
        return result.stdout + "\n" + result.stderr
    }

    // MARK: Apple container

    func container(_ row: ComponentInfo) async -> [HealthCheck] {
        guard let cli = row.location else { return [] }
        var checks: [HealthCheck] = []
        let status = await run(cli, ["system", "status"])
        let running = HealthChecks.serviceRunning(status)
        checks.append(HealthChecks.check("container.service.cli", "The container service answers the container command",
                                         "The container service doesn't answer the container command",
                                         running ? .passed : .skipped, running ? nil : "The container service is stopped."))
        switch await directPing() {
        case .answered:
            checks.append(HealthChecks.check("container.service.api", "The container service answers the app directly",
                                             "The container service doesn't answer the app directly", .passed))
        case .stopped:
            checks.append(HealthChecks.check("container.service.api", "The container service answers the app directly",
                                             "The container service doesn't answer the app directly", .skipped, "The container service is stopped."))
        case .failed(let reason):
            checks.append(HealthChecks.check("container.service.api", "The container service answers the app directly",
                                             "The container service doesn't answer the app directly",
                                             running ? .failed : .skipped, running ? reason : "The container service is stopped."))
        case .unavailable:
            break
        }

        let needsService: [(String, String, String, [String], (String) throws -> Void)] = [
            ("container.containers", "Containers can be listed", "Containers can't be listed",
             ["list", "--all", "--format", "json"], { _ = try ContainerOutputParser.containers($0) }),
            ("container.images", "Images can be listed", "Images can't be listed",
             ["image", "list", "--format", "json"], { _ = try ContainerOutputParser.images($0) }),
            ("container.volumes", "Volumes can be listed", "Volumes can't be listed",
             ["volume", "list", "--format", "json"], { _ = try ContainerOutputParser.volumes($0) }),
            ("container.networks", "Networks can be listed", "Networks can't be listed",
             ["network", "list", "--format", "json"], { _ = try ContainerOutputParser.networks($0) }),
            ("container.properties", "System settings can be read", "System settings can't be read",
             ["system", "property", "list", "--format", "json"], { try HealthChecks.requireProperties($0) })
        ]
        for (id, feature, failure, arguments, parse) in needsService {
            guard running else {
                checks.append(HealthChecks.check(id, feature, failure, .skipped, "The container service is stopped."))
                continue
            }
            checks.append(HealthChecks.parsed(id, feature, failure, await run(cli, arguments), parse: parse))
        }

        // Kubernetes clusters (Apple's cluster plugin), only when the plugin is there. Same
        // per-release rules as the Kubernetes screen: `k8s` before 1.6.1, JSON from 1.7.
        let features = ContainerPlatformFeatures(version: row.installed.flatMap { SemanticVersion.firstMatch(in: $0) })
        let help = await text(cli, [features.clusterCommand, "--help"]) ?? ""
        let clusterFeature = ("container.clusters", "Kubernetes clusters can be listed", "Kubernetes clusters can't be listed")
        if KubeClusterParser.isUnsupportedText(help) {
            checks.append(HealthChecks.check(clusterFeature.0, clusterFeature.1, clusterFeature.2, .skipped, "The cluster plugin isn't installed."))
        } else if !running {
            checks.append(HealthChecks.check(clusterFeature.0, clusterFeature.1, clusterFeature.2, .skipped, "The container service is stopped."))
        } else {
            let listing = features.clusterListJSON
                ? await run(cli, [features.clusterCommand, "list", "--format", "json"])
                : await run(cli, [features.clusterCommand, "list"])
            checks.append(HealthChecks.parsed(clusterFeature.0, clusterFeature.1, clusterFeature.2, listing,
                                              parse: features.clusterListJSON ? HealthChecks.requireClusterJSON : HealthChecks.requireClusterTable))
        }

        checks.append(HealthChecks.kernel(files: system.listDirectory(containerAppRoot + "/kernels")))
        return checks
    }

    // MARK: Ollama

    func ollama(_ row: ComponentInfo) async -> [HealthCheck] {
        let endpoints: [(String, String, String, String, (Data) -> Bool)] = [
            ("ollama.version", "Ollama's server answers", "Ollama's server doesn't answer", "api/version",
             { ModelDiscoveryParser.parseOllamaVersion($0) != nil }),
            ("ollama.models", "Downloaded models can be listed", "Downloaded models can't be listed", "api/tags",
             { ModelDiscoveryParser.parseOllamaTags($0) != nil }),
            ("ollama.loaded", "Loaded models can be listed", "Loaded models can't be listed", "api/ps",
             { HealthChecks.hasModelsArray($0) })
        ]
        var checks: [HealthCheck] = []
        var reachable = true
        for (id, feature, failure, path, parse) in endpoints {
            guard reachable else {
                checks.append(HealthChecks.check(id, feature, failure, .skipped, "Ollama is not running."))
                continue
            }
            do {
                let reply = try await http.get(ollamaURL.appendingPathComponent(path), timeout: 3)
                if reply.status == 200, parse(reply.body) {
                    checks.append(HealthChecks.check(id, feature, failure, .passed))
                } else {
                    checks.append(HealthChecks.check(id, feature, failure, .failed,
                                                     reply.status == 200 ? "The answer has a new format." : "HTTP \(reply.status) from /\(path)."))
                }
            } catch {
                // Not running: nothing to check, and the app never starts it here.
                reachable = false
                checks.append(HealthChecks.check(id, feature, failure, .skipped, "Ollama is not running."))
            }
        }
        if let cli = row.location, system.isExecutable(cli), !cli.hasSuffix(".app") {
            let version = await text(cli, ["-v"]).flatMap(ComponentParsers.ollamaVersion)
            checks.insert(HealthChecks.check("ollama.cli", "The ollama command reports its version", "The ollama command doesn't report its version",
                                             version != nil ? .passed : .failed), at: 0)
        }
        return checks
    }

    // MARK: MLX

    func mlx(_ row: ComponentInfo) async -> [HealthCheck] {
        guard row.method == .appRuntime else { return [] }
        let python = aiPaths.tools.appendingPathComponent("mlx-lm/bin/python").path
        var checks: [HealthCheck] = []
        let imports = await run(python, ["-c", "import mlx.core, mlx_lm, mlx_lm.server"])
        checks.append(HealthChecks.check("mlx.import", "mlx-lm loads", "mlx-lm doesn't load",
                                         imports?.succeeded == true ? .passed : .failed,
                                         imports?.succeeded == true ? nil : HealthChecks.lastLine(imports)))
        let server = row.location ?? aiPaths.mlxServer.path
        let help = await run(server, ["--help"])
        let flags = ["--model", "--host", "--port"]
        checks.append(HealthChecks.helpFlags("mlx.server", "The MLX server can start", "The MLX server can't start",
                                             help?.succeeded == true ? (help!.stdout + help!.stderr) : "", flags: flags))
        return checks
    }

    // MARK: LM Studio

    func lmStudio(_ row: ComponentInfo) async -> [HealthCheck] {
        guard row.method == .lmStudioScript, let lms = row.location else { return [] }
        var checks: [HealthCheck] = []
        let version = await run(lms, ["version"])
        checks.append(HealthChecks.check("lmstudio.cli", "The lms command runs", "The lms command doesn't run",
                                         version?.succeeded == true ? .passed : .failed, version?.succeeded == true ? nil : HealthChecks.lastLine(version)))
        let daemon = LMStudioRuntime.parseDaemonStatus(await text(lms, ["daemon", "status", "--json"]) ?? "")
        checks.append(HealthChecks.check("lmstudio.daemon", "LM Studio's service status can be read", "LM Studio's service status can't be read",
                                         daemon == .unknown ? .failed : .passed, daemon == .unknown ? "The answer has a new format." : nil))
        // `lms ls` and `lms ps` can wake LM Studio's service, so they run only while it already runs.
        let reads: [(String, String, String, [String], (String) throws -> Void)] = [
            ("lmstudio.models", "Downloaded models can be listed", "Downloaded models can't be listed", ["ls", "--json"],
             { try HealthChecks.requireJSONArray($0) }),
            ("lmstudio.loaded", "Loaded models can be listed", "Loaded models can't be listed", ["ps", "--json"],
             { try HealthChecks.requireJSONArray($0) }),
            ("lmstudio.server", "The LM Studio server status can be read", "The LM Studio server status can't be read", ["server", "status", "--json"],
             { if LMStudioRuntime.parseServerStatus($0) == nil { throw DeckError.parse("lms server status") } })
        ]
        for (id, feature, failure, arguments, parse) in reads {
            guard daemon == .running else {
                checks.append(HealthChecks.check(id, feature, failure, .skipped, "LM Studio is not running."))
                continue
            }
            checks.append(HealthChecks.parsed(id, feature, failure, await run(lms, arguments), parse: parse))
        }
        return checks
    }

    // MARK: uv, sharing and Kubernetes tools

    func uv(_ row: ComponentInfo) async -> [HealthCheck] {
        guard let path = row.location else { return [] }
        return [
            HealthChecks.version("uv.version", "uv", await text(path, ["--version"]), parse: ComponentParsers.uvVersion),
            HealthChecks.helpFlags("uv.install", "uv can install the MLX runtime", "uv can't install the MLX runtime",
                                   await text(path, ["tool", "install", "--help"]) ?? "", flags: ["--python", "--upgrade", "--force"])
        ]
    }

    func cloudflared(_ row: ComponentInfo) async -> [HealthCheck] {
        guard let path = row.location else { return [] }
        return [
            HealthChecks.version("cloudflared.version", "cloudflared", await text(path, ["--version"]), parse: ComponentParsers.cloudflaredVersion),
            HealthChecks.helpFlags("cloudflared.tunnel", "Cloudflare quick tunnels can start", "Cloudflare quick tunnels can't start",
                                   await text(path, ["tunnel", "--help"]) ?? "", flags: CloudflareShareFlags.used)
        ]
    }

    func ngrok(_ row: ComponentInfo) async -> [HealthCheck] {
        guard let path = row.location else { return [] }
        return [
            HealthChecks.version("ngrok.version", "ngrok", await text(path, ["version"]), parse: ComponentParsers.ngrokVersion),
            HealthChecks.helpFlags("ngrok.http", "ngrok shares can start", "ngrok shares can't start",
                                   await text(path, ["http", "--help"]) ?? "", flags: ["--log", "--log-format", "--url"])
        ]
    }

    func tailscale(_ row: ComponentInfo) async -> [HealthCheck] {
        guard let path = row.location else { return [] }
        return [
            HealthChecks.version("tailscale.version", "Tailscale", await text(path, ["version"]), parse: ComponentParsers.tailscaleVersion),
            HealthChecks.helpFlags("tailscale.funnel", "Tailscale Funnel shares can start", "Tailscale Funnel shares can't start",
                                   await text(path, ["funnel", "--help"]) ?? "", flags: ["--https"])
        ]
    }

    func kubectl(_ row: ComponentInfo) async -> [HealthCheck] {
        guard let path = row.location else { return [] }
        return [
            HealthChecks.version("kubectl.version", "kubectl", await text(path, ["version", "--client", "-o", "json"]), parse: ComponentParsers.kubectlVersion),
            HealthChecks.helpFlags("kubectl.portForward", "Kubernetes port forwards can start", "Kubernetes port forwards can't start",
                                   await text(path, ["port-forward", "--help"]) ?? "", flags: ["--address"]),
            // --kubeconfig, --context and --namespace are global flags, listed by `kubectl options`.
            HealthChecks.helpFlags("kubectl.global", "kubectl reads the app's cluster settings", "kubectl can't read the app's cluster settings",
                                   await text(path, ["options"]) ?? "", flags: ["--kubeconfig", "--context", "--namespace"]),
            HealthChecks.helpFlags("kubectl.apply", "Kubernetes manifests can be applied", "Kubernetes manifests can't be applied",
                                   await text(path, ["apply", "--help"]) ?? "", flags: ["--filename"])
        ]
    }

    func helm(_ row: ComponentInfo) async -> [HealthCheck] {
        guard let path = row.location else { return [] }
        return [HealthChecks.version("helm.version", "Helm", await text(path, ["version", "--short"]), parse: ComponentParsers.helmVersion)]
    }

    // MARK: AI agents

    func agent(_ row: ComponentInfo) async -> [HealthCheck] {
        guard let path = row.location, !path.isEmpty else { return [] }
        var checks = [HealthChecks.version("agent.version", row.name, await text(path, ["--version"]),
                                           parse: { ToolVersion.firstMatch(in: $0) })]
        guard let tool = AgentTool(rawValue: String(row.id.dropFirst("agent:".count))) else { return checks }
        if let config = agentResolver.configFile(tool), let file = config.path {
            checks.append(HealthChecks.configFile("agent.config", tool: row.name, path: file, data: system.readFile(file),
                                                  exists: system.fileExists(file)))
        }
        if let sessions = agentResolver.sessionsFolder(tool), let folder = sessions.path {
            let exists = system.fileExists(folder)
            checks.append(HealthChecks.check("agent.sessions", "\(row.name) sessions can be read", "\(row.name) sessions can't be read",
                                             exists ? .passed : .skipped, exists ? nil : HealthCheck.missingDetail))
        }
        return checks
    }
}

/// Flags the Cloudflare share provider passes (`tunnel --no-autoupdate --url <upstream>`).
public enum CloudflareShareFlags {
    public static let used = ["--no-autoupdate", "--url"]
}

/// Small pure builders for checks, tested with real output.
public enum HealthChecks {
    public static func check(_ id: String, _ feature: String, _ failure: String, _ outcome: HealthCheck.Outcome,
                             _ detail: String? = nil) -> HealthCheck {
        HealthCheck(id: id, feature: feature, failure: failure, outcome: outcome, detail: detail)
    }

    /// `container system status` says the service runs.
    public static func serviceRunning(_ result: CommandResult?) -> Bool {
        guard let result, result.succeeded else { return false }
        let text = (result.stdout + " " + result.stderr).lowercased()
        return !text.contains("not running") && !text.contains("not registered")
    }

    /// A command whose output must parse.
    public static func parsed(_ id: String, _ feature: String, _ failure: String, _ result: CommandResult?,
                              parse: (String) throws -> Void) -> HealthCheck {
        guard let result else { return check(id, feature, failure, .failed, "The command did not run.") }
        guard result.succeeded else { return check(id, feature, failure, .failed, lastLine(result) ?? "Exit code \(result.exitCode).") }
        do {
            try parse(result.stdout)
            return check(id, feature, failure, .passed)
        } catch {
            return check(id, feature, failure, .failed, "The output has a new format.")
        }
    }

    /// "<tool> reports its version".
    public static func version(_ id: String, _ tool: String, _ text: String?, parse: (String) -> ToolVersion?) -> HealthCheck {
        let ok = text.flatMap(parse) != nil
        return check(id, "\(tool) reports its version", "\(tool) doesn't report its version", ok ? .passed : .failed,
                     ok ? nil : "The version can't be read.")
    }

    /// `--help` text still lists every flag the app passes.
    public static func helpFlags(_ id: String, _ feature: String, _ failure: String, _ help: String, flags: [String]) -> HealthCheck {
        let missing = flags.filter { !mentions(help, flag: $0) }
        if missing.isEmpty { return check(id, feature, failure, .passed) }
        return check(id, feature, failure, .failed, "The help no longer lists " + missing.joined(separator: ", ") + ".")
    }

    /// The flag as a word in help text: "--url URL", "--address=[localhost]:", "-f, --filename=[]:".
    public static func mentions(_ help: String, flag: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: flag)
        return help.range(of: "(^|[\\s,\\[])" + escaped + "($|[\\s=,\\]:])", options: .regularExpression) != nil
    }

    /// `container system property list --format json`, with the kernel settings the app reads.
    public static func requireProperties(_ text: String) throws {
        let properties = try ContainerOutputParser.systemProperties(text)
        guard !properties.isEmpty else { throw DeckError.parse("system properties") }
    }

    /// `container cluster list`: empty, or the table with its CLUSTER header.
    public static func requireClusterTable(_ text: String) throws {
        let first = text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard first.isEmpty || first.hasPrefix("CLUSTER") else { throw DeckError.parse("cluster list") }
        if first.hasPrefix("CLUSTER"), text.split(whereSeparator: \.isNewline).count > 1, KubeClusterParser.parseTable(text).isEmpty {
            throw DeckError.parse("cluster list")
        }
    }

    /// `container cluster list --format json` (1.7 and newer): a JSON list of clusters.
    public static func requireClusterJSON(_ text: String) throws {
        _ = try KubeClusterParser.parseClusterJSON(text)
    }

    public static func requireJSONArray(_ text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) is [Any] else {
            throw DeckError.parse("JSON list")
        }
    }

    /// Ollama `/api/ps` and `/api/tags`: `{"models": [...]}`.
    public static func hasModelsArray(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["models"] is [Any]
    }

    /// The Linux kernel the container service boots (`kernels/default.kernel-*`).
    public static func kernel(files: [String]) -> HealthCheck {
        let ok = files.contains { $0.hasPrefix("default.kernel") }
        return check("container.kernel", "The Linux kernel is installed", "The Linux kernel is missing", ok ? .passed : .failed,
                     ok ? nil : "No default kernel in the container data folder.")
    }

    /// An agent's config file: missing is fine (never used), present must parse.
    public static func configFile(_ id: String, tool: String, path: String, data: Data?, exists: Bool) -> HealthCheck {
        let feature = "\(tool) settings can be read"
        let failure = "\(tool) settings can't be read"
        guard exists else { return check(id, feature, failure, .skipped, HealthCheck.missingDetail) }
        guard let data, let text = String(data: data, encoding: .utf8) else { return check(id, feature, failure, .failed, "The file can't be read.") }
        if path.hasSuffix(".toml") {
            // The TOML reader never throws, so reading it at all is the check.
            _ = TOMLEditor(text: text).mcpServers()
            return check(id, feature, failure, .passed)
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return check(id, feature, failure, .passed) }
        do {
            _ = try JSONCEditor(text: text).foundationValue()
            return check(id, feature, failure, .passed)
        } catch {
            return check(id, feature, failure, .failed, "The file has a new format.")
        }
    }

    /// The last line of a failed command, for the detail.
    public static func lastLine(_ result: CommandResult?) -> String? {
        guard let result else { return nil }
        let lines = (result.stderr + "\n" + result.stdout).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.last.map { $0.count > 160 ? String($0.prefix(159)) + "…" : $0 }
    }
}
