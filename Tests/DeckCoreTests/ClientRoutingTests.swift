import XCTest
@testable import DeckCore

/// `ContainerClient` with a router: the calls marked Direct go to the daemon first,
/// fall back to the CLI on a transport error, and honour the Settings switch.
final class ClientRoutingTests: XCTestCase {
    private let cliPath = "/usr/local/bin/container"

    private struct Setup {
        let client: ContainerClient
        let router: ContainerBackendRouter
        /// The CLI runner the router falls back to.
        let fallbackRunner: MockRunner
        /// The runner of the routed client itself. Must stay unused for routed calls.
        let clientRunner: MockRunner
        let daemon: RecordedDaemon
        let force: Flag
    }

    private func setup(force: Bool = false) throws -> Setup {
        let daemon = try RecordedDaemon()
        let fallbackRunner = MockRunner()
        let clientRunner = MockRunner()
        let flag = Flag(force)
        let selector = BackendSelector(ping: { _ in "1.6.1" }, forceCLI: { flag.value })
        let router = ContainerBackendRouter(cli: ContainerClient(cliPath: cliPath, runner: fallbackRunner), api: daemon.client(), selector: selector)
        let client = ContainerClient(cliPath: cliPath, runner: clientRunner).routed(through: router)
        return Setup(client: client, router: router, fallbackRunner: fallbackRunner, clientRunner: clientRunner, daemon: daemon, force: flag)
    }

    private func ok(_ text: String) -> CommandResult { CommandResult(exitCode: 0, stdout: text) }

    func testPlainClientHasNoRouter() {
        let client = ContainerClient(cliPath: cliPath, runner: MockRunner())
        XCTAssertNil(client.router)
    }

    func testRouterKeepsAPlainCLIClient() throws {
        let s = try setup()
        // Even when handed a routed client, the router's CLI path must not route back.
        let looped = ContainerBackendRouter(cli: s.client)
        XCTAssertNil(looped.cli.router)
    }

    func testDirectPathIsUsed() async throws {
        let s = try setup()
        let list = try await s.client.listContainers(all: true)
        XCTAssertEqual(list.count, 4)
        _ = try await s.client.listVolumeSummaries()
        _ = try await s.client.listNetworkSummaries()
        _ = try await s.client.countVolumes()
        _ = try await s.client.diskUsage()
        let stats = try await s.client.stats([])
        XCTAssertFalse(stats.isEmpty)
        XCTAssertEqual(s.fallbackRunner.calls, [], "No CLI process")
        XCTAssertEqual(s.clientRunner.calls, [], "Routed calls never run the client's own CLI")
        XCTAssertTrue(s.daemon.api.routes.contains(APIRoute.containerList))
        XCTAssertTrue(s.daemon.api.routes.contains(APIRoute.volumeList))
        XCTAssertTrue(s.daemon.api.routes.contains(APIRoute.containerStats))
        let current = await s.client.backendStatus()
        let status = try XCTUnwrap(current)
        XCTAssertTrue(status.isDirect(.containerList))
        XCTAssertTrue(status.isDirect(.stats))
        XCTAssertEqual(status.summary, "Talks to Apple's container service directly (container 1.6.1)")
    }

    func testTransportErrorFallsBackToCLI() async throws {
        let s = try setup()
        s.daemon.api.setHandler { request in .failure(.interrupted(route: request.route)) }
        s.fallbackRunner.responses["list --all --format json"] = ok(RealCLIFixtures.containerList)
        let list = try await s.client.listContainers(all: true)
        XCTAssertEqual(list.count, 3, "The CLI's answer")
        XCTAssertEqual(s.fallbackRunner.calls.map { Array($0.dropFirst()) }, [["list", "--all", "--format", "json"]])
        XCTAssertEqual(s.clientRunner.calls, [])
        let current = await s.client.backendStatus()
        let status = try XCTUnwrap(current)
        XCTAssertEqual(status.fallbackCounts[.containerList], 1)
    }

    func testForceCLIIsHonouredAtOnce() async throws {
        let s = try setup(force: true)
        s.fallbackRunner.responses["list --all --format json"] = ok(RealCLIFixtures.containerList)
        _ = try await s.client.listContainers(all: true)
        XCTAssertEqual(s.daemon.api.requests.count, 0, "No XPC while the switch is on")
        XCTAssertEqual(s.fallbackRunner.calls.count, 1)
        let current = await s.client.backendStatus()
        var status = try XCTUnwrap(current)
        XCTAssertFalse(status.isDirect(.containerList))
        XCTAssertEqual(status.summary, "Uses the container command (chosen in Settings)")

        // Turning it off applies on the next call, no restart.
        s.force.value = false
        _ = try await s.client.listContainers(all: true)
        XCTAssertEqual(s.fallbackRunner.calls.count, 1)
        XCTAssertTrue(s.daemon.api.routes.contains(APIRoute.containerList))
        let again = await s.client.backendStatus()
        status = try XCTUnwrap(again)
        XCTAssertTrue(status.isDirect(.containerList))
    }

    func testCLIOnlyCallsStayOnTheClient() async throws {
        let s = try setup()
        s.clientRunner.responses["run --detach --name x alpine"] = ok("x\n")
        let id = try await s.client.runContainer(RunOptions(image: "alpine", name: "x"))
        XCTAssertEqual(id, "x")
        XCTAssertEqual(s.daemon.api.requests.count, 0)
    }

    func testServiceCheckUsesTheDaemon() async throws {
        let s = try setup()
        let running = try await s.client.isServiceRunning()
        XCTAssertTrue(running)
        XCTAssertEqual(s.fallbackRunner.calls, [])
        XCTAssertEqual(s.clientRunner.calls, [])
    }

    func testSetupServiceTakesTheServiceCheck() async {
        let runner = MockRunner()
        runner.responses["--version"] = CommandResult(exitCode: 0, stdout: "container CLI version 1.6.1\n")
        let files = FileSystem(fileExists: { $0 == "/usr/local/bin/container" }, isExecutable: { $0 == "/usr/local/bin/container" },
                               contentsOfDirectory: { _ in [] })
        let env = SetupEnvironment(system: SystemInfo(isAppleSilicon: true, osMajor: 26, osMinor: 0), files: files,
                                   pathEnv: "/usr/local/bin", customCLIPath: nil, appRoot: "/tmp/none")
        let asked = Flag(false)
        let service = SetupService(runner: runner, environment: env) { path in
            XCTAssertEqual(path, "/usr/local/bin/container")
            asked.value = true
            return true
        }
        let report = await service.runChecks()
        XCTAssertTrue(asked.value)
        XCTAssertTrue(report.serviceRunning)
        XCTAssertFalse(runner.calls.contains { $0.dropFirst().starts(with: ["system", "status"]) }, "No system status process")
    }
}
