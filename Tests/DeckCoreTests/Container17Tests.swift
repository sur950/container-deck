import XCTest
@testable import DeckCore

/// Apple container 1.7 next to 1.6: what changed, how each release is handled, and that an
/// unknown newer release (1.8) falls back sanely. Fixtures are real 1.7.1 output
/// (`Container17Fixtures`) and real 1.6.1 output (`KubeFixtures`, `APIFixtures`).
final class Container17Tests: XCTestCase {
    private let cliPath = "/usr/local/bin/container"
    private let v14 = SemanticVersion(1, 4, 1)
    private let v15 = SemanticVersion(1, 5, 0)
    private let v16 = SemanticVersion(1, 6, 1)
    private let v17 = SemanticVersion(1, 7, 1)
    private let v18 = SemanticVersion(1, 8, 0)

    private func ok(_ text: String) -> CommandResult { CommandResult(exitCode: 0, stdout: text) }
    private func fail(_ text: String, code: Int32 = 1) -> CommandResult { CommandResult(exitCode: code, stdout: "", stderr: text) }
    private func client(_ runner: MockRunner, _ version: SemanticVersion?) -> ContainerClient {
        ContainerClient(cliPath: cliPath, runner: runner).withPlatformVersion(version)
    }
    private func args(_ runner: MockRunner) -> [String] {
        runner.calls.map { $0.dropFirst().joined(separator: " ") }
    }

    // MARK: - Features per release

    func testFeaturesPerRelease() {
        for old in [v14, v15, v16, SemanticVersion(1, 6, 99)] {
            let f = ContainerPlatformFeatures(version: old)
            XCTAssertFalse(f.listHidesClusterNodes, "\(old)")
            XCTAssertFalse(f.lifecycleSkipsClusterNodes, "\(old)")
            XCTAssertFalse(f.clusterListJSON, "\(old)")
            XCTAssertTrue(f.clusterLoadImage, "\(old)")
            XCTAssertFalse(f.clusterSharedImageStore, "\(old)")
            XCTAssertFalse(f.clusterWorkerGroups, "\(old)")
            XCTAssertFalse(f.newerThanKnown, "\(old)")
        }
        for new in [SemanticVersion(1, 7, 0), v17] {
            let f = ContainerPlatformFeatures(version: new)
            XCTAssertTrue(f.listHidesClusterNodes)
            XCTAssertTrue(f.lifecycleSkipsClusterNodes)
            XCTAssertTrue(f.clusterListJSON)
            XCTAssertFalse(f.clusterLoadImage)
            XCTAssertTrue(f.clusterSharedImageStore)
            XCTAssertTrue(f.clusterWorkerGroups)
            XCTAssertTrue(f.statsReportCPUUtilization)
            XCTAssertTrue(f.limitsCPUsToHostCores)
            XCTAssertFalse(f.newerThanKnown)
        }
        // Unknown newer releases get the newest known behaviour and say they are newer.
        for future in [v18, SemanticVersion(2, 0, 0)] {
            let f = ContainerPlatformFeatures(version: future)
            XCTAssertTrue(f.clusterListJSON)
            XCTAssertFalse(f.clusterLoadImage)
            XCTAssertTrue(f.newerThanKnown)
        }
        XCTAssertFalse(ContainerPlatformFeatures(version: SemanticVersion(1, 7, 9)).newerThanKnown)
        // A version that could not be read: newest behaviour, nothing claimed about it.
        let unknown = ContainerPlatformFeatures(version: nil)
        XCTAssertTrue(unknown.clusterListJSON)
        XCTAssertFalse(unknown.newerThanKnown)
        XCTAssertEqual(unknown.releaseName, "this container release")
    }

    func testFailureTextNamesNewerRelease() {
        let text = ContainerPlatformFeatures(version: v18).explainFailure("Could not read the clusters.", details: "boom").localizedDescription
        XCTAssertTrue(text.contains("container 1.8.0 is newer than Container Deck was tested with (up to 1.7.x)"), text)
        XCTAssertTrue(text.hasSuffix("Details: boom"), text)
        let known = ContainerPlatformFeatures(version: v17).explainFailure("Could not read the clusters.", details: "").localizedDescription
        XCTAssertEqual(known, "Could not read the clusters.")
    }

    func testClientVersionComesFromReportOrCache() async {
        let runner = MockRunner()
        let given = await client(runner, v17).resolvedPlatformVersion()
        XCTAssertEqual(given, v17)
        XCTAssertEqual(runner.calls, [], "A known version runs nothing")

        let path = "/tmp/deck-test-\(UUID().uuidString)/container"
        let reading = MockRunner()
        reading.responses["--version"] = ok(Container17Fixtures.version)
        let plain = ContainerClient(cliPath: path, runner: reading)
        let first = await plain.resolvedPlatformVersion()
        let second = await plain.resolvedPlatformVersion()
        XCTAssertEqual(first, v17)
        XCTAssertEqual(second, v17)
        XCTAssertEqual(args(reading), ["--version"], "Read once per path")
        await PlatformVersionCache.shared.forget(path)
    }

    // MARK: - Parsing 1.7 output

    func testClusterListJSON17() throws {
        let records = try KubeClusterParser.parseClusterJSON(Container17Fixtures.clusterListJSON)
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.name, "deck-17-test-k")
        XCTAssertEqual(record.kubernetesVersion, "v1.35.5")
        XCTAssertTrue(record.sharedImageStore)
        XCTAssertFalse(record.removeOnStop)
        XCTAssertNotNil(record.createdAt)
        XCTAssertEqual(record.nodes, [
            KubeClusterRecord.Node(name: "deck-17-test-k", roles: ["control-plane", "worker"], state: .running,
                                   addresses: ["192.168.64.3"], ports: [PortMapping(hostPort: 6445, containerPort: 6443)])
        ])
        XCTAssertEqual(try KubeClusterParser.parseClusterJSON(Container17Fixtures.clusterListEmptyJSON), [])
    }

    func testClusterJSONToleratesNewKeysAndMissingStatus() throws {
        let text = #"""
        [{"id":"dev","configuration":{"name":"dev","kubernetesVersion":"v1.36.4","futureKey":{"a":1},
          "nodes":[{"name":"dev","roles":["control-plane"]},{"name":"dev-worker-1","roles":["worker"],"kind":"linux"}]},
          "status":{"state":"degraded","nodes":[{"name":"dev","status":"running","addresses":["192.168.64.9/24"]}]}},
         {"id":"gone"}]
        """#
        let records = try KubeClusterParser.parseClusterJSON(text)
        XCTAssertEqual(records.map(\.name), ["dev", "gone"])
        XCTAssertFalse(records[0].sharedImageStore, "Absent means off")
        XCTAssertEqual(records[0].nodes.map(\.state), [.running, .stopped], "A node without status reads stopped")
        XCTAssertEqual(records[0].nodes[0].addresses, ["192.168.64.9"])
        XCTAssertEqual(records[1].nodes, [])
    }

    func testClusterJSONRejectsTables() {
        // 1.6 prints a table for `cluster list --format json`? It has no --format, so it errors, but a
        // table must never parse as an empty JSON list.
        XCTAssertThrowsError(try KubeClusterParser.parseClusterJSON(Container17Fixtures.clusterListTable))
        XCTAssertThrowsError(try KubeClusterParser.parseClusterJSON(KubeFixtures.clusterList))
        XCTAssertThrowsError(try KubeClusterParser.parseClusterJSON(#"{"clusters":[]}"#))
    }

    func testNodeTablesOf16And17() {
        // 1.6 prints MB, 1.7 `--nodes` prints ByteCountFormatter memory style (binary units).
        let old = KubeClusterParser.parseTable(KubeFixtures.clusterList)
        XCTAssertEqual(old.first?.nodes.first?.memoryBytes, 3072 * 1_048_576)
        let new = KubeClusterParser.parseTable(Container17Fixtures.clusterListNodesTable)
        XCTAssertEqual(new.map(\.name), ["deck-17-test-k"])
        let node = new.first?.nodes.first
        XCTAssertEqual(node?.memoryBytes, 3 * 1_073_741_824)
        XCTAssertEqual(node?.cpus, 2)
        XCTAssertEqual(node?.role, .controlPlaneWorker)
        XCTAssertEqual(node?.ipAddress, "192.168.64.3")
        XCTAssertEqual(node?.ports, [PortMapping(hostPort: 6445, containerPort: 6443)])
        // The per cluster table (no --nodes) is not a node table.
        XCTAssertEqual(KubeClusterParser.parseTable(Container17Fixtures.clusterListTable), [])
        XCTAssertEqual(KubeClusterParser.parseMemory("1.5 GB"), 1_610_612_736)
        XCTAssertNil(KubeClusterParser.parseMemory("lots"))
    }

    func testListAll17HidesNodesAndInspectStillWorks() throws {
        let listed = try ContainerOutputParser.containers(Container17Fixtures.listAll)
        XCTAssertEqual(listed.map(\.id), ["deck-17-test-a"])
        XCTAssertTrue(KubeClusterParser.clusters(from: listed).isEmpty, "1.7 container list has no nodes")
        let inspected = try ContainerOutputParser.containerDetails(Container17Fixtures.inspectNode).map(\.summary)
        XCTAssertEqual(inspected.map(\.id), ["deck-17-test-k"])
        XCTAssertTrue(KubeClusterParser.isClusterNode(inspected[0]))
        let clusters = KubeClusterParser.clusters(nodes: inspected, records: try KubeClusterParser.parseClusterJSON(Container17Fixtures.clusterListJSON))
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].sharedImageStore, true)
        XCTAssertEqual(clusters[0].kubernetesVersion, "v1.35.5")
        XCTAssertEqual(clusters[0].imageVersion, "v1.35.5", "The node image has a digest only, the record has the version")
        XCTAssertEqual(clusters[0].state, .running)
        XCTAssertEqual(clusters[0].apiServerHostPort, 6445)
        XCTAssertEqual(clusters[0].controlPlane?.cpus, 2)
    }

    func testRecordsKeepClustersWhoseNodesAreGone() throws {
        // A --rm cluster that stopped: the record stays, the containers are gone.
        let record = KubeClusterRecord(name: "tmp", kubernetesVersion: "v1.35.5", removeOnStop: true, nodes: [
            .init(name: "tmp", roles: ["control-plane"], state: .stopped),
            .init(name: "tmp-worker-1", roles: ["worker"], state: .stopped),
        ])
        let clusters = KubeClusterParser.clusters(nodes: [], records: [record])
        XCTAssertEqual(clusters.map(\.name), ["tmp"])
        XCTAssertEqual(clusters[0].nodes.map(\.role), [.controlPlane, .worker])
        XCTAssertEqual(clusters[0].state, .stopped)
        XCTAssertEqual(clusters[0].sharedImageStore, false)
        // A cluster made by 1.6 (no record) still shows from its containers.
        let old = try ContainerOutputParser.containers(KubeFixtures.clusterContainers)
        let merged = KubeClusterParser.clusters(nodes: old, records: [record])
        XCTAssertEqual(merged.map(\.name), ["deck-v2-k8s-a", "tmp"])
        XCTAssertNil(merged[0].sharedImageStore, "No record, so not known")
    }

    func testStatsAndPropertiesOf17() throws {
        let stats = try ContainerOutputParser.stats(Container17Fixtures.statsJSON, cache: CPUSampleCache())
        XCTAssertEqual(stats.first?.id, "deck-17-test-k")
        XCTAssertEqual(stats.first?.reportedCPUPercent ?? 0, 12.067, accuracy: 0.01)
        XCTAssertEqual(stats.first?.cpuPercent ?? 0, 12.067, accuracy: 0.01)

        let properties = try ContainerOutputParser.systemProperties(Container17Fixtures.propertyListJSON)
        let kernel = try XCTUnwrap(KernelSource.from(properties: properties))
        XCTAssertEqual(kernel.binaryPath, "opt/kata/share/kata-containers/vmlinux-6.18.56-208-debug")
        XCTAssertEqual(kernel.expectedSize, 676_287_269, "Matches the tested 1.7 entry in AppConfig.kernelDefaults")
        XCTAssertEqual(KernelSource.builtIn(for: v17).binaryPath, kernel.binaryPath)
        XCTAssertEqual(KernelSource.builtIn(for: v16).binaryPath, "opt/kata/share/kata-containers/vmlinux-6.18.35-197-debug")
        XCTAssertEqual(KernelSource.builtIn(for: v18).binaryPath, kernel.binaryPath, "Unknown newer releases use the newest entry")
    }

    func testNodeErrorsOf17AreNotMistakenForAMissingPlugin() {
        for text in [Container17Fixtures.stopNodeError, Container17Fixtures.startNodeError,
                     Container17Fixtures.deleteNodeError, Container17Fixtures.loadImageError, Container17Fixtures.clusterDeleteMissingError] {
            XCTAssertFalse(KubeClusterParser.isUnsupportedText(text), text)
        }
        XCTAssertTrue(Container17Fixtures.stopNodeError.contains("not found"))
        XCTAssertTrue(Container17Fixtures.cpusTooManyError.contains("cpus must be between 1 and"))
    }

    // MARK: - Cluster list per release (CLI)

    func testListClusters16ReadsTheContainerList() async throws {
        let runner = MockRunner()
        runner.responses["list --all --format json"] = ok(KubeFixtures.clusterContainers)
        let clusters = try await client(runner, v16).listClusters()
        XCTAssertEqual(clusters.map(\.name), ["deck-v2-k8s-a"])
        XCTAssertNil(clusters[0].sharedImageStore)
        XCTAssertEqual(args(runner), ["list --all --format json"])
    }

    func testListClusters17CLIReadsRecordsAndInspectsNodes() async throws {
        let runner = MockRunner()
        runner.responses["cluster list --format json"] = ok(Container17Fixtures.clusterListJSON)
        runner.responses["inspect deck-17-test-k"] = ok(Container17Fixtures.inspectNode)
        let clusters = try await client(runner, v17).listClusters()
        XCTAssertEqual(clusters.map(\.name), ["deck-17-test-k"])
        XCTAssertEqual(clusters[0].sharedImageStore, true)
        XCTAssertEqual(clusters[0].nodes.first?.cpus, 2)
        XCTAssertEqual(clusters[0].nodes.first?.memoryBytes, 3 * 1_073_741_824)
        XCTAssertEqual(args(runner), ["cluster list --format json", "inspect deck-17-test-k"])
        XCTAssertFalse(args(runner).contains("list --all --format json"), "1.7 container list has no nodes, so it is not read")
    }

    func testListClusters17KeepsRecordsWhenInspectFails() async throws {
        let runner = MockRunner()
        runner.responses["cluster list --format json"] = ok(Container17Fixtures.clusterListJSON)
        let clusters = try await client(runner, v17).listClusters()
        XCTAssertEqual(clusters.map(\.name), ["deck-17-test-k"])
        XCTAssertEqual(clusters[0].nodes.first?.state, .running)
        XCTAssertEqual(clusters[0].apiServerHostPort, 6445, "Ports come from the record")
        XCTAssertEqual(args(runner), ["cluster list --format json", "inspect deck-17-test-k", "inspect deck-17-test-k"])
    }

    func testListClusters18FallsBackToTheNodeTable() async throws {
        let runner = MockRunner()
        runner.responses["cluster list --format json"] = ok(#"{"clusters":"a new shape"}"#)
        runner.responses["cluster list --nodes"] = ok(Container17Fixtures.clusterListNodesTable)
        let clusters = try await client(runner, v18).listClusters()
        XCTAssertEqual(clusters.map(\.name), ["deck-17-test-k"])
        XCTAssertEqual(args(runner), ["cluster list --format json", "cluster list --nodes"])
    }

    func testListClusters18SaysWhatFailed() async {
        let runner = MockRunner()
        runner.responses["cluster list --format json"] = fail("Error: Unknown option '--format'", code: 64)
        runner.responses["cluster list --nodes"] = fail("Error: Unknown option '--nodes'", code: 64)
        do {
            _ = try await client(runner, v18).listClusters()
            XCTFail("Expected an error")
        } catch {
            let text = error.localizedDescription
            XCTAssertTrue(text.hasPrefix("Could not read the Kubernetes clusters."), text)
            XCTAssertTrue(text.contains("container 1.8.0 is newer than Container Deck was tested with"), text)
            XCTAssertTrue(text.contains("Unknown option '--format'"), text)
        }
    }

    // MARK: - Load image per release

    func testLoadImage16UsesThePlugin() async throws {
        let runner = MockRunner()
        runner.responses["cluster load-image --name dev demo:latest"] = ok("")
        try await client(runner, v16).loadImage(intoCluster: "dev", image: "demo:latest")
        XCTAssertEqual(args(runner), ["cluster load-image --name dev demo:latest"])
    }

    func testLoadImage17SavesCopiesAndImports() async throws {
        let runner = MockRunner()
        runner.responses["cluster list --format json"] = ok(Container17Fixtures.clusterListJSON)
        runner.responses["inspect deck-17-test-k"] = ok(Container17Fixtures.inspectNode)
        let c = ContainerClient(cliPath: cliPath, runner: ArchiveRunner(base: runner)).withPlatformVersion(v17)
        try await c.loadImage(intoCluster: "deck-17-test-k", image: "demo:latest")
        let calls = args(runner).map { $0.replacingOccurrences(of: #"deck-cluster-image-[0-9A-F-]+\.tar"#, with: "X.tar", options: .regularExpression) }
        let tmp = FileManager.default.temporaryDirectory.path
        let archive = (tmp.hasSuffix("/") ? tmp : tmp + "/") + "X.tar"
        XCTAssertEqual(calls, [
            "cluster list --format json",
            "inspect deck-17-test-k",
            "image save --platform linux/arm64 --output \(archive) demo:latest",
            "copy \(archive) deck-17-test-k:/var/deck-image-load.tar",
            "exec deck-17-test-k /usr/local/bin/ctr --namespace k8s.io images import /var/deck-image-load.tar",
            "exec deck-17-test-k rm -f /var/deck-image-load.tar",
        ])
        XCTAssertFalse(calls.contains { $0.contains("load-image") })
    }

    func testLoadImage17ReportsFailures() async {
        let runner = MockRunner()
        do {
            try await client(runner, v17).loadImage(intoCluster: "dev", image: "demo", nodes: ["dev"])
            XCTFail("Expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.hasPrefix("Could not load demo into cluster dev."), error.localizedDescription)
        }
    }

    // MARK: - Create per release

    func testCreateArgumentsPerRelease() throws {
        let c = client(MockRunner(), nil)
        let options = KubeClusterOptions(name: "dev", workers: 2, cpus: 4, memory: "4G")
        // 1.6: --cpus and --memory size every node.
        XCTAssertEqual(try c.createClusterArguments(options, features: ContainerPlatformFeatures(version: v16)),
                       ["cluster", "create", "--name", "dev", "--cpus", "4", "--memory", "4G", "--workers", "2"])
        // 1.7: they size the control plane only, so the workers get the same sizes as a group.
        XCTAssertEqual(try c.createClusterArguments(options, features: ContainerPlatformFeatures(version: v17)),
                       ["cluster", "create", "--name", "dev", "--cpus", "4", "--memory", "4G", "--workers", "count=2,cpus=4,memory=4G"])
        var shared = KubeClusterOptions(name: "dev")
        shared.sharedImageStore = true
        XCTAssertEqual(try c.createClusterArguments(shared, features: ContainerPlatformFeatures(version: v17)),
                       ["cluster", "create", "--name", "dev", "--shared-image-store"])
        XCTAssertEqual(c.createClusterHintArguments(KubeClusterOptions(name: "dev", workers: 1)),
                       ["cluster", "create", "--name", "dev", "--workers", "1"], "No sizes, plain count on every release")
    }

    func testCreateOn16DropsSharedImageStore() async throws {
        let streamer = RecordingStreamer()
        var c = ContainerClient(cliPath: cliPath, runner: MockRunner(), streamer: streamer).withPlatformVersion(v16)
        c.router = nil
        var options = KubeClusterOptions(name: "dev")
        options.sharedImageStore = true
        for try await _ in c.createCluster(options) {}
        XCTAssertEqual(streamer.calls, [["cluster", "create", "--name", "dev"]])

        let newer = ContainerClient(cliPath: cliPath, runner: MockRunner(), streamer: streamer).withPlatformVersion(v17)
        for try await _ in newer.createCluster(options) {}
        XCTAssertEqual(streamer.calls.last, ["cluster", "create", "--name", "dev", "--shared-image-store"])
    }

    func testSavedOptionsFromOlderAppsStillDecode() throws {
        let old = #"{"name":"dev","nodeImage":"","workers":1,"cni":{"kindnet":{}},"cpus":2,"memory":"3G","removeOnStop":false}"#
        let options = try JSONDecoder().decode(KubeClusterOptions.self, from: Data(old.utf8))
        XCTAssertEqual(options.name, "dev")
        XCTAssertEqual(options.workers, 1)
        XCTAssertFalse(options.sharedImageStore)
        var shared = options
        shared.sharedImageStore = true
        let round = try JSONDecoder().decode(KubeClusterOptions.self, from: JSONEncoder().encode(shared))
        XCTAssertTrue(round.sharedImageStore)
    }

    // MARK: - Direct API per daemon release

    func testDirectListFilterFollowsTheDaemonRelease() async throws {
        let old = ClusterDaemon(version: "1.6.1")
        let oldList = try await old.client.listContainers(all: true)
        XCTAssertTrue(oldList.map(\.id).contains("dev"), "1.6 lists cluster nodes like its CLI")
        XCTAssertEqual(old.lastFilterLabel, "^(?!machine$)")

        let new = ClusterDaemon(version: "1.7.1")
        let newList = try await new.client.listContainers(all: true)
        XCTAssertFalse(newList.map(\.id).contains("dev"), "1.7 hides them like its CLI")
        XCTAssertTrue(newList.map(\.id).contains("deck-demo-web"))
        XCTAssertEqual(new.lastFilterLabel, "^(?!(?:machine|cluster)$)")

        let nodes = try await new.client.listClusterNodes()
        XCTAssertEqual(nodes.map(\.id), ["dev"])
        XCTAssertEqual(new.lastFilterLabel, "^(?:cluster|k8s)$")
    }

    func testListClusters17WithRouterUsesDirectNodes() async throws {
        let daemon = ClusterDaemon(version: "1.7.1")
        let runner = MockRunner()
        runner.responses["cluster list --format json"] = ok(#"[{"id":"dev","configuration":{"name":"dev","kubernetesVersion":"v1.35.5","sharedImageStore":false,"nodes":[{"name":"dev","roles":["control-plane","worker"]}]},"status":{"state":"stopped","nodes":[{"name":"dev","status":"stopped"}]}}]"#)
        let client = daemon.routedClient(runner: runner, version: v17)
        let clusters = try await client.listClusters()
        XCTAssertEqual(clusters.map(\.name), ["dev"])
        XCTAssertEqual(clusters[0].sharedImageStore, false)
        XCTAssertEqual(clusters[0].nodes.first?.image, "docker.io/library/alpine:latest", "Node details come from the direct list")
        XCTAssertEqual(args(runner), ["cluster list --format json"], "Only the records need a process")
    }

    func testStartAndStopNodes17GoDirectEvenWithTheCLISwitchOn() async throws {
        let daemon = ClusterDaemon(version: "1.7.1", forceCLI: true)
        let runner = MockRunner()
        let client = daemon.routedClient(runner: runner, version: v17)
        let cluster = KubeCluster(name: "dev", nodes: [KubeClusterNode(name: "dev", cluster: "dev", role: .controlPlaneWorker, state: .stopped)])
        try await client.startCluster(cluster)
        XCTAssertTrue(daemon.api.routes.contains(APIRoute.containerBootstrap))
        XCTAssertTrue(daemon.api.routes.contains(APIRoute.containerStartProcess))

        var running = cluster
        running.nodes[0].state = .running
        try await client.stopCluster(running)
        XCTAssertTrue(daemon.api.routes.contains(APIRoute.containerStop))
        XCTAssertEqual(runner.calls, [], "The 1.7 CLI answers not found for nodes, so it is never asked")
        XCTAssertEqual(daemon.fallback.calls, [])
    }

    func testStartNodes16UseTheNormalRoute() async throws {
        let daemon = ClusterDaemon(version: "1.6.1", forceCLI: true)
        daemon.fallback.responses["start dev"] = ok("dev")
        let client = daemon.routedClient(runner: MockRunner(), version: v16)
        let cluster = KubeCluster(name: "dev", nodes: [KubeClusterNode(name: "dev", cluster: "dev", role: .controlPlaneWorker, state: .stopped)])
        try await client.startCluster(cluster)
        XCTAssertEqual(daemon.fallback.calls.map { $0.dropFirst().joined(separator: " ") }, ["start dev"], "1.6 with the CLI switch on uses the CLI")
        XCTAssertFalse(daemon.api.routes.contains(APIRoute.containerBootstrap))
    }

    func testNodeLifecycle17ExplainsAStoppedService() async {
        let daemon = ClusterDaemon(version: "1.7.1", running: false)
        let client = daemon.routedClient(runner: MockRunner(), version: v17)
        do {
            try await client.clusterNode(.start, "dev")
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The container services are not running.")
        }
    }

    func testNodeLifecycle18NotAnsweringSaysWhy() async {
        let daemon = ClusterDaemon(version: "1.8.0", pingError: .timeout(route: "ping", seconds: 2))
        let client = daemon.routedClient(runner: MockRunner(), version: v18)
        do {
            try await client.clusterNode(.stop, "dev")
            XCTFail("Expected an error")
        } catch {
            let text = error.localizedDescription
            XCTAssertTrue(text.hasPrefix("Could not stop cluster node dev. container 1.8.0 only does this through its service"), text)
            XCTAssertTrue(text.contains("newer than Container Deck was tested with"), text)
        }
    }

    // MARK: - container k8s (1.4.0 to 1.6.0)

    private let v140 = SemanticVersion(1, 4, 0)
    private let v160 = SemanticVersion(1, 6, 0)

    func testK8sPluginFeatures() {
        for (version, manifest, none) in [(v140, false, false), (v15, true, false), (v160, true, true)] {
            let f = ContainerPlatformFeatures(version: version)
            XCTAssertEqual(f.clusterCommand, "k8s", "\(version)")
            XCTAssertFalse(f.clusterWorkers, "\(version)")
            XCTAssertEqual(f.clusterCNIManifest, manifest, "\(version)")
            XCTAssertEqual(f.clusterCNINone, none, "\(version)")
            XCTAssertEqual(f.clusterLoadImageNodes, none, "\(version)")
            XCTAssertTrue(f.clusterLoadImage)
        }
        for version in [v16, v17, v18] {
            let f = ContainerPlatformFeatures(version: version)
            XCTAssertEqual(f.clusterCommand, "cluster")
            XCTAssertTrue(f.clusterWorkers && f.clusterCNIManifest && f.clusterCNINone)
        }
        XCTAssertEqual(ContainerPlatformFeatures(version: nil).clusterCommand, "cluster")
    }

    func testK8sPluginArguments() throws {
        let old = client(MockRunner(), v140)
        let options = KubeClusterOptions(name: "dev", workers: 2, cni: .none, cpus: 2, memory: "3G")
        XCTAssertEqual(try old.createClusterArguments(options), ["k8s", "create", "--name", "dev", "--cpus", "2", "--memory", "3G"],
                       "No workers and no CNI choice on 1.4")
        XCTAssertEqual(try client(MockRunner(), v15).createClusterArguments(KubeClusterOptions(name: "dev", cni: .manifest("/tmp/c.yaml"))),
                       ["k8s", "create", "--name", "dev", "--cni", "/tmp/c.yaml"])
        XCTAssertEqual(try client(MockRunner(), v160).createClusterArguments(KubeClusterOptions(name: "dev", cni: .none)),
                       ["k8s", "create", "--name", "dev", "--cni", "NONE"])
        XCTAssertEqual(old.deleteClusterArguments("dev"), ["k8s", "delete", "--name", "dev"])
        XCTAssertEqual(old.writeKubeconfigArguments("dev", path: "/tmp/k"), ["k8s", "write-config", "--name", "dev", "--kubeconfig", "/tmp/k"])
        XCTAssertEqual(old.loadImageArguments(cluster: "dev", image: "demo", nodes: ["dev"]), ["k8s", "load-image", "--name", "dev", "demo"])
        XCTAssertEqual(client(MockRunner(), v160).loadImageArguments(cluster: "dev", image: "demo", nodes: ["dev"]),
                       ["k8s", "load-image", "--name", "dev", "--node", "dev", "demo"])
        XCTAssertEqual(client(MockRunner(), v16).deleteClusterArguments("dev"), ["cluster", "delete", "--name", "dev"])
    }

    func testK8sPluginCommandsRun() async throws {
        let runner = MockRunner()
        runner.responses["k8s --help"] = ok("OVERVIEW: Manage local Kubernetes development clusters (EXPERIMENTAL)\nUSAGE: k8s <subcommand>")
        runner.responses["k8s delete --name dev"] = ok("dev")
        runner.responses["k8s load-image --name dev demo:latest"] = ok("")
        let c = client(runner, v15)
        let supported = await c.clusterSupported()
        XCTAssertTrue(supported)
        try await c.deleteCluster("dev")
        try await c.loadImage(intoCluster: "dev", image: "demo:latest")
        XCTAssertEqual(args(runner), ["k8s --help", "k8s delete --name dev", "k8s load-image --name dev demo:latest"])
        // A 1.3 tool has neither command.
        let none = MockRunner()
        none.responses["k8s --help"] = fail("Error: Unknown command 'k8s'. If 'k8s' is a plugin, check that it is installed")
        let unsupported = await client(none, SemanticVersion(1, 3, 1)).clusterSupported()
        XCTAssertFalse(unsupported)
    }

    func testK8sNodesAreClusters() async throws {
        // The same node as KubeFixtures, labelled the way the k8s plugin labels nodes.
        let k8s = KubeFixtures.clusterContainers.replacingOccurrences(of: #""com.apple.container.plugin":"cluster""#, with: #""com.apple.container.plugin":"k8s""#)
        XCTAssertNotEqual(k8s, KubeFixtures.clusterContainers, "fixture has the plugin label")
        let runner = MockRunner()
        runner.responses["list --all --format json"] = ok(k8s)
        let clusters = try await client(runner, v15).listClusters()
        XCTAssertEqual(clusters.map(\.name), ["deck-v2-k8s-a"])
        XCTAssertEqual(clusters[0].controlPlane?.role.isControlPlane, true)

        // Table fallback through `k8s list`, which prints the same table as 1.6.1.
        let table = MockRunner()
        table.responses["k8s list"] = ok(KubeFixtures.clusterList)
        let fromTable = try await client(table, v140).listClusters()
        XCTAssertEqual(fromTable.map(\.name), ["deck-v2-k8s-a"])
        XCTAssertEqual(args(table), ["list --all --format json", "k8s list"])

        // The direct filter matches both labels.
        let regex = try NSRegularExpression(pattern: APILabel.onlyClusterNodes)
        for value in ["cluster", "k8s"] {
            XCTAssertNotNil(regex.firstMatch(in: value, range: NSRange(location: 0, length: value.count)))
        }
        XCTAssertNil(regex.firstMatch(in: "machine", range: NSRange(location: 0, length: 7)))
    }

    // MARK: - Image prune keeps cluster node images

    /// Four images: the node image (untagged, by digest), alpine (used by a container),
    /// an untagged leftover and a tagged unused image.
    private static let imagesForPrune = #"""
    [{"configuration":{"name":"docker.io/kindest/node@sha256:ce977ae6d65918d0b58a5f8b5e940429c2ce42fa3a5619ec2bbc60b949c0ac95","descriptor":{"digest":"sha256:ce977ae6d65918d0b58a5f8b5e940429c2ce42fa3a5619ec2bbc60b949c0ac95","mediaType":"application/vnd.oci.image.index.v1+json","size":703}},"variants":[]},
     {"configuration":{"name":"docker.io/library/alpine:latest","descriptor":{"digest":"sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf","mediaType":"application/vnd.oci.image.index.v1+json","size":9218}},"variants":[]},
     {"configuration":{"name":"docker.io/library/old@sha256:1111111111111111111111111111111111111111111111111111111111111111","descriptor":{"digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111","mediaType":"application/vnd.oci.image.index.v1+json","size":10}},"variants":[]},
     {"configuration":{"name":"docker.io/library/redis:7","descriptor":{"digest":"sha256:2222222222222222222222222222222222222222222222222222222222222222","mediaType":"application/vnd.oci.image.index.v1+json","size":10}},"variants":[]}]
    """#
    private let nodeImage = "docker.io/kindest/node@sha256:ce977ae6d65918d0b58a5f8b5e940429c2ce42fa3a5619ec2bbc60b949c0ac95"

    private func deletes(_ runner: MockRunner) -> [String] {
        args(runner).filter { $0.hasPrefix("image delete ") }.map { String($0.dropFirst("image delete ".count)) }
    }

    func testUntaggedAndUseRules() throws {
        XCTAssertTrue(ImageUsage.isUntagged(nodeImage))
        XCTAssertTrue(ImageUsage.isUntagged("sha256:abc"))
        XCTAssertFalse(ImageUsage.isUntagged("docker.io/library/alpine:latest"))
        XCTAssertFalse(ImageUsage.isUntagged("localhost:5000/app:1"))
        XCTAssertTrue(ImageUsage.isUntagged("localhost:5000/app"))
        let images = try ContainerOutputParser.images(Self.imagesForPrune)
        let node = try XCTUnwrap(images.first { $0.reference == nodeImage })
        XCTAssertTrue(ImageUsage.uses(nodeImage, image: node))
        XCTAssertTrue(ImageUsage.uses("kindest/node@sha256:ce977ae6d65918d0b58a5f8b5e940429c2ce42fa3a5619ec2bbc60b949c0ac95", image: node))
        XCTAssertTrue(ImageUsage.uses("alpine", image: try XCTUnwrap(images.first { $0.reference.hasSuffix("alpine:latest") })))
        XCTAssertFalse(ImageUsage.uses("alpine:3.22", image: try XCTUnwrap(images.first { $0.reference.hasSuffix("alpine:latest") })))

        let users = [ImageUser(name: "dev", image: nodeImage, kind: .clusterNode), ImageUser(name: "web", image: "alpine", kind: .container)]
        XCTAssertEqual(ImageUsage.prunable(images, users: users, all: false).map(\.reference),
                       ["docker.io/library/old@sha256:1111111111111111111111111111111111111111111111111111111111111111"],
                       "Apple's plain prune would also take the untagged node image")
        XCTAssertEqual(ImageUsage.prunable(images, users: users, all: true).map(\.reference),
                       ["docker.io/library/old@sha256:1111111111111111111111111111111111111111111111111111111111111111", "docker.io/library/redis:7"])
        XCTAssertTrue(ImageUsage.prunable(images, users: [], all: false).contains { $0.reference == nodeImage }, "Without the node it would go")
    }

    func testPrune17KeepsTheNodeImageOfAHiddenNode() async throws {
        for all in [false, true] {
            let runner = MockRunner()
            runner.responses["image list --format json"] = ok(Self.imagesForPrune)
            runner.responses["list --all --format json"] = ok(Container17Fixtures.listAll)   // the node is hidden here
            runner.responses["cluster list --format json"] = ok(Container17Fixtures.clusterListJSON)
            runner.responses["inspect deck-17-test-k"] = ok(Container17Fixtures.inspectNode)
            for ref in ["docker.io/library/old@sha256:1111111111111111111111111111111111111111111111111111111111111111", "docker.io/library/redis:7"] {
                runner.responses["image delete \(ref)"] = ok(ref)
            }
            let removed = try await client(runner, v17).pruneImages(all: all)
            XCTAssertFalse(deletes(runner).contains(nodeImage), "all=\(all): the node image must stay")
            XCTAssertFalse(deletes(runner).contains("docker.io/library/alpine:latest"))
            XCTAssertEqual(removed.contains("docker.io/library/redis:7"), all)
            XCTAssertTrue(removed.contains("docker.io/library/old@sha256:1111111111111111111111111111111111111111111111111111111111111111"))
            XCTAssertFalse(args(runner).contains { $0.hasPrefix("image prune") }, "Apple's prune is not used")
        }
    }

    func testPrune16KeepsTheNodeImage() async throws {
        let runner = MockRunner()
        runner.responses["image list --format json"] = ok(Self.imagesForPrune)
        runner.responses["list --all --format json"] = ok(KubeFixtures.clusterContainers)   // 1.6 lists the node
        runner.responses["image delete docker.io/library/old@sha256:1111111111111111111111111111111111111111111111111111111111111111"] = ok("")
        try await client(runner, v16).pruneImages(all: false)
        XCTAssertEqual(deletes(runner), ["docker.io/library/old@sha256:1111111111111111111111111111111111111111111111111111111111111111"])
        XCTAssertFalse(args(runner).contains("cluster list --format json"), "1.6 needs no extra node list")
    }

    func testPrune17RemovesNothingWhenNodesCannotBeRead() async {
        let runner = MockRunner()
        runner.responses["image list --format json"] = ok(Self.imagesForPrune)
        runner.responses["list --all --format json"] = ok(Container17Fixtures.listAll)
        do {
            try await client(runner, v17).pruneImages(all: true)
            XCTFail("Expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.hasPrefix("Could not check which images the Kubernetes nodes use, so no image was removed."), error.localizedDescription)
        }
        XCTAssertEqual(deletes(runner), [])
    }

    func testMachineImagesCountAsUsed() throws {
        let images = try ContainerOutputParser.images(Self.imagesForPrune)
        let users = [ImageUser(name: "dev", image: "redis:7", kind: .machine)]
        XCTAssertFalse(ImageUsage.prunable(images, users: users, all: true).contains { $0.reference == "docker.io/library/redis:7" })
    }

    // MARK: - Version range

    func testSupportedRangeCoversOneSeven() {
        let range = AppConfig.apiSupportedVersions
        for version in [SemanticVersion(1, 4, 0), v15, v16, SemanticVersion(1, 7, 0), v17, SemanticVersion(1, 7, 99)] {
            XCTAssertTrue(range.contains(version), "\(version)")
        }
        XCTAssertFalse(range.contains(v18), "1.8 is not tested, so it uses the CLI")
        XCTAssertFalse(range.contains(SemanticVersion(1, 3, 1)))
        XCTAssertEqual(ComponentGate.tested(for: "container")?.line, [1, 7], "Components: the tested version follows the same range")
    }

    func testSelectorSends18ToTheCLI() async {
        let selector = BackendSelector(ping: { _ in "1.8.0" }, forceCLI: { false })
        let decision = await selector.decision(for: .containerList)
        XCTAssertEqual(decision, .cli)
        let status = await selector.status()
        XCTAssertFalse(status.versionSupported)
        XCTAssertTrue(status.summary.contains("1.8.0 is not tested yet"), status.summary)
        let current = BackendSelector(ping: { _ in "1.7.1" }, forceCLI: { false })
        let direct = await current.decision(for: .containerList)
        XCTAssertEqual(direct, .direct)
    }

    // MARK: - Kernel after an upgrade

    func testKernelCheckOffersTheRecommendedKernelAfterAnUpgrade() {
        let root = "/Users/test/Library/Application Support/com.apple.container"
        func service(link target: String) -> SetupService {
            var files = FileSystem(fileExists: { _ in true }, isExecutable: { _ in false },
                                   contentsOfDirectory: { $0 == root + "/kernels" ? ["default.kernel-arm64", target] : [] })
            files.symlinkDestination = { $0 == root + "/kernels/default.kernel-arm64" ? root + "/kernels/" + target : nil }
            let env = SetupEnvironment(system: SystemInfo(isAppleSilicon: true, osMajor: 26, osMinor: 0), files: files,
                                       pathEnv: "", customCLIPath: nil, appRoot: root)
            return SetupService(runner: MockRunner(), environment: env)
        }
        let upgraded = service(link: "vmlinux-6.18.35-197-debug").kernelCheck(version: v17)
        XCTAssertEqual(upgraded.fix, .useRecommendedKernel)
        XCTAssertEqual(upgraded.state, .warning("Installed kernel 6.18.35. This container release recommends kernel 6.18.56."))
        XCTAssertTrue(upgraded.state.isPassing, "Containers still run, so it never blocks")
        XCTAssertEqual(FixAction.useRecommendedKernel.title, "Use the recommended kernel")
        XCTAssertFalse(FixAction.useRecommendedKernel.needsAdmin)

        XCTAssertEqual(service(link: "vmlinux-6.18.35-197-debug").kernelCheck(version: v16).state, .ok("Installed"))
        XCTAssertEqual(service(link: "vmlinux-6.18.56-208-debug").kernelCheck(version: v17).state, .ok("Installed"))
        // The tool's own answer wins (a kernel chosen in config.toml).
        XCTAssertEqual(service(link: "vmlinux-6.18.35-197-debug").kernelCheck(version: v17, recommended: "vmlinux-6.18.35-197-debug").state, .ok("Installed"))
        // A custom kernel file someone set on purpose is left alone.
        XCTAssertEqual(service(link: "my-kvm-kernel").kernelCheck(version: v17).state, .ok("Installed"))
    }

    func testAppRootHonoursTheContainerVariable() {
        XCTAssertEqual(ContainerAppRoot.current(defaultHome: "/Users/a", environment: [:]), "/Users/a/Library/Application Support/com.apple.container")
        XCTAssertEqual(ContainerAppRoot.current(defaultHome: "/Users/a", environment: ["CONTAINER_APP_ROOT": "/tmp/deck-17/appdata/"]), "/tmp/deck-17/appdata")
        XCTAssertEqual(ContainerAppRoot.current(defaultHome: "/Users/a", environment: ["CONTAINER_APP_ROOT": "relative"]), "/Users/a/Library/Application Support/com.apple.container")
    }
}

// MARK: - Helpers

/// The last plugin label filter the fake daemon saw.
private final class LabelRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    var value: String? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// Writes the archive `image save` would write, so the manual load sees a file.
private final class ArchiveRunner: CommandRunning, @unchecked Sendable {
    let base: MockRunner
    init(base: MockRunner) { self.base = base }

    func run(_ executable: String, _ arguments: [String], stdin: Data?) async throws -> CommandResult {
        let result = try await base.run(executable, arguments, stdin: stdin)
        if arguments.first == "image" || arguments.first == "copy" || arguments.first == "exec" {
            if arguments.first == "image", let index = arguments.firstIndex(of: "--output") {
                FileManager.default.createFile(atPath: arguments[index + 1], contents: Data("tar".utf8))
            }
            return CommandResult(exitCode: 0, stdout: "")
        }
        return result
    }
}

/// Records streamed commands and ends each stream at once.
private final class RecordingStreamer: CommandStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return recorded }

    func stream(_ executable: String, _ arguments: [String]) -> AsyncThrowingStream<String, Error> {
        lock.lock(); recorded.append(arguments); lock.unlock()
        return AsyncThrowingStream { $0.finish() }
    }
}

/// A daemon with the recorded 1.6.1 containers plus one cluster node "dev", that answers
/// ping with the given version and applies the label filter like the real daemon
/// (a regex on the label value, a missing label reads as "").
private final class ClusterDaemon: @unchecked Sendable {
    let api: FakeTransport
    let images: FakeTransport
    let fallback = MockRunner()
    let force: Flag
    private let recorder = LabelRecorder()

    var lastFilterLabel: String? { recorder.value }

    init(version: String, forceCLI: Bool = false, running: Bool = true, pingError: APIError? = nil) {
        force = Flag(forceCLI)
        images = FakeTransport("images") { _ in .success(XPCReply()) }
        var values = APIFixtures.ping
        values["apiServerVersion"] = version
        let pingValues = values
        let containers = Self.containersWithNode()
        let recorder = self.recorder
        api = FakeTransport("apiserver") { request in
            if !running { return .failure(.serviceUnavailable(route: request.route)) }
            switch request.route {
            case APIRoute.ping:
                if let pingError { return .failure(pingError) }
                return .success(XPCReply(pingValues.mapValues { .string($0) }))
            case APIRoute.containerList:
                let filters = request.data(APIKey.listFilters).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                let ids = filters["ids"] as? [String] ?? []
                let labels = filters["labels"] as? [String: String] ?? [:]
                recorder.value = labels[APILabel.plugin]
                let kept = containers.filter { item in
                    let config = item["configuration"] as? [String: Any] ?? [:]
                    let id = config["id"] as? String ?? ""
                    if !ids.isEmpty && !ids.contains(id) { return false }
                    let have = config["labels"] as? [String: String] ?? [:]
                    for (key, pattern) in labels {
                        let value = have[key] ?? ""
                        guard let regex = try? NSRegularExpression(pattern: pattern),
                              regex.firstMatch(in: value, range: NSRange(location: 0, length: (value as NSString).length)) != nil else { return false }
                    }
                    return true
                }
                return .success(XPCReply([APIKey.containers: .data((try? JSONSerialization.data(withJSONObject: kept)) ?? Data("[]".utf8))]))
            default:
                return .success(XPCReply())
            }
        }
    }

    var settings: DirectAPISettings {
        DirectAPISettings(registryDomain: { "docker.io" }, configuredInfraImages: { [] }, sshAuthSocket: { nil }, fileExists: { _ in true })
    }

    var client: DirectAPIClient {
        DirectAPIClient(apiServer: api, imageService: images, settings: settings, statsCache: CPUSampleCache())
    }

    func routedClient(runner: MockRunner, version: SemanticVersion) -> ContainerClient {
        let api = self.client
        let flag = force
        let selector = BackendSelector(ping: { timeout in try await api.ping(timeout: timeout).version }, forceCLI: { flag.value })
        let router = ContainerBackendRouter(cli: ContainerClient(cliPath: "/usr/local/bin/container", runner: fallback).withPlatformVersion(version),
                                            api: api, selector: selector)
        return ContainerClient(cliPath: "/usr/local/bin/container", runner: runner).routed(through: router).withPlatformVersion(version)
    }

    /// The recorded list plus a stopped node named "dev", labelled like the cluster plugin does.
    static func containersWithNode() -> [[String: Any]] {
        var all = (try? JSONSerialization.jsonObject(with: Data(APIFixtures.containerList.utf8))) as? [[String: Any]] ?? []
        guard var node = all.first(where: { (($0["configuration"] as? [String: Any])?["id"] as? String) == "deck-demo-stopped" }),
              var config = node["configuration"] as? [String: Any] else { return all }
        config["id"] = "dev"
        config["labels"] = [APILabel.plugin: "cluster", KubernetesConfig.roleLabel: "control-plane,worker"]
        node["configuration"] = config
        all.append(node)
        return all
    }
}
