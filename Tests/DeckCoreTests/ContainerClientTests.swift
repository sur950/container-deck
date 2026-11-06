import XCTest
@testable import DeckCore

/// Streams canned lines and records the arguments of each call.
private final class ClientTestStreamer: CommandStreaming, @unchecked Sendable {
    var lines: [String] = []
    private(set) var calls: [[String]] = []

    func stream(_ executable: String, _ arguments: [String]) -> AsyncThrowingStream<String, Error> {
        calls.append(arguments)
        let lines = self.lines
        return AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
    }
}

private let cliPath = "/usr/local/bin/container"

private func makeClient(_ runner: MockRunner, streamer: ClientTestStreamer = ClientTestStreamer()) -> ContainerClient {
    ContainerClient(cliPath: cliPath, runner: runner, streamer: streamer)
}

private func ok(_ stdout: String) -> CommandResult {
    CommandResult(exitCode: 0, stdout: stdout)
}

private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
    var lines: [String] = []
    for try await line in stream { lines.append(line) }
    return lines
}

final class ContainerClientTests: XCTestCase {

    // MARK: Containers

    func testListContainersMapsCurrentShape() async throws {
        let runner = MockRunner()
        runner.responses["list --all --format json"] = ok(ContainerCLIFixtures.containerList)
        let list = try await makeClient(runner).listContainers()

        XCTAssertEqual(runner.calls.first, [cliPath, "list", "--all", "--format", "json"])
        XCTAssertEqual(list.map(\.id), ["web", "db"])

        let web = list[0]
        XCTAssertEqual(web.name, "web")
        XCTAssertEqual(web.image, "docker.io/library/nginx:latest")
        XCTAssertEqual(web.state, .running)
        XCTAssertEqual(web.ipAddress, "192.168.64.3")
        XCTAssertEqual(web.hostname, "web.test")
        XCTAssertEqual(web.platform, "linux/arm64")
        XCTAssertEqual(web.cpus, 2)
        XCTAssertEqual(web.memoryBytes, 1_073_741_824)
        XCTAssertEqual(web.labels, ["com.example.team": "web"])
        XCTAssertEqual(web.command, ["nginx", "-g", "daemon off;"])
        XCTAssertEqual(web.createdAt, Date(timeIntervalSince1970: 1_793_351_564))
        XCTAssertEqual(web.startedAt?.timeIntervalSince1970 ?? 0, 1_793_351_566.512, accuracy: 0.001)
        XCTAssertEqual(web.ports, [
            PortMapping(hostAddress: nil, hostPort: 8080, containerPort: 80, proto: "tcp"),
            PortMapping(hostAddress: "127.0.0.1", hostPort: 5353, containerPort: 53, proto: "udp"),
            PortMapping(hostAddress: "127.0.0.1", hostPort: 5354, containerPort: 54, proto: "udp")
        ])

        let db = list[1]
        XCTAssertEqual(db.state, .stopped)
        XCTAssertNil(db.ipAddress)
        XCTAssertEqual(db.hostname, "db")
        XCTAssertEqual(db.platform, "linux/amd64")
        XCTAssertEqual(db.command, ["docker-entrypoint.sh"])
    }

    func testListContainersReadsLegacyShapeAndSkipsBrokenItems() throws {
        let list = try ContainerOutputParser.containers(ContainerCLIFixtures.containerListLegacy)
        XCTAssertEqual(list.count, 1)
        let old = list[0]
        XCTAssertEqual(old.id, "old")
        XCTAssertEqual(old.state, .running)
        XCTAssertEqual(old.ipAddress, "192.168.64.5")
        XCTAssertEqual(old.hostname, "old")
        XCTAssertEqual(old.command, ["/bin/sh", "sleep", "infinity"])
        XCTAssertEqual(old.createdAt, Date(timeIntervalSinceReferenceDate: 783_420_000))
        XCTAssertEqual(old.startedAt, Date(timeIntervalSinceReferenceDate: 783_420_010.5))
    }

    func testEmptyListIsEmpty() throws {
        XCTAssertEqual(try ContainerOutputParser.containers(""), [])
        XCTAssertEqual(try ContainerOutputParser.containers("[]\n"), [])
        XCTAssertThrowsError(try ContainerOutputParser.containers("not json"))
    }

    func testInspectContainer() async throws {
        let runner = MockRunner()
        runner.responses["inspect web"] = ok(ContainerCLIFixtures.containerInspect)
        let detail = try await makeClient(runner).inspectContainer("web")

        XCTAssertEqual(detail.summary.id, "web")
        XCTAssertEqual(detail.entrypoint, ["nginx"])
        XCTAssertEqual(detail.arguments, ["-g", "daemon off;"])
        XCTAssertEqual(detail.workingDir, "/srv")
        XCTAssertEqual(detail.user, "101:101")
        XCTAssertTrue(detail.readOnlyRootfs)
        XCTAssertEqual(detail.env, [EnvVar(key: "PATH", value: "/usr/bin"), EnvVar(key: "GREETING", value: "a=b")])
        XCTAssertEqual(detail.mounts, [
            MountInfo(type: "bind", source: "/Users/me/site", destination: "/usr/share/nginx/html", readOnly: true),
            MountInfo(type: "volume", source: "webdata", destination: "/data", readOnly: false),
            MountInfo(type: "tmpfs", source: "tmpfs", destination: "/tmp", readOnly: false)
        ])
        XCTAssertEqual(detail.networks, [
            NetworkAttachment(network: "default", ipAddress: "192.168.64.3", gateway: "192.168.64.1", macAddress: "02:42:ac:11:00:02", hostname: "web.test")
        ])
        XCTAssertTrue(detail.rawJSON.contains("\"configuration\""))
        XCTAssertTrue(detail.rawJSON.contains("daemon off;"))
    }

    func testStoppedContainerDetailUsesConfiguredNetworks() throws {
        let details = try ContainerOutputParser.containerDetails(ContainerCLIFixtures.containerList)
        let db = try XCTUnwrap(details.first { $0.summary.id == "db" })
        XCTAssertEqual(db.networks, [NetworkAttachment(network: "backend", hostname: "db")])
        XCTAssertEqual(db.user, "postgres")
        XCTAssertTrue(db.rosetta)
    }

    func testLifecycleCommands() async throws {
        let runner = MockRunner()
        for key in ["start web", "stop web", "kill web", "delete web", "delete --force web", "prune"] {
            runner.responses[key] = ok("")
        }
        let client = makeClient(runner)
        try await client.startContainer("web")
        try await client.stopContainer("web")
        try await client.killContainer("web")
        try await client.deleteContainer("web")
        try await client.deleteContainer("web", force: true)
        try await client.pruneContainers()
        try await client.restartContainer("web")

        XCTAssertEqual(runner.calls.map { Array($0.dropFirst()) }, [
            ["start", "web"], ["stop", "web"], ["kill", "web"], ["delete", "web"],
            ["delete", "--force", "web"], ["prune"], ["stop", "web"], ["start", "web"]
        ])
    }

    func testFailedCommandThrowsStderr() async {
        let runner = MockRunner()
        runner.responses["stop web"] = CommandResult(exitCode: 1, stdout: "", stderr: "Error: container web not found")
        do {
            try await makeClient(runner).stopContainer("web")
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Error: container web not found")
        }
    }

    // MARK: Run

    func testRunArgumentsFullOptions() {
        let options = RunOptions(
            image: "nginx:latest",
            name: "web",
            command: ["nginx", "-g", "daemon off;"],
            entrypoint: "/docker-entrypoint.sh",
            env: [EnvVar(key: "A", value: "1"), EnvVar(key: " ", value: "skip"), EnvVar(key: "B", value: "x y")],
            ports: [PortMapping(hostPort: 8080, containerPort: 80), PortMapping(hostAddress: "127.0.0.1", hostPort: 53, containerPort: 53, proto: "udp")],
            mounts: [
                MountSpec(kind: .bind, source: "/Users/me/site", destination: "/usr/share/nginx/html", readOnly: true),
                MountSpec(kind: .volume, source: "webdata", destination: "/data"),
                MountSpec(kind: .bind, source: "/Users/me/a:b", destination: "/odd")
            ],
            cpus: 2,
            memory: "1G",
            network: "backend",
            workingDir: "/srv",
            labels: ["z": "last", "a": "first"],
            detach: true,
            autoRemove: true,
            platform: "linux/amd64"
        )
        let args = makeClient(MockRunner()).runArguments(options)
        XCTAssertEqual(args, [
            "run", "--detach", "--rm", "--name", "web",
            "--env", "A=1", "--env", "B=x y",
            "--publish", "8080:80/tcp", "--publish", "127.0.0.1:53:53/udp",
            "--volume", "/Users/me/site:/usr/share/nginx/html:ro",
            "--volume", "webdata:/data",
            "--mount", "type=bind,source=/Users/me/a:b,target=/odd",
            "--cpus", "2", "--memory", "1G", "--network", "backend", "--workdir", "/srv",
            "--label", "a=first", "--label", "z=last",
            "--entrypoint", "/docker-entrypoint.sh",
            "--platform", "linux/amd64",
            "nginx:latest", "nginx", "-g", "daemon off;"
        ])
    }

    func testRunArgumentsMinimal() {
        let args = makeClient(MockRunner()).runArguments(RunOptions(image: "alpine", name: "  ", detach: false))
        XCTAssertEqual(args, ["run", "alpine"])
    }

    func testRunContainerReturnsPrintedID() async throws {
        let runner = MockRunner()
        runner.responses["run --detach --name web nginx"] = ok("web\n")
        let id = try await makeClient(runner).runContainer(RunOptions(image: "nginx", name: "web"))
        XCTAssertEqual(id, "web")
        XCTAssertEqual(ContainerOutputParser.runOutputID("\u{1B}[2KStarting container\n3f1c2a9e\n\n"), "3f1c2a9e")
    }

    // MARK: Logs and stats

    func testLogsArguments() async throws {
        let streamer = ClientTestStreamer()
        streamer.lines = ["one", "two"]
        let client = makeClient(MockRunner(), streamer: streamer)
        let lines = try await collect(client.logs("web", options: LogOptions(follow: true, tail: 100, boot: true)))
        XCTAssertEqual(lines, ["one", "two"])
        XCTAssertEqual(streamer.calls.first, ["logs", "--follow", "-n", "100", "--boot", "web"])
        XCTAssertEqual(client.logArguments("web", options: LogOptions(follow: false, tail: nil)), ["logs", "web"])
    }

    func testStatsUsesUtilizationWhenPresent() async throws {
        let runner = MockRunner()
        runner.responses["stats --no-stream --format json"] = ok(ContainerCLIFixtures.statsWithUtilization)
        let stats = try await makeClient(runner).stats()
        XCTAssertEqual(stats.count, 1)
        let web = stats[0]
        XCTAssertEqual(web.id, "web")
        XCTAssertEqual(web.cpuPercent, 25, accuracy: 0.0001)
        XCTAssertEqual(web.memoryUsageBytes, 52_428_800)
        XCTAssertEqual(web.memoryLimitBytes, 1_073_741_824)
        XCTAssertEqual(web.netRxBytes, 1000)
        XCTAssertEqual(web.netTxBytes, 2000)
        XCTAssertEqual(web.blockReadBytes, 4096)
        XCTAssertEqual(web.blockWriteBytes, 8192)
        XCTAssertEqual(web.pids, 5)
    }

    func testStatsComputesPercentFromTwoSamples() throws {
        let cache = CPUSampleCache()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let first = try ContainerOutputParser.stats(ContainerCLIFixtures.statsCumulative(usec: 1_000_000), cache: cache, now: start)
        XCTAssertEqual(first.first?.cpuPercent, 0)
        // 1.5 s of CPU over 2 s of wall time = 75% (100% is one core).
        let second = try ContainerOutputParser.stats(
            ContainerCLIFixtures.statsCumulative(usec: 2_500_000), cache: cache, now: start.addingTimeInterval(2)
        )
        XCTAssertEqual(second.first?.cpuPercent ?? -1, 75, accuracy: 0.0001)
        XCTAssertEqual(second.first?.pids, 2)
    }

    func testStatsWithIDs() async throws {
        let runner = MockRunner()
        runner.responses["stats --no-stream --format json web db"] = ok("[]")
        let stats = try await makeClient(runner).stats(["web", "db"])
        XCTAssertTrue(stats.isEmpty)
    }

    // MARK: Files

    func testListFilesRunsScriptAndParsesStat() async throws {
        let runner = MockRunner()
        let key = ["exec", "web", "sh", "-c", ContainerOutputParser.listFilesScript, "sh", "/"].joined(separator: " ")
        runner.responses[key] = ok(ContainerCLIFixtures.statListing)
        let entries = try await makeClient(runner).listFiles("web", path: "/")

        XCTAssertEqual(entries.count, 5)
        XCTAssertEqual(Array(entries.map(\.name).prefix(2)), ["bin", "etc"], "Folders come first")
        XCTAssertEqual(Set(entries.map(\.name)), ["bin", "etc", ".hidden", "hello|world.txt", "motd"])
        func entry(_ name: String) -> FileEntry? { entries.first { $0.name == name } }
        let bin = try XCTUnwrap(entry("bin"))
        XCTAssertTrue(bin.isDirectory)
        XCTAssertTrue(bin.isSymlink)
        XCTAssertEqual(bin.path, "/bin")
        let file = try XCTUnwrap(entry("hello|world.txt"))
        XCTAssertFalse(file.isDirectory)
        XCTAssertEqual(file.sizeBytes, 12)
        XCTAssertEqual(file.modified, Date(timeIntervalSince1970: 1_730_000_100))
        XCTAssertEqual(file.permissions, "-rw-r--r--")
        let motd = try XCTUnwrap(entry("motd"))
        XCTAssertTrue(motd.isSymlink)
        XCTAssertFalse(motd.isDirectory)
    }

    func testListFilesFallsBackToLs() {
        let entries = ContainerOutputParser.fileEntries(ContainerCLIFixtures.lsListing, in: "/srv/")
        XCTAssertEqual(entries.map(\.name), ["conf d", "index.html", "log"])
        XCTAssertEqual(entries[0].path, "/srv/conf d")
        XCTAssertTrue(entries[0].isDirectory)
        XCTAssertEqual(entries[1].sizeBytes, 321)
        XCTAssertTrue(entries[2].isSymlink)
    }

    func testDeleteFileRefusesRoot() async throws {
        let runner = MockRunner()
        runner.responses["exec web rm -rf -- /tmp/x"] = ok("")
        let client = makeClient(runner)
        try await client.deleteFile("web", path: "/tmp/x")
        do {
            try await client.deleteFile("web", path: "/")
            XCTFail("Deleting / must fail")
        } catch {}
        XCTAssertEqual(runner.calls.count, 1)
    }

    func testCopyUsesContainerCopy() async throws {
        let runner = MockRunner()
        runner.responses["copy web:/etc/hosts /tmp/out"] = ok("/tmp/out")
        runner.responses["copy /tmp/in.txt web:/root/"] = ok("web:/root/in.txt")
        let client = makeClient(runner)
        try await client.copyFromContainer("web", path: "/etc/hosts", to: URL(fileURLWithPath: "/tmp/out"))
        try await client.copyToContainer("web", from: URL(fileURLWithPath: "/tmp/in.txt"), path: "/root/")
        XCTAssertEqual(runner.calls.count, 2)
    }

    func testExecReturnsResultWithoutThrowing() async throws {
        let runner = MockRunner()
        runner.responses["exec web false"] = CommandResult(exitCode: 1, stdout: "", stderr: "")
        let result = try await makeClient(runner).exec("web", ["false"])
        XCTAssertFalse(result.succeeded)
    }

    // MARK: Images

    func testListImages() async throws {
        let runner = MockRunner()
        runner.responses["image list --format json"] = ok(ContainerCLIFixtures.imageList)
        let images = try await makeClient(runner).listImages()
        XCTAssertEqual(images.count, 2)

        let nginx = images[0]
        XCTAssertEqual(nginx.reference, "docker.io/library/nginx:latest")
        XCTAssertEqual(nginx.shortName, "nginx")
        XCTAssertEqual(nginx.digest, "sha256:index1")
        XCTAssertEqual(nginx.platforms, ["linux/arm64/v8", "linux/amd64"])
        // Size of this Mac's platform, not the sum of every platform.
        XCTAssertEqual(nginx.sizeBytes, ContainerClient.hostArchitecture == "arm64" ? 72_000_000 : 70_000_000)
        XCTAssertEqual(nginx.createdAt, Date(timeIntervalSince1970: 1_759_947_735))

        let local = images[1]
        XCTAssertEqual(local.reference, "localhost/my-app:dev")
        XCTAssertNil(local.createdAt)
        XCTAssertEqual(local.platforms, [])
    }

    func testInspectImageLayersAndConfig() throws {
        let detail = try ContainerOutputParser.imageDetail(ContainerCLIFixtures.imageList, preferredArchitecture: "arm64")
        XCTAssertEqual(detail.summary.reference, "docker.io/library/nginx:latest")
        XCTAssertEqual(detail.layers.map(\.digest), ["sha256:layer1", "sha256:layer2"])
        XCTAssertEqual(detail.layers.map(\.createdBy), ["ADD file:abc in /", "RUN /bin/sh -c apt-get update # buildkit"])
        XCTAssertEqual(detail.config.entrypoint, ["/docker-entrypoint.sh"])
        XCTAssertEqual(detail.config.cmd, ["nginx", "-g", "daemon off;"])
        XCTAssertEqual(detail.config.env.first, EnvVar(key: "PATH", value: "/usr/local/sbin:/usr/bin"))
        XCTAssertNil(detail.config.workingDir)
        XCTAssertNil(detail.config.user)
        XCTAssertEqual(detail.config.labels["maintainer"], "NGINX Docker Maintainers")
        XCTAssertTrue(detail.rawJSON.contains("sha256:index1"))

        let amd = try ContainerOutputParser.imageDetail(ContainerCLIFixtures.imageList, preferredArchitecture: "amd64")
        XCTAssertEqual(amd.layers.map(\.digest), ["sha256:amd1"])
        XCTAssertEqual(amd.config.cmd, ["nginx"])
    }

    func testImageCommands() async throws {
        let runner = MockRunner()
        for key in [
            "image tag nginx my/nginx:1", "image delete nginx", "image prune", "image prune --all",
            "image load --input /tmp/a.tar", "image save --output /tmp/b.tar nginx"
        ] {
            runner.responses[key] = ok("")
        }
        let client = makeClient(runner)
        try await client.tagImage("nginx", as: "my/nginx:1")
        try await client.deleteImage("nginx")
        try await client.pruneImages()
        try await client.pruneImages(all: true)
        try await client.loadImage(from: URL(fileURLWithPath: "/tmp/a.tar"))
        try await client.saveImage("nginx", to: URL(fileURLWithPath: "/tmp/b.tar"))
        XCTAssertEqual(runner.calls.count, 6)
    }

    func testPullStripsTerminalCodes() async throws {
        let streamer = ClientTestStreamer()
        streamer.lines = ["\u{1B}[2K\u{1B}[1G[1/2] Fetching image 10% (1 of 10 blobs)", "   ", "\u{1B}[32mdone\u{1B}[0m"]
        let client = makeClient(MockRunner(), streamer: streamer)
        let lines = try await collect(client.pullImage("nginx", platform: "linux/amd64"))
        XCTAssertEqual(lines, ["[1/2] Fetching image 10% (1 of 10 blobs)", "done"])
        XCTAssertEqual(streamer.calls.first, ["image", "pull", "--platform", "linux/amd64", "nginx"])
    }

    func testBuildArguments() async throws {
        let streamer = ClientTestStreamer()
        let client = makeClient(MockRunner(), streamer: streamer)
        let options = BuildOptions(
            contextDir: "/Users/me/app",
            dockerfile: "/Users/me/app/Dockerfile.prod",
            tags: ["my-app:latest", "my-app:1.0"],
            buildArgs: [EnvVar(key: "NODE_VERSION", value: "22")],
            platform: "linux/amd64",
            target: "production",
            noCache: true
        )
        _ = try await collect(client.build(options))
        XCTAssertEqual(streamer.calls.first, [
            "build", "--progress", "plain", "--file", "/Users/me/app/Dockerfile.prod",
            "--tag", "my-app:latest", "--tag", "my-app:1.0", "--build-arg", "NODE_VERSION=22",
            "--platform", "linux/amd64", "--target", "production", "--no-cache", "/Users/me/app"
        ])
        XCTAssertEqual(
            client.buildArguments(BuildOptions(contextDir: ".")),
            ["build", "--progress", "plain", "--platform", "linux/arm64", "."]
        )
    }

    // MARK: Volumes and networks

    func testListVolumesWithUsers() async throws {
        let runner = MockRunner()
        runner.responses["volume list --format json"] = ok(ContainerCLIFixtures.volumeList)
        runner.responses["list --all --format json"] = ok(ContainerCLIFixtures.containerList)
        runner.responses["inspect web db"] = ok(ContainerCLIFixtures.containerList)
        let volumes = try await makeClient(runner).listVolumes()

        XCTAssertEqual(volumes.map(\.name), ["webdata", "3f1c2a", "legacy"])
        XCTAssertEqual(volumes[0].sizeBytes, 549_755_813_888)
        XCTAssertEqual(volumes[0].createdAt, Date(timeIntervalSince1970: 1_790_848_800))
        XCTAssertEqual(volumes[0].usedBy, ["web"])
        XCTAssertTrue(volumes[0].backingPath?.hasSuffix("volume.img") ?? false)
        XCTAssertTrue(volumes[1].isAnonymous)
        XCTAssertEqual(volumes[1].sizeBytes, 10 * 1024 * 1024 * 1024)
        XCTAssertEqual(volumes[2].labels, ["team": "data"])
        XCTAssertEqual(volumes[2].createdAt, Date(timeIntervalSinceReferenceDate: 783_420_000))
    }

    func testListVolumesWithoutContainerListStillWorks() async throws {
        let runner = MockRunner()
        runner.responses["volume list --format json"] = ok(ContainerCLIFixtures.volumeList)
        let volumes = try await makeClient(runner).listVolumes()
        XCTAssertEqual(volumes.count, 3)
        XCTAssertEqual(volumes[0].usedBy, [])
    }

    func testVolumeAndNetworkCommands() async throws {
        let runner = MockRunner()
        for key in [
            "volume create -s 10G --label a=1 --label b=2 data", "volume delete data", "volume prune",
            "network create --subnet 192.168.100.0/24 --internal backend", "network create front",
            "network delete backend", "network prune"
        ] {
            runner.responses[key] = ok("")
        }
        let client = makeClient(runner)
        try await client.createVolume(name: "data", size: "10G", labels: ["b": "2", "a": "1"])
        try await client.deleteVolume("data")
        try await client.pruneVolumes()
        try await client.createNetwork(name: "backend", subnet: "192.168.100.0/24", internal: true)
        try await client.createNetwork(name: "front")
        try await client.deleteNetwork("backend")
        try await client.pruneNetworks()
        XCTAssertEqual(runner.calls.count, 7)
    }

    func testListNetworks() async throws {
        let runner = MockRunner()
        runner.responses["network list --format json"] = ok(ContainerCLIFixtures.networkList)
        runner.responses["list --all --format json"] = ok(ContainerCLIFixtures.containerList)
        // Stopped containers are inspected too (they still block network delete).
        runner.responses["inspect web db"] = ok(ContainerCLIFixtures.containerInspect)
        let networks = try await makeClient(runner).listNetworks()

        XCTAssertEqual(networks.map(\.name), ["default", "backend"])
        let main = networks[0]
        XCTAssertEqual(main.subnet, "192.168.64.0/24")
        XCTAssertEqual(main.gateway, "192.168.64.1")
        XCTAssertFalse(main.isInternal)
        XCTAssertTrue(main.isBuiltin)
        XCTAssertEqual(main.state, "running")
        XCTAssertEqual(main.attachedContainers, ["web"])

        let backend = networks[1]
        XCTAssertTrue(backend.isInternal)
        XCTAssertFalse(backend.isBuiltin)
        XCTAssertEqual(backend.ipv6Subnet, "fd00:1::/64")
        XCTAssertEqual(backend.attachedContainers, [])
    }

    func testLegacyNetworkList() throws {
        let networks = try ContainerOutputParser.networks(ContainerCLIFixtures.networkListLegacy)
        XCTAssertEqual(networks.count, 1)
        XCTAssertEqual(networks[0].name, "default")
        XCTAssertEqual(networks[0].subnet, "192.168.64.0/24")
        XCTAssertEqual(networks[0].gateway, "192.168.64.1")
        XCTAssertEqual(networks[0].state, "running")
    }

    // MARK: System

    func testDiskUsage() async throws {
        let runner = MockRunner()
        runner.responses["system df --format json"] = ok(ContainerCLIFixtures.diskUsage)
        let usage = try await makeClient(runner).diskUsage()
        XCTAssertEqual(usage.images, UsageBucket(total: 3, active: 2, sizeBytes: 9000, reclaimableBytes: 3000))
        XCTAssertEqual(usage.containers, UsageBucket(total: 2, active: 1, sizeBytes: 1000, reclaimableBytes: 0))
        XCTAssertEqual(usage.volumes.total, 2)
        XCTAssertEqual(usage.totalBytes, 10_700)
        XCTAssertEqual(usage.reclaimableBytes, 3500)
    }

    func testSystemProperties() async throws {
        let runner = MockRunner()
        runner.responses["system property list --format json"] = ok(ContainerCLIFixtures.systemProperties)
        let properties = try await makeClient(runner).systemProperties()
        func value(_ key: String) -> String? { properties.first { $0.key == key }?.value }

        XCTAssertEqual(value("build.rosetta"), "true")
        XCTAssertEqual(value("build.cpus"), "2")
        XCTAssertEqual(value("container.memory"), "1gb")
        XCTAssertEqual(value("dns.domain"), "test")
        XCTAssertEqual(value("container.dns.nameservers"), "[\"1.1.1.1\"]")
        XCTAssertNotNil(properties.first { $0.key == "build.cpus" }?.description)
        XCTAssertEqual(properties.map(\.key), properties.map(\.key).sorted())

        let legacy = try ContainerOutputParser.systemProperties(ContainerCLIFixtures.systemPropertiesLegacy)
        XCTAssertEqual(legacy.map(\.key), ["build.rosetta", "dns.domain"])
        XCTAssertEqual(legacy[0].value, "true")
        XCTAssertEqual(legacy[0].description, "Use Rosetta.")
        XCTAssertEqual(legacy[1].value, "")
    }

    func testConfigFileEditing() {
        let original = """
        # my settings
        [build]
        cpus = 2

        [container]
        memory = "1g"
        """
        var text = SystemConfigFile.updating(original, key: "build.cpus", value: "8")
        XCTAssertTrue(text.contains("[build]\ncpus = 8\n"))
        text = SystemConfigFile.updating(text, key: "build.rosetta", value: "false")
        XCTAssertTrue(text.contains("cpus = 8\nrosetta = false\n"))
        text = SystemConfigFile.updating(text, key: "container.memory", value: "4g")
        XCTAssertTrue(text.contains("memory = \"4g\""))
        text = SystemConfigFile.updating(text, key: "dns.domain", value: "test")
        XCTAssertTrue(text.hasSuffix("[dns]\ndomain = \"test\"\n"))
        text = SystemConfigFile.updating(text, key: "container.dns.nameservers", value: "[\"1.1.1.1\"]")
        XCTAssertTrue(text.contains("[container.dns]\nnameservers = [\"1.1.1.1\"]"))
        text = SystemConfigFile.updating(text, key: "build.cpus", value: nil)
        XCTAssertFalse(text.contains("cpus ="))
        XCTAssertTrue(text.hasPrefix("# my settings\n[build]\n"))
        XCTAssertEqual(SystemConfigFile.tomlValue("a \"b\""), "\"a \\\"b\\\"\"")

        let url = SystemConfigFile.defaultURL(environment: ["XDG_CONFIG_HOME": "/tmp/xdg"])
        XCTAssertEqual(url.path, "/tmp/xdg/container/config.toml")
    }

    func testRegistries() async throws {
        let runner = MockRunner()
        runner.responses["registry list --format json"] = ok(ContainerCLIFixtures.registryList)
        let names = try await makeClient(runner).registries()
        XCTAssertEqual(names, ["docker.io", "ghcr.io"])

        let older = MockRunner()
        older.responses["registry list"] = ok(ContainerCLIFixtures.registryTable)
        let olderNames = try await makeClient(older).registries()
        XCTAssertEqual(olderNames, ["docker.io"])
    }

    func testRegistryLoginAndLogout() async throws {
        let runner = MockRunner()
        runner.responses["registry login --username me --password-stdin ghcr.io"] = ok("Login succeeded")
        runner.responses["registry logout ghcr.io"] = ok("")
        let client = makeClient(runner)
        try await client.registryLogin(server: "ghcr.io", username: "me", password: "s3cret")
        try await client.registryLogout(server: "ghcr.io")
        XCTAssertFalse(runner.calls.flatMap { $0 }.contains("s3cret"))
    }

    func testDNSDomainUsesAdminPrompt() async {
        let runner = MockRunner()
        let client = makeClient(runner)
        _ = try? await client.createDNSDomain("test")
        _ = try? await client.deleteDNSDomain("test")
        XCTAssertEqual(runner.calls.count, 2)
        XCTAssertEqual(runner.calls[0].first, "/usr/bin/osascript")
        let script = runner.calls[0].last ?? ""
        XCTAssertTrue(script.contains("'\(cliPath)' 'system' 'dns' 'create' 'test'"))
        XCTAssertTrue(script.contains("with administrator privileges"))
        XCTAssertTrue((runner.calls[1].last ?? "").contains("'dns' 'delete' 'test'"))
    }

    // MARK: Helpers

    func testDateParsing() {
        XCTAssertEqual(DeckDate.parse("2025-01-10T18:47:44Z"), Date(timeIntervalSince1970: 1_736_534_864))
        XCTAssertEqual(DeckDate.parse("2025-01-10T18:47:44.418467Z")?.timeIntervalSince1970 ?? 0, 1_736_534_864.418467, accuracy: 0.000_01)
        XCTAssertEqual(DeckDate.parse("2025-01-10T20:47:44+02:00"), Date(timeIntervalSince1970: 1_736_534_864))
        XCTAssertEqual(DeckDate.parse("2025-01-10T20:47:44+0200"), Date(timeIntervalSince1970: 1_736_534_864))
        XCTAssertEqual(DeckDate.fromNumber(1_736_534_864), Date(timeIntervalSince1970: 1_736_534_864))
        XCTAssertEqual(DeckDate.fromNumber(1_736_534_864_000), Date(timeIntervalSince1970: 1_736_534_864))
        XCTAssertEqual(DeckDate.fromNumber(783_420_000), Date(timeIntervalSinceReferenceDate: 783_420_000))
        XCTAssertNil(DeckDate.parse("yesterday"))
    }

    func testCPUSampleCache() {
        let cache = CPUSampleCache()
        let start = Date(timeIntervalSince1970: 100)
        XCTAssertNil(cache.percent(id: "a", usageUsec: 1_000_000, at: start))
        XCTAssertEqual(cache.percent(id: "a", usageUsec: 1_500_000, at: start.addingTimeInterval(2)) ?? -1, 25, accuracy: 0.0001)
        // A restarted container (counter went down) gives no reading.
        XCTAssertNil(cache.percent(id: "a", usageUsec: 10, at: start.addingTimeInterval(4)))
    }
}
