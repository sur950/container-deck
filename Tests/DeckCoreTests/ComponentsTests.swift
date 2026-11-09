import XCTest
@testable import DeckCore

// MARK: - Test doubles

/// Answers by matching the start of "executable args...". Records every call.
private final class ScriptedRunner: CommandRunning, @unchecked Sendable {
    var rules: [(prefix: String, result: CommandResult)] = []
    var fallback = CommandResult(exitCode: 0, stdout: "")
    private let lock = NSLock()
    private var recorded: [[String]] = []
    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return recorded }

    func on(_ prefix: String, _ stdout: String, exit: Int32 = 0, stderr: String = "") {
        rules.append((prefix, CommandResult(exitCode: exit, stdout: stdout, stderr: stderr)))
    }

    func run(_ executable: String, _ arguments: [String], stdin: Data?) async throws -> CommandResult {
        let call = [executable] + arguments
        lock.lock(); recorded.append(call); lock.unlock()
        let line = call.joined(separator: " ")
        return rules.first { line.hasPrefix($0.prefix) }?.result ?? fallback
    }
}

private final class LinesStreamer: CommandStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return recorded }
    var fail = false

    func stream(_ executable: String, _ arguments: [String]) -> AsyncThrowingStream<String, Error> {
        lock.lock(); recorded.append([executable] + arguments); lock.unlock()
        let fail = self.fail
        return AsyncThrowingStream { continuation in
            continuation.yield("line one")
            continuation.yield("line two")
            if fail {
                continuation.finish(throwing: DeckError.commandFailed("brew failed"))
            } else {
                continuation.finish()
            }
        }
    }
}

/// Replies by URL. Counts requests.
private final class FakeComponentHTTP: ComponentHTTPFetching, @unchecked Sendable {
    var replies: [String: HTTPReply] = [:]
    /// HEAD answers, by URL.
    var headReplies: [String: [HTTPReply]] = [:]
    var failAll = false
    private(set) var requests: [URLRequest] = []

    func send(_ request: URLRequest) async throws -> HTTPReply {
        requests.append(request)
        if failAll { throw URLError(.notConnectedToInternet) }
        let key = request.url?.absoluteString ?? ""
        if request.httpMethod == "HEAD", var queue = headReplies[key], !queue.isEmpty {
            let reply = queue.removeFirst()
            headReplies[key] = queue
            return reply
        }
        return replies[key] ?? HTTPReply(status: 404)
    }

    static func ok(_ text: String) -> HTTPReply { HTTPReply(status: 200, body: Data(text.utf8)) }
}

private func v(_ text: String) -> ToolVersion { ToolVersion(text)! }

private func tempFile(_ name: String = "cache.json") -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("deck-components-\(UUID().uuidString)").appendingPathComponent(name)
}

private final class Clock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
}

// MARK: - Versions

final class ComponentVersionTests: XCTestCase {
    func testToolVersionParsing() {
        XCTAssertEqual(v("1.6.1").parts, [1, 6, 1])
        XCTAssertEqual(v("v1.35.0").parts, [1, 35, 0])
        XCTAssertEqual(v("2026.10.7").parts, [2026, 10, 7])
        XCTAssertEqual(v("0.0.27-1").parts, [0, 0, 27, 1])
        XCTAssertEqual(v("0.0.27+1").parts, [0, 0, 27, 1])
        XCTAssertEqual(v("0.4.28,2").parts, [0, 4, 28, 2])
        XCTAssertEqual(v("v4.1.0+g4553a0a").parts, [4, 1, 0])
        XCTAssertFalse(v("v4.1.0+g4553a0a").isPrerelease)
        XCTAssertEqual(v("1.3.0-rc.1").prerelease, "rc.1")
        XCTAssertEqual(v("0.33.0rc1").prerelease, "rc1")
        XCTAssertEqual(v("1.6.1 (build: release)").parts, [1, 6, 1])
        XCTAssertNil(ToolVersion("unknown"))
        XCTAssertNil(ToolVersion(""))
    }

    func testToolVersionOrder() {
        XCTAssertEqual(v("0.0.27-1"), v("0.0.27+1"))
        XCTAssertGreaterThan(v("0.0.27-1"), v("0.0.27"))
        XCTAssertGreaterThan(v("0.0.28"), v("0.0.27-1"))
        XCTAssertLessThan(v("1.3.0-rc.1"), v("1.3.0"))
        XCTAssertLessThan(v("1.3.0-rc.2"), v("1.3.0-rc.10"))
        XCTAssertGreaterThan(v("2026.10.7"), v("2026.3.0"))
        XCTAssertGreaterThan(v("0.40.15"), v("0.16.2"))
        XCTAssertEqual(v("1.6"), v("1.6.0"))
        XCTAssertEqual(Set([v("1.6"), v("1.6.0")]).count, 1)
    }

    func testFirstMatch() {
        XCTAssertEqual(ToolVersion.firstMatch(in: "ollama version is 0.16.2"), v("0.16.2"))
        XCTAssertEqual(ToolVersion.firstMatch(in: "llmster v0.0.27+1 is running"), v("0.0.27-1"))
        XCTAssertNil(ToolVersion.firstMatch(in: "no numbers"))
    }

    func testInstalledVersionParsersWithRealOutput() {
        typealias P = ComponentParsers
        XCTAssertEqual(P.containerVersion(ComponentFixtures.containerVersion), v("1.6.1"))
        XCTAssertEqual(P.ollamaVersion(ComponentFixtures.ollamaVersion), v("0.16.2"))
        XCTAssertEqual(P.ollamaVersion(ComponentFixtures.ollamaClientWarning), v("0.17.0"))
        XCTAssertEqual(P.ollamaAPIVersion(Data(ComponentFixtures.ollamaAPIVersion.utf8)), v("0.16.2"))
        XCTAssertEqual(P.llmsterVersion(ComponentFixtures.llmsterStatus), v("0.0.27-1"))
        XCTAssertNil(P.llmsterVersion("llmster is not running"))
        XCTAssertEqual(P.llmsterVersion(folders: ["0.0.26-3", "0.0.27-1", ".DS_Store", "tmp"]), v("0.0.27-1"))
        XCTAssertTrue(P.lmsHasDaemonUpdate(ComponentFixtures.lmsDaemonHelp))
        XCTAssertFalse(P.lmsHasDaemonUpdate(ComponentFixtures.lmsDaemonHelpOld))
        XCTAssertEqual(P.uvVersion(ComponentFixtures.uvVersion), v("0.9.28"))
        XCTAssertEqual(P.uvToolVersion(ComponentFixtures.uvToolList, package: "mlx-lm"), v("0.32.2"))
        XCTAssertNil(P.uvToolVersion(ComponentFixtures.uvToolList, package: "other"))
        XCTAssertEqual(P.cloudflaredVersion(ComponentFixtures.cloudflaredVersion), v("2026.3.0"))
        XCTAssertEqual(P.kubectlVersion(ComponentFixtures.kubectlJSON), v("1.35.0"))
        XCTAssertEqual(P.kubectlVersion(ComponentFixtures.kubectlText), v("1.35.0"))
        XCTAssertEqual(P.helmVersion(ComponentFixtures.helmShort), v("4.1.0"))
        XCTAssertEqual(P.tailscaleVersion(ComponentFixtures.tailscaleVersion), v("1.104.5"))
        XCTAssertEqual(P.ngrokVersion(ComponentFixtures.ngrokVersion), v("3.24.0"))
        XCTAssertEqual(P.appVersion(infoPlist: Data(ComponentFixtures.infoPlist.utf8)), v("0.40.15"))
        XCTAssertTrue(P.isAdmin(groups: ComponentFixtures.idGroups))
        XCTAssertFalse(P.isAdmin(groups: ComponentFixtures.idGroupsStandard))
        let brew = P.homebrewFormula(resolvedPath: "/opt/homebrew/Cellar/ollama/0.16.2/bin/ollama")
        XCTAssertEqual(brew?.name, "ollama")
        XCTAssertEqual(brew?.version, v("0.16.2"))
        XCTAssertNil(P.homebrewFormula(resolvedPath: "/Applications/Ollama.app/Contents/Resources/ollama"))
    }

    func testLatestVersionParsersWithRealAnswers() throws {
        let releases = try ComponentParsers.githubReleases(Data(ComponentFixtures.containerReleases.utf8))
        XCTAssertEqual(releases.map(\.version), [v("1.7.1"), v("1.6.1"), v("1.6.0")])
        XCTAssertEqual(releases[0].signedPackage?.name, "container-1.7.1-installer-signed.pkg")
        XCTAssertEqual(releases[0].signedPackage?.digest, "sha256:b6739caf3d47ca53a78f1a7edf32521420a75c7941838c3cefa75f30b80f5a97")

        let one = try ComponentParsers.githubReleases(Data(ComponentFixtures.cloudflaredLatest.utf8))
        XCTAssertEqual(one.map(\.version), [v("2026.10.7")])

        let pypi = try ComponentParsers.pypiVersions(Data(ComponentFixtures.pypiMLX.utf8))
        XCTAssertEqual(pypi.latest, v("0.32.2"))
        // Yanked 0.31.0 and the empty 0.40.0 are skipped.
        XCTAssertEqual(Set(pypi.all), Set([v("0.32.1"), v("0.32.2"), v("0.33.0rc1")]))

        XCTAssertEqual(try ComponentParsers.homebrewFormulaVersion(Data(ComponentFixtures.brewOllama.utf8)), v("0.40.15"))
        let cask = try ComponentParsers.homebrewCaskVersion(Data(ComponentFixtures.caskLMStudio.utf8))
        XCTAssertEqual(cask.version, v("0.4.28.2"))
        XCTAssertTrue(cask.autoUpdates)
        XCTAssertEqual(ComponentParsers.lmStudioScriptVersion(ComponentFixtures.lmStudioScript), v("0.0.27-1"))
        XCTAssertThrowsError(try ComponentParsers.githubReleases(Data("nope".utf8)))
        XCTAssertThrowsError(try ComponentParsers.homebrewFormulaVersion(Data("{}".utf8)))
    }

    func testLatestReleasesSkipsPrereleasesAndKeepsPackages() throws {
        let releases = try LatestReleases.parse(Data(ComponentFixtures.containerReleasesWithPatch.utf8),
                                                source: .githubReleases("apple/container"))
        XCTAssertFalse(releases.versions.contains(v("1.8.0-beta.1")))
        XCTAssertEqual(releases.newest, v("1.7.1"))
        XCTAssertEqual(releases.packages["1.6.2"]?.name, "container-1.6.2-installer-signed.pkg")
        XCTAssertEqual(releases.notes["1.7.1"]?.absoluteString, "https://github.com/apple/container/releases/tag/1.7.1")
        let pypi = try LatestReleases.parse(Data(ComponentFixtures.pypiMLX.utf8), source: .pypi("mlx-lm"))
        XCTAssertFalse(pypi.versions.contains(where: \.isPrerelease))
    }
}

// MARK: - Compatibility gate

final class ComponentGateTests: XCTestCase {
    func testEveryNewerReleaseIsAnUpdate() {
        // Nothing is blocked: a new minor of Apple container and a new major of any tool update.
        XCTAssertEqual(ComponentGate.evaluate(installed: v("1.6.1"), available: [v("1.7.1"), v("1.6.2"), v("1.6.1")]).verdict, .update(to: v("1.7.1")))
        XCTAssertEqual(ComponentGate.evaluate(installed: v("0.16.2"), available: [v("1.0.0"), v("0.99.0")]).verdict, .update(to: v("1.0.0")))
        XCTAssertEqual(ComponentGate.evaluate(installed: v("2026.3.0"), available: [v("2027.1.0")]).verdict, .update(to: v("2027.1.0")))
        XCTAssertEqual(ComponentGate.evaluate(installed: v("1.6.1"), available: [v("1.7.1")]).status, .updateAvailable)
    }

    func testUpToDateUnknownAndNotInstalled() {
        XCTAssertEqual(ComponentGate.evaluate(installed: v("0.40.15"), available: [v("0.40.15")]).verdict, .upToDate)
        XCTAssertEqual(ComponentGate.evaluate(installed: v("1.8.0"), available: [v("1.7.1")]).verdict, .upToDate, "Newer than every release")
        XCTAssertEqual(ComponentGate.evaluate(installed: v("0.40.15"), available: []).verdict, .unknown)
        XCTAssertEqual(ComponentGate.evaluate(installed: nil, available: [v("1.0.0")]).verdict, .notInstalled)
    }

    func testPrereleasesAreIgnored() {
        XCTAssertEqual(ComponentGate.evaluate(installed: v("1.6.1"), available: [v("1.6.2-rc.1"), v("1.6.1")]).verdict, .upToDate)
    }

    func testTestedVersionsComeFromAppConfig() {
        let container = ComponentGate.tested(for: "container")
        let upper = AppConfig.apiSupportedVersions.upperBound
        XCTAssertEqual(container?.line, [upper.major, upper.minor - 1], "Apple container: the newest minor of apiSupportedVersions")
        for kind in ComponentChecker.fixedKinds {
            XCTAssertNotNil(ComponentGate.tested(for: kind.rawValue), "No tested version for \(kind.rawValue)")
        }
        XCTAssertNotNil(ComponentGate.tested(for: "lmstudio-app"))
        XCTAssertNil(ComponentGate.tested(for: "mcp:fetch"))
    }
}

// MARK: - Update plans

final class ComponentPlanTests: XCTestCase {
    private func row(_ kind: ComponentKind, _ method: InstallMethod, target: String? = "2.0.0", id: String? = nil,
                     status: ComponentStatus = .updateAvailable, updatesItself: Bool = false) -> ComponentInfo {
        ComponentInfo(id: id ?? kind.rawValue, kind: kind, name: kind.title, method: method, installed: "1.0.0", latest: target,
                      target: target, status: status, updatesItself: updatesItself)
    }

    let package = PackageRef(name: "container-1.6.2-installer-signed.pkg",
                             url: URL(string: "https://github.com/apple/container/releases/download/1.6.2/container-1.6.2-installer-signed.pkg")!,
                             digest: "sha256:00")

    func testContainerPlan() throws {
        let plan = try ComponentUpdatePlanner.plan(for: row(.container, .applePackage, target: "1.6.2"),
                                                   context: ComponentPlanContext(containerPath: "/usr/local/bin/container", package: package))
        XCTAssertEqual(plan.steps, [.downloadPackage(package), .verifyPackage, .stopContainerService, .installPackage, .startContainerService, .recheck, .healthCheck],
                       "Every update ends with the health checks")
        XCTAssertTrue(plan.needsAdmin)
        XCTAssertFalse(plan.manualOnly)
        XCTAssertTrue(plan.confirmation.contains("Running containers stop"))
        XCTAssertEqual(plan.terminalCommand,
                       "curl -fL -o /tmp/container-1.6.2-installer-signed.pkg https://github.com/apple/container/releases/download/1.6.2/container-1.6.2-installer-signed.pkg"
                       + " && pkgutil --check-signature /tmp/container-1.6.2-installer-signed.pkg && /usr/local/bin/container system stop"
                       + " && sudo installer -pkg /tmp/container-1.6.2-installer-signed.pkg -target / && /usr/local/bin/container system start")
        XCTAssertTrue(plan.steps.prefix(2).allSatisfy(\.isCancellable))
        XCTAssertFalse(ComponentUpdatePlan.Step.installPackage.isCancellable)
    }

    func testContainerPlanWithoutAdminIsManual() throws {
        let plan = try ComponentUpdatePlanner.plan(for: row(.container, .applePackage, target: "1.6.2"),
                                                   context: ComponentPlanContext(containerPath: "/usr/local/bin/container", package: package, isAdmin: false))
        XCTAssertTrue(plan.manualOnly)
        XCTAssertTrue(plan.terminalCommand.contains("sudo installer -pkg"))
    }

    func testContainerPlanNeedsPackage() {
        XCTAssertThrowsError(try ComponentUpdatePlanner.plan(for: row(.container, .applePackage), context: ComponentPlanContext()))
    }

    func testHomebrewPlans() throws {
        let brew = "/opt/homebrew/bin/brew"
        let ollama = try ComponentUpdatePlanner.plan(for: row(.ollama, .homebrewFormula("ollama")), context: ComponentPlanContext(brewPath: brew))
        XCTAssertEqual(ollama.steps, [.run(executable: brew, arguments: ["upgrade", "ollama"]), .recheck, .healthCheck])
        XCTAssertEqual(ollama.terminalCommand, "brew upgrade ollama")

        let restart = try ComponentUpdatePlanner.plan(for: row(.ollama, .homebrewFormula("ollama")),
                                                      context: ComponentPlanContext(brewPath: brew, restartOllama: true))
        XCTAssertEqual(restart.steps, [.run(executable: brew, arguments: ["upgrade", "ollama"]), .stopOllama, .startOllama, .recheck, .healthCheck])

        let ngrok = try ComponentUpdatePlanner.plan(for: row(.ngrok, .homebrewCask("ngrok")), context: ComponentPlanContext(brewPath: brew))
        XCTAssertEqual(ngrok.steps.first, .run(executable: brew, arguments: ["upgrade", "--cask", "ngrok"]))

        let kubectl = try ComponentUpdatePlanner.plan(for: row(.kubectl, .homebrewFormula("kubernetes-cli")), context: ComponentPlanContext(brewPath: brew))
        XCTAssertEqual(kubectl.terminalCommand, "brew upgrade kubernetes-cli")

        XCTAssertThrowsError(try ComponentUpdatePlanner.plan(for: row(.ollama, .homebrewFormula("ollama")), context: ComponentPlanContext()))
    }

    func testMLXPlanPinsTheGatedVersionAndStopsTheServer() throws {
        let env = ["UV_TOOL_DIR=/x/uv-tools", "UV_TOOL_BIN_DIR=/x/bin"]
        let plan = try ComponentUpdatePlanner.plan(for: row(.mlx, .appRuntime, target: "0.32.2"),
                                                   context: ComponentPlanContext(uvPath: "/x/bin/uv", mlxEnvironment: env, mlxServerRunning: true))
        XCTAssertEqual(plan.steps, [
            .stopMLXServer,
            .run(executable: "/usr/bin/env", arguments: env + ["/x/bin/uv", "tool", "install", "--python", AIConfig.mlxPythonVersion, "--upgrade", "mlx-lm==0.32.2"]),
            .recheck, .healthCheck
        ])
        XCTAssertEqual(plan.steps[1].label, "Run uv tool install --python \(AIConfig.mlxPythonVersion) --upgrade mlx-lm==0.32.2")
        let idle = try ComponentUpdatePlanner.plan(for: row(.mlx, .appRuntime, target: "0.32.2"),
                                                   context: ComponentPlanContext(uvPath: "/x/bin/uv", mlxEnvironment: env))
        XCTAssertNotEqual(idle.steps.first, .stopMLXServer)
    }

    func testLMStudioPlans() throws {
        let lms = "/Users/me/.lmstudio/bin/lms"
        let update = try ComponentUpdatePlanner.plan(for: row(.lmStudio, .lmStudioScript),
                                                     context: ComponentPlanContext(lmsPath: lms, lmsHasDaemonUpdate: true))
        XCTAssertEqual(update.steps, [.run(executable: lms, arguments: ["daemon", "update"]), .recheck, .healthCheck])
        let script = try ComponentUpdatePlanner.plan(for: row(.lmStudio, .lmStudioScript),
                                                     context: ComponentPlanContext(lmsPath: lms, lmsHasDaemonUpdate: false))
        XCTAssertEqual(script.steps.first, .run(executable: "/bin/bash", arguments: ["-c", "set -o pipefail; curl -fsSL https://lmstudio.ai/install.sh | bash"]))
        let standIn = try ComponentUpdatePlanner.plan(for: row(.lmStudio, .lmStudioScript),
                                                      context: ComponentPlanContext(lmStudioInstallCommand: ("/bin/bash", ["/tmp/tools/install.sh"])))
        XCTAssertEqual(standIn.steps.first, .run(executable: "/bin/bash", arguments: ["/tmp/tools/install.sh"]))
    }

    func testOwnDownloadsAndImages() throws {
        XCTAssertEqual(try ComponentUpdatePlanner.plan(for: row(.uv, .appDownload), context: ComponentPlanContext()).steps, [.downloadUV, .recheck, .healthCheck])
        XCTAssertEqual(try ComponentUpdatePlanner.plan(for: row(.cloudflared, .appDownload), context: ComponentPlanContext()).steps,
                       [.downloadCloudflared, .recheck, .healthCheck])
        let image = row(.mcp, .containerImage("mcp/fetch"), target: "1a7a0996a565", id: "mcp:fetch")
        var named = image
        named.name = "fetch"
        XCTAssertEqual(try ComponentUpdatePlanner.plan(for: named, context: ComponentPlanContext()).steps, [.pullImage("mcp/fetch"), .recheck], "MCP images have no health checks")
        XCTAssertEqual(try ComponentUpdatePlanner.plan(for: named, context: ComponentPlanContext(mcpServerRunning: true)).steps,
                       [.pullImage("mcp/fetch"), .recreateMCPServer("fetch"), .recheck])
    }

    func testRowsWithoutASafeUpdateHaveNoPlan() {
        XCTAssertThrowsError(try ComponentUpdatePlanner.plan(for: row(.container, .applePackage, status: .upToDate), context: ComponentPlanContext()))
        XCTAssertThrowsError(try ComponentUpdatePlanner.plan(for: row(.ollama, .appBundle("/Applications/Ollama.app"), updatesItself: true),
                                                             context: ComponentPlanContext()))
        XCTAssertThrowsError(try ComponentUpdatePlanner.plan(for: row(.helm, .other("/usr/local/bin/helm")), context: ComponentPlanContext(brewPath: "/b")))
    }
}

// MARK: - Cache and fetcher

final class ComponentCacheTests: XCTestCase {
    func testFreshExpiredAndPersisted() {
        let file = tempFile()
        let clock = Clock()
        let cache = ComponentLatestCache(file: file, lifetime: 6 * 3600, now: { clock.now })
        let releases = LatestReleases(versions: [v("1.6.1")])
        cache.store(releases, for: "github:apple/container")
        XCTAssertEqual(cache.fresh("github:apple/container"), releases)
        clock.now = clock.now.addingTimeInterval(6 * 3600 - 1)
        XCTAssertNotNil(cache.fresh("github:apple/container"))
        clock.now = clock.now.addingTimeInterval(2)
        XCTAssertNil(cache.fresh("github:apple/container"))
        XCTAssertEqual(cache.any("github:apple/container"), releases)

        // A new cache reads the same file.
        let again = ComponentLatestCache(file: file, lifetime: 6 * 3600, now: { clock.now })
        XCTAssertEqual(again.any("github:apple/container"), releases)
        again.store(releases, for: "pypi:mlx-lm")
        again.expireAll()
        XCTAssertNil(again.fresh("pypi:mlx-lm"))
        XCTAssertEqual(again.any("pypi:mlx-lm"), releases)
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    func testFetcherUsesCacheAndFallsBackWhenOffline() async {
        let http = FakeComponentHTTP()
        let source = LatestSource.homebrewFormula("ollama")
        http.replies[source.url.absoluteString] = FakeComponentHTTP.ok(ComponentFixtures.brewOllama)
        let clock = Clock()
        let cache = ComponentLatestCache(file: nil, lifetime: 100, now: { clock.now })
        let fetcher = ComponentLatestFetcher(http: http, cache: cache)

        let first = await fetcher.releases(source)
        XCTAssertEqual(first?.newest, v("0.40.15"))
        _ = await fetcher.releases(source)
        XCTAssertEqual(http.requests.count, 1, "The second read comes from the cache")

        clock.now = clock.now.addingTimeInterval(101)
        http.failAll = true
        let offline = await fetcher.releases(source)
        XCTAssertEqual(offline?.newest, v("0.40.15"), "An old answer is used when the check fails")
        XCTAssertEqual(http.requests.count, 2)

        let none = await ComponentLatestFetcher(http: http, cache: ComponentLatestCache(file: nil)).releases(source)
        XCTAssertNil(none)
    }

    func testGitHubRequestsHaveNoToken() async {
        let http = FakeComponentHTTP()
        let source = LatestSource.githubReleases("apple/container")
        http.replies[source.url.absoluteString] = FakeComponentHTTP.ok(ComponentFixtures.containerReleases)
        let fetcher = ComponentLatestFetcher(http: http, cache: ComponentLatestCache(file: nil))
        let releases = await fetcher.releases(source)
        XCTAssertEqual(releases?.newest, v("1.7.1"))
        let request = http.requests.first
        XCTAssertNil(request?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
    }

    func testStandInFile() async throws {
        let file = tempFile("latest.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let all = ["formula:ollama": LatestReleases(versions: [v("9.9.9")]), "registry:mcp/fetch": LatestReleases(versions: [], digest: "sha256:ab")]
        try JSONEncoder().encode(all).write(to: file)
        let http = FakeComponentHTTP()
        let fetcher = ComponentLatestFetcher(http: http, cache: ComponentLatestCache(file: nil), standIn: file)
        let ollama = await fetcher.releases(.homebrewFormula("ollama"))
        let digest = await fetcher.registryDigest("mcp/fetch")
        XCTAssertEqual(ollama?.newest, v("9.9.9"))
        XCTAssertEqual(digest, "sha256:ab")
        XCTAssertTrue(http.requests.isEmpty)
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    func testRegistryDigestWithAnonymousToken() async throws {
        let http = FakeComponentHTTP()
        let manifest = "https://registry-1.docker.io/v2/mcp/fetch/manifests/latest"
        http.headReplies[manifest] = [
            HTTPReply(status: 401, headers: ["Www-Authenticate": ComponentFixtures.dockerHubChallenge]),
            HTTPReply(status: 200, headers: ["Docker-Content-Digest": ComponentFixtures.mcpFetchDigest])
        ]
        http.replies["https://auth.docker.io/token?service=registry.docker.io&scope=repository:mcp/fetch:pull"] = FakeComponentHTTP.ok(#"{"token":"abc"}"#)
        let digest = try await RegistryDigestReader(http: http).digest(of: "mcp/fetch")
        XCTAssertEqual(digest, ComponentFixtures.mcpFetchDigest)
        XCTAssertEqual(http.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer abc")
        XCTAssertEqual(http.requests.first?.httpMethod, "HEAD")

        let challenge = RegistryDigestReader.bearerChallenge(ComponentFixtures.dockerHubChallenge)
        XCTAssertEqual(challenge?.realm.absoluteString, "https://auth.docker.io/token")
        XCTAssertEqual(challenge?.scope, "repository:mcp/fetch:pull")
        XCTAssertEqual(RegistryDigestReader.manifestURL(PullReference.parse("nginx")!)?.absoluteString,
                       "https://registry-1.docker.io/v2/library/nginx/manifests/latest")
        XCTAssertEqual(RegistryDigestReader.manifestURL(PullReference.parse("ghcr.io/github/github-mcp-server:1.2")!)?.absoluteString,
                       "https://ghcr.io/v2/github/github-mcp-server/manifests/1.2")
    }
}

// MARK: - Checker

final class ComponentCheckerTests: XCTestCase {
    /// The fixtures were recorded while 1.6.x was the tested line. Pinned, so widening
    /// `AppConfig.apiSupportedVersions` does not change these tests.
    static let container16: @Sendable (String) -> ComponentGate.Tested? = {
        $0 == "container" ? ComponentGate.Tested(line: [1, 6]) : ComponentGate.tested(for: $0)
    }

    private func system(_ runner: ScriptedRunner, executables: Set<String>, files: Set<String> = [], links: [String: String] = [:],
                        folders: [String: [String]] = [:], data: [String: Data] = [:]) -> ComponentSystem {
        ComponentSystem(runner: runner, isExecutable: { executables.contains($0) }, fileExists: { executables.contains($0) || files.contains($0) },
                        resolve: { links[$0] ?? $0 }, readFile: { data[$0] }, listDirectory: { folders[$0] ?? [] }, home: "/Users/me")
    }

    private func fetcher(_ replies: [LatestSource: String]) -> ComponentLatestFetcher {
        let http = FakeComponentHTTP()
        for (source, body) in replies { http.replies[source.url.absoluteString] = FakeComponentHTTP.ok(body) }
        return ComponentLatestFetcher(http: http, cache: ComponentLatestCache(file: nil))
    }

    func testContainerRowUpdatesToTheNewestRelease() async {
        let runner = ScriptedRunner()
        runner.on("/usr/local/bin/container --version", ComponentFixtures.containerVersion)
        var checker = ComponentChecker(system: system(runner, executables: ["/usr/local/bin/container"]),
                                       fetcher: fetcher([.githubReleases("apple/container"): ComponentFixtures.containerReleasesWithPatch]),
                                       containerPath: "/usr/local/bin/container", toolsDirectory: nil)
        checker.tested = Self.container16
        let row = await checker.check(.container).first
        XCTAssertEqual(row?.installed, "1.6.1")
        XCTAssertEqual(row?.latest, "1.7.1")
        XCTAssertEqual(row?.status, .updateAvailable, "A new minor is not blocked")
        XCTAssertEqual(row?.target, "1.7.1")
        XCTAssertEqual(row?.method, .applePackage)
        XCTAssertTrue(row?.canUpdateInApp == true)
        XCTAssertEqual(row?.testedText, "1.6.x", "Shown as information")
        XCTAssertEqual(row?.matchesTested, true)
        XCTAssertNil(row?.note)
        XCTAssertEqual(row?.notesURL?.absoluteString, "https://github.com/apple/container/releases/tag/1.7.1")
        XCTAssertEqual(runner.calls, [["/usr/local/bin/container", "--version"]], "Only a read only version call")
        let context = await checker.planContext(for: row!)
        XCTAssertEqual(context.package?.name, "container-1.7.1-installer-signed.pkg")
    }

    func testVersionOutsideTheTestedLineIsOnlyInformation() async {
        let runner = ScriptedRunner()
        runner.on("/usr/local/bin/container --version", "container CLI version 1.7.1 (build: release, commit: aa8d76b)")
        var checker = ComponentChecker(system: system(runner, executables: ["/usr/local/bin/container"]),
                                       fetcher: fetcher([.githubReleases("apple/container"): ComponentFixtures.containerReleases]),
                                       containerPath: "/usr/local/bin/container", toolsDirectory: nil)
        checker.tested = Self.container16
        let row = await checker.check(.container).first
        XCTAssertEqual(row?.status, .upToDate)
        XCTAssertEqual(row?.matchesTested, false)
        XCTAssertNil(row?.switchTarget, "No offer until something fails")
    }

    func testOllamaFromHomebrew() async {
        let runner = ScriptedRunner()
        runner.on("/opt/homebrew/bin/ollama -v", ComponentFixtures.ollamaVersion)
        let checker = ComponentChecker(system: system(runner, executables: ["/opt/homebrew/bin/ollama"],
                                                      links: ["/opt/homebrew/bin/ollama": "/opt/homebrew/Cellar/ollama/0.16.2/bin/ollama"]),
                                       fetcher: fetcher([.homebrewFormula("ollama"): ComponentFixtures.brewOllama]), toolsDirectory: nil)
        let row = await checker.check(.ollama).first
        XCTAssertEqual(row?.method, .homebrewFormula("ollama"))
        XCTAssertEqual(row?.installed, "0.16.2")
        XCTAssertEqual(row?.target, "0.40.15")
        XCTAssertEqual(row?.status, .updateAvailable)
        XCTAssertFalse(row?.updatesItself ?? true)
    }

    func testOllamaAppUpdatesItself() async {
        let runner = ScriptedRunner()
        let checker = ComponentChecker(system: system(runner, executables: [], files: ["/Applications/Ollama.app"],
                                                      data: ["/Applications/Ollama.app/Contents/Info.plist": Data(ComponentFixtures.infoPlist.utf8)]),
                                       fetcher: fetcher([.homebrewCask("ollama-app"): #"{"version":"0.41.0","auto_updates":true}"#]), toolsDirectory: nil)
        let row = await checker.check(.ollama).first
        XCTAssertEqual(row?.method, .appBundle("/Applications/Ollama.app"))
        XCTAssertEqual(row?.status, .updateAvailable)
        XCTAssertTrue(row?.updatesItself == true)
        XCTAssertFalse(row?.canUpdateInApp ?? true)
    }

    func testLMStudioCoreFromFolders() async {
        let runner = ScriptedRunner()
        let lms = "/Users/me/.lmstudio/bin/lms"
        let checker = ComponentChecker(system: system(runner, executables: [AIConfig.expand("~/.lmstudio/bin/lms")],
                                                      folders: ["/Users/me/.lmstudio/llmster": ["0.0.26-3", "0.0.27-1"]]),
                                       fetcher: fetcher([.lmStudioScript: ComponentFixtures.lmStudioScript]), toolsDirectory: nil)
        let row = await checker.check(.lmStudio).first
        XCTAssertEqual(row?.name, "LM Studio core")
        XCTAssertEqual(row?.method, .lmStudioScript)
        XCTAssertEqual(row?.installed, "0.0.27-1")
        XCTAssertEqual(row?.status, .upToDate)
        _ = lms
    }

    func testMissingToolsAreNotInstalled() async {
        let checker = ComponentChecker(system: system(ScriptedRunner(), executables: []), fetcher: fetcher([:]), toolsDirectory: nil,
                                       aiPaths: AIPaths(base: URL(fileURLWithPath: "/nowhere")))
        for kind in [ComponentKind.ngrok, .tailscale, .kubectl, .helm, .cloudflared] {
            let row = await checker.check(kind).first
            XCTAssertEqual(row?.status, .notInstalled, "\(kind)")
        }
        let uv = await checker.check(.uv)
        XCTAssertTrue(uv.isEmpty, "uv shows only when installed")
    }

    func testOfflineRowIsNotChecked() async {
        let runner = ScriptedRunner()
        runner.on("/opt/homebrew/bin/helm version", ComponentFixtures.helmShort)
        let checker = ComponentChecker(system: system(runner, executables: ["/opt/homebrew/bin/helm"],
                                                      links: ["/opt/homebrew/bin/helm": "/opt/homebrew/Cellar/helm/4.1.0/bin/helm"]),
                                       fetcher: fetcher([:]), toolsDirectory: nil)
        let row = await checker.check(.helm).first
        XCTAssertEqual(row?.installed, "4.1.0")
        XCTAssertEqual(row?.status, .unknown)
    }

    func testMCPDigests() async {
        let http = FakeComponentHTTP()
        http.headReplies["https://registry-1.docker.io/v2/mcp/fetch/manifests/latest"] = [
            HTTPReply(status: 200, headers: ["Docker-Content-Digest": ComponentFixtures.mcpFetchDigest])
        ]
        let servers = [MCPInstalledServer(name: "fetch", image: "mcp/fetch", transport: .stdio),
                       MCPInstalledServer(name: "notes", image: "ghcr.io/me/notes:1", transport: .http),
                       MCPInstalledServer(name: "remote", kind: .remote, transport: .http)]
        let images = [ImageSummary(reference: "docker.io/mcp/fetch:latest", digest: "sha256:0f3e5b2a9c8d")]
        let checker = ComponentChecker(system: system(ScriptedRunner(), executables: []),
                                       fetcher: ComponentLatestFetcher(http: http, cache: ComponentLatestCache(file: nil)),
                                       toolsDirectory: nil, mcpServers: servers, localImages: { images })
        let rows = await checker.check(.mcp)
        XCTAssertEqual(rows.map(\.id), ["mcp:fetch", "mcp:notes"])
        XCTAssertEqual(rows[0].status, .updateAvailable)
        XCTAssertEqual(rows[0].installed, "0f3e5b2a9c8d")
        XCTAssertEqual(rows[0].target, "1a7a0996a565")
        XCTAssertEqual(rows[1].status, .notInstalled)
    }
}

// MARK: - Updater

final class ComponentUpdaterTests: XCTestCase {
    private func collect(_ stream: AsyncThrowingStream<ComponentUpdateEvent, Error>) async -> (events: [ComponentUpdateEvent], error: Error?) {
        var events: [ComponentUpdateEvent] = []
        do {
            for try await event in stream { events.append(event) }
            return (events, nil)
        } catch {
            return (events, error)
        }
    }

    private func package() throws -> (PackageRef, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("deck-pkg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("container-1.6.2-installer-signed.pkg")
        let body = Data("stand in package".utf8)
        try body.write(to: file)
        let digest = "sha256:" + CloudflaredInstaller.sha256Hex(of: body)
        return (PackageRef(name: file.lastPathComponent, url: file, digest: digest), folder)
    }

    private let signed = """
    Package "container-1.6.2-installer-signed.pkg":
       Status: signed by a developer certificate issued by Apple for distribution
       Certificate Chain:
        1. Developer ID Installer: Apple Inc. (TEAM)
    """

    func testContainerUpdateWithStandInTools() async throws {
        let (pkg, folder) = try package()
        defer { try? FileManager.default.removeItem(at: folder) }
        let runner = ScriptedRunner()
        runner.on("/tools/pkgutil --check-signature", signed)
        runner.on("/tools/container system status", "apiserver is running")
        let after = ComponentInfo(id: "container", kind: .container, name: "Apple container", installed: "1.6.2", status: .upToDate)
        let updater = ComponentUpdater(runner: runner, streamer: LinesStreamer(), toolsDirectory: "/tools",
                                       workRoot: FileManager.default.temporaryDirectory, recheck: { after })
        let plan = ComponentUpdatePlan(componentID: "container", title: "Update", target: "1.6.2",
                                       steps: [.downloadPackage(pkg), .verifyPackage, .stopContainerService, .installPackage, .startContainerService, .recheck],
                                       confirmation: "", needsAdmin: true, manualOnly: false, terminalCommand: "")
        let result = await collect(updater.run(plan, containerPath: "/usr/local/bin/container"))
        XCTAssertNil(result.error)
        XCTAssertEqual(result.events.last, .finished(after))
        let commands = runner.calls.map { $0.joined(separator: " ") }
        XCTAssertTrue(commands.contains { $0.hasPrefix("/tools/pkgutil --check-signature") })
        XCTAssertTrue(commands.contains("/tools/container system stop"))
        XCTAssertTrue(commands.contains { $0.hasPrefix("/tools/installer -pkg") && $0.hasSuffix("-target /") })
        XCTAssertTrue(commands.contains("/tools/container system start --disable-kernel-install"))
        XCTAssertFalse(commands.contains { $0.contains("osascript") || $0.hasPrefix("/usr/sbin/installer") }, "Stand in runs never ask for a password")
        XCTAssertTrue(result.events.contains(.log("Checksum matches GitHub (sha256 \(pkg.digest!.dropFirst(7).prefix(12))).")))
    }

    func testRealInstallUsesThePasswordPrompt() async throws {
        let (pkg, folder) = try package()
        defer { try? FileManager.default.removeItem(at: folder) }
        let runner = ScriptedRunner()
        runner.on("/usr/sbin/pkgutil --check-signature", signed)
        runner.on("/usr/local/bin/container system status", "apiserver is running")
        let updater = ComponentUpdater(runner: runner, streamer: LinesStreamer(), toolsDirectory: nil)
        let plan = ComponentUpdatePlan(componentID: "container", title: "Update", target: "1.6.2",
                                       steps: [.downloadPackage(pkg), .verifyPackage, .stopContainerService, .installPackage, .startContainerService],
                                       confirmation: "", needsAdmin: true, manualOnly: false, terminalCommand: "")
        let result = await collect(updater.run(plan, containerPath: "/usr/local/bin/container"))
        XCTAssertNil(result.error)
        let admin = runner.calls.first { $0.first == "/usr/bin/osascript" }
        XCTAssertNotNil(admin)
        XCTAssertTrue(admin?.last?.contains("/usr/sbin/installer") == true)
        XCTAssertTrue(admin?.last?.contains("with administrator privileges") == true)
    }

    func testFailedInstallStartsTheServiceAgain() async throws {
        let (pkg, folder) = try package()
        defer { try? FileManager.default.removeItem(at: folder) }
        let runner = ScriptedRunner()
        runner.on("/tools/pkgutil --check-signature", signed)
        runner.on("/tools/installer", "", exit: 1, stderr: "installer: Error")
        let updater = ComponentUpdater(runner: runner, streamer: LinesStreamer(), toolsDirectory: "/tools")
        let plan = ComponentUpdatePlan(componentID: "container", title: "Update", target: "1.6.2",
                                       steps: [.downloadPackage(pkg), .verifyPackage, .stopContainerService, .installPackage, .startContainerService],
                                       confirmation: "", needsAdmin: true, manualOnly: false, terminalCommand: "")
        let result = await collect(updater.run(plan, containerPath: nil))
        XCTAssertNotNil(result.error)
        let commands = runner.calls.map { $0.joined(separator: " ") }
        XCTAssertEqual(commands.last, "/tools/container system start --disable-kernel-install")
    }

    func testBadChecksumStopsBeforeAnythingChanges() async throws {
        var (pkg, folder) = try package()
        defer { try? FileManager.default.removeItem(at: folder) }
        pkg.digest = "sha256:" + String(repeating: "0", count: 64)
        let runner = ScriptedRunner()
        let updater = ComponentUpdater(runner: runner, streamer: LinesStreamer(), toolsDirectory: "/tools")
        let plan = ComponentUpdatePlan(componentID: "container", title: "Update", target: "1.6.2",
                                       steps: [.downloadPackage(pkg), .verifyPackage, .stopContainerService, .installPackage],
                                       confirmation: "", needsAdmin: true, manualOnly: false, terminalCommand: "")
        let result = await collect(updater.run(plan, containerPath: nil))
        XCTAssertNotNil(result.error)
        XCTAssertTrue(runner.calls.isEmpty, "Nothing ran after the checksum failed")
    }

    func testStreamedStepsAndStandInGuard() async {
        let streamer = LinesStreamer()
        let updater = ComponentUpdater(runner: ScriptedRunner(), streamer: streamer, toolsDirectory: "/tools",
                                       aiPaths: AIPaths(base: URL(fileURLWithPath: "/ai")))
        let brew = ComponentUpdatePlan(componentID: "ollama", title: "Update", target: nil,
                                       steps: [.run(executable: "/tools/brew", arguments: ["upgrade", "ollama"])],
                                       confirmation: "", needsAdmin: false, manualOnly: false, terminalCommand: "")
        let ok = await collect(updater.run(brew, containerPath: nil))
        XCTAssertNil(ok.error)
        XCTAssertTrue(ok.events.contains(.log("line two")))

        // The real Homebrew or LM Studio's real script never runs in a stand in session.
        for step in [ComponentUpdatePlan.Step.run(executable: "/opt/homebrew/bin/brew", arguments: ["upgrade", "ollama"]),
                     .run(executable: "/bin/bash", arguments: ["-c", "curl -fsSL https://lmstudio.ai/install.sh | bash"]),
                     .run(executable: "/usr/bin/env", arguments: ["A=1", "/opt/homebrew/bin/uv", "tool", "install"])] {
            let plan = ComponentUpdatePlan(componentID: "x", title: "x", target: nil, steps: [step], confirmation: "",
                                           needsAdmin: false, manualOnly: false, terminalCommand: "")
            let result = await collect(updater.run(plan, containerPath: nil))
            XCTAssertNotNil(result.error, "\(step)")
        }
        XCTAssertTrue(updater.standInAllows("/usr/bin/env", ["A=1", "/ai/bin/uv", "tool", "install"]))
        XCTAssertTrue(updater.standInAllows("/bin/bash", ["/tools/install.sh"]))
        XCTAssertEqual(streamer.calls.count, 1)
    }

    func testFriendlyPasswordCancel() {
        let error = ComponentUpdater.friendly(DeckError.commandFailed("execution error: User canceled. (-128)"))
        XCTAssertEqual(error.localizedDescription.contains("password prompt was closed"), true)
    }
}


// MARK: - Agents, notes

final class ComponentAgentTests: XCTestCase {
    func testAgentInstallMethods() {
        typealias P = ComponentParsers
        XCTAssertEqual(P.agentInstallMethod(resolvedPath: ComponentFixtures.claudeResolved, home: "/Users/me"),
                       .npmGlobal(package: "@anthropic-ai/claude-code", prefix: "/opt/homebrew"))
        XCTAssertEqual(P.agentInstallMethod(resolvedPath: ComponentFixtures.geminiResolved, home: "/Users/me"), .homebrewFormula("gemini-cli"))
        XCTAssertEqual(P.agentInstallMethod(resolvedPath: "/Users/me/.npm-global/lib/node_modules/opencode-ai/bin/opencode", home: "/Users/me"),
                       .npmGlobal(package: "opencode-ai", prefix: "/Users/me/.npm-global"))
        XCTAssertEqual(P.agentInstallMethod(resolvedPath: "/Users/me/.local/share/uv/tools/aider-chat/bin/aider", home: "/Users/me"), .uvTool("aider-chat"))
        XCTAssertEqual(P.agentInstallMethod(resolvedPath: "/Users/me/.local/pipx/venvs/aider-chat/bin/aider", home: "/Users/me"), .pipx("aider-chat"))
        XCTAssertEqual(P.agentInstallMethod(resolvedPath: "/Users/me/.local/share/claude/versions/2.1.318", home: "/Users/me"),
                       .selfUpdater("/Users/me/.local/share/claude/versions/2.1.318"))
        XCTAssertNil(P.agentInstallMethod(resolvedPath: "/Users/me/.pyenv/shims/aider", home: "/Users/me"))
    }

    func testAgentVersionsAndNpm() throws {
        XCTAssertEqual(ToolVersion.firstMatch(in: ComponentFixtures.claudeVersion), v("2.1.318"))
        XCTAssertEqual(ToolVersion.firstMatch(in: ComponentFixtures.aiderVersion), v("0.86.1"))
        XCTAssertEqual(try ComponentParsers.npmLatestVersion(Data(ComponentFixtures.npmClaude.utf8)), v("2.1.319"))
        let amp = try ComponentParsers.npmLatestVersion(Data(ComponentFixtures.npmAmp.utf8))
        XCTAssertFalse(amp.isPrerelease)
        XCTAssertEqual(amp.parts, [0, 0, 1794196844])
        XCTAssertEqual(LatestSource.npm("@openai/codex").url.absoluteString, "https://registry.npmjs.org/@openai/codex/latest")
    }

    private func checker(_ agents: [DetectedAgentTool], replies: [LatestSource: String], links: [String: String]) -> ComponentChecker {
        let http = FakeComponentHTTP()
        for (source, body) in replies { http.replies[source.url.absoluteString] = FakeComponentHTTP.ok(body) }
        let system = ComponentSystem(runner: ScriptedRunner(), isExecutable: { _ in false }, fileExists: { _ in false },
                                     resolve: { links[$0] ?? $0 }, readFile: { _ in nil }, listDirectory: { _ in [] }, home: "/Users/me")
        return ComponentChecker(system: system, fetcher: ComponentLatestFetcher(http: http, cache: ComponentLatestCache(file: nil)),
                                toolsDirectory: nil, agents: { agents })
    }

    func testAgentRows() async {
        let agents = [
            DetectedAgentTool(tool: .claude, path: "/opt/homebrew/bin/claude", version: "2.1.318"),
            DetectedAgentTool(tool: .gemini, path: "/opt/homebrew/bin/gemini", version: "0.29.2"),
            DetectedAgentTool(tool: .codex, path: nil, version: nil),
            DetectedAgentTool(tool: .claudeDesktop, path: "/Applications/Claude.app", version: nil)
        ]
        let checker = checker(agents, replies: [
            .npm("@anthropic-ai/claude-code"): #"{"version":"3.0.0"}"#,
            .homebrewFormula("gemini-cli"): #"{"versions":{"stable":"0.67.0"}}"#
        ], links: ["/opt/homebrew/bin/claude": ComponentFixtures.claudeResolved, "/opt/homebrew/bin/gemini": ComponentFixtures.geminiResolved])
        let rows = await checker.check(.agent)
        XCTAssertEqual(rows.map(\.id), ["agent:claude", "agent:gemini"], "Apps and missing tools are left out")
        XCTAssertEqual(rows[0].status, .updateAvailable, "Claude Code 3.0, a new major, is an update too")
        XCTAssertEqual(rows[0].target, "3.0.0")
        XCTAssertEqual(rows[0].method, .npmGlobal(package: "@anthropic-ai/claude-code", prefix: "/opt/homebrew"))
        XCTAssertEqual(rows[1].status, .updateAvailable)
        XCTAssertEqual(rows[1].target, "0.67.0")
        XCTAssertEqual(rows[1].kind.group, .agents)
    }

    func testAgentPlans() throws {
        func row(_ method: InstallMethod) -> ComponentInfo {
            ComponentInfo(id: "agent:x", kind: .agent, name: "Agent", method: method, installed: "1.0.0", latest: "1.1.0", target: "1.1.0",
                          status: .updateAvailable)
        }
        let npm = try ComponentUpdatePlanner.plan(for: row(.npmGlobal(package: "@openai/codex", prefix: "/opt/homebrew")), context: ComponentPlanContext())
        XCTAssertEqual(npm.steps.first, .run(executable: "/usr/bin/env",
                                             arguments: ["PATH=/opt/homebrew/bin:/usr/bin:/bin", "/opt/homebrew/bin/npm", "install", "-g", "@openai/codex@1.1.0"]))
        XCTAssertEqual(npm.terminalCommand, "npm install -g @openai/codex@1.1.0")
        XCTAssertEqual(npm.steps.first?.label, "Run npm install -g @openai/codex@1.1.0")

        var context = ComponentPlanContext()
        context.toolUVPath = "/opt/homebrew/bin/uv"
        context.pipxPath = "/opt/homebrew/bin/pipx"
        XCTAssertEqual(try ComponentUpdatePlanner.plan(for: row(.uvTool("aider-chat")), context: context).steps.first,
                       .run(executable: "/opt/homebrew/bin/uv", arguments: ["tool", "upgrade", "aider-chat"]))
        XCTAssertEqual(try ComponentUpdatePlanner.plan(for: row(.pipx("aider-chat")), context: context).steps.first,
                       .run(executable: "/opt/homebrew/bin/pipx", arguments: ["upgrade", "aider-chat"]))
        XCTAssertEqual(try ComponentUpdatePlanner.plan(for: row(.selfUpdater("/Users/me/.local/bin/claude")), context: context).steps.first,
                       .run(executable: "/Users/me/.local/bin/claude", arguments: ["update"]))
        XCTAssertEqual(try ComponentUpdatePlanner.plan(for: row(.homebrewFormula("gemini-cli")),
                                                       context: ComponentPlanContext(brewPath: "/opt/homebrew/bin/brew")).steps.first,
                       .run(executable: "/opt/homebrew/bin/brew", arguments: ["upgrade", "gemini-cli"]))
        XCTAssertThrowsError(try ComponentUpdatePlanner.plan(for: row(.uvTool("aider-chat")), context: ComponentPlanContext()))
        XCTAssertTrue(ComponentUpdater(toolsDirectory: "/tools").standInAllows("/usr/bin/env", ["PATH=/tools/npm/bin:/usr/bin", "/tools/npm/bin/npm", "install"]))
        XCTAssertFalse(ComponentUpdater(toolsDirectory: "/tools").standInAllows("/usr/bin/env", ["PATH=/opt/homebrew/bin", "/opt/homebrew/bin/npm", "install"]))
    }

    func testAgentTestedVersionsInAppConfig() {
        for tool in AgentTool.allCases where !tool.isApp {
            guard tool != .cursorAgent else { continue }   // date versions, no published list
            XCTAssertNotNil(ComponentGate.tested(for: tool.componentID), tool.rawValue)
        }
    }

    func testNotesSummary() {
        let lines = ComponentParsers.notesSummary(ComponentFixtures.containerNotes, maxLines: 4)
        XCTAssertEqual(Array(lines.prefix(3)), [
            "container stats now reports cpuUtilization in JSON, YAML, and TOML output",
            "Image snapshots and container filesystems are now excluded from Time Machine backups",
            "Default Kata kernel is now 4.3.1 (vmlinux-6.18.56-208-debug)"
        ])
        XCTAssertTrue(lines[3].hasPrefix("New --shared-image-store option"), "The emoji legend mark is gone")
        XCTAssertTrue(lines[3].hasSuffix("…"))
        XCTAssertEqual(lines[3].count, 140)
        XCTAssertEqual(ComponentParsers.notesSummary("Plain text release.\n\nSecond line."), ["Plain text release.", "Second line."])
        XCTAssertTrue(ComponentParsers.notesSummary("").isEmpty)
    }

    func testReleaseSummariesAreKeptPerVersion() throws {
        let json = """
        [{"tag_name":"1.6.2","html_url":"https://github.com/apple/container/releases/tag/1.6.2","prerelease":false,"draft":false,"assets":[],
          "body":"- Fix one\\n- Fix two"}]
        """
        let releases = try LatestReleases.parse(Data(json.utf8), source: .githubReleases("apple/container"))
        XCTAssertEqual(releases.summaries?["1.6.2"], ["Fix one", "Fix two"])
    }
}
