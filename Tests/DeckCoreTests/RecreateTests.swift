import XCTest
@testable import DeckCore

/// Edit and Recreate: capture from real 1.6.1 inspect output, round trip to
/// `container run` arguments, plan order, rollback and the manual command.
final class RecreateTests: XCTestCase {
    private let cliPath = "/usr/local/bin/container"
    private let defaults = RunDefaults(properties: (try? ContainerOutputParser.systemProperties(RecreateFixtures.systemProperties)) ?? [])

    private func client(_ runner: MockRunner = MockRunner()) -> ContainerClient {
        ContainerClient(cliPath: cliPath, runner: runner)
    }

    private func detail(_ json: String) throws -> ContainerDetail {
        try XCTUnwrap(ContainerOutputParser.containerDetails(json).first)
    }

    private func alpineConfig() throws -> ImageConfigInfo {
        try ContainerOutputParser.imageDetail(RecreateFixtures.alpineImage, preferredArchitecture: "arm64").config
    }

    private func capture(_ json: String) throws -> RunOptions {
        RunOptions(recreating: try detail(json), imageConfig: try alpineConfig(), defaults: defaults)
    }

    // MARK: Defaults

    func testDefaultsFromSystemProperties() {
        XCTAssertEqual(defaults, RunDefaults(cpus: 4, memoryBytes: 1 << 30))
        XCTAssertEqual(RunDefaults(properties: []), .builtIn)
    }

    func testParseMemory() {
        XCTAssertEqual(RunDefaults.parseMemory("1gb"), 1 << 30)
        XCTAssertEqual(RunDefaults.parseMemory("2048mb"), 2048 << 20)
        XCTAssertEqual(RunDefaults.parseMemory("512M"), 512 << 20)
        XCTAssertEqual(RunDefaults.parseMemory("1GiB"), 1 << 30)
        XCTAssertEqual(RunDefaults.parseMemory("4096"), 4096)
        XCTAssertNil(RunDefaults.parseMemory("lots"))
        XCTAssertEqual(RunDefaults.memoryText(1 << 30), "1G")
        XCTAssertEqual(RunDefaults.memoryText(512 << 20), "512M")
        XCTAssertEqual(RunDefaults.memoryText(134_217_728), "128M")
    }

    // MARK: Round trip

    func testRoundTripFull() throws {
        let options = try capture(RecreateFixtures.full)
        XCTAssertEqual(options.image, "docker.io/library/alpine:latest")
        XCTAssertEqual(options.name, "deck-test-rec-full")
        XCTAssertEqual(options.user, "1000:1000")
        XCTAssertTrue(options.readOnlyRootfs)
        // Image has no entrypoint, so the whole process is the command.
        XCTAssertNil(options.entrypoint)
        XCTAssertEqual(options.command, ["sleep", "3600"])
        // Image env (PATH) is left out.
        XCTAssertEqual(Set(options.env), [EnvVar(key: "FOO", value: "bar"), EnvVar(key: "GREETING", value: "hello world")])
        XCTAssertEqual(options.ports, [
            PortMapping(hostAddress: "127.0.0.1", hostPort: 18081, containerPort: 80, proto: "tcp"),
            PortMapping(hostPort: 18082, containerPort: 81, proto: "udp")
        ])
        XCTAssertEqual(options.mounts.map(\.kind), [.bind, .volume])
        XCTAssertEqual(options.mounts.map(\.source), ["/tmp/deck-rec-src", "deck-test-recvol"])
        XCTAssertEqual(options.mounts.map(\.readOnly), [true, false])
        XCTAssertEqual(options.tmpfs, ["/scratch"])
        XCTAssertEqual(options.workingDir, "/tmp")
        XCTAssertEqual(options.labels, ["app": "rec", "tier": "test"])
        XCTAssertEqual(options.capAdd, ["CAP_NET_RAW"])
        XCTAssertEqual(options.dnsServers, ["1.1.1.1"])
        XCTAssertTrue(options.useInit)
        XCTAssertEqual(options.shmSize, "128M")
        XCTAssertNil(options.network, "default network stays implicit")
        XCTAssertNil(options.cpus, "4 CPUs is the default, so no --cpus")
        XCTAssertNil(options.memory, "1G is the default, so no --memory")
        XCTAssertFalse(options.rosetta)
        XCTAssertFalse(options.noDNS)
        XCTAssertNil(options.maskedPaths)

        let args = client().runArguments(options)
        XCTAssertEqual(args, [
            "run", "--detach", "--name", "deck-test-rec-full",
            "--env", "GREETING=hello world", "--env", "FOO=bar",
            "--publish", "127.0.0.1:18081:80/tcp", "--publish", "18082:81/udp",
            "--volume", "/tmp/deck-rec-src:/src:ro", "--volume", "deck-test-recvol:/data",
            "--workdir", "/tmp",
            "--label", "app=rec", "--label", "tier=test",
            "--user", "1000:1000", "--read-only", "--tmpfs", "/scratch", "--cap-add", "CAP_NET_RAW",
            "--dns", "1.1.1.1", "--init", "--shm-size", "128M",
            "docker.io/library/alpine:latest", "sleep", "3600"
        ])
        XCTAssertFalse(args.contains("--cpus"))
        XCTAssertFalse(args.contains("--memory"))
    }

    func testRoundTripLimitsDNSAndMAC() throws {
        let options = try capture(RecreateFixtures.more)
        XCTAssertEqual(options.user, "1001:1002", "--uid and --gid come back as one --user")
        XCTAssertEqual(options.ulimits, ["nofile=1024:2048"])
        XCTAssertEqual(options.dnsSearch, ["example.com"])
        XCTAssertEqual(options.dnsOptions, ["ndots:2"])
        XCTAssertEqual(options.dnsDomain, "corp.local")
        XCTAssertEqual(options.capDrop, ["CAP_CHOWN"])
        XCTAssertEqual(options.macAddress, "02:42:ac:11:00:09")
        XCTAssertFalse(options.readOnlyRootfs)

        let args = client().runArguments(options)
        XCTAssertTrue(args.containsSequence(["--network", "default,mac=02:42:ac:11:00:09"]))
        XCTAssertTrue(args.containsSequence(["--user", "1001:1002"]))
        XCTAssertTrue(args.containsSequence(["--ulimit", "nofile=1024:2048"]))
        XCTAssertTrue(args.containsSequence(["--dns-domain", "corp.local", "--dns-search", "example.com", "--dns-option", "ndots:2"]))
        XCTAssertTrue(args.containsSequence(["--cap-drop", "CAP_CHOWN"]))
        XCTAssertFalse(args.contains("--read-only"))
        XCTAssertFalse(args.contains("--dns"))
    }

    func testRoundTripPathsSocketsAndResources() throws {
        let options = try capture(RecreateFixtures.misc)
        XCTAssertTrue(options.noDNS)
        XCTAssertTrue(options.rosetta)
        XCTAssertTrue(options.ssh)
        XCTAssertEqual(options.publishSockets, ["/tmp/deck-rec-src/s.sock:/run/s.sock"])
        XCTAssertEqual(options.network, "deck-demo-net")
        XCTAssertEqual(options.cpus, 2)
        XCTAssertEqual(options.memory, "512M")
        XCTAssertEqual(options.maskedPaths?.contains("/proc/kcore"), true)
        XCTAssertEqual(options.readOnlyPaths?.last, "/etc")
        XCTAssertNil(options.user, "root is the default")

        let args = client().runArguments(options)
        XCTAssertTrue(args.containsSequence(["--cpus", "2"]))
        XCTAssertTrue(args.containsSequence(["--memory", "512M"]))
        XCTAssertTrue(args.containsSequence(["--network", "deck-demo-net"]))
        XCTAssertTrue(args.contains("--no-dns"))
        XCTAssertTrue(args.contains("--rosetta"))
        XCTAssertTrue(args.contains("--ssh"))
        XCTAssertTrue(args.containsSequence(["--publish-socket", "/tmp/deck-rec-src/s.sock:/run/s.sock"]))
        // The full list replaces the defaults, so it starts with NONE.
        XCTAssertTrue(args.containsSequence(["--masked-path", "NONE", "--masked-path", "/proc/asound"]))
        XCTAssertTrue(args.containsSequence(["--read-only-path", "NONE", "--read-only-path", "/proc/bus"]))
        XCTAssertFalse(args.contains("--user"))
    }

    func testDefaultsAreNotMadeExplicit() throws {
        // A plain container: nothing beyond the name should be written.
        let options = try capture(RealCLIFixtures.containerList.replacingOccurrences(of: "nginx:alpine", with: "alpine:latest"))
        let base = RunOptions(recreating: try detail(RecreateFixtures.misc), imageConfig: try alpineConfig(), defaults: RunDefaults(cpus: 2, memoryBytes: 512 << 20))
        XCTAssertNil(base.cpus, "Matches the defaults given, so left out")
        XCTAssertNil(base.memory)
        XCTAssertNil(options.user)
        XCTAssertNil(options.workingDir)
        XCTAssertNil(options.dnsDomain)
        XCTAssertNil(options.runtime, "container-runtime-linux is the default handler")
        XCTAssertNil(options.shmSize)
        XCTAssertFalse(options.useInit)
        XCTAssertFalse(options.noDNS)
        XCTAssertFalse(options.tty)
        XCTAssertNil(options.maskedPaths)
        XCTAssertFalse(options.env.contains { $0.key == "PATH" })
    }

    func testOldFixtureKeepsEntrypointOverNginxImage() throws {
        // nginx has an entrypoint, so a different program is written as --entrypoint.
        let sleeper = try XCTUnwrap(ContainerOutputParser.containerDetails(RealCLIFixtures.containerList).first { $0.summary.id == "deck-test-ctr-b" })
        let nginx = ImageConfigInfo(entrypoint: ["/docker-entrypoint.sh"], cmd: ["nginx", "-g", "daemon off;"])
        let options = RunOptions(recreating: sleeper, imageConfig: nginx, defaults: .builtIn)
        XCTAssertEqual(options.entrypoint, "sleep")
        XCTAssertEqual(options.command, ["3600"])

        let web = try XCTUnwrap(ContainerOutputParser.containerDetails(RealCLIFixtures.containerList).first { $0.summary.id == "deck-test-ctr-web" })
        let webOptions = RunOptions(recreating: web, imageConfig: nginx, defaults: .builtIn)
        XCTAssertNil(webOptions.entrypoint)
        XCTAssertEqual(webOptions.command, [], "Image default process is not repeated")
        XCTAssertEqual(webOptions.cpus, 2)
        XCTAssertEqual(webOptions.memory, "512M")
    }

    func testNewFieldsDefaultToNothing() {
        let args = client().runArguments(RunOptions(image: "alpine"))
        XCTAssertEqual(args, ["run", "--detach", "alpine"])
        XCTAssertEqual(ContainerClient.extraRunArguments(RunOptions(image: "alpine")), [])
    }

    func testCreateArguments() throws {
        let options = try capture(RecreateFixtures.full)
        let args = client().createArguments(options)
        XCTAssertEqual(args.first, "create")
        XCTAssertFalse(args.contains("--detach"))
        XCTAssertEqual(Array(args.dropFirst()), Array(client().runArguments(options).dropFirst(2)))
    }

    // MARK: Checks

    func testChecksFindConflicts() throws {
        let others = try ContainerOutputParser.containerDetails(RealCLIFixtures.containerList)
        var new = RunOptions(image: "alpine", name: "deck-test-ctr-c")
        new.ports = [PortMapping(hostPort: 18080, containerPort: 80)]
        new.mounts = [MountSpec(kind: .volume, source: "deck-test-ctr-vol", destination: "/v")]
        new.tty = true
        let issues = RecreateCheck.issues(new: new, replacing: "deck-test-ctr-b", others: others)
        XCTAssertEqual(Set(issues.map(\.kind)), [.name, .port, .volume, .terminal])

        // The container being replaced does not clash with itself.
        var same = RunOptions(image: "alpine", name: "deck-test-ctr-web")
        same.ports = [PortMapping(hostPort: 18080, containerPort: 80)]
        same.mounts = [MountSpec(kind: .volume, source: "deck-test-ctr-vol", destination: "/data")]
        XCTAssertEqual(RecreateCheck.issues(new: same, replacing: "deck-test-ctr-web", others: others), [])

        // Stopped containers do not hold ports. 18081 is on stopped deck-test-ctr-c.
        var stoppedPort = RunOptions(image: "alpine")
        stoppedPort.ports = [PortMapping(hostAddress: "127.0.0.1", hostPort: 18081, containerPort: 80)]
        XCTAssertEqual(RecreateCheck.issues(new: stoppedPort, replacing: "x", others: others), [])

        XCTAssertEqual(RecreateCheck.issues(new: RunOptions(image: "a", name: "bad name"), replacing: "x", others: []).map(\.kind), [.name])
    }

    func testPortOverlap() {
        let all = PortMapping(hostPort: 80, containerPort: 80)
        let local = PortMapping(hostAddress: "127.0.0.1", hostPort: 80, containerPort: 8080)
        let other = PortMapping(hostAddress: "127.0.0.2", hostPort: 80, containerPort: 80)
        XCTAssertTrue(RecreateCheck.overlaps(all, local))
        XCTAssertFalse(RecreateCheck.overlaps(local, other))
        XCTAssertFalse(RecreateCheck.overlaps(all, PortMapping(hostPort: 80, containerPort: 80, proto: "udp")))
    }

    func testImageIsLocal() throws {
        let images = try ContainerOutputParser.images(ContainerCLIFixtures.imageList)
        let first = try XCTUnwrap(images.first)
        XCTAssertTrue(RecreateCheck.imageIsLocal(first.reference, images: images))
        XCTAssertTrue(RecreateCheck.imageIsLocal("\(first.shortName):\(first.tag)", images: images))
        XCTAssertFalse(RecreateCheck.imageIsLocal("deck-no-such-image:latest", images: images))
    }

    // MARK: Plan

    private func plan(running: Bool = true, newImage: String = "nginx:alpine") throws -> RecreatePlan {
        let old = try capture(RecreateFixtures.full)
        var new = old
        new.image = newImage
        return RecreatePlan(old: RecreateCapture(id: "deck-test-rec-full", options: old, wasRunning: running), new: new)
    }

    func testPlanOrder() throws {
        let running = try plan()
        XCTAssertEqual(running.steps.count, 3)
        guard case .stop("deck-test-rec-full") = running.steps[0],
              case .delete("deck-test-rec-full") = running.steps[1],
              case .run(let options) = running.steps[2] else {
            return XCTFail("Expected stop, delete, run. Got \(running.steps)")
        }
        XCTAssertEqual(options.image, "nginx:alpine")
        guard case .run(let restore) = try XCTUnwrap(running.restoreSteps.first) else { return XCTFail("Restore runs a running container") }
        XCTAssertEqual(restore.image, "docker.io/library/alpine:latest")

        let stopped = try plan(running: false)
        XCTAssertEqual(stopped.steps.count, 2, "A stopped container is not stopped again")
        guard case .create = try XCTUnwrap(stopped.restoreSteps.first) else { return XCTFail("Restore only creates a stopped container") }
        XCTAssertTrue(stopped.restoreCommand(client: client()).hasPrefix("container create --name deck-test-rec-full"))
    }

    func testRecreateSucceeds() async throws {
        let plan = try plan()
        let runner = MockRunner()
        let c = client(runner)
        runner.responses["stop deck-test-rec-full"] = CommandResult(exitCode: 0, stdout: "deck-test-rec-full\n")
        runner.responses["delete --force deck-test-rec-full"] = CommandResult(exitCode: 0, stdout: "deck-test-rec-full\n")
        runner.responses["list --all --format json"] = CommandResult(exitCode: 0, stdout: "[]")
        runner.responses[c.runArguments(plan.new).joined(separator: " ")] = CommandResult(exitCode: 0, stdout: "deck-test-rec-full\n")

        let outcome = try await c.performRecreate(plan)
        XCTAssertEqual(outcome, .recreated(id: "deck-test-rec-full"))
        XCTAssertEqual(runner.calls.map { Array($0.dropFirst()) }, [
            ["stop", "deck-test-rec-full"],
            ["delete", "--force", "deck-test-rec-full"],
            ["list", "--all", "--format", "json"],
            c.runArguments(plan.new)
        ])
    }

    func testRunFailureRestoresOldAndStartsIt() async throws {
        let plan = try plan(newImage: "deck-no-such-image:latest")
        let runner = MockRunner()
        let c = client(runner)
        runner.responses["stop deck-test-rec-full"] = CommandResult(exitCode: 0, stdout: "")
        runner.responses["delete --force deck-test-rec-full"] = CommandResult(exitCode: 0, stdout: "")
        runner.responses["list --all --format json"] = CommandResult(exitCode: 0, stdout: "[]")
        runner.responses[c.runArguments(plan.new).joined(separator: " ")] = CommandResult(exitCode: 1, stdout: "", stderr: RecreateFixtures.runMissingImage)
        let restoreArgs = c.runArguments(plan.old.options)
        runner.responses[restoreArgs.joined(separator: " ")] = CommandResult(exitCode: 0, stdout: "deck-test-rec-full\n")

        let outcome = try await c.performRecreate(plan)
        guard case .restored(let failure, let running) = outcome else { return XCTFail("Got \(outcome)") }
        XCTAssertTrue(running)
        XCTAssertTrue(failure.contains("401 Unauthorized"), failure)
        let calls = runner.calls.map { Array($0.dropFirst()) }
        XCTAssertEqual(calls.last, restoreArgs, "Old container is run again (started) last")
        XCTAssertTrue(restoreArgs.contains("--detach"))
        XCTAssertTrue(restoreArgs.containsSequence(["--name", "deck-test-rec-full"]))
        XCTAssertTrue(restoreArgs.containsSequence(["--user", "1000:1000"]))
        XCTAssertTrue(restoreArgs.contains("--read-only"))
        XCTAssertTrue(restoreArgs.contains("docker.io/library/alpine:latest"))
        // Any half made container with the same name is removed before restoring.
        XCTAssertEqual(calls.filter { $0 == ["delete", "--force", "deck-test-rec-full"] }.count, 2)
    }

    func testRestoreFailureGivesManualCommand() async throws {
        let plan = try plan(newImage: "deck-no-such-image:latest")
        let runner = MockRunner()
        let c = client(runner)
        runner.responses["stop deck-test-rec-full"] = CommandResult(exitCode: 0, stdout: "")
        runner.responses["delete --force deck-test-rec-full"] = CommandResult(exitCode: 0, stdout: "")
        runner.responses["list --all --format json"] = CommandResult(exitCode: 0, stdout: "[]")
        runner.responses[c.runArguments(plan.new).joined(separator: " ")] = CommandResult(exitCode: 1, stdout: "", stderr: RecreateFixtures.runMissingImage)
        // Restore is not mocked, so it fails.

        let outcome = try await c.performRecreate(plan)
        guard case .notRestored(_, let restoreFailure, let command) = outcome else { return XCTFail("Got \(outcome)") }
        XCTAssertFalse(restoreFailure.isEmpty)
        XCTAssertEqual(command, plan.restoreCommand(client: c))
        XCTAssertTrue(command.hasPrefix("container run --detach --name deck-test-rec-full "), command)
        XCTAssertTrue(command.contains("--env 'GREETING=hello world'"), "Quoted for the shell: \(command)")
        XCTAssertTrue(command.contains("--user 1000:1000 --read-only"))
        XCTAssertTrue(command.hasSuffix("docker.io/library/alpine:latest sleep 3600"))
    }

    func testFailureTextDropsProgressLines() {
        let raw = "[0/6] [0s]\n[3/6] Fetching kernel [0s]\nError: failed to bootstrap container (bind: Address already in use)\n"
        XCTAssertEqual(RecreatePlan.cleanFailure(raw), "Error: failed to bootstrap container (bind: Address already in use)")
        XCTAssertEqual(RecreatePlan.cleanFailure("[1/6] x"), "[1/6] x", "Keeps something to show")
    }

    func testDeleteFailureChangesNothing() async throws {
        let plan = try plan()
        let runner = MockRunner()
        runner.responses["stop deck-test-rec-full"] = CommandResult(exitCode: 0, stdout: "")
        runner.responses["start deck-test-rec-full"] = CommandResult(exitCode: 0, stdout: "")
        do {
            _ = try await client(runner).performRecreate(plan)
            XCTFail("Expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("nothing was changed"))
        }
        XCTAssertEqual(runner.calls.last.map { Array($0.dropFirst()) }, ["start", "deck-test-rec-full"], "Old one is started again")
        XCTAssertFalse(runner.calls.contains { $0.count > 1 && $0[1] == "run" })
    }
}

/// Runs against the real CLI only when DECK_REAL_CLI=1. Uses its own
/// deck-test-recreate container and removes it at the end.
final class RealCLIRecreateTests: XCTestCase {
    private let cliPath = "/usr/local/bin/container"
    private let containerName = "deck-test-recreate"

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DECK_REAL_CLI"] == "1", "Set DECK_REAL_CLI=1 to run against the real CLI")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: cliPath), "container CLI not installed")
    }

    func testFailedRecreateRestoresOldContainer() async throws {
        let client = ContainerClient(cliPath: cliPath)
        try? await client.deleteContainer(containerName, force: true)
        defer {
            let cleanup = Process()
            cleanup.executableURL = URL(fileURLWithPath: cliPath)
            cleanup.arguments = ["delete", "--force", containerName]
            try? cleanup.run()
            cleanup.waitUntilExit()
        }

        let original = RunOptions(
            image: "alpine:latest", name: containerName, command: ["sleep", "3600"],
            env: [EnvVar(key: "FOO", value: "bar baz")],
            ports: [PortMapping(hostAddress: "127.0.0.1", hostPort: 18391, containerPort: 80)],
            workingDir: "/tmp", labels: ["deck.test": "1"],
            user: "1000:1000", readOnlyRootfs: true, tmpfs: ["/scratch"], useInit: true
        )
        try await client.runContainer(original)

        let before = try await client.captureForRecreate(containerName)
        XCTAssertTrue(before.wasRunning)
        XCTAssertEqual(before.options.user, "1000:1000")
        XCTAssertTrue(before.options.readOnlyRootfs)

        var broken = before.options
        broken.image = "deck-no-such-image:latest"
        let plan = RecreatePlan(old: before, new: broken)
        let issues = await client.checkRecreate(plan)
        XCTAssertTrue(issues.contains { $0.kind == .image }, "The check catches the bad image before anything changes")

        // Skip the check on purpose to force a failed run.
        let outcome = try await client.performRecreate(plan)
        guard case .restored(_, let running) = outcome else { return XCTFail("Got \(outcome)") }
        XCTAssertTrue(running)

        let after = try await client.captureForRecreate(containerName)
        XCTAssertTrue(after.wasRunning, "The old container is back and running")
        XCTAssertEqual(after.options, before.options, "Every setting came back")
        XCTAssertEqual(client.runArguments(after.options), client.runArguments(before.options))
    }
}

extension RealCLIRecreateTests {
    /// A successful recreate with the same settings gives back the same settings.
    func testRecreateKeepsEverySetting() async throws {
        let client = ContainerClient(cliPath: cliPath)
        let name = "deck-test-recreate-keep"
        try? await client.deleteContainer(name, force: true)
        defer {
            let cleanup = Process()
            cleanup.executableURL = URL(fileURLWithPath: cliPath)
            cleanup.arguments = ["delete", "--force", name]
            try? cleanup.run()
            cleanup.waitUntilExit()
        }
        try await client.run([
            "run", "--detach", "--name", name, "--ulimit", "nofile=1024:2048", "--dns-search", "example.com",
            "--dns-option", "ndots:2", "--dns-domain", "corp.local", "--cap-drop", "CAP_CHOWN", "--cap-add", "CAP_NET_RAW",
            "--network", "default,mac=02:42:ac:11:00:19", "--uid", "1001", "--gid", "1002", "--read-only-path", "/etc",
            "--masked-path", "/proc/kcore", "--ssh", "--cpus", "2", "--memory", "512M", "--shm-size", "64M",
            "--read-only", "--init", "--tmpfs", "/scratch", "--label", "deck.test=1",
            "alpine:latest", "sleep", "3600"
        ])
        let before = try await client.captureForRecreate(name)
        let outcome = try await client.performRecreate(RecreatePlan(old: before, new: before.options))
        XCTAssertEqual(outcome, .recreated(id: name))
        let after = try await client.captureForRecreate(name)
        XCTAssertEqual(after.options, before.options)
        XCTAssertEqual(after.options.user, "1001:1002")
        XCTAssertEqual(after.options.macAddress, "02:42:ac:11:00:19")
        XCTAssertEqual(after.options.ulimits, ["nofile=1024:2048"])
        XCTAssertEqual(after.options.cpus, 2)
        XCTAssertEqual(after.options.shmSize, "64M")
        XCTAssertTrue(after.options.readOnlyRootfs)
    }
}

private extension Array where Element: Equatable {
    func containsSequence(_ part: [Element]) -> Bool {
        guard !part.isEmpty, part.count <= count else { return part.isEmpty }
        for start in 0...(count - part.count) where Array(self[start..<(start + part.count)]) == part {
            return true
        }
        return false
    }
}
