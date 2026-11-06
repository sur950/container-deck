import XCTest
@testable import DeckCore

/// Parsers and arguments checked against output recorded from the real
/// `container` 1.6.1 CLI (see Fixtures/RealCLIContainerFixtures.swift).
final class RealCLIContainerTests: XCTestCase {
    private let cliPath = "/usr/local/bin/container"

    private func client(_ runner: MockRunner) -> ContainerClient {
        ContainerClient(cliPath: cliPath, runner: runner)
    }

    // MARK: list

    func testListRunningContainer() throws {
        let list = try ContainerOutputParser.containers(RealCLIFixtures.containerList)
        XCTAssertEqual(list.map(\.id), ["deck-test-ctr-b", "deck-test-ctr-web", "deck-test-ctr-c"])

        let web = try XCTUnwrap(list.first { $0.id == "deck-test-ctr-web" })
        XCTAssertEqual(web.name, "deck-test-ctr-web")
        XCTAssertEqual(web.image, "docker.io/library/nginx:alpine")
        XCTAssertEqual(web.state, .running)
        XCTAssertEqual(web.ipAddress, "192.168.64.2")
        XCTAssertEqual(web.hostname, "deck-test-ctr-web")
        XCTAssertEqual(web.platform, "linux/arm64/v8")
        XCTAssertEqual(web.cpus, 2)
        XCTAssertEqual(web.memoryBytes, 536_870_912)
        XCTAssertEqual(web.labels, ["app": "web", "deck.test": "1"])
        XCTAssertEqual(web.command, ["/docker-entrypoint.sh", "nginx", "-g", "daemon off;"])
        XCTAssertEqual(web.createdAt, Date(timeIntervalSince1970: 1_793_881_493))
        XCTAssertEqual(web.startedAt, Date(timeIntervalSince1970: 1_793_881_494))
        // 0.0.0.0 is shown as "all addresses" (nil).
        XCTAssertEqual(web.ports, [PortMapping(hostPort: 18080, containerPort: 80, proto: "tcp")])
    }

    func testListStoppedContainer() throws {
        let list = try ContainerOutputParser.containers(RealCLIFixtures.containerList)
        let stopped = try XCTUnwrap(list.first { $0.id == "deck-test-ctr-c" })
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertFalse(stopped.isRunning)
        XCTAssertNil(stopped.ipAddress, "Stopped containers have no live network")
        XCTAssertEqual(stopped.hostname, "deck-test-ctr-c", "Hostname falls back to the configured one")
        XCTAssertEqual(stopped.cpus, 4)
        XCTAssertEqual(stopped.memoryBytes, 1_073_741_824)
        XCTAssertEqual(stopped.ports, [
            PortMapping(hostAddress: "127.0.0.1", hostPort: 18081, containerPort: 80, proto: "tcp"),
            PortMapping(hostPort: 18082, containerPort: 53, proto: "udp")
        ])
    }

    func testListEntrypointOverride() throws {
        let list = try ContainerOutputParser.containers(RealCLIFixtures.containerList)
        let sleeper = try XCTUnwrap(list.first { $0.id == "deck-test-ctr-b" })
        XCTAssertEqual(sleeper.command, ["sleep", "3600"])
        XCTAssertEqual(sleeper.state, .running)
    }

    func testListContainersCallsCLI() async throws {
        let runner = MockRunner()
        runner.responses["list --all --format json"] = CommandResult(exitCode: 0, stdout: RealCLIFixtures.containerList)
        let list = try await client(runner).listContainers()
        XCTAssertEqual(runner.calls, [[cliPath, "list", "--all", "--format", "json"]])
        XCTAssertEqual(list.count, 3)
    }

    func testEmptyListIsEmpty() throws {
        XCTAssertEqual(try ContainerOutputParser.containers("[]\n"), [])
    }

    // MARK: inspect

    func testInspectRunningDetail() throws {
        // `container inspect` prints the same objects as `list` (pretty printed).
        let details = try ContainerOutputParser.containerDetails(RealCLIFixtures.containerList)
        let web = try XCTUnwrap(details.first { $0.summary.id == "deck-test-ctr-web" })
        XCTAssertEqual(web.entrypoint, ["/docker-entrypoint.sh"])
        XCTAssertEqual(web.arguments, ["nginx", "-g", "daemon off;"])
        XCTAssertEqual(web.workingDir, "/usr/share/nginx")
        XCTAssertEqual(web.user, "0:0")
        XCTAssertFalse(web.readOnlyRootfs)
        XCTAssertFalse(web.rosetta)
        XCTAssertTrue(web.env.contains(EnvVar(key: "FOO", value: "bar")))
        XCTAssertTrue(web.env.contains(EnvVar(key: "SPACED", value: "a b")))
        XCTAssertEqual(web.mounts, [
            MountInfo(type: "bind", source: "/tmp/deck-ctr-share", destination: "/share", readOnly: true),
            MountInfo(type: "volume", source: "deck-test-ctr-vol", destination: "/data", readOnly: false)
        ])
        XCTAssertEqual(web.networks.count, 1)
        let net = try XCTUnwrap(web.networks.first)
        XCTAssertEqual(net.network, "default")
        XCTAssertEqual(net.ipAddress, "192.168.64.2")
        XCTAssertEqual(net.gateway, "192.168.64.1")
        XCTAssertEqual(net.macAddress, "fa:94:9a:86:7d:bb")
        XCTAssertFalse(web.rawJSON.isEmpty)
    }

    func testInspectStoppedDetail() async throws {
        let runner = MockRunner()
        runner.responses["inspect deck-test-ctr-c"] = CommandResult(exitCode: 0, stdout: RealCLIFixtures.stoppedInspect)
        let detail = try await client(runner).inspectContainer("deck-test-ctr-c")
        XCTAssertEqual(detail.summary.state, .stopped)
        XCTAssertEqual(detail.summary.createdAt, Date(timeIntervalSince1970: 1_793_881_548))
        XCTAssertEqual(detail.mounts, [
            MountInfo(type: "bind", source: "/tmp/deck-ctr-share/with space", destination: "/sp", readOnly: true)
        ])
        // No live attachment, so the requested network is shown.
        XCTAssertEqual(detail.networks.map(\.network), ["default"])
        XCTAssertEqual(detail.networks.first?.hostname, "deck-test-ctr-c")
        XCTAssertNil(detail.networks.first?.ipAddress)
        XCTAssertTrue(detail.rawJSON.contains("\"deck-test-ctr-c\""))
    }

    func testInspectMissingContainerThrowsCLIMessage() async {
        let runner = MockRunner()
        runner.responses["inspect nonexist"] = CommandResult(exitCode: 1, stdout: "", stderr: RealCLIFixtures.inspectMissing)
        do {
            _ = try await client(runner).inspectContainer("nonexist")
            XCTFail("Expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.lowercased().contains("not found"), error.localizedDescription)
        }
    }

    // MARK: stats

    func testStatsCumulativeOnly() throws {
        let cache = CPUSampleCache()
        let start = Date(timeIntervalSince1970: 1000)
        let first = try ContainerOutputParser.stats(RealCLIFixtures.stats, cache: cache, now: start)
        XCTAssertEqual(first.map(\.id), ["deck-test-m-5fe835", "deck-test-ctr-web"])
        let web = try XCTUnwrap(first.first { $0.id == "deck-test-ctr-web" })
        XCTAssertEqual(web.cpuPercent, 0, "First sample has nothing to compare with")
        XCTAssertEqual(web.memoryUsageBytes, 15_032_320)
        XCTAssertEqual(web.memoryLimitBytes, 536_870_912)
        XCTAssertEqual(web.netRxBytes, 22_099)
        XCTAssertEqual(web.netTxBytes, 602)
        XCTAssertEqual(web.blockReadBytes, 10_609_664)
        XCTAssertEqual(web.blockWriteBytes, 12_288)
        XCTAssertEqual(web.pids, 4)

        // 0.5 s of CPU over 2 s is 25 percent of one core.
        let later = RealCLIFixtures.stats.replacingOccurrences(of: "\"cpuUsageUsec\":13587", with: "\"cpuUsageUsec\":513587")
        let second = try ContainerOutputParser.stats(later, cache: cache, now: start.addingTimeInterval(2))
        XCTAssertEqual(second.first { $0.id == "deck-test-ctr-web" }?.cpuPercent ?? -1, 25, accuracy: 0.001)
    }

    func testStatsCallsCLI() async throws {
        let runner = MockRunner()
        runner.responses["stats --no-stream --format json deck-test-ctr-web"] = CommandResult(exitCode: 0, stdout: RealCLIFixtures.stats)
        let list = try await client(runner).stats(["deck-test-ctr-web"])
        XCTAssertEqual(runner.calls.first, [cliPath, "stats", "--no-stream", "--format", "json", "deck-test-ctr-web"])
        XCTAssertEqual(list.count, 2)
    }

    func testCPUCacheRepeatsPercentForBackToBackPolls() {
        let cache = CPUSampleCache()
        let start = Date(timeIntervalSince1970: 0)
        XCTAssertNil(cache.percent(id: "a", usageUsec: 0, at: start))
        XCTAssertEqual(cache.percent(id: "a", usageUsec: 1_000_000, at: start.addingTimeInterval(2)) ?? -1, 50, accuracy: 0.001)
        // Another screen polls 10 ms later. It sees the same reading, not 0.
        XCTAssertEqual(cache.percent(id: "a", usageUsec: 1_000_100, at: start.addingTimeInterval(2.01)) ?? -1, 50, accuracy: 0.001)
        // The next real interval is measured from the last full sample.
        XCTAssertEqual(cache.percent(id: "a", usageUsec: 2_000_000, at: start.addingTimeInterval(4)) ?? -1, 50, accuracy: 0.001)
    }

    // MARK: logs and run

    func testLogArgumentsMatchHelp() {
        let c = client(MockRunner())
        XCTAssertEqual(c.logArguments("web"), ["logs", "--follow", "-n", "500", "web"])
        XCTAssertEqual(c.logArguments("web", options: LogOptions(follow: false, tail: nil, boot: true)), ["logs", "--boot", "web"])
    }

    func testRunArgumentsMatchVerifiedCommand() {
        let options = RunOptions(
            image: "nginx:alpine",
            name: "deck-test-ctr-web",
            env: [EnvVar(key: "FOO", value: "bar"), EnvVar(key: "SPACED", value: "a b")],
            ports: [PortMapping(hostPort: 18080, containerPort: 80)],
            mounts: [
                MountSpec(kind: .bind, source: "/tmp/deck-ctr-share", destination: "/share", readOnly: true),
                MountSpec(kind: .volume, source: "deck-test-ctr-vol", destination: "/data")
            ],
            cpus: 2,
            memory: "512M",
            workingDir: "/usr/share/nginx",
            labels: ["deck.test": "1", "app": "web"]
        )
        XCTAssertEqual(client(MockRunner()).runArguments(options), [
            "run", "--detach", "--name", "deck-test-ctr-web",
            "--env", "FOO=bar", "--env", "SPACED=a b",
            "--publish", "18080:80/tcp",
            "--volume", "/tmp/deck-ctr-share:/share:ro", "--volume", "deck-test-ctr-vol:/data",
            "--cpus", "2", "--memory", "512M", "--workdir", "/usr/share/nginx",
            "--label", "app=web", "--label", "deck.test=1",
            "nginx:alpine"
        ])
    }

    func testRunReturnsIDFromStdout() async throws {
        let runner = MockRunner()
        let options = RunOptions(image: "nginx:alpine", name: "deck-test-ctr-b", entrypoint: "sleep", autoRemove: true)
        let c = client(runner)
        runner.responses[c.runArguments(options).joined(separator: " ")] = CommandResult(exitCode: 0, stdout: RealCLIFixtures.runStdout)
        let id = try await c.runContainer(options)
        XCTAssertEqual(id, "deck-test-ctr-b")
        XCTAssertEqual(runner.calls.first, [cliPath, "run", "--detach", "--rm", "--name", "deck-test-ctr-b", "--entrypoint", "sleep", "nginx:alpine"])
    }

    func testRunFailureCarriesCLIMessage() async {
        let runner = MockRunner()
        let options = RunOptions(image: "nginx:alpine", name: "x")
        let c = client(runner)
        runner.responses[c.runArguments(options).joined(separator: " ")] = CommandResult(exitCode: 1, stdout: "", stderr: RealCLIFixtures.volumeInUse)
        do {
            try await c.runContainer(options)
            XCTFail("Expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("storage device attachment is invalid"), error.localizedDescription)
        }
    }

    // MARK: lifecycle arguments

    func testLifecycleArguments() async throws {
        let runner = MockRunner()
        for key in ["start w", "stop w", "kill w", "delete w", "delete --force w", "prune"] {
            runner.responses[key] = CommandResult(exitCode: 0, stdout: "w\n")
        }
        let c = client(runner)
        try await c.startContainer("w")
        try await c.stopContainer("w")
        try await c.killContainer("w")
        try await c.deleteContainer("w")
        try await c.deleteContainer("w", force: true)
        try await c.pruneContainers()
        XCTAssertEqual(runner.calls.map { Array($0.dropFirst()) }, [
            ["start", "w"], ["stop", "w"], ["kill", "w"], ["delete", "w"], ["delete", "--force", "w"], ["prune"]
        ])
    }

    // MARK: files

    func testFileListingRoot() throws {
        let entries = ContainerOutputParser.fileEntries(RealCLIFixtures.filesRoot, in: "/")
        XCTAssertEqual(entries.count, 22)
        XCTAssertTrue(entries.prefix(21).allSatisfy(\.isDirectory), "Folders first")
        let script = try XCTUnwrap(entries.first { $0.name == "docker-entrypoint.sh" })
        XCTAssertFalse(script.isDirectory)
        XCTAssertEqual(script.path, "/docker-entrypoint.sh")
        XCTAssertEqual(script.sizeBytes, 1620)
        XCTAssertEqual(script.permissions, "-rwxr-xr-x")
        XCTAssertEqual(script.modified, Date(timeIntervalSince1970: 1_792_624_377))
        XCTAssertEqual(entries.first { $0.name == "proc" }?.permissions, "dr-xr-xr-x")
    }

    func testFileListingSymlinkFolder() throws {
        let entries = ContainerOutputParser.fileEntries(RealCLIFixtures.filesNginx, in: "/etc/nginx")
        XCTAssertEqual(entries.map(\.name), [
            "conf.d", "modules", "fastcgi_params", "fastcgi.conf", "mime.types", "nginx.conf", "scgi_params", "uwsgi_params"
        ])
        let modules = try XCTUnwrap(entries.first { $0.name == "modules" })
        XCTAssertTrue(modules.isSymlink)
        XCTAssertTrue(modules.isDirectory)
        XCTAssertEqual(modules.path, "/etc/nginx/modules")
    }

    func testListFilesMissingFolder() async {
        let runner = MockRunner()
        let key = ["exec", "w", "sh", "-c", ContainerOutputParser.listFilesScript, "sh", "/nope"].joined(separator: " ")
        runner.responses[key] = CommandResult(exitCode: 2, stdout: "", stderr: "sh: cd: line 0: can't cd to /nope: No such file or directory")
        do {
            _ = try await client(runner).listFiles("w", path: "/nope")
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Could not open /nope in w.")
        }
    }

    func testCopyUsesContainerCopy() async throws {
        let runner = MockRunner()
        runner.responses["copy w:/etc/nginx/nginx.conf /tmp/out"] = CommandResult(exitCode: 0, stdout: "/tmp/out/nginx.conf\n")
        runner.responses["copy /tmp/in.txt w:/tmp"] = CommandResult(exitCode: 0, stdout: "w:/tmp\n")
        let c = client(runner)
        try await c.copyFromContainer("w", path: "/etc/nginx/nginx.conf", to: URL(fileURLWithPath: "/tmp/out"))
        try await c.copyToContainer("w", from: URL(fileURLWithPath: "/tmp/in.txt"), path: "/tmp")
        XCTAssertEqual(runner.calls.count, 2, "No tar fallback when copy works")
    }

    func testCopyErrorIsNotTreatedAsMissingCommand() async {
        let runner = MockRunner()
        runner.responses["copy w:/nope /tmp/out"] = CommandResult(
            exitCode: 1, stdout: "",
            stderr: #"Error: failed to copy from container w (cause: "internalError: "failed to copy from container w (cause: "unknown: "notFound: "copy: path not found '/nope'""")"")"#
        )
        do {
            try await client(runner).copyFromContainer("w", path: "/nope", to: URL(fileURLWithPath: "/tmp/out"))
            XCTFail("Expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("path not found"), error.localizedDescription)
            XCTAssertEqual(runner.calls.count, 1)
        }
    }

    // MARK: shell

    func testShellCommand() {
        let c = client(MockRunner())
        XCTAssertEqual(c.shellCommand("web"), "/usr/local/bin/container exec -it web /bin/sh")
        XCTAssertEqual(c.commandLine(c.shellArguments("web")), "container exec -it web /bin/sh")
        let odd = ContainerClient(cliPath: "/Applications/My Tools/container", runner: MockRunner())
        XCTAssertEqual(odd.shellCommand("web"), "'/Applications/My Tools/container' exec -it web /bin/sh")
        XCTAssertEqual(CLIText.shellQuoted("it's"), #"'it'\''s'"#)
        XCTAssertEqual(CLIText.shellQuoted(""), "''")
    }
}
