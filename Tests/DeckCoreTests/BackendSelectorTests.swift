import XCTest
@testable import DeckCore

/// A ping whose answer the test sets, counting calls.
final class FakePing: @unchecked Sendable {
    private let lock = NSLock()
    private var answer: Result<String, APIError>
    private var count = 0

    init(_ answer: Result<String, APIError>) { self.answer = answer }

    func set(_ answer: Result<String, APIError>) { lock.lock(); self.answer = answer; lock.unlock() }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }

    var closure: BackendSelector.Ping {
        { _ in
            self.lock.lock()
            self.count += 1
            let answer = self.answer
            self.lock.unlock()
            return try answer.get()
        }
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool
    init(_ value: Bool) { stored = value }
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

final class BackendSelectorTests: XCTestCase {
    private func selector(_ ping: FakePing, force: Flag = Flag(false), recheck: TimeInterval = 30) -> BackendSelector {
        BackendSelector(ping: ping.closure, supportedVersions: AppConfig.apiSupportedVersions, forceCLI: { force.value }, recheckInterval: recheck)
    }

    func testSupportedRangeInAppConfig() {
        XCTAssertTrue(AppConfig.apiSupportedVersions.contains(SemanticVersion(1, 4, 0)))
        XCTAssertTrue(AppConfig.apiSupportedVersions.contains(SemanticVersion(1, 6, 1)))
        XCTAssertTrue(AppConfig.apiSupportedVersions.contains(SemanticVersion(1, 6, 99)))
        XCTAssertFalse(AppConfig.apiSupportedVersions.contains(SemanticVersion(1, 3, 1)))
        XCTAssertFalse(AppConfig.apiSupportedVersions.contains(SemanticVersion(1, 7, 0)))
        XCTAssertEqual(AppConfig.forceCLIBackendKey, "forceCLIBackend")
    }

    func testVersionRange() async {
        for (version, expected) in [("1.6.1", BackendSelector.Decision.direct), ("1.4.0", .direct), ("1.6.12", .direct),
                                    ("1.7.0", .cli), ("1.3.1", .cli), ("2.0.0", .cli), ("dev", .cli)] {
            let s = selector(FakePing(.success(version)))
            let decision = await s.decision(for: .containerList)
            XCTAssertEqual(decision, expected, version)
        }
        let s = selector(FakePing(.success("1.7.0")))
        _ = await s.decision(for: .images)
        let status = await s.status()
        XCTAssertEqual(status.backend, .cli)
        XCTAssertFalse(status.versionSupported)
        XCTAssertEqual(status.summary, "Uses the container command (container 1.7.0 is not tested yet)")
    }

    func testForceCLISkipsThePing() async {
        let ping = FakePing(.success("1.6.1"))
        let force = Flag(true)
        let s = selector(ping, force: force)
        let decision = await s.decision(for: .containerList)
        XCTAssertEqual(decision, .cli)
        XCTAssertEqual(ping.calls, 0)
        let status = await s.status()
        XCTAssertTrue(status.forcedCLI)
        XCTAssertEqual(status.summary, "Uses the container command (chosen in Settings)")
        // Turning it off applies on the next call.
        force.value = false
        let after = await s.decision(for: .containerList)
        XCTAssertEqual(after, .direct)
    }

    func testForceCLIReadsUserDefaultsKey() throws {
        // A private suite: the shared app defaults can be changed by other test runs at the same time.
        let suite = "deck-test-forcecli-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AppConfig.forceCLIBackendKey, "forceCLIBackend")
        XCTAssertFalse(BackendSelector.forceCLI(in: defaults))
        defaults.set(true, forKey: AppConfig.forceCLIBackendKey)
        XCTAssertTrue(BackendSelector.forceCLI(in: defaults))
        defaults.set(false, forKey: AppConfig.forceCLIBackendKey)
        XCTAssertFalse(BackendSelector.forceCLI(in: defaults))
    }

    func testDaemonDownIsServiceStoppedNotFallback() async {
        let ping = FakePing(.failure(.serviceUnavailable(route: "ping")))
        let s = selector(ping)
        let decision = await s.decision(for: .containerList)
        XCTAssertEqual(decision, .serviceStopped)
        var status = await s.status()
        XCTAssertEqual(status.service, .stopped)
        XCTAssertEqual(status.totalFallbacks, 0)
        XCTAssertEqual(status.summary, "The container services are not running")
        // A stopped daemon is checked again on every call, so a start is seen at once.
        ping.set(.success("1.6.1"))
        let after = await s.decision(for: .containerList)
        XCTAssertEqual(after, .direct)
        XCTAssertEqual(ping.calls, 2)
        status = await s.status()
        XCTAssertEqual(status.summary, "Talks to Apple's container service directly (container 1.6.1)")
    }

    func testSilentDaemonUsesCLI() async {
        let s = selector(FakePing(.failure(.timeout(route: "ping", seconds: 2))))
        let decision = await s.decision(for: .stats)
        XCTAssertEqual(decision, .cli)
        let status = await s.status()
        XCTAssertEqual(status.service, .notAnswering)
    }

    func testPingIsReusedWithinRecheckInterval() async {
        let ping = FakePing(.success("1.6.1"))
        let s = selector(ping)
        for _ in 0..<5 { _ = await s.decision(for: .containerList) }
        XCTAssertEqual(ping.calls, 1)
        await s.connectionChanged()
        _ = await s.decision(for: .containerList)
        XCTAssertEqual(ping.calls, 2)
    }

    func testTwoFailuresInARowMoveOneFamilyToCLI() async {
        let ping = FakePing(.success("1.6.1"))
        let s = selector(ping)
        _ = await s.decision(for: .stats)
        await s.recordFailure(.stats)
        var decision = await s.decision(for: .stats)
        XCTAssertEqual(decision, .direct, "One failure is not enough")
        await s.recordFailure(.stats)
        decision = await s.decision(for: .stats)
        XCTAssertEqual(decision, .cli)
        let other = await s.decision(for: .containerList)
        XCTAssertEqual(other, .direct, "Other families stay direct")
        let status = await s.status()
        XCTAssertEqual(status.cliFamilies, [.stats])
        XCTAssertEqual(status.fallbackCounts[.stats], 2)
        XCTAssertEqual(status.backend, .directAPI)
        XCTAssertEqual(status.summary, "Talks to Apple's container service directly (container 1.6.1). Uses the container command for stats. 2 calls used the container command")
    }

    func testSuccessResetsTheRun() async {
        let s = selector(FakePing(.success("1.6.1")))
        await s.recordFailure(.images)
        await s.recordSuccess(.images)
        await s.recordFailure(.images)
        let decision = await s.decision(for: .images)
        XCTAssertEqual(decision, .direct)
        let status = await s.status()
        XCTAssertEqual(status.fallbackCounts[.images], 2, "Counts keep the total")
    }

    func testFailuresWhileDaemonIsDownDoNotSwitch() async {
        let ping = FakePing(.success("1.6.1"))
        let s = selector(ping)
        _ = await s.decision(for: .volumes)
        ping.set(.failure(.serviceUnavailable(route: "ping")))
        await s.recordFailure(.volumes)
        await s.recordFailure(.volumes)
        ping.set(.success("1.6.1"))
        let decision = await s.decision(for: .volumes)
        XCTAssertEqual(decision, .direct)
    }

    func testNewDaemonVersionClearsSwitchedFamilies() async {
        let ping = FakePing(.success("1.6.0"))
        let s = selector(ping)
        _ = await s.decision(for: .logs)
        await s.recordFailure(.logs)
        await s.recordFailure(.logs)
        var decision = await s.decision(for: .logs)
        XCTAssertEqual(decision, .cli)
        ping.set(.success("1.6.1"))
        await s.connectionChanged()
        decision = await s.decision(for: .logs)
        XCTAssertEqual(decision, .direct)
        let status = await s.status()
        XCTAssertEqual(status.daemonVersion, "1.6.1")
        XCTAssertEqual(status.cliFamilies, [])
    }

    func testConfirmServiceStopped() async {
        let ping = FakePing(.success("1.6.1"))
        let s = selector(ping)
        var stopped = await s.confirmServiceStopped()
        XCTAssertFalse(stopped)
        ping.set(.failure(.serviceUnavailable(route: "ping")))
        stopped = await s.confirmServiceStopped()
        XCTAssertTrue(stopped)
    }
}

// MARK: - Router

/// Streams fixed lines per argument list and records calls.
final class RouterTestStreamer: CommandStreaming, @unchecked Sendable {
    private let lock = NSLock()
    var lines: [String: [String]] = [:]
    private var recorded: [[String]] = []
    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return recorded }

    func stream(_ executable: String, _ arguments: [String]) -> AsyncThrowingStream<String, Error> {
        lock.lock()
        recorded.append(arguments)
        let output = lines[arguments.joined(separator: " ")] ?? []
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for line in output { continuation.yield(line) }
            continuation.finish()
        }
    }
}

final class ContainerBackendRouterTests: XCTestCase {
    private let cliPath = "/usr/local/bin/container"

    private struct Setup {
        let router: ContainerBackendRouter
        let runner: MockRunner
        let streamer: RouterTestStreamer
        let daemon: RecordedDaemon
        let ping: FakePing
    }

    private func setup(version: Result<String, APIError> = .success("1.6.1"), force: Bool = false) throws -> Setup {
        let daemon = try RecordedDaemon()
        let runner = MockRunner()
        let streamer = RouterTestStreamer()
        let ping = FakePing(version)
        let selector = BackendSelector(ping: ping.closure, forceCLI: { force })
        let router = ContainerBackendRouter(cli: ContainerClient(cliPath: cliPath, runner: runner, streamer: streamer), api: daemon.client(), selector: selector)
        return Setup(router: router, runner: runner, streamer: streamer, daemon: daemon, ping: ping)
    }

    private func ok(_ text: String) -> CommandResult { CommandResult(exitCode: 0, stdout: text) }

    func testHealthyDaemonUsesDirectAPIOnly() async throws {
        let s = try setup()
        let list = try await s.router.listContainers(all: true)
        XCTAssertEqual(list.count, 4)
        _ = try await s.router.listVolumes()
        _ = try await s.router.listNetworks()
        _ = try await s.router.diskUsage()
        XCTAssertEqual(s.runner.calls, [], "No CLI calls")
        let status = await s.router.status()
        XCTAssertEqual(status.backend, .directAPI)
        XCTAssertEqual(status.totalFallbacks, 0)
    }

    func testForcedCLIUsesOnlyTheCLI() async throws {
        let s = try setup(force: true)
        s.runner.responses["list --all --format json"] = ok(RealCLIFixtures.containerList)
        let list = try await s.router.listContainers(all: true)
        XCTAssertEqual(list.map(\.id), ["deck-test-ctr-b", "deck-test-ctr-web", "deck-test-ctr-c"])
        XCTAssertEqual(s.daemon.api.requests.count, 0)
        XCTAssertEqual(s.ping.calls, 0)
    }

    func testTransportFailureOnReadFallsBackAndCounts() async throws {
        let s = try setup()
        s.daemon.api.setHandler { request in .failure(.interrupted(route: request.route)) }
        s.runner.responses["list --all --format json"] = ok(RealCLIFixtures.containerList)
        let list = try await s.router.listContainers(all: true)
        XCTAssertEqual(list.count, 3, "CLI answer")
        XCTAssertEqual(s.runner.calls.map { Array($0.dropFirst()) }, [["list", "--all", "--format", "json"]])
        var status = await s.router.status()
        XCTAssertEqual(status.fallbackCounts[.containerList], 1)
        XCTAssertEqual(status.cliFamilies, [])

        // The second failure in a row moves the family to the CLI (ping still answers).
        _ = try await s.router.listContainers(all: true)
        status = await s.router.status()
        XCTAssertEqual(status.cliFamilies, [.containerList])
        let before = s.daemon.api.requests.filter { $0.route == APIRoute.containerList }.count
        _ = try await s.router.listContainers(all: true)
        let after = s.daemon.api.requests.filter { $0.route == APIRoute.containerList }.count
        XCTAssertEqual(before, after, "No more direct tries this session")
    }

    func testDaemonErrorIsShownNotRetried() async throws {
        let s = try setup()
        s.daemon.api.setHandler { _ in .success(XPCReply([APIKey.error: .data(Data(APIFixtures.notFoundError.utf8))])) }
        do {
            try await s.router.deleteContainer("deck-test-api-missing", force: false)
            XCTFail("Expected an error")
        } catch let error as DeckError {
            XCTAssertEqual(error, .commandFailed("container with ID deck-test-api-missing not found"))
        }
        XCTAssertEqual(s.runner.calls, [])
        let status = await s.router.status()
        XCTAssertEqual(status.totalFallbacks, 0)
    }

    func testTimedOutChangeIsNotRetriedThroughCLI() async throws {
        let s = try setup()
        s.daemon.api.setHandler { request in
            request.route == APIRoute.containerStop ? .failure(.timeout(route: request.route, seconds: 35)) : .success(XPCReply())
        }
        do {
            try await s.router.stopContainer("web")
            XCTFail("Expected a timeout")
        } catch let error as APIError {
            guard case .timeout = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(s.runner.calls, [], "The stop may still be running, so the CLI is not asked to stop it again")
        let status = await s.router.status()
        XCTAssertEqual(status.fallbackCounts[.containerLifecycle], 1)
    }

    func testRejectedChangeIsRetriedThroughCLI() async throws {
        let s = try setup()
        s.daemon.api.setHandler { request in
            request.route == APIRoute.containerKill
                ? .success(XPCReply([APIKey.error: .data(Data(#"{"code":"invalidArgument","message":"missing signal in xpc message"}"#.utf8))]))
                : .success(XPCReply())
        }
        s.runner.responses["kill web"] = ok("web\n")
        try await s.router.killContainer("web")
        XCTAssertEqual(s.runner.calls.map { Array($0.dropFirst()) }, [["kill", "web"]])
    }

    func testStoppedServiceSaysSo() async throws {
        let s = try setup(version: .failure(.serviceUnavailable(route: "ping")))
        do {
            _ = try await s.router.listImages()
            XCTFail("Expected an error")
        } catch let error as APIError {
            XCTAssertEqual(error.localizedDescription, "The container services are not running.")
        }
        XCTAssertEqual(s.runner.calls, [], "No CLI call: it cannot reach a stopped daemon either")
    }

    func testServiceGoneMidCallIsStoppedNotFallback() async throws {
        let s = try setup()
        _ = try await s.router.listContainers(all: true)
        s.daemon.api.setHandler { request in .failure(.serviceUnavailable(route: request.route)) }
        s.ping.set(.failure(.serviceUnavailable(route: "ping")))
        do {
            _ = try await s.router.listVolumes()
            XCTFail("Expected an error")
        } catch let error as APIError {
            guard case .serviceUnavailable = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(s.runner.calls, [])
        let status = await s.router.status()
        XCTAssertEqual(status.totalFallbacks, 0)
    }

    func testNeedsCLIIsNotAFailure() async throws {
        let s = try setup()
        s.runner.responses["inspect nope"] = CommandResult(exitCode: 1, stdout: "", stderr: "Error: container not found: nope")
        do {
            _ = try await s.router.inspectContainer("nope")
            XCTFail("Expected the CLI error")
        } catch let error as DeckError {
            XCTAssertEqual(error, .commandFailed("Error: container not found: nope"))
        }
        let status = await s.router.status()
        XCTAssertEqual(status.totalFallbacks, 0)
    }

    func testUnsupportedVersionUsesCLI() async throws {
        let s = try setup(version: .success("1.7.0"))
        s.runner.responses["volume list --format json"] = ok(RealCLIVolumeNetworkFixtures.volumeList)
        let volumes = try await s.router.listVolumeSummaries()
        XCTAssertEqual(volumes.count, 3)
        XCTAssertFalse(s.daemon.api.routes.contains(APIRoute.volumeList))
    }

    func testRunAlwaysUsesCLI() async throws {
        let s = try setup()
        s.runner.responses["run --detach --name x alpine"] = ok("x\n")
        let id = try await s.router.runContainer(RunOptions(image: "alpine", name: "x"))
        XCTAssertEqual(id, "x")
        XCTAssertEqual(s.daemon.api.requests.count, 0)
    }

    func testLogsFallBackBeforeFirstLine() async throws {
        let s = try setup()
        // No log descriptors in the reply: unreadable, so the CLI stream takes over.
        s.streamer.lines["logs -n 5 web"] = ["a", "b"]
        var lines: [String] = []
        for try await line in s.router.logs("web", options: LogOptions(follow: false, tail: 5)) { lines.append(line) }
        XCTAssertEqual(lines, ["a", "b"])
        XCTAssertEqual(s.streamer.calls, [["logs", "-n", "5", "web"]])
        XCTAssertEqual(s.daemon.api.routes.last, APIRoute.containerLogs)
        let status = await s.router.status()
        XCTAssertEqual(status.fallbackCounts[.logs], 1)
    }

    func testRouterMatchesProtocol() {
        let cli: any ContainerOperations = ContainerClient(cliPath: cliPath, runner: MockRunner())
        XCTAssertNotNil(cli)
    }
}
