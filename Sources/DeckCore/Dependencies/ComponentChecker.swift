import Foundation

/// File and process access for the component checks, swapped for fakes in tests.
public struct ComponentSystem: Sendable {
    public var runner: any CommandRunning
    public var isExecutable: @Sendable (String) -> Bool
    public var fileExists: @Sendable (String) -> Bool
    /// Follows symlinks (a Homebrew link points into the Cellar or the Caskroom).
    public var resolve: @Sendable (String) -> String
    public var readFile: @Sendable (String) -> Data?
    public var listDirectory: @Sendable (String) -> [String]
    public var home: String

    public init(runner: any CommandRunning, isExecutable: @escaping @Sendable (String) -> Bool,
                fileExists: @escaping @Sendable (String) -> Bool, resolve: @escaping @Sendable (String) -> String,
                readFile: @escaping @Sendable (String) -> Data?, listDirectory: @escaping @Sendable (String) -> [String],
                home: String) {
        self.runner = runner
        self.isExecutable = isExecutable
        self.fileExists = fileExists
        self.resolve = resolve
        self.readFile = readFile
        self.listDirectory = listDirectory
        self.home = home
    }

    public static func live(runner: any CommandRunning = ProcessRunner()) -> ComponentSystem {
        ComponentSystem(
            runner: runner,
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            resolve: { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            readFile: { FileManager.default.contents(atPath: $0) },
            listDirectory: { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] },
            home: NSHomeDirectory()
        )
    }
}

/// Reads what is installed (read only commands and files) and what is published, then applies
/// `ComponentGate`. One `ComponentInfo` per row. Never throws: a tool that cannot be read shows
/// as not checked.
public struct ComponentChecker: Sendable {
    public var system: ComponentSystem
    public var fetcher: ComponentLatestFetcher
    /// The `container` command the app uses (Settings, Platform). nil: the usual places.
    public var containerPath: String?
    /// Debug builds: every tool is looked up only in this folder (stand in tools).
    public var toolsDirectory: String?
    public var aiPaths: AIPaths
    /// Application Support/<bundle id>/bin, where the app keeps its own cloudflared.
    public var shareToolsDirectory: String
    public var mcpServers: [MCPInstalledServer]
    public var localImages: @Sendable () async -> [ImageSummary]
    /// AI agent command line tools found on this Mac (path and version).
    public var agents: @Sendable () async -> [DetectedAgentTool]
    /// The tested version per component id. `ComponentGate.tested(for:)` (AppConfig) unless a test sets one.
    public var tested: @Sendable (String) -> ComponentGate.Tested? = { ComponentGate.tested(for: $0) }

    public init(system: ComponentSystem = .live(), fetcher: ComponentLatestFetcher = ComponentLatestFetcher(),
                containerPath: String? = nil, toolsDirectory: String? = ComponentChecker.debugToolsDirectory,
                aiPaths: AIPaths = AIPaths(), shareToolsDirectory: String = DomainsConfig.toolsDirectory().path,
                mcpServers: [MCPInstalledServer] = [], agents: (@Sendable () async -> [DetectedAgentTool])? = nil,
                localImages: @escaping @Sendable () async -> [ImageSummary] = { [] }) {
        self.system = system
        self.fetcher = fetcher
        self.containerPath = containerPath
        self.toolsDirectory = toolsDirectory
        self.aiPaths = aiPaths
        self.shareToolsDirectory = shareToolsDirectory
        self.mcpServers = mcpServers
        self.localImages = localImages
        self.agents = agents ?? Self.detectAgents(toolsDirectory: toolsDirectory)
    }

    /// Debug builds only: DECK_COMPONENTS_TOOLS_DIR, a folder of stand in tools (see `ComponentStandIn`).
    public static let debugToolsVariable = "DECK_COMPONENTS_TOOLS_DIR"
    public static var debugToolsDirectory: String? {
        #if DEBUG
        if let dir = ProcessInfo.processInfo.environment[debugToolsVariable], !dir.isEmpty { return dir }
        #endif
        return nil
    }

    /// Kinds with one fixed row. MCP servers add one row each.
    public static let fixedKinds: [ComponentKind] = [.container, .ollama, .mlx, .lmStudio, .uv, .cloudflared, .ngrok, .tailscale, .kubectl, .helm]

    /// Every row, in list order.
    public func checkAll(force: Bool = false) async -> [ComponentInfo] {
        let kinds = Self.fixedKinds + [.agent, .mcp]
        let results = await withTaskGroup(of: (Int, [ComponentInfo]).self) { group in
            for (index, kind) in kinds.enumerated() {
                group.addTask { (index, await self.check(kind, force: force)) }
            }
            var all: [(Int, [ComponentInfo])] = []
            for await item in group { all.append(item) }
            return all
        }
        return results.sorted { $0.0 < $1.0 }.flatMap(\.1)
    }

    public func check(_ kind: ComponentKind, force: Bool = false) async -> [ComponentInfo] {
        switch kind {
        case .container: return [await container(force: force)]
        case .ollama: return [await ollama(force: force)]
        case .mlx: return [await mlx(force: force)]
        case .lmStudio: return [await lmStudio(force: force)]
        case .uv: return await uv(force: force).map { [$0] } ?? []
        case .cloudflared: return [await cloudflared(force: force)]
        case .ngrok: return [await ngrok(force: force)]
        case .tailscale: return [await tailscale(force: force)]
        case .kubectl: return [await simpleBrewTool(.kubectl, binary: "kubectl", formula: "kubernetes-cli", arguments: ["version", "--client", "-o", "json"],
                                                    parse: ComponentParsers.kubectlVersion, notes: { "https://github.com/kubernetes/kubernetes/releases/tag/v\($0)" },
                                                    download: "https://kubernetes.io/docs/tasks/tools/install-kubectl-macos/", force: force)]
        case .helm: return [await simpleBrewTool(.helm, binary: "helm", formula: "helm", arguments: ["version", "--short"],
                                                 parse: ComponentParsers.helmVersion, notes: { "https://github.com/helm/helm/releases/tag/v\($0)" },
                                                 download: "https://helm.sh/docs/intro/install/", force: force)]
        case .mcp: return await mcp(force: force)
        case .agent: return await agentRows(force: force)
        }
    }

    // MARK: - Finding tools

    func find(_ name: String, in candidates: [String]) -> String? {
        if let toolsDirectory { return [toolsDirectory + "/" + name].first(where: system.isExecutable) }
        return candidates.map(AIConfig.expand).first(where: system.isExecutable)
    }

    func findApp(_ name: String, at paths: [String]) -> String? {
        if let toolsDirectory { return [toolsDirectory + "/" + name].first(where: system.fileExists) }
        return paths.map(AIConfig.expand).first(where: system.fileExists)
    }

    /// Homebrew formula or cask behind a command, from where its link points.
    func homebrewMethod(for path: String) -> InstallMethod? {
        let resolved = system.resolve(path)
        if let formula = ComponentParsers.homebrewFormula(resolvedPath: resolved) { return .homebrewFormula(formula.name) }
        let parts = resolved.split(separator: "/").map(String.init)
        if let index = parts.firstIndex(of: "Caskroom"), index + 1 < parts.count { return .homebrewCask(parts[index + 1]) }
        return nil
    }

    func output(_ executable: String, _ arguments: [String]) async -> String? {
        guard let result = try? await system.runner.run(executable, arguments), result.succeeded else { return nil }
        return result.stdout + "\n" + result.stderr
    }

    func appVersion(_ app: String) -> ToolVersion? {
        system.readFile(app + "/Contents/Info.plist").flatMap(ComponentParsers.appVersion(infoPlist:))
    }

    // MARK: - Rows

    /// Reads the newest release and fills in a row. Nothing is blocked: a newer release is an update.
    /// `testedKey` picks another tested version than the row id (LM Studio's app).
    func finish(_ kind: ComponentKind, id: String? = nil, testedKey: String? = nil, name: String? = nil, location: String?,
                method: InstallMethod?, installed: ToolVersion?, found: Bool, source: LatestSource?,
                notes: ((ToolVersion) -> String)? = nil, download: String?, updatesItself: Bool = false, force: Bool) async -> ComponentInfo {
        let id = id ?? kind.rawValue
        let tested = self.tested(testedKey ?? id)
        var info = ComponentInfo(id: id, kind: kind, name: name ?? kind.title, location: location, method: method,
                                 installed: installed.map { Self.display($0, kind: kind) }, status: found ? .unknown : .notInstalled,
                                 downloadURL: download.flatMap(URL.init(string:)), testedText: tested?.text,
                                 updatesItself: updatesItself)
        guard found else { return info }
        if installed == nil { info.installed = "Unknown" }
        if let installed, let tested { info.matchesTested = tested.matches(installed) }
        guard let source, let releases = await fetcher.releases(source, force: force) else {
            info.note = installed == nil ? "Could not read the installed version." : "Could not check for a newer version."
            return info
        }
        let decision = ComponentGate.evaluate(installed: installed, available: releases.versions)
        info.latest = releases.newest.map { Self.display($0, kind: kind) }
        info.status = installed == nil ? .unknown : decision.status
        if installed == nil { info.note = "Could not read the installed version." }
        if case .update(let target) = decision.verdict { info.target = target.description }
        if let shown = releases.newest {
            info.notesURL = releases.notes[shown.description] ?? notes.flatMap { URL(string: $0(shown)) }
            info.notesSummary = releases.summaries?[shown.description] ?? []
        }
        return info
    }

    /// Version text as the tool writes it: LM Studio core "0.0.27-1", a cask "0.4.28" without its build.
    static func display(_ version: ToolVersion, kind: ComponentKind) -> String {
        if kind == .lmStudio, version.parts.count == 4 {
            return version.parts.prefix(3).map(String.init).joined(separator: ".") + "-\(version.parts[3])"
        }
        return version.description
    }

    // MARK: Apple container

    func container(force: Bool) async -> ComponentInfo {
        let path: String?
        if let toolsDirectory {
            path = [toolsDirectory + "/container"].first(where: system.isExecutable)
        } else {
            path = containerPath.flatMap { system.isExecutable($0) ? $0 : nil } ?? ContainerCLILocator.defaultCandidates.first(where: system.isExecutable)
        }
        var version: ToolVersion?
        if let path, let text = await output(path, ["--version"]) { version = ComponentParsers.containerVersion(text) }
        let method: InstallMethod? = path.map { homebrewMethod(for: $0) ?? .applePackage }
        return await finish(.container, location: path, method: method, installed: version, found: path != nil,
                            source: .githubReleases(AppConfig.appleContainerRepository),
                            notes: { "https://github.com/\(AppConfig.appleContainerRepository)/releases/tag/\($0)" },
                            download: VersionCompatibility.releasesURL.absoluteString, force: force)
    }

    // MARK: Ollama

    func ollama(force: Bool) async -> ComponentInfo {
        let cli = find("ollama", in: AIConfig.ollamaSearchPaths)
        let app = findApp("Ollama.app", at: [AIConfig.ollamaApp])
        var method: InstallMethod?
        var version: ToolVersion?
        if let cli {
            version = await output(cli, ["-v"]).flatMap(ComponentParsers.ollamaVersion)
            if let brew = homebrewMethod(for: cli), case .homebrewFormula = brew {
                method = brew
            } else if system.resolve(cli).contains(".app/"), let app {
                method = .appBundle(app)
            } else if let app {
                method = .appBundle(app)
            } else {
                method = .other(cli)
            }
        } else if let app {
            method = .appBundle(app)
            version = appVersion(app)
        }
        let source: LatestSource
        switch method {
        case .appBundle: source = .homebrewCask("ollama-app")
        default: source = .homebrewFormula("ollama")
        }
        let manual: Bool
        switch method {
        case .homebrewFormula: manual = false
        default: manual = true
        }
        return await finish(.ollama, location: cli ?? app, method: method, installed: version, found: method != nil, source: source,
                            notes: { "https://github.com/ollama/ollama/releases/tag/v\($0)" }, download: "https://ollama.com/download",
                            updatesItself: manual, force: force)
    }

    // MARK: MLX

    func mlx(force: Bool) async -> ComponentInfo {
        let runtime = MLXRuntime(paths: aiPaths, runner: system.runner, isExecutable: system.isExecutable)
        let status = await runtime.status()
        if status.isOwnInstall {
            return await finish(.mlx, location: status.serverPath, method: .appRuntime,
                                installed: status.mlxVersion.flatMap(ToolVersion.init), found: true,
                                source: .pypi(AIConfig.mlxPackage), notes: { "https://github.com/ml-explore/mlx-lm/releases/tag/v\($0)" },
                                download: "https://pypi.org/project/mlx-lm/", force: force)
        }
        let path = toolsDirectory == nil ? status.serverPath : nil
        return await finish(.mlx, location: path, method: path.map { .other($0) }, installed: nil, found: path != nil,
                            source: .pypi(AIConfig.mlxPackage), notes: { "https://github.com/ml-explore/mlx-lm/releases/tag/v\($0)" },
                            download: "https://pypi.org/project/mlx-lm/", updatesItself: true, force: force)
    }

    // MARK: LM Studio

    func lmStudio(force: Bool) async -> ComponentInfo {
        let lms = find("lms", in: AIConfig.lmStudioCLIPaths)
        let folder = toolsDirectory.map { $0 + "/llmster" } ?? system.home + "/.lmstudio/llmster"
        let core = ComponentParsers.llmsterVersion(folders: system.listDirectory(folder))
        if let lms, core != nil || system.fileExists(folder) {
            var version = core
            if version == nil, let text = await output(lms, ["daemon", "status"]) { version = ComponentParsers.llmsterVersion(text) }
            return await finish(.lmStudio, name: "LM Studio core", location: lms, method: .lmStudioScript, installed: version, found: true,
                                source: .lmStudioScript, notes: { _ in "https://lmstudio.ai/changelog" },
                                download: AIConfig.lmStudioDownloadURL.absoluteString, force: force)
        }
        let app = findApp("LM Studio.app", at: AIConfig.lmStudioApps)
        return await finish(.lmStudio, testedKey: "lmstudio-app", location: app ?? lms, method: app.map { .appBundle($0) },
                            installed: app.flatMap(appVersion), found: app != nil, source: .homebrewCask(AIConfig.lmStudioCask),
                            notes: { _ in "https://lmstudio.ai/changelog" }, download: AIConfig.lmStudioDownloadURL.absoluteString,
                            updatesItself: true, force: force)
    }

    // MARK: uv

    func uv(force: Bool) async -> ComponentInfo? {
        let own = aiPaths.ownUV.path
        let path: String?
        if system.isExecutable(own) {
            path = own
        } else {
            path = find("uv", in: AIConfig.uvSearchPaths)
        }
        guard let path else { return nil }
        let version = await output(path, ["--version"]).flatMap(ComponentParsers.uvVersion)
        let method: InstallMethod = path == own ? .appDownload : (homebrewMethod(for: path) ?? .other(path))
        let source: LatestSource
        if case .homebrewFormula(let name) = method { source = .homebrewFormula(name) } else { source = .pypi("uv") }
        let manual: Bool
        switch method {
        case .appDownload, .homebrewFormula: manual = false
        default: manual = true
        }
        return await finish(.uv, location: path, method: method, installed: version, found: true, source: source,
                            notes: { "https://github.com/astral-sh/uv/releases/tag/\($0)" },
                            download: "https://docs.astral.sh/uv/getting-started/installation/", updatesItself: manual, force: force)
    }

    // MARK: Sharing tools

    func cloudflared(force: Bool) async -> ComponentInfo {
        let own = shareToolsDirectory + "/cloudflared"
        let path = find("cloudflared", in: DomainsConfig.toolSearchPaths.map { $0 + "/cloudflared" } + [own])
        let version = await path.asyncMap { await output($0, ["--version"]) }?.flatMap(ComponentParsers.cloudflaredVersion)
        var method: InstallMethod?
        if let path { method = path == own ? .appDownload : (homebrewMethod(for: path) ?? .other(path)) }
        let source: LatestSource
        switch method {
        case .homebrewFormula(let name): source = .homebrewFormula(name)
        case .appDownload: source = .githubLatest(DomainsConfig.cloudflaredRepository)
        default: source = .homebrewFormula("cloudflared")
        }
        let manual: Bool
        switch method {
        case .appDownload, .homebrewFormula: manual = false
        default: manual = true
        }
        return await finish(.cloudflared, location: path, method: method, installed: version, found: path != nil, source: source,
                            notes: { "https://github.com/cloudflare/cloudflared/releases/tag/\($0)" },
                            download: "https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/",
                            updatesItself: manual, force: force)
    }

    func ngrok(force: Bool) async -> ComponentInfo {
        let path = find("ngrok", in: DomainsConfig.toolSearchPaths.map { $0 + "/ngrok" })
        let version = await path.asyncMap { await output($0, ["version"]) }?.flatMap(ComponentParsers.ngrokVersion)
        let method: InstallMethod? = path.map { homebrewMethod(for: $0) ?? .other($0) }
        let source: LatestSource
        if case .homebrewFormula(let name) = method { source = .homebrewFormula(name) } else { source = .homebrewCask("ngrok") }
        let manual: Bool
        switch method {
        case .homebrewFormula, .homebrewCask: manual = false
        default: manual = true
        }
        return await finish(.ngrok, location: path, method: method, installed: version, found: path != nil, source: source,
                            notes: { _ in "https://ngrok.com/docs/agent/changelog/" }, download: DomainsConfig.ngrokDownloadPage,
                            updatesItself: manual, force: force)
    }

    func tailscale(force: Bool) async -> ComponentInfo {
        let app = toolsDirectory == nil ? DomainsConfig.tailscaleAppBinary : (toolsDirectory! + "/Tailscale.app/Contents/MacOS/Tailscale")
        let path = find("tailscale", in: DomainsConfig.toolSearchPaths.map { $0 + "/tailscale" }) ?? (system.isExecutable(app) ? app : nil)
        let version = await path.asyncMap { await output($0, ["version"]) }?.flatMap(ComponentParsers.tailscaleVersion)
        var method: InstallMethod?
        if let path {
            if let brew = homebrewMethod(for: path) {
                method = brew
            } else if path == app || system.resolve(path).contains("Tailscale.app/") {
                method = .appBundle((app as NSString).deletingLastPathComponent.replacingOccurrences(of: "/Contents/MacOS", with: ""))
            } else {
                method = .other(path)
            }
        }
        let source: LatestSource
        switch method {
        case .homebrewFormula(let name): source = .homebrewFormula(name)
        default: source = .homebrewCask("tailscale-app")
        }
        let manual: Bool
        if case .homebrewFormula = method { manual = false } else { manual = true }
        return await finish(.tailscale, location: path, method: method, installed: version, found: path != nil, source: source,
                            notes: { _ in "https://tailscale.com/changelog" }, download: DomainsConfig.tailscaleDownloadPage,
                            updatesItself: manual, force: force)
    }

    // MARK: Kubernetes tools

    func simpleBrewTool(_ kind: ComponentKind, binary: String, formula: String, arguments: [String],
                        parse: @escaping (String) -> ToolVersion?, notes: @escaping (ToolVersion) -> String,
                        download: String, force: Bool) async -> ComponentInfo {
        let path = find(binary, in: KubeTools.searchFolders(home: system.home).map { $0 + "/" + binary })
        let version = await path.asyncMap { await output($0, arguments) }?.flatMap(parse)
        let method: InstallMethod? = path.map { homebrewMethod(for: $0) ?? .other($0) }
        let manual: Bool
        if case .homebrewFormula = method { manual = false } else { manual = true }
        let source: LatestSource
        if case .homebrewFormula(let name) = method { source = .homebrewFormula(name) } else { source = .homebrewFormula(formula) }
        return await finish(kind, location: path, method: method, installed: version, found: path != nil, source: source,
                            notes: notes, download: download, updatesItself: manual, force: force)
    }

    // MARK: MCP servers

    func mcp(force: Bool) async -> [ComponentInfo] {
        let servers = mcpServers.filter { $0.kind == .container && !$0.image.isEmpty }
        guard !servers.isEmpty else { return [] }
        let images = await localImages()
        var rows: [ComponentInfo] = []
        for server in servers {
            let canonical = PullReference.parse(server.image)?.canonical ?? server.image
            let local = images.first { $0.reference == canonical || $0.reference == server.image }
            var info = ComponentInfo(id: "mcp:\(server.name)", kind: .mcp, name: server.name, location: server.image,
                                     method: .containerImage(server.image), status: .notInstalled,
                                     downloadURL: Self.imagePage(server.image))
            guard let local, !local.digest.isEmpty else {
                info.note = "The image is not pulled yet. It is pulled the first time the server runs."
                rows.append(info)
                continue
            }
            info.installed = Self.shortDigest(local.digest)
            guard let remote = await fetcher.registryDigest(server.image, force: force) else {
                info.status = .unknown
                info.note = "Could not read the registry."
                rows.append(info)
                continue
            }
            info.latest = Self.shortDigest(remote)
            if remote == local.digest {
                info.status = .upToDate
            } else {
                info.status = .updateAvailable
                info.target = Self.shortDigest(remote)
                info.note = "A newer image is published for this tag."
            }
            rows.append(info)
        }
        return rows
    }

    /// "sha256:1a7a0996a565…" to "1a7a0996a565".
    public static func shortDigest(_ digest: String) -> String {
        let hex = digest.hasPrefix("sha256:") ? String(digest.dropFirst(7)) : digest
        return String(hex.prefix(12))
    }

    /// Docker Hub or GitHub page for an image.
    static func imagePage(_ image: String) -> URL? {
        guard let reference = PullReference.parse(image) else { return nil }
        if reference.isDockerHub {
            let path = reference.repository.contains("/") ? "r/\(reference.repository)" : "_/\(reference.repository)"
            return URL(string: "https://hub.docker.com/\(path)")
        }
        if reference.effectiveRegistry == "ghcr.io" {
            return URL(string: "https://github.com/\(reference.repository.split(separator: "/").prefix(2).joined(separator: "/"))")
        }
        return nil
    }
}

fileprivate extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async -> T) async -> T? {
        guard let value = self else { return nil }
        return await transform(value)
    }
}
