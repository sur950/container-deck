import XCTest
@testable import DeckCore

// MARK: - Helpers

private func v(_ text: String) -> ToolVersion { ToolVersion(text)! }

private func ok(_ stdout: String) -> CommandResult { CommandResult(exitCode: 0, stdout: stdout) }

private func healthSystem(_ runner: any CommandRunning, executables: Set<String> = [], files: [String: Data] = [:],
                          folders: [String: [String]] = [:]) -> ComponentSystem {
    ComponentSystem(runner: runner, isExecutable: { executables.contains($0) },
                    fileExists: { executables.contains($0) || files[$0] != nil || folders[$0] != nil },
                    resolve: { $0 }, readFile: { files[$0] }, listDirectory: { folders[$0] ?? [] }, home: "/Users/me")
}

/// Replies by URL path. Throws for every request when `down`.
private final class PathHTTP: ComponentHTTPFetching, @unchecked Sendable {
    var replies: [String: String] = [:]
    var down = false
    private(set) var paths: [String] = []

    func send(_ request: URLRequest) async throws -> HTTPReply {
        paths.append(request.url?.path ?? "")
        if down { throw URLError(.cannotConnectToHost) }
        guard let body = replies[request.url?.path ?? ""] else { return HTTPReply(status: 404) }
        return HTTPReply(status: 200, body: Data(body.utf8))
    }
}

/// Replies by URL, for the newest version sources.
private final class URLHTTP: ComponentHTTPFetching, @unchecked Sendable {
    var replies: [String: String] = [:]
    func send(_ request: URLRequest) async throws -> HTTPReply {
        guard let body = replies[request.url?.absoluteString ?? ""] else { return HTTPReply(status: 404) }
        return HTTPReply(status: 200, body: Data(body.utf8))
    }
}

private func probe(_ runner: any CommandRunning, executables: Set<String> = [], files: [String: Data] = [:],
                   folders: [String: [String]] = [:], http: any ComponentHTTPFetching = PathHTTP(),
                   ping: ComponentHealthProbe.DirectPing = .answered(version: "1.6.1"),
                   resolver: AgentPathResolver = AgentPathResolver(home: "/Users/me", environment: [:])) -> ComponentHealthProbe {
    ComponentHealthProbe(system: healthSystem(runner, executables: executables, files: files, folders: folders), http: http,
                         ollamaURL: URL(string: "http://127.0.0.1:11434")!, aiPaths: AIPaths(base: URL(fileURLWithPath: "/ai")),
                         containerAppRoot: "/root", agentResolver: resolver, directPing: { ping })
}

private func row(_ kind: ComponentKind, id: String? = nil, installed: String = "1.0.0", location: String? = nil,
                 method: InstallMethod? = nil, status: ComponentStatus = .upToDate) -> ComponentInfo {
    ComponentInfo(id: id ?? kind.rawValue, kind: kind, name: kind.title, location: location, method: method,
                  installed: installed, status: status)
}

private func outcomes(_ report: ComponentHealthReport?) -> [String: HealthCheck.Outcome] {
    Dictionary(uniqueKeysWithValues: (report?.checks ?? []).map { ($0.id, $0.outcome) })
}

private func tempStoreFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("deck-health-\(UUID().uuidString)/component-health.json")
}

// MARK: - The owner's rule: nothing blocked, one tested version per tool

final class ComponentPolicyTests: XCTestCase {
    func testTestedLineMatching() {
        let container = ComponentGate.Tested(line: [1, 7])
        XCTAssertTrue(container.matches(v("1.7.0")))
        XCTAssertTrue(container.matches(v("1.7.1")))
        XCTAssertFalse(container.matches(v("1.8.0")))
        XCTAssertFalse(container.matches(v("1.6.2")))
        XCTAssertFalse(container.matches(v("1")), "Shorter than the line")
        XCTAssertEqual(container.text, "1.7.x")
        let llmster = ComponentGate.Tested(AppConfig.ComponentTested("0.0.27", "0.0.27-1"))
        XCTAssertTrue(llmster.matches(v("0.0.27-1")))
        XCTAssertFalse(llmster.matches(v("0.0.28")))
        XCTAssertTrue(ComponentGate.Tested(line: [3]).matches(v("3.24.0")))
        XCTAssertTrue(ComponentGate.Tested(line: [2026, 3]).matches(v("2026.3.0")), "Date versions use a line too")
    }

    func testSwitchTargetIsTheNewestReleaseOfTheLine() {
        let ollama = ComponentGate.Tested(line: [0, 16], version: v("0.16.2"))
        XCTAssertEqual(ollama.target(published: [v("1.0.0"), v("0.16.3"), v("0.16.2"), v("0.16.4-rc1"), v("0.15.9")]), v("0.16.3"))
        XCTAssertEqual(ollama.target(published: [v("1.0.0"), v("0.40.15")]), v("0.16.2"), "No list for the line: the verified release")
        XCTAssertNil(ComponentGate.Tested(line: [3]).target(published: []))
    }

    func testAppleContainerFollowsTheDirectAPIRange() {
        let upper = AppConfig.apiSupportedVersions.upperBound
        XCTAssertEqual(ComponentGate.tested(for: "container")?.line, [upper.major, upper.minor - 1])
        XCTAssertEqual(ComponentGate.tested(for: "kubectl")?.version, v("1.35.0"))
        XCTAssertNil(ComponentGate.tested(for: "agent:cursorAgent"))
    }
}

// MARK: - Probes

final class ComponentProbeTests: XCTestCase {
    private func containerRunner(status: String = HealthFixtures.systemStatus) -> MockRunner {
        let runner = MockRunner()
        runner.responses["system status"] = ok(status)
        runner.responses["list --all --format json"] = ok(ContainerCLIFixtures.containerList)
        runner.responses["image list --format json"] = ok(ContainerCLIFixtures.imageList)
        runner.responses["volume list --format json"] = ok(ContainerCLIFixtures.volumeList)
        runner.responses["network list --format json"] = ok(ContainerCLIFixtures.networkList)
        runner.responses["system property list --format json"] = ok(ContainerCLIFixtures.systemProperties)
        runner.responses["cluster --help"] = ok("OVERVIEW: Manage Kubernetes clusters")
        runner.responses["cluster list"] = ok(KubeFixtures.clusterList)                         // 1.6.1 table
        runner.responses["cluster list --format json"] = ok(Container17Fixtures.clusterListJSON) // 1.7 and newer
        return runner
    }

    private let cli = "/usr/local/bin/container"

    func testContainerChecksPassWithRealOutput() async {
        // Each release lists clusters its own way: the table on 1.6.1, JSON from 1.7 (real 1.7.1 output).
        for (version, listCall) in [("1.6.1", ["cluster", "list"]), ("1.7.1", ["cluster", "list", "--format", "json"])] {
            let runner = containerRunner()
            let report = await probe(runner, folders: ["/root/kernels": ["default.kernel-arm64"]])
                .probe(row(.container, installed: version, location: cli))
            XCTAssertEqual(report?.failed, [], version)
            XCTAssertTrue(runner.calls.contains { Array($0.dropFirst()) == listCall }, version)
        }
        let runner = containerRunner()
        let report = await probe(runner, folders: ["/root/kernels": ["default.kernel-arm64"]])
            .probe(row(.container, installed: "1.7.1", location: cli))
        XCTAssertEqual(report?.failed, [])
        XCTAssertTrue(report?.allPassed == true)
        XCTAssertEqual(Set(outcomes(report).keys), ["container.service.cli", "container.service.api", "container.containers", "container.images",
                                                    "container.volumes", "container.networks", "container.properties", "container.clusters",
                                                    "container.kernel"])
        // Read only: no start, stop, delete, run or install.
        let verbs = runner.calls.map { $0.dropFirst().prefix(2).joined(separator: " ") }
        for forbidden in ["system start", "system stop", "start", "stop", "delete", "run", "rm", "system kernel"] {
            XCTAssertFalse(verbs.contains { $0 == forbidden || $0.hasPrefix(forbidden + " ") && forbidden.contains(" ") }, forbidden)
        }
        XCTAssertTrue(runner.calls.allSatisfy { $0.first == cli })
    }

    func testStoppedServiceIsSkippedNotBroken() async {
        let runner = containerRunner(status: HealthFixtures.systemStatusStopped)
        let report = await probe(runner, folders: ["/root/kernels": ["default.kernel-arm64"]], ping: .stopped)
            .probe(row(.container, installed: "1.6.1", location: cli))
        let result = outcomes(report)
        XCTAssertEqual(result["container.containers"], .skipped)
        XCTAssertEqual(result["container.service.api"], .skipped)
        XCTAssertEqual(result["container.kernel"], .passed)
        XCTAssertEqual(report?.failed, [])
        XCTAssertFalse(runner.calls.contains { $0.contains("list") }, "No list commands while the service is stopped")
    }

    func testBrokenClusterListAndMissingKernel() async {
        let runner = containerRunner()
        // 1.7 asked for JSON and got a table back: a new format.
        runner.responses["cluster list --format json"] = ok(Container17Fixtures.clusterListTable)
        let report = await probe(runner, ping: .failed("Connection interrupted")).probe(row(.container, installed: "1.7.1", location: cli))
        XCTAssertEqual(report?.failed.map(\.failure), [
            "The container service doesn't answer the app directly",
            "Kubernetes clusters can't be listed",
            "The Linux kernel is missing"
        ])
        XCTAssertEqual(report?.failed[1].detail, "The output has a new format.")
    }

    func testNewListFormatFails() async {
        let runner = containerRunner()
        runner.responses["volume list --format json"] = ok("NAME  DRIVER\ndata  local")
        runner.responses["network list --format json"] = CommandResult(exitCode: 64, stdout: "", stderr: "Error: unknown option '--format'")
        let report = await probe(runner, folders: ["/root/kernels": ["default.kernel"]]).probe(row(.container, installed: "1.6.1", location: cli))
        XCTAssertEqual(report?.failed.map(\.id), ["container.volumes", "container.networks"])
        XCTAssertEqual(report?.failed.last?.detail, "Error: unknown option '--format'")
    }

    func testClusterPluginMissingIsSkipped() async {
        let runner = containerRunner()
        runner.responses["cluster --help"] = CommandResult(exitCode: 1, stdout: "", stderr: HealthFixtures.clusterUnsupported)
        let report = await probe(runner, folders: ["/root/kernels": ["default.kernel"]]).probe(row(.container, installed: "1.6.1", location: cli))
        XCTAssertEqual(outcomes(report)["container.clusters"], .skipped)
        XCTAssertFalse(runner.calls.contains { Array($0.dropFirst().prefix(2)) == ["cluster", "list"] })
    }

    func testOllamaChecks() async {
        let http = PathHTTP()
        http.replies = ["/api/version": HealthFixtures.ollamaVersion, "/api/tags": HealthFixtures.ollamaTags, "/api/ps": HealthFixtures.ollamaPS]
        let runner = MockRunner()
        runner.responses["-v"] = ok("ollama version is 0.16.2\n")
        let ollama = row(.ollama, installed: "1.0.0", location: "/opt/homebrew/bin/ollama", method: .homebrewFormula("ollama"))
        let good = await probe(runner, executables: ["/opt/homebrew/bin/ollama"], http: http).probe(ollama)
        XCTAssertTrue(good?.allPassed == true)
        XCTAssertEqual(good?.checks.map(\.id), ["ollama.cli", "ollama.version", "ollama.models", "ollama.loaded"])
        XCTAssertEqual(http.paths, ["/api/version", "/api/tags", "/api/ps"], "GET only")

        http.replies["/api/ps"] = HealthFixtures.ollamaPSChanged
        let broken = await probe(runner, executables: ["/opt/homebrew/bin/ollama"], http: http).probe(ollama)
        XCTAssertEqual(broken?.failed.map(\.failure), ["Loaded models can't be listed"])

        http.down = true
        let down = await probe(runner, executables: ["/opt/homebrew/bin/ollama"], http: http).probe(ollama)
        XCTAssertEqual(down?.failed, [], "Not running is not broken")
        XCTAssertEqual(outcomes(down)["ollama.models"], .skipped)
    }

    func testLMStudioReadsOnlyWhileItRuns() async {
        let lms = "/Users/me/.lmstudio/bin/lms"
        let runner = MockRunner()
        runner.responses["version"] = ok(HealthFixtures.lmsVersion)
        runner.responses["daemon status --json"] = ok(HealthFixtures.lmsDaemonRunning)
        runner.responses["ls --json"] = ok(LibraryFixtures.lmsList)
        runner.responses["ps --json"] = ok("[]")
        runner.responses["server status --json"] = ok(HealthFixtures.lmsServerStatus)
        let core = row(.lmStudio, installed: "0.1.0", location: lms, method: .lmStudioScript)
        let good = await probe(runner).probe(core)
        XCTAssertTrue(good?.allPassed == true)

        runner.responses["ls --json"] = ok("Models:\n  qwen3 (2 GB)")
        let result9 = await probe(runner).probe(core)
        XCTAssertEqual(result9?.failed.map(\.failure), ["Downloaded models can't be listed"])

        let stopped = MockRunner()
        stopped.responses["version"] = ok(HealthFixtures.lmsVersion)
        stopped.responses["daemon status --json"] = ok(HealthFixtures.lmsDaemonStopped)
        let idle = await probe(stopped).probe(core)
        XCTAssertEqual(idle?.failed, [])
        XCTAssertEqual(outcomes(idle)["lmstudio.models"], .skipped)
        XCTAssertFalse(stopped.calls.contains { $0.contains("ls") || $0.contains("ps") }, "lms ls and ps could wake LM Studio")
    }

    func testMLXChecks() async {
        let runner = MockRunner()
        runner.responses["-c import mlx.core, mlx_lm, mlx_lm.server"] = CommandResult(exitCode: 1, stdout: "",
            stderr: "Traceback (most recent call last):\nModuleNotFoundError: No module named 'mlx_lm.server'")
        runner.responses["--help"] = ok("usage: mlx_lm.server [-h] [--model MODEL] [--host HOST] [--port PORT]")
        let mlx = row(.mlx, installed: "1.0.0", location: "/ai/bin/mlx_lm.server", method: .appRuntime)
        let report = await probe(runner).probe(mlx)
        XCTAssertEqual(report?.failed.map(\.failure), ["mlx-lm doesn't load"])
        XCTAssertEqual(report?.failed.first?.detail, "ModuleNotFoundError: No module named 'mlx_lm.server'")
        XCTAssertEqual(runner.calls.first?.first, "/ai/uv-tools/mlx-lm/bin/python", "The app's own venv")
        let result8 = await probe(runner).probe(row(.mlx, method: .other("/opt/homebrew/bin/mlx_lm.server")))
        XCTAssertNil(result8, "Only the app's own install")
    }

    func testKubernetesAndSharingToolsWithRealHelp() async {
        let runner = MockRunner()
        runner.responses["version --client -o json"] = ok(HealthFixtures.kubectlVersion)
        runner.responses["port-forward --help"] = ok(HealthFixtures.kubectlPortForwardHelp)
        runner.responses["options"] = ok(HealthFixtures.kubectlOptions)
        runner.responses["apply --help"] = ok(HealthFixtures.kubectlApplyHelp)
        let kubectl = await probe(runner).probe(row(.kubectl, installed: "2.0.0", location: "/opt/homebrew/bin/kubectl"))
        XCTAssertTrue(kubectl?.allPassed == true, "\(kubectl?.failed ?? [])")

        runner.responses["port-forward --help"] = ok("Usage:\n  kubectl port-forward TYPE/NAME [options]\n    --listen=[localhost]:")
        let broken = await probe(runner).probe(row(.kubectl, installed: "2.0.0", location: "/opt/homebrew/bin/kubectl"))
        XCTAssertEqual(broken?.failed.map(\.failure), ["Kubernetes port forwards can't start"])
        XCTAssertEqual(broken?.failed.first?.detail, "The help no longer lists --address.")

        let cloud = MockRunner()
        cloud.responses["--version"] = ok(HealthFixtures.cloudflaredVersion)
        cloud.responses["tunnel --help"] = ok(HealthFixtures.cloudflaredTunnelHelp)
        let result7 = await probe(cloud).probe(row(.cloudflared, installed: "2026.3.0", location: "/opt/homebrew/bin/cloudflared"))
        XCTAssertTrue(result7?.allPassed == true)
        cloud.responses["tunnel --help"] = ok(HealthFixtures.cloudflaredTunnelHelpNoURL)
        let result6 = await probe(cloud).probe(row(.cloudflared, installed: "2027.1.0", location: "/opt/homebrew/bin/cloudflared"))
        XCTAssertEqual(result6?.failed.map(\.failure),
                       ["Cloudflare quick tunnels can't start"])

        let helm = MockRunner()
        helm.responses["version --short"] = ok(HealthFixtures.helmVersion)
        let result5 = await probe(helm).probe(row(.helm, installed: "5.0.0", location: "/opt/homebrew/bin/helm"))
        XCTAssertTrue(result5?.allPassed == true)

        let uv = MockRunner()
        uv.responses["--version"] = ok(HealthFixtures.uvVersion)
        uv.responses["tool install --help"] = ok(HealthFixtures.uvToolInstallHelp)
        let result4 = await probe(uv).probe(row(.uv, installed: "1.0.0", location: "/opt/homebrew/bin/uv"))
        XCTAssertTrue(result4?.allPassed == true)
    }

    func testHelpFlagMatching() {
        XCTAssertTrue(HealthChecks.mentions("   --url URL   Connect", flag: "--url"))
        XCTAssertTrue(HealthChecks.mentions("    --address=[localhost]:", flag: "--address"))
        XCTAssertTrue(HealthChecks.mentions("    -n, --namespace='':", flag: "--namespace"))
        XCTAssertTrue(HealthChecks.mentions("    -f, --filename=[]:", flag: "--filename"))
        XCTAssertFalse(HealthChecks.mentions("   --url-prefix value", flag: "--url"))
        XCTAssertFalse(HealthChecks.mentions("   --no-url", flag: "--url"))
    }

    func testAgentChecks() async {
        let runner = MockRunner()
        runner.responses["--version"] = ok(HealthFixtures.claudeVersion)
        var claude = row(.agent, id: "agent:claude", installed: "3.0.0", location: "/opt/homebrew/bin/claude")
        claude.name = "Claude Code"
        let files = ["/Users/me/.claude.json": Data(HealthFixtures.claudeJSON.utf8)]
        let folders = ["/Users/me/.claude/projects": ["-Users-me-app"]]
        let good = await probe(runner, files: files, folders: folders).probe(claude)
        XCTAssertEqual(good?.checks.map(\.id), ["agent.version", "agent.config", "agent.sessions"])
        XCTAssertTrue(good?.allPassed == true)

        let broken = await probe(runner, files: ["/Users/me/.claude.json": Data("version = 3".utf8)]).probe(claude)
        XCTAssertEqual(broken?.failed.map(\.failure), ["Claude Code settings can't be read"])
        XCTAssertEqual(outcomes(broken)["agent.sessions"], .skipped, "A missing folder is skipped")

        // ...but a folder that was there with the last good version and is gone now counts as broken.
        let compared = broken?.comparing(with: good)
        XCTAssertEqual(compared?.failed.map(\.id), ["agent.config", "agent.sessions"])

        let noVersion = MockRunner()
        noVersion.responses["--version"] = ok("Claude Code\n")
        let result3 = await probe(noVersion).probe(claude)
        XCTAssertEqual(result3?.failed.map(\.id), ["agent.version"])
    }

    func testRowsWithoutChecks() async {
        let result2 = await probe(MockRunner()).probe(row(.mcp, id: "mcp:fetch"))
        XCTAssertNil(result2)
        let result1 = await probe(MockRunner()).probe(row(.ollama, status: .notInstalled))
        XCTAssertNil(result1)
    }
}

// MARK: - Last good version

final class ComponentHealthStoreTests: XCTestCase {
    private func report(_ version: String, failing: Bool = false, id: String = "ollama") -> ComponentHealthReport {
        ComponentHealthReport(componentID: id, version: version, checks: [
            HealthCheck(id: "a", feature: "A works", failure: "A doesn't work", outcome: failing ? .failed : .passed)
        ])
    }

    func testKeepsTheNewestGoodVersion() {
        let file = tempStoreFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = ComponentHealthStore(file: file)
        store.record(report("0.30.0"))
        store.record(report("0.40.15"))
        store.record(report("1.0.0", failing: true))
        XCTAssertEqual(store.lastGood("ollama"), v("0.40.15"))
        XCTAssertEqual(store.lastReport("ollama")?.version, "1.0.0")
        XCTAssertEqual(store.goodReport("ollama")?.version, "0.40.15")
        // Saved in the data folder and read back.
        let again = ComponentHealthStore(file: file)
        XCTAssertEqual(again.lastGood("ollama"), v("0.40.15"))
        XCTAssertEqual(again.goodVersions("ollama"), [v("0.30.0"), v("0.40.15")])
    }

    func testOnlyReportsThatReallyRanCount() {
        let store = ComponentHealthStore(file: nil)
        store.record(ComponentHealthReport(componentID: "ollama", version: "0.40.15", checks: [
            HealthCheck(id: "a", feature: "A", failure: "A", outcome: .skipped)
        ]))
        XCTAssertNil(store.lastGood("ollama"), "Everything skipped (Ollama not running) is not good")
    }

    func testReportedFailuresJoinTheReportOfThatVersion() {
        let store = ComponentHealthStore(file: nil)
        store.record(report("1.0.0"))
        let failure = ComponentFailure(componentID: "ollama", feature: "Starting the Ollama server", detail: "unknown flag: --host")
        let merged = store.recordFailure(ComponentHealth.check(for: failure), componentID: "ollama", version: "1.0.0")
        XCTAssertEqual(merged.checks.map(\.id), ["a", "use.starting-the-ollama-server"])
        XCTAssertEqual(merged.failed.first?.name, "Starting the Ollama server")
        XCTAssertTrue(merged.failed.first?.isReported == true)
        // The same failure twice is one check. Another version starts a new report.
        store.recordFailure(ComponentHealth.check(for: failure), componentID: "ollama", version: "1.0.0")
        XCTAssertEqual(store.lastReport("ollama")?.checks.count, 2)
        XCTAssertEqual(store.recordFailure(ComponentHealth.check(for: failure), componentID: "ollama", version: "1.1.0").checks.count, 1)
        for index in 0..<12 { store.record(report("0.\(index).0", id: "many")) }
        XCTAssertEqual(store.goodVersions("many").count, 8)
        XCTAssertEqual(store.goodVersions("many").max(), v("0.11.0"))
    }
}

// MARK: - Assessment

final class ComponentAssessmentTests: XCTestCase {
    private func failing(_ count: Int, version: String = "1.0.0") -> ComponentHealthReport {
        ComponentHealthReport(componentID: "ollama", version: version, checks: (0..<3).map {
            HealthCheck(id: "c\($0)", title: "Feature \($0)", feature: "F\($0)", failure: "X\($0)", outcome: $0 < count ? .failed : .passed)
        })
    }

    private func ollama(_ installed: String, matches: Bool) -> ComponentInfo {
        var info = row(.ollama, installed: installed, method: .homebrewFormula("ollama"), status: .upToDate)
        info.matchesTested = matches
        info.testedText = "0.16.x"
        return info
    }

    private let tested = ComponentGate.Tested(line: [0, 16], version: v("0.16.2"))

    func testAFailureOnAnotherVersionOffersTheTestedOne() {
        let result = ComponentHealthAssessment.apply(to: ollama("1.0.0", matches: false), report: failing(2), tested: tested,
                                                     published: [v("1.0.0"), v("0.16.3"), v("0.16.2")])
        XCTAssertEqual(result.status, .notWorking)
        XCTAssertEqual(result.status.title, "Not working with this version")
        XCTAssertEqual(result.failedChecks.map(\.failure), ["X0", "X1"])
        XCTAssertEqual(result.switchTarget, "0.16.3")
        XCTAssertTrue(result.offersSwitch)
        XCTAssertEqual(result.note, "Feature 0 didn't work with version 1.0.0. It works with 0.16.3. 1 more feature isn't working.")
        XCTAssertEqual(ComponentHealthAssessment.headline(result), "Feature 0 (and 1 more) didn't work with Ollama 1.0.0.")
        XCTAssertEqual(ComponentHealthAssessment.offer(result), "It works with 0.16.3.")
    }

    func testAnOlderVersionSwitchesUp() {
        let result = ComponentHealthAssessment.apply(to: ollama("0.10.0", matches: false), report: failing(1, version: "0.10.0"), tested: tested,
                                                     published: [])
        XCTAssertEqual(result.switchTarget, "0.16.2", "An upgrade to the tested version")
        XCTAssertTrue(ComponentSwitchPlanner.isUpgrade(result, to: result.switchTarget))
    }

    func testNoOfferWithoutAFailureOrOnTheTestedVersion() {
        let untested = ollama("1.0.0", matches: false)
        let fine = ComponentHealthAssessment.apply(to: untested, report: failing(0), tested: tested, published: [])
        XCTAssertEqual(fine.status, .upToDate, "Untested alone is not a problem")
        XCTAssertFalse(fine.offersSwitch)
        let onTested = ComponentHealthAssessment.apply(to: ollama("0.16.2", matches: true), report: failing(1, version: "0.16.2"), tested: tested,
                                                       published: [])
        XCTAssertEqual(onTested.status, .notWorking)
        XCTAssertNil(onTested.switchTarget)
        XCTAssertFalse(onTested.offersSwitch)
        XCTAssertTrue(onTested.note?.contains("This is the tested version") == true)
    }

    func testCheckerChecksOnVersionChangeAndKeepsReportedFailures() async {
        let http = URLHTTP()
        http.replies[LatestSource.homebrewFormula("kubernetes-cli").url.absoluteString] = #"{"versions":{"stable":"2.0.0"}}"#
        http.replies[LatestSource.githubReleases("kubernetes/kubernetes").url.absoluteString] = """
        [{"tag_name":"v2.0.0","html_url":"https://github.com/kubernetes/kubernetes/releases/tag/v2.0.0","prerelease":false,"draft":false,"assets":[]},
         {"tag_name":"v1.35.3","html_url":"https://github.com/kubernetes/kubernetes/releases/tag/v1.35.3","prerelease":false,"draft":false,"assets":[]}]
        """
        let runner = MockRunner()
        runner.responses["version --client -o json"] = ok(HealthFixtures.kubectlVersion.replacingOccurrences(of: "v1.35.0", with: "v2.0.0"))
        runner.responses["port-forward --help"] = ok("no flags here")
        runner.responses["options"] = ok(HealthFixtures.kubectlOptions)
        runner.responses["apply --help"] = ok(HealthFixtures.kubectlApplyHelp)
        let path = "/opt/homebrew/bin/kubectl"
        let system = ComponentSystem(runner: runner, isExecutable: { $0 == path }, fileExists: { $0 == path },
                                     resolve: { $0 == path ? "/opt/homebrew/Cellar/kubernetes-cli/2.0.0/bin/kubectl" : $0 },
                                     readFile: { _ in nil }, listDirectory: { _ in [] }, home: "/Users/me")
        let checker = ComponentChecker(system: system, fetcher: ComponentLatestFetcher(http: http, cache: ComponentLatestCache(file: nil)),
                                       toolsDirectory: nil, agents: { [] })
        let rows = await checker.check(.kubectl)
        XCTAssertEqual(rows.first?.status, .upToDate)
        XCTAssertEqual(rows.first?.matchesTested, false)
        let store = ComponentHealthStore(file: nil)
        let assessed = await checker.applyHealth(to: rows, probe: probe(runner), store: store)
        XCTAssertEqual(assessed.first?.status, .notWorking)
        XCTAssertEqual(assessed.first?.failedChecks.map(\.failure), ["Kubernetes port forwards can't start"])
        XCTAssertEqual(assessed.first?.switchTarget, "1.35.3")
        XCTAssertEqual(store.lastReport("kubectl")?.version, "2.0.0", "The report is kept")

        // Same version again: no new probe, the report stays.
        let calls = runner.calls.count
        _ = await checker.applyHealth(to: rows, probe: probe(runner), store: store)
        XCTAssertEqual(runner.calls.count, calls, "Checks run on version change, not on every check")

        // A failure a screen reported survives Check Now.
        store.recordFailure(ComponentHealth.check(for: ComponentFailure(componentID: "kubectl", feature: "Applying a manifest", detail: "unknown flag")),
                            componentID: "kubectl", version: "2.0.0")
        runner.responses["port-forward --help"] = ok(HealthFixtures.kubectlPortForwardHelp)
        let again = await checker.applyHealth(to: rows, probe: probe(runner), store: store, force: true)
        XCTAssertEqual(again.first?.failedChecks.map(\.id), ["use.applying-a-manifest"])
        XCTAssertGreaterThan(runner.calls.count, calls)
    }
}

// MARK: - Reporting failures at use time

final class ComponentReportTests: XCTestCase {
    private final class Box: @unchecked Sendable {
        var items: [ComponentFailure] = []
    }

    override func tearDown() {
        ComponentHealth.setReceiver(nil)
    }

    func testOnlyVersionProblemsAreReported() {
        let box = Box()
        ComponentHealth.setReceiver { box.items.append($0) }
        XCTAssertTrue(ComponentHealth.report(component: .container, feature: "The Kubernetes cluster list", error: DeckError.parse("cluster list")))
        XCTAssertTrue(ComponentHealth.report(component: "mlx", feature: "Starting the MLX server",
                                             message: "mlx_lm.server: error: unrecognized arguments: --host"))
        XCTAssertTrue(ComponentHealth.report(component: .ollama, feature: "Starting the Ollama server",
                                             error: DeckError.commandFailed("Error: unknown flag: --keep")))
        // Ordinary failures are not a version problem.
        XCTAssertFalse(ComponentHealth.report(component: .container, feature: "Deleting a Kubernetes cluster",
                                              error: DeckError.commandFailed("Error: cluster not found: demo")))
        XCTAssertFalse(ComponentHealth.report(component: .ollama, feature: "Starting the Ollama server", error: URLError(.cannotConnectToHost)))
        XCTAssertEqual(box.items.map(\.componentID), ["container", "mlx", "ollama"])
        XCTAssertEqual(box.items.first?.feature, "The Kubernetes cluster list")
        let check = ComponentHealth.check(for: box.items[1])
        XCTAssertEqual(check.failure, "Starting the MLX server didn't work")
        XCTAssertEqual(check.outcome, .failed)
        XCTAssertEqual(check.detail, "mlx_lm.server: error: unrecognized arguments: --host")
    }

    func testVersionProblemText() {
        for text in ["Error: unknown command \"cluster\"", "ModuleNotFoundError: No module named 'mlx_lm.server'",
                     "Could not read the cluster list.", "error: unexpected argument '--format' found", "HTTP 404 from /api/ps."] {
            XCTAssertTrue(ComponentHealth.isVersionProblem(text), text)
        }
        for text in ["container not found: web", "Connection refused", "The password prompt was closed."] {
            XCTAssertFalse(ComponentHealth.isVersionProblem(text), text)
        }
    }
}

// MARK: - Switch plans (down or up)

final class ComponentSwitchPlanTests: XCTestCase {
    private func broken(_ kind: ComponentKind, _ method: InstallMethod, id: String? = nil, installed: String = "1.0.0") -> ComponentInfo {
        var info = row(kind, id: id, installed: installed, method: method, status: .notWorking)
        info.matchesTested = false
        return info
    }

    let package = PackageRef(name: "container-1.6.2-installer-signed.pkg",
                             url: URL(string: "https://github.com/apple/container/releases/download/1.6.2/container-1.6.2-installer-signed.pkg")!,
                             digest: "sha256:00")

    func testAppleContainerOrder() throws {
        var context = ComponentPlanContext(containerPath: "/usr/local/bin/container", package: package)
        context.uninstallScript = "/usr/local/bin/uninstall-container.sh"
        let noBackup = try ComponentSwitchPlanner.plan(for: broken(.container, .applePackage, installed: "1.8.0"), to: "1.6.2", context: context)
        XCTAssertEqual(noBackup.steps, [.downloadPackage(package), .verifyPackage, .recordRunningContainers, .stopContainerService,
                                        .uninstallKeepingData(script: "/usr/local/bin/uninstall-container.sh"), .installPackage,
                                        .startContainerService, .recheck, .healthCheck, .restartContainers])
        // With the backup (on by default): right after the service stops, before anything is removed.
        context.containerBackupFolder = "/b/container-1"
        let plan = try ComponentSwitchPlanner.plan(for: broken(.container, .applePackage, installed: "1.8.0"), to: "1.6.2", context: context)
        XCTAssertEqual(plan.steps, [.downloadPackage(package), .verifyPackage, .recordRunningContainers, .stopContainerService,
                                    .backupContainerData(folder: "/b/container-1"),
                                    .uninstallKeepingData(script: "/usr/local/bin/uninstall-container.sh"), .installPackage,
                                    .startContainerService, .recheck, .healthCheck, .restartContainers])
        XCTAssertEqual(ComponentSwitchNotes.sharedStoreClusters(["web", "api"]),
                       "Delete these clusters first, they use this Mac's image store, which needs the newer version: api, web.")
        XCTAssertNil(ComponentSwitchNotes.sharedStoreClusters([]))
        XCTAssertTrue(ComponentChecker.containerBackupFolder(toolsDirectory: "/tools", now: Date(timeIntervalSince1970: 0)).hasPrefix("/tools/backups/container-19"))
        XCTAssertEqual(plan.title, "Switch Apple container to 1.6.2")
        XCTAssertTrue(plan.needsAdmin)
        XCTAssertFalse(plan.isManual)
        XCTAssertTrue(plan.confirmation.contains(ComponentSwitchNotes.containerData(from: "1.8.0", to: "1.6.2")))
        XCTAssertTrue(plan.terminalCommand.contains("&& sudo /usr/local/bin/uninstall-container.sh -k && sudo installer -pkg"))
        // Nothing changes before the download is checked.
        XCTAssertTrue(plan.steps.prefix(3).allSatisfy(\.isCancellable))
        XCTAssertFalse(ComponentUpdatePlan.Step.uninstallKeepingData(script: "x").isCancellable)
    }

    func testAppleContainerWithoutPackageShowsApplesSteps() throws {
        let plan = try ComponentSwitchPlanner.plan(for: broken(.container, .applePackage, installed: "1.8.0"), to: "1.6.2",
                                                      context: ComponentPlanContext(containerPath: "/usr/local/bin/container"))
        XCTAssertTrue(plan.isManual)
        XCTAssertEqual(plan.manualSteps.first, "/usr/local/bin/container system stop")
        XCTAssertEqual(plan.manualSteps[1], "sudo /usr/local/bin/uninstall-container.sh -k")
        XCTAssertEqual(plan.manualSteps.last, "/usr/local/bin/container system start")
    }

    func testPackageManagersPinTheVersion() throws {
        var context = ComponentPlanContext()
        context.toolUVPath = "/opt/homebrew/bin/uv"
        context.pipxPath = "/opt/homebrew/bin/pipx"
        let npm = try ComponentSwitchPlanner.plan(for: broken(.agent, .npmGlobal(package: "@openai/codex", prefix: "/opt/homebrew"), id: "agent:codex"),
                                                     to: "0.167.0", context: context)
        XCTAssertEqual(npm.steps, [.run(executable: "/usr/bin/env", arguments: ["PATH=/opt/homebrew/bin:/usr/bin:/bin", "/opt/homebrew/bin/npm", "install", "-g", "@openai/codex@0.167.0"]),
                                   .recheck, .healthCheck])
        XCTAssertEqual(npm.terminalCommand, "npm install -g @openai/codex@0.167.0")

        let uv = try ComponentSwitchPlanner.plan(for: broken(.agent, .uvTool("aider-chat"), id: "agent:aider"), to: "0.86.2", context: context)
        XCTAssertEqual(uv.steps.first, .run(executable: "/opt/homebrew/bin/uv", arguments: ["tool", "install", "aider-chat==0.86.2", "--force"]))

        let pipx = try ComponentSwitchPlanner.plan(for: broken(.agent, .pipx("aider-chat"), id: "agent:aider"), to: "0.86.2", context: context)
        XCTAssertEqual(pipx.steps.first, .run(executable: "/opt/homebrew/bin/pipx", arguments: ["install", "--force", "aider-chat==0.86.2"]))

        let native = try ComponentSwitchPlanner.plan(for: broken(.agent, .selfUpdater("/Users/me/.local/bin/claude"), id: "agent:claude"),
                                                        to: "2.1.318", context: context)
        XCTAssertEqual(native.steps.first, .run(executable: "/Users/me/.local/bin/claude", arguments: ["install", "2.1.318"]))
        XCTAssertTrue(native.confirmation.contains("DISABLE_AUTOUPDATER"))

        XCTAssertThrowsError(try ComponentSwitchPlanner.plan(for: broken(.agent, .uvTool("aider-chat"), id: "agent:aider"), to: "0.86.2",
                                                                context: ComponentPlanContext()))
    }

    func testMLXAndOwnCloudflared() throws {
        let env = ["UV_TOOL_DIR=/x/uv-tools"]
        let mlx = try ComponentSwitchPlanner.plan(for: broken(.mlx, .appRuntime), to: "0.32.2",
                                                     context: ComponentPlanContext(uvPath: "/x/bin/uv", mlxEnvironment: env, mlxServerRunning: true))
        XCTAssertEqual(mlx.steps, [.stopMLXServer,
                                   .run(executable: "/usr/bin/env", arguments: env + ["/x/bin/uv", "tool", "install", "--python", AIConfig.mlxPythonVersion, "--force", "mlx-lm==0.32.2"]),
                                   .recheck, .healthCheck])
        let cloudflared = try ComponentSwitchPlanner.plan(for: broken(.cloudflared, .appDownload, installed: "2027.1.0"), to: "2026.3.0",
                                                             context: ComponentPlanContext())
        XCTAssertEqual(cloudflared.steps, [.downloadCloudflaredVersion("2026.3.0"), .recheck, .healthCheck])
    }

    func testHomebrewUsesAVersionedFormulaOrShowsSteps() throws {
        var context = ComponentPlanContext(brewPath: "/opt/homebrew/bin/brew")
        context.versionedFormula = "helm@3"
        let helm = try ComponentSwitchPlanner.plan(for: broken(.helm, .homebrewFormula("helm"), installed: "4.0.0"), to: "3.22.1", context: context)
        XCTAssertEqual(helm.steps, [.run(executable: "/opt/homebrew/bin/brew", arguments: ["install", "helm@3"]),
                                    .run(executable: "/opt/homebrew/bin/brew", arguments: ["unlink", "helm"]),
                                    .run(executable: "/opt/homebrew/bin/brew", arguments: ["link", "--force", "helm@3"]),
                                    .recheck, .healthCheck])

        let ollama = try ComponentSwitchPlanner.plan(for: broken(.ollama, .homebrewFormula("ollama")), to: "0.40.15",
                                                        context: ComponentPlanContext(brewPath: "/opt/homebrew/bin/brew"))
        XCTAssertTrue(ollama.isManual)
        XCTAssertEqual(ollama.manualReason, "Homebrew only has the newest ollama.")
        XCTAssertTrue(ollama.manualSteps.contains("curl -fsSL https://ollama.com/install.sh | OLLAMA_VERSION=0.40.15 sh"))

        let kubectl = try ComponentSwitchPlanner.plan(for: broken(.kubectl, .homebrewFormula("kubernetes-cli"), installed: "2.0.0"), to: "1.37.2",
                                                         context: ComponentPlanContext(brewPath: "/opt/homebrew/bin/brew"))
        XCTAssertEqual(kubectl.manualSteps.first, "curl -fLO https://dl.k8s.io/release/v1.37.2/bin/darwin/arm64/kubectl")
    }

    func testToolsWithoutAVersionPickerShowSteps() throws {
        let lms = try ComponentSwitchPlanner.plan(for: broken(.lmStudio, .lmStudioScript, installed: "0.1.0"), to: "0.0.27",
                                                     context: ComponentPlanContext())
        XCTAssertTrue(lms.isManual)
        XCTAssertTrue(lms.manualReason?.contains("only install the newest") == true)
        let tailscale = try ComponentSwitchPlanner.plan(for: broken(.tailscale, .homebrewCask("tailscale-app"), installed: "2.0.0"), to: "1.104.5",
                                                           context: ComponentPlanContext())
        XCTAssertTrue(tailscale.manualSteps.contains("curl -fLO https://pkgs.tailscale.com/stable/Tailscale-1.104.5-macos.pkg"))
        let unknown = try ComponentSwitchPlanner.plan(for: broken(.ngrok, .other("/usr/local/bin/ngrok"), installed: "4.0.0"), to: nil,
                                                         context: ComponentPlanContext())
        XCTAssertTrue(unknown.isManual)

        XCTAssertTrue(ComponentSwitchPlanner.runsInApp(broken(.container, .applePackage)))
        XCTAssertTrue(ComponentSwitchPlanner.runsInApp(broken(.agent, .npmGlobal(package: "x", prefix: "/p"), id: "agent:x")))
        XCTAssertTrue(ComponentSwitchPlanner.runsInApp(broken(.helm, .homebrewFormula("helm"))))
        XCTAssertFalse(ComponentSwitchPlanner.runsInApp(broken(.ollama, .homebrewFormula("ollama"))))
        XCTAssertFalse(ComponentSwitchPlanner.runsInApp(broken(.lmStudio, .lmStudioScript)))
    }

    func testVersionedFormulaLookup() async {
        let http = URLHTTP()
        http.replies[LatestSource.homebrewFormula("helm@3").url.absoluteString] = #"{"versions":{"stable":"3.22.1"},"keg_only":true}"#
        http.replies[LatestSource.homebrewFormula("kubernetes-cli@1.34").url.absoluteString] = #"{"versions":{"stable":"1.34.9"},"disabled":true}"#
        var checker = ComponentChecker(system: healthSystem(MockRunner()), fetcher: ComponentLatestFetcher(http: http, cache: ComponentLatestCache(file: nil)),
                                       toolsDirectory: nil, agents: { [] })
        checker.tested = { $0 == "helm" ? ComponentGate.Tested(line: [3]) : ComponentGate.Tested(line: [1, 34]) }
        let helm = await checker.switchContext(for: broken(.helm, .homebrewFormula("helm"), installed: "4.0.0"), target: "3.20.0")
        XCTAssertEqual(helm.context.versionedFormula, "helm@3")
        XCTAssertEqual(helm.target, "3.22.1", "The versioned formula installs its own newest version")
        let kubectl = await checker.switchContext(for: broken(.kubectl, .homebrewFormula("kubernetes-cli"), installed: "1.35.0"), target: "1.34.2")
        XCTAssertNil(kubectl.context.versionedFormula, "A disabled formula can't be installed")
        XCTAssertEqual(kubectl.target, "1.34.2")
    }

    func testSwitchingUp() throws {
        // Apple container older than the tested line: Apple's installer over it, no uninstall.
        let up = try ComponentSwitchPlanner.plan(for: broken(.container, .applePackage, installed: "1.5.0"), to: "1.6.2",
                                                 context: ComponentPlanContext(containerPath: "/usr/local/bin/container", package: package))
        XCTAssertEqual(up.steps, [.downloadPackage(package), .verifyPackage, .recordRunningContainers, .stopContainerService, .installPackage,
                                  .startContainerService, .recheck, .healthCheck, .restartContainers])
        XCTAssertFalse(up.steps.contains { if case .uninstallKeepingData = $0 { return true } else { return false } })
        // Homebrew up: brew upgrade when Homebrew's newest is the tested version, else steps.
        var context = ComponentPlanContext(brewPath: "/opt/homebrew/bin/brew")
        context.brewNewestMatchesTested = true
        let brew = try ComponentSwitchPlanner.plan(for: broken(.kubectl, .homebrewFormula("kubernetes-cli"), installed: "1.30.0"), to: "1.35.3", context: context)
        XCTAssertEqual(brew.steps.first, .run(executable: "/opt/homebrew/bin/brew", arguments: ["upgrade", "kubernetes-cli"]))
        context.brewNewestMatchesTested = false
        let manual = try ComponentSwitchPlanner.plan(for: broken(.kubectl, .homebrewFormula("kubernetes-cli"), installed: "1.30.0"), to: "1.35.3", context: context)
        XCTAssertTrue(manual.isManual)
        XCTAssertEqual(manual.manualReason, "Homebrew's newest kubernetes-cli is not the tested version.")
        // npm works both ways.
        let npm = try ComponentSwitchPlanner.plan(for: broken(.agent, .npmGlobal(package: "@openai/codex", prefix: "/p"), id: "agent:codex", installed: "0.100.0"),
                                                  to: "0.167.0", context: ComponentPlanContext())
        XCTAssertEqual(npm.terminalCommand, "npm install -g @openai/codex@0.167.0")
    }

    func testNpmVersionList() throws {
        let json = #"{"name":"@openai/codex","dist-tags":{"latest":"0.167.0"},"versions":{"0.160.0":{},"0.167.0":{},"0.150.0":{"deprecated":"broken"},"1.0.0-alpha.1":{}}}"#
        let versions = try LatestReleases.parse(Data(json.utf8), source: .npmVersions("@openai/codex")).versions
        XCTAssertEqual(Set(versions), [v("0.160.0"), v("0.167.0"), v("1.0.0-alpha.1")])
        XCTAssertEqual(LatestSource.npmVersions("@openai/codex").url.absoluteString, "https://registry.npmjs.org/@openai/codex")
    }
}

// MARK: - Running a switch

final class ComponentDowngradeRunTests: XCTestCase {
    private func collect(_ stream: AsyncThrowingStream<ComponentUpdateEvent, Error>) async -> (events: [ComponentUpdateEvent], error: Error?) {
        var events: [ComponentUpdateEvent] = []
        do {
            for try await event in stream { events.append(event) }
            return (events, nil)
        } catch {
            return (events, error)
        }
    }

    private func plan(_ steps: [ComponentUpdatePlan.Step]) -> ComponentUpdatePlan {
        ComponentUpdatePlan(componentID: "container", title: "Downgrade Apple container to 1.6.2", target: "1.6.2", steps: steps,
                            confirmation: "", needsAdmin: true, manualOnly: false, terminalCommand: "")
    }

    func testContainerDowngradeOrderWithStandInTools() async throws {
        let runner = PrefixRunner()
        runner.on("/tools/container list --format json", ContainerCLIFixtures.containerList)
        runner.on("/tools/container system stop", "Stopping")
        runner.on("/tools/uninstall-container.sh -k", "Removed `container` tool and helpers")
        runner.on("/tools/installer -pkg", "installer: The install was successful.")
        runner.on("/tools/container system start", "Started")
        runner.on("/tools/container system status", "apiserver is running")
        runner.on("/tools/pkgutil --check-signature", "Status: signed by a developer certificate issued by Apple\n   1. Developer ID Installer: Apple Inc. (X)")
        runner.on("/tools/container start", "started")
        runner.on("/bin/mkdir -p /tools/backups/b1", "")
        runner.on("/bin/cp -cR /tools/home/Library/Application Support/com.apple.container /tools/backups/b1/com.apple.container", "")
        let containers = try ContainerOutputParser.containers(ContainerCLIFixtures.containerList).filter(\.isRunning).map(\.id)
        XCTAssertFalse(containers.isEmpty, "The fixture has a running container")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("deck-downgrade-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pkg = folder.appendingPathComponent("container-1.6.2-installer-signed.pkg")
        try Data("pkg".utf8).write(to: pkg)

        let after = ComponentInfo(id: "container", kind: .container, name: "Apple container", installed: "1.6.2", status: .upToDate)
        let report = ComponentHealthReport(componentID: "container", version: "1.6.2",
                                           checks: [HealthCheck(id: "a", feature: "Containers can be listed", failure: "x", outcome: .passed)])
        let updater = ComponentUpdater(runner: runner, streamer: LinesOnly(), toolsDirectory: "/tools", workRoot: folder,
                                       recheck: { after }, health: { info in
                                           runner.note("health \(info?.installed ?? "")")
                                           return report
                                       })
        let steps: [ComponentUpdatePlan.Step] = [.downloadPackage(PackageRef(name: pkg.lastPathComponent, url: pkg)), .verifyPackage,
                                                 .recordRunningContainers, .stopContainerService, .backupContainerData(folder: "/tools/backups/b1"),
                                                 .uninstallKeepingData(script: "/usr/local/bin/uninstall-container.sh"), .installPackage,
                                                 .startContainerService, .recheck, .healthCheck, .restartContainers]
        let result = await collect(updater.run(plan(steps), containerPath: "/usr/local/bin/container"))
        XCTAssertNil(result.error, "\(String(describing: result.error))")
        XCTAssertTrue(result.events.contains(.health(report)))

        let commands = runner.lines
        func index(_ prefix: String) -> Int { commands.firstIndex { $0.hasPrefix(prefix) } ?? -1 }
        let list = index("/tools/container list --format json"), stop = index("/tools/container system stop")
        let uninstall = index("/tools/uninstall-container.sh -k"), install = index("/tools/installer -pkg")
        let backup = index("/bin/cp -cR /tools/home/Library/Application Support/com.apple.container")
        let start = index("/tools/container system start"), checks = index("health 1.6.2")
        let restart = index("/tools/container start ")
        XCTAssertTrue(list >= 0 && list < stop, "Running containers are noted before anything stops")
        XCTAssertTrue(stop < backup && backup < uninstall, "The backup runs while the service is stopped, before the uninstall")
        XCTAssertTrue(stop < uninstall && uninstall < install && install < start && start < checks && checks < restart, "\(commands)")
        XCTAssertEqual(commands.filter { $0.hasPrefix("/tools/container start ") }, containers.map { "/tools/container start \($0)" },
                       "Only the containers that ran before start again")
    }

    func testRealRunSharesOnePasswordPromptForUninstallAndInstall() async throws {
        let runner = MockRunner()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("deck-downgrade-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pkg = folder.appendingPathComponent("container-1.6.2-installer-signed.pkg")
        try Data("pkg".utf8).write(to: pkg)
        let updater = ComponentUpdater(runner: runner, streamer: LinesOnly(), toolsDirectory: nil, workRoot: folder)
        let state = ComponentUpdater.RunState()
        state.packageFile = pkg
        try await updater.perform(.uninstallKeepingData(script: "/usr/local/bin/uninstall-container.sh"), plan: plan([]), containerPath: nil,
                                  state: state, emit: { _ in })
        XCTAssertTrue(runner.calls.isEmpty, "The uninstall waits for the install")
        _ = try? await updater.perform(.installPackage, plan: plan([]), containerPath: nil, state: state, emit: { _ in })
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(runner.calls.first?.first, "/usr/bin/osascript")
        let script = runner.calls.first?.last ?? ""
        XCTAssertTrue(script.contains("'/usr/local/bin/uninstall-container.sh' '-k' && '/usr/sbin/installer' '-pkg'"), script)
        XCTAssertTrue(script.hasSuffix("with administrator privileges"))
        XCTAssertTrue(state.uninstalled)
    }

    func testFailedRestartIsReported() async {
        let runner = MockRunner()
        runner.responses["list --format json"] = CommandResult(exitCode: 0, stdout: ContainerCLIFixtures.containerList)
        let updater = ComponentUpdater(runner: runner, streamer: LinesOnly(), toolsDirectory: "/tools")
        let result = await collect(updater.run(plan([.recordRunningContainers, .restartContainers]), containerPath: nil))
        let ids = (try? ContainerOutputParser.containers(ContainerCLIFixtures.containerList).filter(\.isRunning).map(\.id)) ?? []
        if ids.isEmpty {
            XCTAssertNil(result.error)
        } else {
            XCTAssertTrue(result.error?.localizedDescription.contains("did not start") == true)
        }
    }
}

/// Answers by the start of "executable args...". Keeps every call (and notes) in order.
private final class PrefixRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var rules: [(String, String)] = []
    private var recorded: [String] = []
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return recorded }

    func on(_ prefix: String, _ stdout: String) { rules.append((prefix, stdout)) }
    func note(_ text: String) { lock.lock(); recorded.append(text); lock.unlock() }

    func run(_ executable: String, _ arguments: [String], stdin: Data?) async throws -> CommandResult {
        let line = ([executable] + arguments).joined(separator: " ")
        note(line)
        guard let rule = rules.first(where: { line.hasPrefix($0.0) }) else { return CommandResult(exitCode: 1, stdout: "", stderr: "not mocked") }
        return CommandResult(exitCode: 0, stdout: rule.1)
    }
}

private struct LinesOnly: CommandStreaming {
    func stream(_ executable: String, _ arguments: [String]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
