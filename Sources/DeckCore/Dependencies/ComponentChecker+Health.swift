import Foundation

public extension ComponentChecker {
    /// Where every published version of a row's tool is listed, for picking the switch target.
    /// nil when no list exists (LM Studio, ngrok, Tailscale, apps).
    func downgradeSource(for row: ComponentInfo) -> LatestSource? {
        switch row.kind {
        case .container: return .githubReleases(AppConfig.appleContainerRepository)
        case .ollama: return .githubReleases("ollama/ollama")
        case .mlx: return .pypi(AIConfig.mlxPackage)
        case .uv: return .githubReleases("astral-sh/uv")
        case .cloudflared: return .githubReleases(DomainsConfig.cloudflaredRepository)
        case .kubectl: return .githubReleases("kubernetes/kubernetes")
        case .helm: return .githubReleases("helm/helm")
        case .lmStudio, .ngrok, .tailscale, .mcp: return nil
        case .agent:
            switch row.method {
            case .npmGlobal(let package, _): return .npmVersions(package)
            case .uvTool(let package), .pipx(let package): return .pypi(package)
            default: break
            }
            guard let tool = AgentTool(rawValue: String(row.id.dropFirst("agent:".count))) else { return nil }
            if let npm = tool.npmPackage { return .npmVersions(npm) }
            if let pypi = tool.pypiPackage { return .pypi(pypi) }
            if tool == .goose { return .githubReleases("block/goose") }
            if tool == .crush { return .githubReleases("charmbracelet/crush") }
            return nil
        }
    }

    /// The tested version key of a row: LM Studio's app has its own.
    static func testedKey(_ row: ComponentInfo) -> String {
        if row.kind == .lmStudio, case .appBundle = row.method { return "lmstudio-app" }
        return row.id
    }

    /// Every published version a switch can pick from. Empty when unknown.
    func publishedVersions(for row: ComponentInfo, force: Bool = false) async -> [ToolVersion] {
        guard let source = downgradeSource(for: row) else { return [] }
        return await fetcher.releases(source, force: force)?.versions ?? []
    }

    /// Runs the health checks where they are needed and fills in the "not working" state:
    /// - a tool whose version changed since its last report (or that has none yet) is checked now,
    /// - otherwise the last report of this version stays, with the failures screens reported,
    /// - `force` (Check Now) checks again, keeping reported failures of the same version.
    /// Reports are kept in `store`.
    func applyHealth(to rows: [ComponentInfo], probe: ComponentHealthProbe, store: ComponentHealthStore,
                     force: Bool = false) async -> [ComponentInfo] {
        await withTaskGroup(of: (Int, ComponentInfo).self) { group in
            for (index, row) in rows.enumerated() {
                group.addTask { (index, await self.applyHealth(to: row, probe: probe, store: store, force: force)) }
            }
            var result = rows
            for await (index, row) in group { result[index] = row }
            return result
        }
    }

    func applyHealth(to row: ComponentInfo, probe: ComponentHealthProbe, store: ComponentHealthStore,
                     force: Bool = false) async -> ComponentInfo {
        guard ComponentHealthProbe.hasChecks(row.kind), let installedText = row.installed,
              ToolVersion(installedText) != nil else { return row }
        let last = store.lastReport(row.id)
        var report = last?.version == installedText ? last : nil
        if report == nil || force {
            if var fresh = await probe.probe(row)?.comparing(with: store.goodReport(row.id)) {
                // Failures a screen reported for this version stay: they really happened.
                fresh.checks += (report?.checks ?? []).filter { $0.isReported && $0.outcome == .failed }
                store.record(fresh)
                report = fresh
            }
        }
        return await assess(row, report: report, force: force)
    }

    /// Fills in the state from a report: "Not working with this version" and the switch target.
    func assess(_ row: ComponentInfo, report: ComponentHealthReport?, force: Bool = false) async -> ComponentInfo {
        guard let report, !report.failed.isEmpty else {
            var row = row
            row.health = report
            return row
        }
        let tested = self.tested(Self.testedKey(row))
        let published = row.matchesTested ? [] : await publishedVersions(for: row, force: force)
        return ComponentHealthAssessment.apply(to: row, report: report, tested: tested, published: published)
    }
}

public extension ComponentStandIn {
    /// Debug builds: health checks against the stand in tools folder. Ollama answers from
    /// `<dir>/ollama-api/<path>.json` (no folder: not running), the direct API from
    /// `<dir>/container-api` ("ok", "stopped" or an error text), agents and the kernel from `<dir>/home`.
    static func probe(_ directory: String) -> ComponentHealthProbe {
        let home = directory + "/home"
        let resolver = AgentPathResolver(home: home, environment: [:], applicationFolders: [], systemFolders: [],
                                         toolsFolder: directory + "/agents")
        return ComponentHealthProbe(
            http: StandInHTTP(folder: directory + "/ollama-api"),
            containerAppRoot: home + "/Library/Application Support/com.apple.container",
            agentResolver: resolver,
            directPing: {
                guard let text = try? String(contentsOfFile: directory + "/container-api", encoding: .utf8) else { return .unavailable }
                let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
                switch answer {
                case "ok": return .answered(version: "stand in")
                case "stopped": return .stopped
                default: return .failed(answer)
                }
            })
    }

    /// Answers GET requests from files: `/api/tags` reads `<folder>/tags.json`. A missing folder
    /// fails like a server that is not running.
    struct StandInHTTP: ComponentHTTPFetching {
        let folder: String

        public func send(_ request: URLRequest) async throws -> HTTPReply {
            guard FileManager.default.fileExists(atPath: folder) else { throw URLError(.cannotConnectToHost) }
            let name = request.url?.lastPathComponent ?? ""
            guard let data = FileManager.default.contents(atPath: folder + "/" + name + ".json") else { return HTTPReply(status: 404) }
            return HTTPReply(status: 200, body: data)
        }
    }
}
