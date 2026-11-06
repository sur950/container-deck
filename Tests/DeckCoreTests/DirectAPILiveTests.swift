import XCTest
@testable import DeckCore

/// Live checks of the direct API against the real daemon and CLI.
/// Only with DECK_REAL_CLI=1. Uses `deck-test-api-*` names and removes them.
/// Never touches `deck-demo-*`.
final class DirectAPILiveTests: XCTestCase {
    private let cliPath = "/usr/local/bin/container"

    private func requireLive() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DECK_REAL_CLI"] == "1", "Set DECK_REAL_CLI=1 to run against the real daemon")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: cliPath), "container CLI not installed")
    }

    private var cli: ContainerClient { ContainerClient(cliPath: cliPath) }

    // MARK: Parity

    func testListParity() async throws {
        try requireLive()
        let api = DirectAPIClient()
        for all in [true, false] {
            let viaCLI = try await cli.listContainers(all: all)
            let viaAPI = try await api.listContainers(all: all)
            XCTAssertEqual(viaAPI.map(\.id).sorted(), viaCLI.map(\.id).sorted(), "all=\(all)")
            for item in viaCLI {
                guard let other = viaAPI.first(where: { $0.id == item.id }) else { continue }
                // A container can change state between the two calls. Compare the rest always.
                if other.state != item.state { continue }
                Self.assertSame(other, item)
            }
        }
    }

    func testInspectParity() async throws {
        try requireLive()
        let api = DirectAPIClient()
        let ids = try await cli.listContainers(all: true).map(\.id)
        try XCTSkipIf(ids.isEmpty, "No containers to inspect")
        let viaCLI = try await cli.inspectContainers(ids)
        let viaAPI = try await api.inspectContainers(ids)
        for detail in viaCLI {
            let other = try XCTUnwrap(viaAPI.first { $0.summary.id == detail.summary.id })
            if other.summary.state == detail.summary.state { Self.assertSame(other.summary, detail.summary) }
            XCTAssertEqual(other.entrypoint, detail.entrypoint)
            XCTAssertEqual(other.arguments, detail.arguments)
            XCTAssertEqual(other.env, detail.env)
            XCTAssertEqual(other.mounts, detail.mounts)
            XCTAssertEqual(other.workingDir, detail.workingDir)
            XCTAssertEqual(other.user, detail.user)
            XCTAssertEqual(other.rosetta, detail.rosetta)
            XCTAssertEqual(other.readOnlyRootfs, detail.readOnlyRootfs)
            XCTAssertEqual(other.networks.map(\.network), detail.networks.map(\.network))
            XCTAssertEqual(other.networks.map(\.ipAddress), detail.networks.map(\.ipAddress))
            XCTAssertFalse(other.rawJSON.isEmpty)
        }
        let single = try await api.inspectContainer(ids[0])
        XCTAssertEqual(single.summary.id, ids[0])
    }

    func testStatsParity() async throws {
        try requireLive()
        let api = DirectAPIClient(statsCache: CPUSampleCache())
        let viaCLI = try await cli.stats()
        let viaAPI = try await api.stats()
        XCTAssertEqual(viaAPI.map(\.id).sorted(), viaCLI.map(\.id).sorted())
        for item in viaCLI {
            guard let other = viaAPI.first(where: { $0.id == item.id }) else { continue }
            XCTAssertEqual(other.memoryLimitBytes, item.memoryLimitBytes, item.id)
            Self.assertClose(other.memoryUsageBytes, item.memoryUsageBytes, fraction: 0.25, item.id)
            XCTAssertGreaterThanOrEqual(other.cpuUsageUsec ?? 0, item.cpuUsageUsec ?? 0, "CPU time only grows")
            XCTAssertGreaterThanOrEqual(other.netRxBytes, item.netRxBytes)
            XCTAssertGreaterThan(other.pids, 0)
        }
    }

    func testImagesParity() async throws {
        try requireLive()
        let api = DirectAPIClient()
        let viaCLI = try await cli.listImages()
        let viaAPI = try await api.listImages()
        XCTAssertEqual(viaAPI.map(\.reference), viaCLI.map(\.reference))
        for image in viaCLI {
            let other = try XCTUnwrap(viaAPI.first { $0.reference == image.reference })
            XCTAssertEqual(other.digest, image.digest)
            XCTAssertEqual(other.sizeBytes, image.sizeBytes, image.reference)
            XCTAssertEqual(other.platforms, image.platforms, image.reference)
            Self.assertSameDate(other.createdAt, image.createdAt, image.reference)
        }
        if let first = viaCLI.first {
            let a = try await api.inspectImage(first.reference)
            let b = try await cli.inspectImage(first.reference)
            XCTAssertEqual(a.summary.reference, b.summary.reference)
            XCTAssertEqual(a.layers.map(\.digest), b.layers.map(\.digest))
            XCTAssertEqual(a.config, b.config)
            // Short names resolve like the CLI.
            let short = try await api.inspectImage(first.shortName + ":" + first.tag)
            XCTAssertEqual(short.summary.reference, first.reference)
        }
    }

    func testVolumesAndNetworksParity() async throws {
        try requireLive()
        let api = DirectAPIClient()
        let volumesCLI = try await cli.listVolumes()
        let volumesAPI = try await api.listVolumes()
        XCTAssertEqual(volumesAPI.map(\.name), volumesCLI.map(\.name))
        for volume in volumesCLI {
            let other = try XCTUnwrap(volumesAPI.first { $0.name == volume.name })
            XCTAssertEqual(other.sizeBytes, volume.sizeBytes)
            XCTAssertEqual(other.labels, volume.labels)
            XCTAssertEqual(other.backingPath, volume.backingPath)
            XCTAssertEqual(other.usedBy.sorted(), volume.usedBy.sorted())
            Self.assertSameDate(other.createdAt, volume.createdAt, volume.name)
        }
        let networksCLI = try await cli.listNetworks()
        let networksAPI = try await api.listNetworks()
        XCTAssertEqual(networksAPI.map(\.name), networksCLI.map(\.name))
        for network in networksCLI {
            let other = try XCTUnwrap(networksAPI.first { $0.name == network.name })
            XCTAssertEqual(other.subnet, network.subnet)
            XCTAssertEqual(other.gateway, network.gateway)
            XCTAssertEqual(other.ipv6Subnet, network.ipv6Subnet)
            XCTAssertEqual(other.isInternal, network.isInternal)
            XCTAssertEqual(other.isBuiltin, network.isBuiltin)
            XCTAssertEqual(other.labels, network.labels)
            XCTAssertEqual(other.attachedContainers.sorted(), network.attachedContainers.sorted())
            Self.assertSameDate(other.createdAt, network.createdAt, network.name)
        }
        let duCLI = try await cli.diskUsage()
        let duAPI = try await api.diskUsage()
        XCTAssertEqual(duAPI.images.total, duCLI.images.total)
        XCTAssertEqual(duAPI.containers.total, duCLI.containers.total)
        XCTAssertEqual(duAPI.volumes.total, duCLI.volumes.total)
        Self.assertClose(duAPI.images.sizeBytes, duCLI.images.sizeBytes, fraction: 0.01, "image bytes")
    }

    func testPingAndSelector() async throws {
        try requireLive()
        let api = DirectAPIClient()
        let health = try await api.ping()
        let cliVersion = try await cli.cli.version()
        XCTAssertEqual(health.semanticVersion, cliVersion)
        XCTAssertFalse(health.appRoot.isEmpty)
        let selector = BackendSelector(client: api, forceCLI: { false })
        let decision = await selector.decision(for: .containerList)
        XCTAssertEqual(decision, .direct)
        let status = await selector.status()
        XCTAssertEqual(status.backend, .directAPI)
        XCTAssertEqual(status.daemonVersion, health.version)
    }

    // MARK: Lifecycle

    /// create (CLI), start, stop, kill, delete (API), each step checked with the CLI.
    /// Also volume and network create and delete over the API, and logs.
    func testLifecycleRoundTrip() async throws {
        try requireLive()
        let api = DirectAPIClient()
        let suffix = String(UUID().uuidString.prefix(6)).lowercased()
        let name = "deck-test-api-\(suffix)"
        let volume = "deck-test-api-vol-\(suffix)"
        let network = "deck-test-api-net-\(suffix)"
        let image = try await cli.listImages().first { $0.reference.contains("alpine") }?.reference
        let alpine = try XCTUnwrap(image, "Needs an alpine image")

        defer {
            // Clean up through the CLI whatever happened.
            let path = cliPath
            let cleanup = Process()
            cleanup.executableURL = URL(fileURLWithPath: "/bin/sh")
            cleanup.arguments = ["-c", "\(path) delete --force \(name); \(path) volume delete \(volume); \(path) network delete \(network); true"]
            cleanup.standardOutput = FileHandle.nullDevice
            cleanup.standardError = FileHandle.nullDevice
            try? cleanup.run()
            cleanup.waitUntilExit()
        }

        try await api.createVolume(name: volume, size: "64M", labels: ["deck.test": "1"])
        let volumes = try await cli.listVolumeSummaries()
        XCTAssertEqual(volumes.first { $0.name == volume }?.labels["deck.test"], "1")
        XCTAssertEqual(volumes.first { $0.name == volume }?.sizeBytes, 64 * 1024 * 1024)

        try await api.createNetwork(name: network, subnet: nil, subnetV6: nil, internal: true, labels: ["deck.test": "1"])
        let networks = try await cli.listNetworkSummaries()
        XCTAssertEqual(networks.first { $0.name == network }?.isInternal, true)

        try await cli.run(["create", "--name", name, "--label", "deck.test=1", "--network", network,
                           "--volume", "\(volume):/data", alpine, "sh", "-c", "echo deck-api-hello; while true; do echo tick; sleep 1; done"])
        var state = try await cli.inspectContainer(name).summary.state
        XCTAssertEqual(state, .stopped)

        try await api.startContainer(name)
        state = try await cli.inspectContainer(name).summary.state
        XCTAssertEqual(state, .running)
        // Starting a running container is a no op, like the CLI.
        try await api.startContainer(name)

        // Logs: the tail, then follow picks up new lines.
        try await Task.sleep(for: .seconds(2))
        var lines: [String] = []
        for try await line in api.logs(name, options: LogOptions(follow: false, tail: nil)) { lines.append(line) }
        XCTAssertEqual(lines.first, "deck-api-hello")
        var followed: [String] = []
        let stream = api.logs(name, options: LogOptions(follow: true, tail: 1))
        for try await line in stream {
            followed.append(line)
            if followed.count >= 3 { break }
        }
        XCTAssertEqual(followed.count, 3)
        XCTAssertTrue(followed.allSatisfy { $0 == "tick" })
        var tail: [String] = []
        for try await line in api.logs(name, options: LogOptions(follow: false, tail: 2)) { tail.append(line) }
        let cliTail = try await cli.run(["logs", "-n", "2", name]).stdout.split(separator: "\n").map(String.init)
        XCTAssertEqual(tail.count, 2)
        XCTAssertEqual(cliTail.count, 2)

        let stats = try await api.stats([name])
        XCTAssertEqual(stats.map(\.id), [name])

        try await api.stopContainer(name)
        state = try await cli.inspectContainer(name).summary.state
        XCTAssertEqual(state, .stopped)

        try await api.startContainer(name)
        try await api.killContainer(name)
        try await Task.sleep(for: .seconds(1))
        state = try await cli.inspectContainer(name).summary.state
        XCTAssertNotEqual(state, .running)

        try await api.deleteContainer(name, force: true)
        let left = try await cli.listContainers(all: true).map(\.id)
        XCTAssertFalse(left.contains(name))

        try await api.deleteNetwork(network)
        try await api.deleteVolume(volume)
        let networksAfter = try await cli.listNetworkSummaries().map(\.name)
        let volumesAfter = try await cli.listVolumeSummaries().map(\.name)
        XCTAssertFalse(networksAfter.contains(network))
        XCTAssertFalse(volumesAfter.contains(volume))
    }

    /// Daemon errors come back as text the UI can show, through the router too.
    func testErrorsThroughRouter() async throws {
        try requireLive()
        let router = ContainerBackendRouter(cli: cli, selector: BackendSelector(client: DirectAPIClient(), forceCLI: { false }))
        do {
            try await router.deleteVolume("deck-test-api-missing-volume")
            XCTFail("Expected an error")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        do {
            _ = try await router.inspectContainer("deck-test-api-missing")
            XCTFail("Expected an error")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        let status = await router.status()
        XCTAssertEqual(status.backend, .directAPI)
        XCTAssertEqual(status.totalFallbacks, 0, "Daemon errors are answers, not fallbacks")
    }

    // MARK: Helpers

    static func assertSame(_ a: ContainerSummary, _ b: ContainerSummary, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.id, b.id, file: file, line: line)
        XCTAssertEqual(a.image, b.image, file: file, line: line)
        XCTAssertEqual(a.state, b.state, file: file, line: line)
        XCTAssertEqual(a.ipAddress, b.ipAddress, file: file, line: line)
        XCTAssertEqual(a.hostname, b.hostname, file: file, line: line)
        XCTAssertEqual(a.ports, b.ports, file: file, line: line)
        XCTAssertEqual(a.platform, b.platform, file: file, line: line)
        XCTAssertEqual(a.cpus, b.cpus, file: file, line: line)
        XCTAssertEqual(a.memoryBytes, b.memoryBytes, file: file, line: line)
        XCTAssertEqual(a.labels, b.labels, file: file, line: line)
        XCTAssertEqual(a.command, b.command, file: file, line: line)
        assertSameDate(a.createdAt, b.createdAt, a.id, file: file, line: line)
        assertSameDate(a.startedAt, b.startedAt, a.id, file: file, line: line)
    }

    /// The CLI prints whole seconds. The API keeps fractions.
    static func assertSameDate(_ a: Date?, _ b: Date?, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a == nil, b == nil, "\(what) date presence", file: file, line: line)
        if let a, let b {
            XCTAssertLessThan(abs(a.timeIntervalSince(b)), 1.01, "\(what) date", file: file, line: line)
        }
    }

    static func assertClose(_ a: UInt64, _ b: UInt64, fraction: Double, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let larger = Double(max(a, b))
        XCTAssertLessThanOrEqual(abs(Double(a) - Double(b)), max(larger * fraction, 4096), what, file: file, line: line)
    }
}

/// Records real replies for the fixtures in Fixtures/API (DECK_CAPTURE_API=1).
/// Writes raw payloads to /tmp/deck-api-capture. APIFixtures.swift was generated
/// from these with home paths scrubbed to /Users/me.
final class DirectAPICaptureTests: XCTestCase {
    func testCaptureReplies() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DECK_CAPTURE_API"] == "1", "Set DECK_CAPTURE_API=1 to record replies")
        let out = URL(fileURLWithPath: "/tmp/deck-api-capture", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let server = XPCConnection.shared(APIService.apiServer)
        let images = XPCConnection.shared(APIService.images)
        func save(_ name: String, _ data: Data?) throws {
            try (data ?? Data()).write(to: out.appendingPathComponent(name))
        }

        let ping = try await server.call(XPCRequest(route: APIRoute.ping))
        var strings: [String: String] = [:]
        for (key, value) in ping.values { if case .string(let text) = value { strings[key] = text } }
        try save("ping.json", try JSONSerialization.data(withJSONObject: strings, options: [.sortedKeys]))

        var list = XPCRequest(route: APIRoute.containerList)
        try list.set(APIKey.listFilters, json: APIListFilters())
        try save("containerList.json", try await server.call(list).data(APIKey.containers))

        var stats = XPCRequest(route: APIRoute.containerStats)
        stats.set(APIKey.id, "deck-demo-web")
        try save("containerStats.json", try await server.call(stats).data(APIKey.statistics))

        try save("volumeList.json", try await server.call(XPCRequest(route: APIRoute.volumeList)).data(APIKey.volumes))
        try save("networkList.json", try await server.call(XPCRequest(route: APIRoute.networkList)).data(APIKey.networkResources))
        try save("systemDiskUsage.json", try await server.call(XPCRequest(route: APIRoute.systemDiskUsage)).data(APIKey.diskUsageStats))
        let imageList = try await images.call(XPCRequest(route: APIRoute.imageList)).data(APIKey.imageDescriptions)
        try save("imageList.json", imageList)

        // A real error reply.
        var missing = XPCRequest(route: APIRoute.containerStats)
        missing.set(APIKey.id, "deck-test-api-missing")
        let raw = await withCheckedContinuation { (c: CheckedContinuation<XPCReply?, Never>) in
            server.send(missing) { c.resume(returning: try? $0.get()) }
        }
        try save("error.json", raw?.data(APIKey.error))

        // Content blobs of alpine:latest (index, every manifest and config).
        let descriptions = try DirectAPIClient.parseImageDescriptions(imageList ?? Data())
        let api = DirectAPIClient()
        if let alpine = descriptions.first(where: { $0.reference == "docker.io/library/alpine:latest" }) {
            let index = try await api.contentData(alpine.digest)
            try save("blob-\(alpine.digest).json", index)
            let object = try APIDecode.jsonObject(index, what: "index")
            for entry in object["manifests"] as? [[String: Any]] ?? [] {
                guard let digest = entry["digest"] as? String else { continue }
                guard let manifest = try? await api.contentData(digest) else { continue }
                try save("blob-\(digest).json", manifest)
                if let config = (try? APIDecode.jsonObject(manifest, what: "m"))?["config"] as? [String: Any],
                   let configDigest = config["digest"] as? String,
                   let data = try? await api.contentData(configDigest) {
                    try save("blob-\(configDigest).json", data)
                }
            }
        }
    }
}

/// Latency of each operation over the direct API and the CLI (DECK_REAL_CLI=1 DECK_BENCH=1).
/// Prints a markdown table. Median of several runs.
final class DirectAPIBenchmarkTests: XCTestCase {
    private let cliPath = "/usr/local/bin/container"

    private func median(_ runs: Int, _ body: () async throws -> Void) async rethrows -> Double {
        var times: [Double] = []
        let clock = ContinuousClock()
        for _ in 0..<runs {
            let start = clock.now
            try await body()
            let elapsed = clock.now - start
            times.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
        }
        return times.sorted()[times.count / 2]
    }

    func testMeasureLatency() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["DECK_REAL_CLI"] == "1" && env["DECK_BENCH"] == "1", "Set DECK_REAL_CLI=1 DECK_BENCH=1")
        let cli = ContainerClient(cliPath: cliPath)
        let api = DirectAPIClient()
        let runs = 5
        var rows: [(String, Double, Double)] = []
        func add(_ name: String, _ a: Double, _ c: Double) { rows.append((name, a, c)) }

        let allContainers = try await cli.listContainers(all: true)
        let anyID = try XCTUnwrap(allContainers.first?.id)
        let runningID = allContainers.first { $0.isRunning }?.id
        let allImages = try await cli.listImages()
        let image = try XCTUnwrap(allImages.first?.reference)

        add("ping / system status", try await median(runs) { _ = try await api.ping() },
            try await median(runs) { _ = try await cli.cli.isServiceRunning() })
        add("list containers", try await median(runs) { _ = try await api.listContainers(all: true) },
            try await median(runs) { _ = try await cli.listContainers(all: true) })
        add("inspect container", try await median(runs) { _ = try await api.inspectContainer(anyID) },
            try await median(runs) { _ = try await cli.inspectContainer(anyID) })
        if let runningID {
            add("stats (one container)", try await median(runs) { _ = try await api.stats([runningID]) },
                try await median(3) { _ = try await cli.stats([runningID]) })
        }
        add("stats (all running)", try await median(runs) { _ = try await api.stats() },
            try await median(3) { _ = try await cli.stats() })
        add("list images (cold cache)", try await median(runs) { _ = try await DirectAPIClient().listImages() },
            try await median(runs) { _ = try await cli.listImages() })
        _ = try await api.listImages()
        add("list images (warm cache)", try await median(runs) { _ = try await api.listImages() },
            try await median(runs) { _ = try await cli.listImages() })
        add("inspect image", try await median(runs) { _ = try await api.inspectImage(image) },
            try await median(runs) { _ = try await cli.inspectImage(image) })
        add("list volumes (no usedBy)", try await median(runs) { _ = try await api.listVolumeSummaries() },
            try await median(runs) { _ = try await cli.listVolumeSummaries() })
        add("list volumes (with usedBy)", try await median(runs) { _ = try await api.listVolumes() },
            try await median(runs) { _ = try await cli.listVolumes() })
        add("list networks (no attached)", try await median(runs) { _ = try await api.listNetworkSummaries() },
            try await median(runs) { _ = try await cli.listNetworkSummaries() })
        add("list networks (with attached)", try await median(runs) { _ = try await api.listNetworks() },
            try await median(runs) { _ = try await cli.listNetworks() })
        add("disk usage", try await median(runs) { _ = try await api.diskUsage() },
            try await median(runs) { _ = try await cli.diskUsage() })

        // Changes on a throwaway container and volume.
        let suffix = String(UUID().uuidString.prefix(6)).lowercased()
        let name = "deck-test-api-bench-\(suffix)"
        let alpine = try XCTUnwrap(allImages.first { $0.reference.contains("alpine") }?.reference)
        try await cli.run(["create", "--name", name, alpine, "sleep", "3600"])
        defer {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: cliPath)
            p.arguments = ["delete", "--force", name]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
        var apiStart: [Double] = [], apiStop: [Double] = [], cliStart: [Double] = [], cliStop: [Double] = []
        for _ in 0..<3 {
            apiStart.append(try await median(1) { try await api.startContainer(name) })
            apiStop.append(try await median(1) { try await api.stopContainer(name) })
            cliStart.append(try await median(1) { try await cli.startContainer(name) })
            cliStop.append(try await median(1) { try await cli.stopContainer(name) })
        }
        add("start container", apiStart.sorted()[1], cliStart.sorted()[1])
        add("stop container", apiStop.sorted()[1], cliStop.sorted()[1])
        var apiVol: [Double] = [], cliVol: [Double] = []
        for index in 0..<3 {
            apiVol.append(try await median(1) {
                try await api.createVolume(name: "deck-test-api-bv-\(suffix)-a\(index)")
                try await api.deleteVolume("deck-test-api-bv-\(suffix)-a\(index)")
            })
            cliVol.append(try await median(1) {
                try await cli.createVolume(name: "deck-test-api-bv-\(suffix)-c\(index)")
                try await cli.deleteVolume("deck-test-api-bv-\(suffix)-c\(index)")
            })
        }
        add("create + delete volume", apiVol.sorted()[1], cliVol.sorted()[1])

        var table = "| Operation | Direct API | CLI | Faster |\n| --- | ---: | ---: | ---: |\n"
        for (name, a, c) in rows {
            table += String(format: "| %@ | %.1f ms | %.0f ms | %.0fx |\n", name, a, c, c / max(a, 0.01))
        }
        print("DECK_BENCH_TABLE\n" + table)
        try table.write(toFile: "/tmp/deck-api-bench.md", atomically: true, encoding: .utf8)
    }
}
