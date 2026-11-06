import XCTest
@testable import DeckCore

/// Replays canned Kubernetes API answers and records the requests.
final class MockKubeTransport: KubeTransport, @unchecked Sendable {
    var responses: [String: (Int, String)] = [:]
    var logLines: [String] = []
    private let lock = NSLock()
    private var recorded: [URLRequest] = []

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    /// Key: "GET /api/v1/pods".
    private func record(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(request)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        record(request)
        let key = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
        let (code, body) = responses[key] ?? (404, #"{"kind":"Status","message":"not mocked","code":404}"#)
        let response = HTTPURLResponse(url: request.url ?? URL(string: "https://x")!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (Data(body.utf8), response)
    }

    func lines(_ request: URLRequest) -> AsyncThrowingStream<String, Error> {
        record(request)
        let lines = logLines
        return AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
    }
}

final class KubernetesClusterTests: XCTestCase {

    private func client(_ runner: MockRunner) -> ContainerClient {
        ContainerClient(cliPath: "/usr/local/bin/container", runner: runner)
    }

    // MARK: - Listing

    func testClustersFromRecordedContainerList() throws {
        let containers = try ContainerOutputParser.containers(KubeFixtures.clusterContainers)
        let clusters = KubeClusterParser.clusters(from: containers)
        XCTAssertEqual(clusters.count, 1)
        let cluster = try XCTUnwrap(clusters.first)
        XCTAssertEqual(cluster.name, "deck-v2-k8s-a")
        XCTAssertEqual(cluster.state, .running)
        XCTAssertEqual(cluster.nodes.count, 1)
        let node = try XCTUnwrap(cluster.controlPlane)
        XCTAssertEqual(node.role, .controlPlaneWorker)
        XCTAssertEqual(node.cpus, 2)
        XCTAssertEqual(node.memoryBytes, 3_221_225_472)
        XCTAssertEqual(node.ipAddress, "192.168.64.61")
        XCTAssertEqual(cluster.apiServerHostPort, 6445)
        XCTAssertEqual(cluster.apiServerURL, "https://127.0.0.1:6445")
        XCTAssertEqual(node.portsText, "6445->6443")
        // The default node image is listed by digest only.
        XCTAssertNil(cluster.imageVersion)
    }

    func testClustersIgnoreOtherContainersAndGroupWorkers() {
        func node(_ id: String, role: String, state: ContainerRunState = .running) -> ContainerSummary {
            ContainerSummary(id: id, name: id, image: "docker.io/kindest/node:v1.34.11", state: state,
                             labels: [KubernetesConfig.pluginLabel: "cluster", KubernetesConfig.roleLabel: role])
        }
        let list = [
            ContainerSummary(id: "web", name: "web", image: "nginx", state: .running),
            node("dev-worker-10", role: "worker"),
            node("dev", role: "control-plane"),
            node("dev-worker-2", role: "worker", state: .stopped),
            node("gone-worker-1", role: "worker"),
            ContainerSummary(id: "fake", name: "fake", image: "x", state: .running, labels: [KubernetesConfig.pluginLabel: "machine"]),
        ]
        let clusters = KubeClusterParser.clusters(from: list)
        XCTAssertEqual(clusters.map(\.name), ["dev", "gone"])
        XCTAssertEqual(clusters[0].nodes.map(\.name), ["dev", "dev-worker-2", "dev-worker-10"])
        XCTAssertEqual(clusters[0].nodes[0].role, .controlPlane)
        XCTAssertEqual(clusters[0].workers.count, 2)
        XCTAssertEqual(clusters[0].state, .partial)
        XCTAssertEqual(clusters[0].imageVersion, "v1.34.11")
        XCTAssertEqual(clusters[1].nodes.map(\.name), ["gone-worker-1"])
        XCTAssertNil(clusters[1].controlPlane)
    }

    func testClusterStates() {
        func cluster(_ states: [ContainerRunState]) -> KubeCluster {
            KubeCluster(name: "c", nodes: states.enumerated().map { index, state in
                KubeClusterNode(name: "n\(index)", cluster: "c", role: index == 0 ? .controlPlane : .worker, state: state)
            })
        }
        XCTAssertEqual(cluster([.running, .running]).state, .running)
        XCTAssertEqual(cluster([.stopped, .stopped]).state, .stopped)
        XCTAssertEqual(cluster([.running, .stopped]).state, .partial)
        XCTAssertEqual(cluster([.stopping, .stopped]).state, .stopping)
        XCTAssertEqual(KubeCluster(name: "x", nodes: []).state, .stopped)
    }

    func testParseRecordedTable() throws {
        let clusters = KubeClusterParser.parseTable(KubeFixtures.clusterList)
        XCTAssertEqual(clusters.count, 1)
        let node = try XCTUnwrap(clusters.first?.nodes.first)
        XCTAssertEqual(node.name, "deck-v2-k8s-a")
        XCTAssertEqual(node.role, .controlPlaneWorker)
        XCTAssertEqual(node.state, .running)
        XCTAssertEqual(node.cpus, 2)
        XCTAssertEqual(node.memoryBytes, 3072 * 1_048_576)
        XCTAssertEqual(node.ipAddress, "192.168.64.61")
        XCTAssertEqual(node.ports, [PortMapping(hostPort: 6445, containerPort: 6443)])
    }

    func testParseTableWithBlankCellsAndWorkers() {
        let text = """
        CLUSTER  NODE            ROLE           STATE    CPUS  MEMORY   ADDR          PORTS
        dev      dev             control-plane  running  4     4096 MB  192.168.64.9  6446->6443
        dev      dev-worker-1    worker         stopped  4     4096 MB
        """
        let clusters = KubeClusterParser.parseTable(text)
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].nodes.count, 2)
        XCTAssertEqual(clusters[0].nodes[1].state, .stopped)
        XCTAssertNil(clusters[0].nodes[1].ipAddress)
        XCTAssertTrue(clusters[0].nodes[1].ports.isEmpty)
        XCTAssertEqual(KubeClusterParser.parseTable("CLUSTER  NODE  ROLE  STATE  CPUS  MEMORY  ADDR  PORTS").count, 0)
        XCTAssertEqual(KubeClusterParser.parseTable("garbage").count, 0)
    }

    func testListFallsBackToTableWhenContainerListFails() async throws {
        let runner = MockRunner()
        runner.responses["cluster list"] = CommandResult(exitCode: 0, stdout: KubeFixtures.clusterList)
        let clusters = try await client(runner).listClusters()
        XCTAssertEqual(clusters.map(\.name), ["deck-v2-k8s-a"])
        XCTAssertEqual(runner.calls.map { Array($0.dropFirst()) }, [["list", "--all", "--format", "json"], ["cluster", "list"]])
    }

    func testUnsupportedCLI() async {
        let runner = MockRunner()
        runner.responses["cluster --help"] = CommandResult(exitCode: 1, stdout: "", stderr: "Error: unknown command 'cluster'\nIf 'cluster' is a plugin, check that it exists")
        let supported = await client(runner).clusterSupported()
        XCTAssertFalse(supported)
        XCTAssertTrue(KubeClusterParser.isUnsupportedText("Error: unknown command 'cluster'"))
        XCTAssertFalse(KubeClusterParser.isUnsupportedText("cluster deck is not a cluster"))

        let ok = MockRunner()
        ok.responses["cluster --help"] = CommandResult(exitCode: 0, stdout: "OVERVIEW: Manage local Kubernetes development clusters (EXPERIMENTAL)")
        let yes = await client(ok).clusterSupported()
        XCTAssertTrue(yes)
    }

    // MARK: - Arguments

    func testCreateArguments() throws {
        let c = client(MockRunner())
        XCTAssertEqual(try c.createClusterArguments(KubeClusterOptions()), ["cluster", "create", "--name", "cluster-dev"])
        let full = KubeClusterOptions(
            name: "dev", nodeImage: "docker.io/kindest/node:v1.34.11", workers: 2, cni: .none,
            cpus: 4, memory: "6G", removeOnStop: true
        )
        XCTAssertEqual(try c.createClusterArguments(full), [
            "cluster", "create", "--name", "dev", "--cpus", "4", "--memory", "6G",
            "--node-image", "docker.io/kindest/node:v1.34.11", "--cni", "NONE", "--workers", "2", "--rm",
        ])
        let manifest = KubeClusterOptions(name: "c1", nodeImage: KubernetesConfig.defaultNodeImage, cni: .manifest("/tmp/calico.yaml"))
        XCTAssertEqual(try c.createClusterArguments(manifest), ["cluster", "create", "--name", "c1", "--cni", "/tmp/calico.yaml"])
        XCTAssertEqual(c.commandLine(try c.createClusterArguments(full)).prefix(30), "container cluster create --nam")
    }

    func testCreateArgumentsRefuseBadNames() async {
        let runner = MockRunner()
        let c = client(runner)
        // The name from the owner's failed cluster: the worker never matched its lowercase node name.
        let upper = KubeClusterOptions(name: "Test-Cluster-K8", workers: 1)
        XCTAssertThrowsError(try c.createClusterArguments(upper)) { error in
            XCTAssertEqual(error as? KubeClusterNameError, KubeClusterNameError(name: "Test-Cluster-K8", problem: .badCharacters))
            XCTAssertTrue(error.localizedDescription.contains("lowercase"))
            XCTAssertFalse(error.localizedDescription.contains(";"))
        }
        for bad in ["my_cluster", "my.cluster", "-dev", "dev-", "1dev", "a", String(repeating: "a", count: 52)] {
            XCTAssertThrowsError(try c.createClusterArguments(KubeClusterOptions(name: bad)), bad)
        }
        // Whitespace is trimmed and an empty name means the plugin default.
        XCTAssertEqual(try c.createClusterArguments(KubeClusterOptions(name: "  dev  ")), ["cluster", "create", "--name", "dev"])
        XCTAssertEqual(try c.createClusterArguments(KubeClusterOptions(name: " ")), ["cluster", "create", "--name", "cluster-dev"])
        // The hint builder still shows what was typed.
        XCTAssertEqual(c.createClusterHintArguments(upper), ["cluster", "create", "--name", "Test-Cluster-K8", "--workers", "1"])

        // createCluster fails before running anything.
        var thrown: Error?
        do {
            for try await _ in c.createCluster(upper) {}
        } catch {
            thrown = error
        }
        XCTAssertTrue(thrown is KubeClusterNameError)
        if let thrown { XCTAssertTrue(KubeClusterParser.explain(thrown) is KubeClusterNameError) }
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testClusterNameRules() {
        XCTAssertNil(KubernetesConfig.nameProblem("cluster-dev"))
        XCTAssertNil(KubernetesConfig.nameProblem("test-cluster-k8"))
        XCTAssertNil(KubernetesConfig.nameProblem("ab"))
        XCTAssertNil(KubernetesConfig.nameProblem("a1"))
        XCTAssertNil(KubernetesConfig.nameProblem("dev--2"))
        XCTAssertEqual(KubernetesConfig.nameProblem(""), .empty)
        XCTAssertEqual(KubernetesConfig.nameProblem("a"), .tooShort)
        XCTAssertEqual(KubernetesConfig.nameProblem("Test-Cluster-K8"), .badCharacters)
        XCTAssertEqual(KubernetesConfig.nameProblem("my_cluster"), .badCharacters)
        XCTAssertEqual(KubernetesConfig.nameProblem("my.cluster"), .badCharacters)
        XCTAssertEqual(KubernetesConfig.nameProblem("has space"), .badCharacters)
        XCTAssertEqual(KubernetesConfig.nameProblem("café"), .badCharacters)
        XCTAssertEqual(KubernetesConfig.nameProblem("-dev"), .badStart)
        XCTAssertEqual(KubernetesConfig.nameProblem("1dev"), .badStart)
        XCTAssertEqual(KubernetesConfig.nameProblem("dev-"), .badEnd)

        // The longest name still leaves room for the last worker in a 63 character DNS label.
        XCTAssertEqual(KubernetesConfig.maxNameLength, 51)
        let longest = String(repeating: "a", count: KubernetesConfig.maxNameLength)
        XCTAssertNil(KubernetesConfig.nameProblem(longest))
        XCTAssertEqual(KubernetesConfig.nameProblem(longest + "a"), .tooLong)
        XCTAssertEqual(KubernetesConfig.workerName(cluster: longest, index: KubernetesConfig.maxWorkers).count, 63)
        XCTAssertEqual(KubernetesConfig.workerName(cluster: "dev", index: 1), "dev-worker-1")

        // Messages are short and plain.
        let all: [KubernetesConfig.NameProblem] = [.empty, .tooShort, .tooLong, .badCharacters, .badStart, .badEnd]
        for problem in all {
            XCTAssertFalse(problem.message.isEmpty)
            XCTAssertFalse(problem.message.contains(";"))
            XCTAssertFalse(problem.message.contains("\u{2014}"))
        }
    }

    func testNameInputLowercasesAsYouType() {
        XCTAssertEqual(KubernetesConfig.normalizedNameInput("Test-Cluster-K8"), "test-cluster-k8")
        XCTAssertEqual(KubernetesConfig.normalizedNameInput("dev_1"), "dev_1")
        XCTAssertEqual(KubernetesConfig.normalizedNameInput(""), "")
        // Only ASCII capitals change. Other characters stay so the sheet can explain them.
        XCTAssertEqual(KubernetesConfig.nameProblem(KubernetesConfig.normalizedNameInput("ÉA")), .badCharacters)
    }

    func testCreateFailureHint() {
        let owner = "[3/5] Joining worker\nError: node Test-Cluster-K8-worker-1 did not become Ready within 360s"
        let hint = KubeClusterParser.createFailureHint(output: owner, clusterName: "Test-Cluster-K8")
        XCTAssertNotNil(hint)
        XCTAssertFalse(hint?.contains(";") ?? true)
        XCTAssertNotNil(KubeClusterParser.createFailureHint(output: "node My_Dev-worker-1 did not register within 120s", clusterName: "My_Dev"))
        // A valid name can time out for other reasons. No hint then.
        XCTAssertNil(KubeClusterParser.createFailureHint(output: "node dev-worker-1 did not become Ready within 360s", clusterName: "dev"))
        XCTAssertNil(KubeClusterParser.createFailureHint(output: "image not found", clusterName: "Test-Cluster-K8"))
    }

    func testOtherArguments() {
        let c = client(MockRunner())
        XCTAssertEqual(c.deleteClusterArguments("dev"), ["cluster", "delete", "--name", "dev"])
        XCTAssertEqual(c.loadImageArguments(cluster: "dev", image: " demo:latest "), ["cluster", "load-image", "--name", "dev", "demo:latest"])
        XCTAssertEqual(
            c.loadImageArguments(cluster: "dev", image: "demo", platform: "linux/arm64", nodes: ["dev-worker-1"]),
            ["cluster", "load-image", "--name", "dev", "--platform", "linux/arm64", "--node", "dev-worker-1", "demo"]
        )
        XCTAssertEqual(c.writeKubeconfigArguments("dev"), ["cluster", "write-config", "--name", "dev"])
        XCTAssertEqual(c.writeKubeconfigArguments("dev", path: "/tmp/x"), ["cluster", "write-config", "--name", "dev", "--kubeconfig", "/tmp/x"])
    }

    func testStartAndStopOrder() async throws {
        let cluster = KubeCluster(name: "dev", nodes: [
            KubeClusterNode(name: "dev-worker-10", cluster: "dev", role: .worker, state: .stopped),
            KubeClusterNode(name: "dev", cluster: "dev", role: .controlPlane, state: .stopped),
            KubeClusterNode(name: "dev-worker-2", cluster: "dev", role: .worker, state: .running),
        ])
        XCTAssertEqual(KubeClusterActions.startOrder(cluster).map(\.name), ["dev", "dev-worker-2", "dev-worker-10"])

        let runner = MockRunner()
        for id in ["dev", "dev-worker-2", "dev-worker-10"] {
            runner.responses["start \(id)"] = CommandResult(exitCode: 0, stdout: id)
            runner.responses["stop \(id)"] = CommandResult(exitCode: 0, stdout: id)
        }
        try await client(runner).startCluster(cluster)
        XCTAssertEqual(runner.calls.map { $0.dropFirst().joined(separator: " ") }, ["start dev", "start dev-worker-10"])

        let stopRunner = MockRunner()
        stopRunner.responses["stop dev-worker-2"] = CommandResult(exitCode: 0, stdout: "")
        try await client(stopRunner).stopCluster(cluster)
        XCTAssertEqual(stopRunner.calls.map { $0.dropFirst().joined(separator: " ") }, ["stop dev-worker-2"])
    }

    func testDeleteExplainsErrors() async {
        let runner = MockRunner()
        runner.responses["cluster delete --name web"] = CommandResult(exitCode: 1, stdout: "", stderr: "Error: web is not a cluster")
        do {
            try await client(runner).deleteCluster("web")
            XCTFail("should throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not a cluster made by the cluster plugin"))
        }
    }

    // MARK: - Config and options

    func testVersions() {
        XCTAssertEqual(KubernetesConfig.version(fromNodeImage: KubernetesConfig.defaultNodeImage), "v1.35.5")
        XCTAssertEqual(KubernetesConfig.version(fromNodeImage: "kindest/node:v1.33.12"), "v1.33.12")
        XCTAssertNil(KubernetesConfig.version(fromNodeImage: "docker.io/kindest/node@sha256:ce97"))
        XCTAssertNil(KubernetesConfig.version(fromNodeImage: "localhost:5000/node"))
        XCTAssertEqual(KubernetesConfig.version(fromNodeImage: "localhost:5000/node:v1"), "v1")
        XCTAssertEqual(KubernetesConfig.nodeImage(forVersion: "v1.35.5"), KubernetesConfig.defaultNodeImage)
        XCTAssertEqual(KubernetesConfig.nodeImage(forVersion: "1.34.11"), "docker.io/kindest/node:v1.34.11")
        XCTAssertEqual(KubernetesConfig.versions.first, KubernetesConfig.defaultVersion)
    }

    func testDefaultsAndNames() {
        XCTAssertEqual(KubernetesConfig.defaultCPUs(processors: 10), 2)
        XCTAssertEqual(KubernetesConfig.defaultCPUs(processors: 16), 4)
        XCTAssertEqual(KubernetesConfig.defaultMemoryGB(physicalMemory: 32 * 1_073_741_824), 8)
        XCTAssertEqual(KubernetesConfig.defaultMemoryGB(physicalMemory: 4 * 1_073_741_824), 2)
        XCTAssertTrue(KubernetesConfig.isValidName("cluster-dev"))
        XCTAssertFalse(KubernetesConfig.isValidName("a"))
        XCTAssertFalse(KubernetesConfig.isValidName("Cluster-Dev"))
        XCTAssertFalse(KubernetesConfig.isValidName("-bad"))
        XCTAssertFalse(KubernetesConfig.isValidName("has space"))
        XCTAssertFalse(KubernetesConfig.isValidName(""))
    }

    func testRecreateOptions() {
        let cluster = KubeCluster(name: "dev", nodes: [
            KubeClusterNode(name: "dev", cluster: "dev", role: .controlPlane, state: .stopped, cpus: 4, memoryBytes: 4 * 1_073_741_824, image: "docker.io/kindest/node@sha256:abc"),
            KubeClusterNode(name: "dev-worker-1", cluster: "dev", role: .worker, state: .stopped),
        ])
        let guessed = KubeClusterOptions.recreate(cluster, saved: nil)
        XCTAssertEqual(guessed.name, "dev")
        XCTAssertEqual(guessed.workers, 1)
        XCTAssertEqual(guessed.cpus, 4)
        XCTAssertEqual(guessed.memory, "4096M")
        XCTAssertEqual(guessed.nodeImage, "")
        XCTAssertEqual(guessed.cni, .kindnet)

        let saved = KubeClusterOptions(name: "dev", nodeImage: "docker.io/kindest/node:v1.34.11", workers: 3, cni: .none, cpus: 2, memory: "3G")
        let fromSaved = KubeClusterOptions.recreate(cluster, saved: saved)
        XCTAssertEqual(fromSaved.cni, .none)
        XCTAssertEqual(fromSaved.workers, 1)
        XCTAssertEqual(fromSaved.nodeImage, "docker.io/kindest/node:v1.34.11")
    }

    func testRecipesRoundTrip() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("deck-k8s-test-\(UUID().uuidString)/clusters.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let recipes = KubeClusterRecipes(file: file)
        XCTAssertNil(recipes.recipe(for: "dev"))
        recipes.save(KubeClusterOptions(name: "dev", cni: .manifest("/tmp/cni.yaml"), cpus: 2))
        recipes.save(KubeClusterOptions(name: "other"))
        XCTAssertEqual(recipes.recipe(for: "dev")?.cni, .manifest("/tmp/cni.yaml"))
        recipes.remove("dev")
        XCTAssertNil(recipes.recipe(for: "dev"))
        XCTAssertNotNil(recipes.recipe(for: "other"))
    }

    // MARK: - Tools

    func testToolDetection() {
        let tools = KubeTools.detect(
            home: "/Users/me", pathEnv: "/custom/bin",
            isExecutable: { ["/opt/homebrew/bin/kubectl", "/custom/bin/k9s"].contains($0) },
            exists: { $0 == "/Users/me/Applications/Freelens.app" }
        )
        XCTAssertEqual(tools.kubectl, "/opt/homebrew/bin/kubectl")
        XCTAssertEqual(tools.k9s, "/custom/bin/k9s")
        XCTAssertNil(tools.helm)
        XCTAssertEqual(tools.lensName, "Freelens")
        XCTAssertEqual(KubeTools.detect(pathEnv: "", isExecutable: { _ in false }, exists: { _ in false }), KubeTools())
    }

    func testToolCommands() {
        XCTAssertEqual(KubeTools.k9sCommand(k9s: "/opt/homebrew/bin/k9s", kubeconfig: "/Users/me/Library/Application Support/x/dev.kubeconfig", context: "dev"),
                       "/opt/homebrew/bin/k9s --kubeconfig '/Users/me/Library/Application Support/x/dev.kubeconfig' --context dev")
        XCTAssertEqual(KubeTools.kubectlHint(kubeconfig: "~/.kube/dev.kubeconfig", context: "dev"),
                       "kubectl --kubeconfig ~/.kube/dev.kubeconfig --context dev get pods -A")
        XCTAssertTrue(KubeTools.kubectlShellCommand(kubectl: "/k", kubeconfig: "/a b", context: "it's").contains("export KUBECONFIG='/a b'"))
        XCTAssertTrue(KubeTools.kubectlShellCommand(kubectl: "/k", kubeconfig: "/a", context: "it's").contains(#"'it'\''s'"#))
        XCTAssertEqual(KubeTools.applyArguments(kubeconfig: "/k", context: "dev", manifest: "/m.yaml"),
                       ["--kubeconfig", "/k", "--context", "dev", "apply", "-f", "/m.yaml"])
        XCTAssertEqual(KubeTools.bundledKindnetManifest(cliPath: "/usr/local/bin/container", exists: { $0.hasPrefix("/usr/local/libexec") }),
                       "/usr/local/libexec/container/plugins/cluster/resources/kindnet.yaml")
        XCTAssertNil(KubeTools.bundledKindnetManifest(cliPath: "/usr/local/bin/container", exists: { _ in false }))
    }

    // MARK: - Port forward

    func testPortForwardArgumentsAndParsing() {
        XCTAssertEqual(
            KubePortForwarder.arguments(kubeconfig: "/k", context: "dev", namespace: "default", kind: "service", name: "web", remotePort: 80, localPort: 0),
            ["--kubeconfig", "/k", "--context", "dev", "--namespace", "default", "port-forward", "--address", "127.0.0.1", "svc/web", ":80"]
        )
        XCTAssertEqual(
            KubePortForwarder.arguments(kubeconfig: "/k", context: "dev", namespace: "ns", kind: "pod", name: "p", remotePort: 8080, localPort: 9000).suffix(2),
            ["pod/p", "9000:8080"]
        )
        XCTAssertEqual(KubePortForwarder.localPort(fromLine: "Forwarding from 127.0.0.1:55078 -> 80"), 55078)
        XCTAssertEqual(KubePortForwarder.localPort(fromLine: "Forwarding from [::1]:8080 -> 8080"), 8080)
        XCTAssertNil(KubePortForwarder.localPort(fromLine: "Handling connection for 55078"))
        XCTAssertEqual(KubePortForwarder.friendly("Unable to listen on port 80: bind: address already in use"), "That port is already in use on this Mac.")
    }

    func testPortForwardWithFakeKubectl() throws {
        // A stand in for kubectl that prints what kubectl prints, then waits.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("deck-k8s-pf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("kubectl")
        try "#!/bin/sh\necho 'Forwarding from 127.0.0.1:43210 -> 80'\nexec sleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: script.path)
        let failing = folder.appendingPathComponent("kubectl-fail")
        try "#!/bin/sh\necho 'error: unable to forward port because pod is not running'\nexit 1\n".write(to: failing, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: failing.path)

        let forwarder = KubePortForwarder()
        let id = forwarder.start(kubectl: script.path, kubeconfig: "/k", context: "dev", cluster: "dev", namespace: "default", kind: "service", name: "web", remotePort: 80)
        let bad = forwarder.start(kubectl: failing.path, kubeconfig: "/k", context: "dev", cluster: "dev", namespace: "default", kind: "pod", name: "p", remotePort: 80)
        try wait(timeout: 5) { forwarder.all.first(where: { $0.id == id })?.state == .running }
        XCTAssertEqual(forwarder.all.first(where: { $0.id == id })?.localURL, "http://127.0.0.1:43210")
        try wait(timeout: 5) {
            if case .failed = forwarder.all.first(where: { $0.id == bad })?.state { return true }
            return false
        }
        if case .failed(let message) = forwarder.all.first(where: { $0.id == bad })?.state {
            XCTAssertTrue(message.contains("unable to forward"))
        }
        forwarder.stopAll(cluster: "dev")
        try wait(timeout: 5) { forwarder.all.first(where: { $0.id == id })?.state == .stopped }
        forwarder.remove(id)
        XCTAssertEqual(forwarder.all.map(\.id), [bad])
    }

    private func wait(timeout: TimeInterval, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw XCTSkip("timed out") }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }
}

final class KubernetesAPITests: XCTestCase {

    // MARK: - Parsing recorded API output

    func testNodesWaitingForCNI() throws {
        let nodes = try KubeParser.nodes(Data(KubeFixtures.nodesNotReady.utf8))
        let node = try XCTUnwrap(nodes.first)
        XCTAssertEqual(node.name, "deck-v2-k8s-a")
        XCTAssertEqual(node.ready, false)
        XCTAssertTrue(node.waitingForCNI)
        XCTAssertEqual(node.statusText, "Waiting for CNI")
        XCTAssertEqual(node.roles, ["control-plane"])
        XCTAssertEqual(node.kubeletVersion, "v1.35.5")
        XCTAssertEqual(node.internalIP, "192.168.64.61")
    }

    func testReadyNodeIsNotWaiting() {
        let node = KubeNodeStatus(name: "n", ready: true, reason: "KubeletReady", message: "kubelet is posting ready status", roles: [])
        XCTAssertFalse(node.waitingForCNI)
        XCTAssertEqual(node.statusText, "Ready")
        let other = KubeNodeStatus(name: "n", ready: false, reason: "KubeletNotReady", message: "PLEG is not healthy", roles: [])
        XCTAssertFalse(other.waitingForCNI)
        XCTAssertEqual(other.statusText, "Not ready")
    }

    func testNamespaces() throws {
        let list = try KubeParser.namespaces(Data(KubeFixtures.namespaces.utf8))
        XCTAssertEqual(list.map(\.name), ["default", "kube-node-lease", "kube-public", "kube-system"])
        XCTAssertEqual(list.first?.phase, "Active")
        XCTAssertNotNil(list.first?.createdAt)
    }

    func testPendingPods() throws {
        let pods = try KubeParser.pods(Data(KubeFixtures.podsPending.utf8))
        XCTAssertEqual(pods.count, 2)
        let pod = pods[0]
        XCTAssertEqual(pod.namespace, "kube-system")
        XCTAssertEqual(pod.status, "Pending")
        XCTAssertEqual(pod.health, .waiting)
        XCTAssertEqual(pod.ownerKind, "ReplicaSet")
        XCTAssertEqual(pod.ports.map(\.port), [53, 53, 9153, 8080, 8181])
        XCTAssertTrue(pod.message?.contains("untolerated taint") ?? false)
    }

    func testRunningAndCrashingPods() throws {
        let running = try KubeParser.pods(Data(KubeFixtures.podsRunning.utf8))
        let etcd = try XCTUnwrap(running.first(where: { $0.name.hasPrefix("etcd") }))
        XCTAssertEqual(etcd.status, "Running")
        XCTAssertEqual(etcd.readyText, "1/1")
        XCTAssertEqual(etcd.health, .good)

        let pods = try KubeParser.pods(Data(KubeFixtures.podsDefault.utf8))
        let crashy = try XCTUnwrap(pods.first(where: { $0.name == "crashy" }))
        XCTAssertEqual(crashy.status, "CrashLoopBackOff")
        XCTAssertEqual(crashy.health, .bad)
        XCTAssertGreaterThan(crashy.restarts, 0)
        XCTAssertNil(crashy.ownerKind)
        let web = try XCTUnwrap(pods.first(where: { $0.name.hasPrefix("web-") }))
        XCTAssertEqual(web.status, "Running")
        XCTAssertEqual(web.ownerKind, "ReplicaSet")
        XCTAssertEqual(web.containers, ["nginx"])
        XCTAssertNotNil(web.podIP)
    }

    func testPodStatusRules() throws {
        func status(_ json: String) throws -> String {
            try XCTUnwrap(KubeParser.pods(Data(#"{"items":[\#(json)]}"#.utf8)).first).status
        }
        XCTAssertEqual(try status(#"{"metadata":{"name":"a","deletionTimestamp":"2026-11-05T10:00:00Z"},"status":{"phase":"Running"}}"#), "Terminating")
        XCTAssertEqual(try status(#"{"metadata":{"name":"a"},"status":{"phase":"Succeeded","containerStatuses":[{"name":"c","state":{"terminated":{"reason":"Completed","exitCode":0}}}]}}"#), "Completed")
        XCTAssertEqual(try status(#"{"metadata":{"name":"a"},"spec":{"initContainers":[{"name":"i"}]},"status":{"phase":"Pending","initContainerStatuses":[{"name":"i","state":{"running":{}}}]}}"#), "Init:0/1")
        XCTAssertEqual(try status(#"{"metadata":{"name":"a"},"status":{"phase":"Pending","containerStatuses":[{"name":"c","state":{"waiting":{"reason":"ContainerCreating"}}}]}}"#), "ContainerCreating")
        XCTAssertEqual(try status(#"{"metadata":{"name":"a"},"status":{"phase":"Failed","reason":"Evicted"}}"#), "Evicted")
        // Unknown and odd objects never break the list.
        XCTAssertEqual(try KubeParser.pods(Data(#"{"items":[{"metadata":{}},{"weird":1}]}"#.utf8)).count, 0)
        XCTAssertThrowsError(try KubeParser.pods(Data("not json".utf8)))
    }

    func testDeploymentsServicesEvents() throws {
        let deployments = try KubeParser.deployments(Data(KubeFixtures.deployments.utf8))
        let coredns = try XCTUnwrap(deployments.first(where: { $0.name == "coredns" }))
        XCTAssertEqual(coredns.namespace, "kube-system")
        XCTAssertEqual(coredns.desired, 2)
        XCTAssertEqual(coredns.images, ["registry.k8s.io/coredns/coredns:v1.13.1"])

        let services = try KubeParser.services(Data(KubeFixtures.services.utf8))
        let dns = try XCTUnwrap(services.first(where: { $0.name == "kube-dns" }))
        XCTAssertEqual(dns.type, "ClusterIP")
        XCTAssertEqual(dns.clusterIP, "10.96.0.10")
        XCTAssertEqual(dns.portsText, "53/UDP, 53/TCP, 9153/TCP")
        XCTAssertEqual(dns.ports.first?.targetPort, "53")
        let api = try XCTUnwrap(services.first(where: { $0.name == "kubernetes" }))
        XCTAssertEqual(api.ports.first?.port, 443)

        let events = try KubeParser.events(Data(KubeFixtures.events.utf8))
        XCTAssertEqual(events.count, 3)
        XCTAssertTrue(events.contains(where: { $0.isWarning && $0.reason == "InvalidDiskCapacity" }))
        XCTAssertEqual(events.first(where: { $0.reason == "Starting" })?.object, "Node/deck-v2-k8s-a")
        // Newest first.
        XCTAssertEqual(events.map(\.lastSeen), events.map(\.lastSeen).sorted { ($0 ?? .distantPast) > ($1 ?? .distantPast) })
        XCTAssertEqual(KubeParser.version(Data(KubeFixtures.version.utf8)), "v1.35.5")
    }

    func testServicePortText() {
        XCTAssertEqual(KubeServicePort(port: 80, nodePort: 30080, proto: "TCP").text, "80:30080/TCP")
        XCTAssertEqual(KubeService(namespace: "d", name: "s", type: "ClusterIP", ports: [], selector: [:]).portsText, "-")
    }

    // MARK: - Requests

    private func api(_ transport: MockKubeTransport, token: String? = nil) -> KubeAPIClient {
        KubeAPIClient(server: URL(string: "https://127.0.0.1:6445")!, token: token, transport: transport)
    }

    func testReadRequests() async throws {
        let transport = MockKubeTransport()
        transport.responses["GET /api/v1/pods"] = (200, KubeFixtures.podsRunning)
        transport.responses["GET /api/v1/namespaces/default/pods"] = (200, KubeFixtures.podsDefault)
        transport.responses["GET /apis/apps/v1/namespaces/kube-system/deployments"] = (200, KubeFixtures.deployments)
        transport.responses["GET /api/v1/nodes"] = (200, KubeFixtures.nodesNotReady)
        transport.responses["GET /version"] = (200, KubeFixtures.version)
        let client = api(transport, token: "abc")
        let all = try await client.pods()
        let defaults = try await client.pods(namespace: "default")
        _ = try await client.deployments(namespace: "kube-system")
        let nodes = try await client.nodes()
        let version = try await client.version()
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(defaults.count, 3)
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(version, "v1.35.5")
        let first = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(first.value(forHTTPHeaderField: "Authorization"), "Bearer abc")
        XCTAssertEqual(first.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(first.url?.absoluteString, "https://127.0.0.1:6445/api/v1/pods")
    }

    func testDeleteAndRestart() async throws {
        let transport = MockKubeTransport()
        transport.responses["DELETE /api/v1/namespaces/default/pods/web-1"] = (200, "{}")
        transport.responses["PATCH /apis/apps/v1/namespaces/default/deployments/web"] = (200, "{}")
        let client = api(transport)
        try await client.deletePod(namespace: "default", name: "web-1")
        let date = Date(timeIntervalSince1970: 1_793_900_000)
        try await client.restartDeployment(namespace: "default", name: "web", at: date)
        let patch = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(patch.httpMethod, "PATCH")
        XCTAssertEqual(patch.value(forHTTPHeaderField: "Content-Type"), "application/strategic-merge-patch+json")
        let body = String(decoding: patch.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains(#""kubectl.kubernetes.io/restartedAt":"2026-11-05T"#), body)
        XCTAssertNil(transport.requests.first?.value(forHTTPHeaderField: "Authorization"))
    }

    func testErrorsCarryTheStatusMessage() async {
        let transport = MockKubeTransport()
        transport.responses["GET /api/v1/pods"] = (403, #"{"kind":"Status","message":"pods is forbidden: User \"system:anonymous\" cannot list resource \"pods\"","code":403}"#)
        do {
            _ = try await api(transport).pods()
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? KubeAPIError, .http(403, #"pods is forbidden: User "system:anonymous" cannot list resource "pods""#))
            XCTAssertTrue(error.localizedDescription.hasPrefix("Not allowed."))
        }
    }

    func testLogRequest() async throws {
        let transport = MockKubeTransport()
        transport.logLines = ["one", "two"]
        let client = api(transport)
        var lines: [String] = []
        for try await line in client.podLogs(namespace: "default", pod: "web-1", container: "nginx", follow: true, tail: 100) {
            lines.append(line)
        }
        XCTAssertEqual(lines, ["one", "two"])
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/api/v1/namespaces/default/pods/web-1/log")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first(where: { $0.name == "container" })?.value, "nginx")
        XCTAssertEqual(query.first(where: { $0.name == "follow" })?.value, "true")
        XCTAssertEqual(query.first(where: { $0.name == "tailLines" })?.value, "100")
        // The API refuses text/plain (406), so accept anything.
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "*/*")
    }

    func testServerWithPathPrefix() {
        let client = KubeAPIClient(server: URL(string: "https://proxy.test/k8s/")!, transport: MockKubeTransport())
        XCTAssertEqual(client.request("/api/v1/pods").url?.absoluteString, "https://proxy.test/k8s/api/v1/pods")
        XCTAssertEqual(KubeAPIClient.path("/api/v1", "pods", namespace: nil), "/api/v1/pods")
        XCTAssertEqual(KubeAPIClient.path("/api/v1", "pods", namespace: "a/b"), "/api/v1/namespaces/a%2Fb/pods")
    }
}

final class KubeConfigTests: XCTestCase {

    /// Makes a throwaway CA, client cert and key with /usr/bin/openssl.
    private func makeCertificates() throws -> (ca: String, cert: String, key: String) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("deck-k8s-certs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func run(_ args: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            process.arguments = args
            process.currentDirectoryURL = folder
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw XCTSkip("openssl failed: \(args)") }
        }
        try run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "ca.key", "-out", "ca.crt", "-days", "2", "-subj", "/CN=kubernetes"])
        try run(["req", "-newkey", "rsa:2048", "-nodes", "-keyout", "client.key", "-out", "client.csr", "-subj", "/O=kubeadm:cluster-admins/CN=kubernetes-admin"])
        try run(["x509", "-req", "-in", "client.csr", "-CA", "ca.crt", "-CAkey", "ca.key", "-CAcreateserial", "-out", "client.crt", "-days", "2"])
        func b64(_ name: String) throws -> String { try Data(contentsOf: folder.appendingPathComponent(name)).base64EncodedString() }
        return (try b64("ca.crt"), try b64("client.crt"), try b64("client.key"))
    }

    /// Same shape `container cluster write-config` writes (no current-context).
    private func kubeconfig(ca: String, cert: String, key: String, current: Bool = false) -> String {
        """
        apiVersion: v1
        kind: Config
        clusters:
        - name: dev
          cluster:
            server: https://127.0.0.1:6445
            certificate-authority-data: \(ca)
        contexts:
        - name: dev
          context:
            cluster: dev
            user: dev
        users:
        - name: dev
          user:
            client-certificate-data: \(cert)
            client-key-data: \(key)
        \(current ? "current-context: dev" : "")
        """
    }

    func testParseAndBuildIdentityInMemory() async throws {
        let certs = try makeCertificates()
        let file = try KubeConfigFile.parse(kubeconfig(ca: certs.ca, cert: certs.cert, key: certs.key))
        XCTAssertNil(file.currentContext)
        XCTAssertEqual(file.contexts, ["dev"])
        let credentials = try XCTUnwrap(file.credentials())
        XCTAssertEqual(credentials.server.absoluteString, "https://127.0.0.1:6445")
        XCTAssertNotNil(credentials.certificateAuthority)
        XCTAssertNil(credentials.token)
        XCTAssertNil(file.credentials(context: "missing"))

        let tls = try await KubeTLS.make(credentials)
        XCTAssertNotNil(tls.anchor)
        let identity = try XCTUnwrap(tls.identity)
        var certificate: SecCertificate?
        XCTAssertEqual(SecIdentityCopyCertificate(identity, &certificate), errSecSuccess)
        XCTAssertEqual(certificate.flatMap { SecCertificateCopySubjectSummary($0) as String? }, "kubernetes-admin")
    }

    func testPKCS12Arguments() {
        let args = KubeTLS.pkcs12Arguments(certificate: "/c", key: "/k", passFile: "/p", output: "/o")
        XCTAssertEqual(args.prefix(2), ["pkcs12", "-export"])
        XCTAssertTrue(args.contains("file:/p"))
        XCTAssertFalse(args.contains(where: { $0.hasPrefix("pass:") }), "the passphrase never goes on the command line")
    }

    func testBadKubeconfigs() {
        XCTAssertThrowsError(try KubeConfigFile.parse("::: not yaml"))
        XCTAssertThrowsError(try KubeConfigFile.parse("apiVersion: v1\nkind: Config\nclusters: []\n"))
        let token = try? KubeConfigFile.parse("""
        clusters:
        - name: c
          cluster: {server: "https://h:1", insecure-skip-tls-verify: true}
        users:
        - name: u
          user: {token: secret}
        contexts:
        - name: x
          context: {cluster: c, user: u, namespace: apps}
        current-context: x
        """)
        XCTAssertEqual(token?.credentials()?.token, "secret")
        XCTAssertEqual(token?.credentials()?.namespace, "apps")
        XCTAssertEqual(token?.credentials()?.insecureSkipTLSVerify, true)
    }

    func testCurrentContextEditing() throws {
        let text = "apiVersion: v1\nclusters: []\n"
        XCTAssertNil(KubeConfigFile.currentContext(inText: text))
        let added = KubeConfigFile.withCurrentContext("dev", text: text)
        XCTAssertEqual(KubeConfigFile.currentContext(inText: added), "dev")
        let replaced = KubeConfigFile.withCurrentContext("prod", text: added)
        XCTAssertEqual(replaced.components(separatedBy: "current-context:").count, 2)
        XCTAssertEqual(KubeConfigFile.currentContext(inText: replaced), "prod")
        XCTAssertNil(KubeConfigFile.currentContext(inText: "current-context: \"\"\n"))

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("deck-k8s-\(UUID().uuidString).kubeconfig")
        defer { try? FileManager.default.removeItem(at: file) }
        try text.write(to: file, atomically: true, encoding: .utf8)
        KubeConfigFile.setCurrentContextIfMissing("dev", in: file)
        KubeConfigFile.setCurrentContextIfMissing("other", in: file)
        XCTAssertEqual(KubeConfigFile.currentContext(inText: try String(contentsOf: file, encoding: .utf8)), "dev")
        KubeConfigFile.makePrivate(file)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testPEMBlocks() {
        let pem = Data("-----BEGIN CERTIFICATE-----\nAAEC\n-----END CERTIFICATE-----\n-----BEGIN RSA PRIVATE KEY-----\nAwQF\n-----END RSA PRIVATE KEY-----\n".utf8)
        XCTAssertEqual(PEM.firstBlock(in: pem, label: "CERTIFICATE"), Data([0, 1, 2]))
        XCTAssertEqual(PEM.firstBlock(in: pem, label: "RSA PRIVATE KEY"), Data([3, 4, 5]))
        XCTAssertNil(PEM.firstBlock(in: pem, label: "EC PRIVATE KEY"))
    }
}
