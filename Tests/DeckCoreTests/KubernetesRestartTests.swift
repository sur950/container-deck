import XCTest
@testable import DeckCore

// The repair after a cluster restart, with probe output recorded from real clusters
// (container 1.6.1, kindest/node v1.35.5) on 6 Nov 2026.

enum KubeRestartFixtures {
    /// Made with kindnet, stopped and started. The node moved from .114 to .115.
    /// The node looks Ready (old CNI config on disk) but kube-proxy still dials the old IP.
    static let kindnetAfterRestart = """
    deck-probe=1
    node_ip=192.168.64.115
    ip_forward=1
    mss=0
    cni_files=10-kindnet.conflist,
    kubelet_server=https://192.168.64.115:6443
    api_ready=ok
    kube_proxy_server=https://192.168.64.114:6443
    cluster_info_server=https://192.168.64.114:6443
    kindnet=daemonset.apps/kindnet
    """

    /// Made with CNI none, restarted (.112 to .113), before kindnet was applied.
    static let noCNIAfterRestart = """
    deck-probe=1
    node_ip=192.168.64.113
    ip_forward=0
    mss=0
    cni_files=
    kubelet_server=https://192.168.64.113:6443
    api_ready=ok
    kube_proxy_server=https://192.168.64.112:6443
    cluster_info_server=https://192.168.64.112:6443
    kindnet=
    """

    /// The same cluster while the API server is still coming up.
    static let apiStarting = """
    deck-probe=1
    node_ip=192.168.64.113
    ip_forward=0
    mss=0
    cni_files=
    kubelet_server=https://192.168.64.113:6443
    api_ready=
    kube_proxy_server=
    cluster_info_server=
    kindnet=
    """

    /// A freshly made cluster: nothing to fix.
    static let healthy = """
    deck-probe=1
    node_ip=192.168.64.116
    ip_forward=1
    mss=1
    cni_files=10-kindnet.conflist,
    kubelet_server=https://192.168.64.116:6443
    api_ready=ok
    kube_proxy_server=https://192.168.64.116:6443
    cluster_info_server=https://192.168.64.116:6443
    kindnet=daemonset.apps/kindnet
    """

    /// Control plane of a cluster with one worker, after a restart (.116 to .118).
    static let controlPlaneWithWorkerAfterRestart = """
    deck-probe=1
    node_ip=192.168.64.118
    ip_forward=1
    mss=0
    cni_files=10-kindnet.conflist,
    kubelet_server=https://192.168.64.118:6443
    api_ready=ok
    kube_proxy_server=https://192.168.64.116:6443
    cluster_info_server=https://192.168.64.116:6443
    kindnet=daemonset.apps/kindnet
    """

    /// Its worker: the kubelet still dials the control plane's old IP.
    static let workerAfterRestart = """
    deck-probe=1
    node_ip=192.168.64.119
    ip_forward=0
    mss=0
    cni_files=10-kindnet.conflist,
    kubelet_server=https://192.168.64.116:6443
    """
}

final class KubernetesRestartTests: XCTestCase {

    func testParseRecordedProbes() throws {
        let broken = try XCTUnwrap(KubeRestartRepair.parseProbe(KubeRestartFixtures.kindnetAfterRestart))
        XCTAssertEqual(broken.nodeIP, "192.168.64.115")
        XCTAssertEqual(broken.ipForward, true)
        XCTAssertEqual(broken.mssClamp, false)
        XCTAssertEqual(broken.cniFiles, ["10-kindnet.conflist"])
        XCTAssertTrue(broken.apiReady)
        XCTAssertEqual(broken.kubeProxyServer, "https://192.168.64.114:6443")
        XCTAssertEqual(broken.clusterInfoServer, "https://192.168.64.114:6443")
        XCTAssertTrue(broken.hasKindnet)
        XCTAssertEqual(broken.kubeletServer, "https://192.168.64.115:6443")

        let none = try XCTUnwrap(KubeRestartRepair.parseProbe(KubeRestartFixtures.noCNIAfterRestart))
        XCTAssertEqual(none.ipForward, false)
        XCTAssertEqual(none.cniFiles, [])
        XCTAssertFalse(none.hasKindnet)

        let starting = try XCTUnwrap(KubeRestartRepair.parseProbe(KubeRestartFixtures.apiStarting))
        XCTAssertFalse(starting.apiReady)
        XCTAssertNil(starting.kubeProxyServer)

        let worker = try XCTUnwrap(KubeRestartRepair.parseProbe(KubeRestartFixtures.workerAfterRestart))
        XCTAssertEqual(worker.nodeIP, "192.168.64.119")
        XCTAssertEqual(worker.kubeletServer, "https://192.168.64.116:6443")
        XCTAssertFalse(worker.apiReady)
        XCTAssertNil(worker.kubeProxyServer)
    }

    func testParseRejectsOtherOutput() {
        XCTAssertNil(KubeRestartRepair.parseProbe(""))
        XCTAssertNil(KubeRestartRepair.parseProbe("Error: container deck-x is not running"))
        XCTAssertNil(KubeRestartRepair.parseProbe("node_ip=1.2.3.4"))
    }

    func testPlanForKindnetClusterAfterRestart() throws {
        let probe = try XCTUnwrap(KubeRestartRepair.parseProbe(KubeRestartFixtures.kindnetAfterRestart))
        let steps = KubeRestartRepair.plan(controlPlane: "deck-k8s-kn-a", address: "192.168.64.115", controlPlaneProbe: probe)
        XCTAssertEqual(steps, [
            .nodeNetwork(node: "deck-k8s-kn-a"),
            .kubeProxyServer(from: "https://192.168.64.114:6443", to: "https://192.168.64.115:6443"),
            .clusterInfoServer(from: "https://192.168.64.114:6443", to: "https://192.168.64.115:6443"),
            .restartNetworkPods(kindnet: true),
        ])
        let report = KubeRepairReport(steps: steps, address: "192.168.64.115")
        XCTAssertTrue(report.fixedAddresses)
        XCTAssertEqual(report.summary, "The node got a new address. Network settings were updated.")
    }

    func testPlanForNoCNIClusterAfterRestart() throws {
        let probe = try XCTUnwrap(KubeRestartRepair.parseProbe(KubeRestartFixtures.noCNIAfterRestart))
        let steps = KubeRestartRepair.plan(controlPlane: "deck-k8s-cni-a", address: "192.168.64.113", controlPlaneProbe: probe)
        XCTAssertEqual(steps.last, .restartNetworkPods(kindnet: false))
        XCTAssertTrue(steps.contains(.kubeProxyServer(from: "https://192.168.64.112:6443", to: "https://192.168.64.113:6443")))
    }

    func testHealthyClusterNeedsNothing() throws {
        let probe = try XCTUnwrap(KubeRestartRepair.parseProbe(KubeRestartFixtures.healthy))
        let steps = KubeRestartRepair.plan(controlPlane: "deck-k8s-kn-b", address: "192.168.64.116", controlPlaneProbe: probe)
        XCTAssertEqual(steps, [])
        XCTAssertEqual(KubeRepairReport(steps: steps).summary, "Nothing needed a fix.")
    }

    func testAPIStillStartingOnlyFixesTheNode() throws {
        let probe = try XCTUnwrap(KubeRestartRepair.parseProbe(KubeRestartFixtures.apiStarting))
        let steps = KubeRestartRepair.plan(controlPlane: "cp", address: "192.168.64.113", controlPlaneProbe: probe)
        XCTAssertEqual(steps, [.nodeNetwork(node: "cp")])
    }

    func testWorkerKubeletIsPointedAtTheNewAddress() throws {
        let control = try XCTUnwrap(KubeRestartRepair.parseProbe(KubeRestartFixtures.controlPlaneWithWorkerAfterRestart))
        let worker = try XCTUnwrap(KubeRestartRepair.parseProbe(KubeRestartFixtures.workerAfterRestart))
        let steps = KubeRestartRepair.plan(
            controlPlane: "deck-k8s-w", address: "192.168.64.118", controlPlaneProbe: control,
            workers: [(name: "deck-k8s-w-worker-1", probe: worker)]
        )
        let old = "https://192.168.64.116:6443", new = "https://192.168.64.118:6443"
        XCTAssertEqual(steps, [
            .nodeNetwork(node: "deck-k8s-w"),
            .nodeNetwork(node: "deck-k8s-w-worker-1"),
            .kubeProxyServer(from: old, to: new),
            .clusterInfoServer(from: old, to: new),
            .workerKubelet(node: "deck-k8s-w-worker-1", from: old, to: new),
            .restartNetworkPods(kindnet: true),
        ])
        XCTAssertEqual(KubeRestartRepair.node(for: steps[4], controlPlane: "deck-k8s-w"), "deck-k8s-w-worker-1")
        XCTAssertEqual(KubeRestartRepair.node(for: .restartNetworkPods(kindnet: true), controlPlane: "deck-k8s-w"), "deck-k8s-w")
    }

    func testAddresses() {
        XCTAssertEqual(KubeRestartRepair.serverURL("192.168.64.5"), "https://192.168.64.5:6443")
        XCTAssertEqual(KubeRestartRepair.serverURL("fd00::5"), "https://[fd00::5]:6443")
        XCTAssertEqual(KubeRestartRepair.bareAddress("192.168.64.5/24"), "192.168.64.5")
        XCTAssertEqual(KubeRestartRepair.bareAddress("192.168.64.5"), "192.168.64.5")
        XCTAssertNil(KubeRestartRepair.bareAddress(""))
        XCTAssertNil(KubeRestartRepair.bareAddress(nil))
    }

    func testScripts() {
        let proxy = KubeRestartRepair.script(for: .kubeProxyServer(from: "https://1.1.1.1:6443", to: "https://192.168.64.115:6443"))
        XCTAssertTrue(proxy.contains("get configmap kube-proxy -o yaml"))
        XCTAssertTrue(proxy.contains("s#server: https://[^ ]*:6443#server: https://192.168.64.115:6443#"))
        XCTAssertTrue(proxy.contains("replace -f -"))
        XCTAssertTrue(proxy.hasPrefix("set -e"))

        let restart = KubeRestartRepair.script(for: .restartNetworkPods(kindnet: true))
        XCTAssertTrue(restart.contains("rollout restart daemonset/kube-proxy"))
        XCTAssertTrue(restart.contains("rollout restart daemonset/kindnet"))
        XCTAssertFalse(KubeRestartRepair.script(for: .restartNetworkPods(kindnet: false)).contains("kindnet"))

        let network = KubeRestartRepair.script(for: .nodeNetwork(node: "n"))
        XCTAssertTrue(network.contains("net.ipv4.ip_forward=1"))
        // Checked first, so running it twice does not add the rule twice.
        XCTAssertTrue(network.contains("iptables -t mangle -C $chain"))

        let kubelet = KubeRestartRepair.script(for: .workerKubelet(node: "w", from: "a", to: "https://192.168.64.9:6443"))
        XCTAssertTrue(kubelet.contains("/etc/kubernetes/kubelet.conf"))
        XCTAssertTrue(kubelet.contains("systemctl restart kubelet"))

        let probe = KubeRestartRepair.probeScript(controlPlane: true)
        XCTAssertTrue(probe.contains("kube-proxy"))
        XCTAssertFalse(KubeRestartRepair.probeScript(controlPlane: false).contains("kubectl"), "workers have no admin kubeconfig")
        for script in [probe, proxy, restart, network, kubelet] {
            XCTAssertFalse(script.contains("delete "), "the repair never deletes anything")
        }
    }

    // MARK: - With a mocked container tool

    private let cli = "/usr/local/bin/container"

    private func execKey(_ node: String, _ script: String) -> String {
        (["exec", node, "/bin/sh", "-c", script]).joined(separator: " ")
    }

    func testRepairRunsOnlyTheNeededSteps() async throws {
        let runner = MockRunner()
        let node = "deck-k8s-kn-a"
        runner.responses[execKey(node, KubeRestartRepair.probeScript(controlPlane: true))] = CommandResult(exitCode: 0, stdout: KubeRestartFixtures.kindnetAfterRestart)
        let expected: [KubeRepairStep] = [
            .nodeNetwork(node: node),
            .kubeProxyServer(from: "https://192.168.64.114:6443", to: "https://192.168.64.115:6443"),
            .clusterInfoServer(from: "https://192.168.64.114:6443", to: "https://192.168.64.115:6443"),
            .restartNetworkPods(kindnet: true),
        ]
        for step in expected {
            runner.responses[execKey(node, KubeRestartRepair.script(for: step))] = CommandResult(exitCode: 0, stdout: "")
        }
        let client = ContainerClient(cliPath: cli, runner: runner)
        let cluster = KubeCluster(name: node, nodes: [
            KubeClusterNode(name: node, cluster: node, role: .controlPlaneWorker, state: .running, ipAddress: "192.168.64.115"),
        ])
        let report = try await client.repairClusterAfterStart(cluster, apiWait: 0)
        XCTAssertEqual(report.steps, expected)
        XCTAssertEqual(report.address, "192.168.64.115")
        XCTAssertFalse(report.apiUnreachable)
        XCTAssertEqual(runner.calls.count, 1 + expected.count)
        XCTAssertEqual(runner.calls.last, [cli] + ["exec", node, "/bin/sh", "-c", KubeRestartRepair.script(for: .restartNetworkPods(kindnet: true))])
    }

    func testRepairOnHealthyClusterChangesNothing() async throws {
        let runner = MockRunner()
        runner.responses[execKey("dev", KubeRestartRepair.probeScript(controlPlane: true))] = CommandResult(exitCode: 0, stdout: KubeRestartFixtures.healthy)
        let client = ContainerClient(cliPath: cli, runner: runner)
        let cluster = KubeCluster(name: "dev", nodes: [
            KubeClusterNode(name: "dev", cluster: "dev", role: .controlPlaneWorker, state: .running, ipAddress: "192.168.64.116"),
        ])
        let report = try await client.repairClusterAfterStart(cluster, apiWait: 0)
        XCTAssertFalse(report.changed)
        XCTAssertEqual(runner.calls.count, 1, "only the read only probe ran")
    }

    func testFailedStepIsReported() async throws {
        let runner = MockRunner()
        let node = "deck-k8s-cni-a"
        runner.responses[execKey(node, KubeRestartRepair.probeScript(controlPlane: true))] = CommandResult(exitCode: 0, stdout: KubeRestartFixtures.noCNIAfterRestart)
        runner.responses[execKey(node, KubeRestartRepair.script(for: .nodeNetwork(node: node)))] = CommandResult(exitCode: 0, stdout: "")
        // The kube-proxy step is not mocked, so it fails.
        let client = ContainerClient(cliPath: cli, runner: runner)
        let cluster = KubeCluster(name: node, nodes: [
            KubeClusterNode(name: node, cluster: node, role: .controlPlaneWorker, state: .running, ipAddress: "192.168.64.113/24"),
        ])
        do {
            try await client.repairClusterAfterStart(cluster, apiWait: 0)
            XCTFail("should throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Pointed kube-proxy at the new node address failed"), error.localizedDescription)
        }
    }

    func testStartThenRepairWithRecordedNodes() async throws {
        let runner = MockRunner()
        // KubeFixtures.clusterContainers: one node deck-v2-k8s-a at 192.168.64.61.
        runner.responses["start deck-v2-k8s-a"] = CommandResult(exitCode: 0, stdout: "deck-v2-k8s-a")
        runner.responses["list --all --format json"] = CommandResult(exitCode: 0, stdout: KubeFixtures.clusterContainers)
        let probe = KubeRestartFixtures.kindnetAfterRestart.replacingOccurrences(of: "192.168.64.115", with: "192.168.64.61")
        runner.responses[execKey("deck-v2-k8s-a", KubeRestartRepair.probeScript(controlPlane: true))] = CommandResult(exitCode: 0, stdout: probe)
        for step: KubeRepairStep in [
            .nodeNetwork(node: "deck-v2-k8s-a"),
            .kubeProxyServer(from: "https://192.168.64.114:6443", to: "https://192.168.64.61:6443"),
            .clusterInfoServer(from: "https://192.168.64.114:6443", to: "https://192.168.64.61:6443"),
            .restartNetworkPods(kindnet: true),
        ] {
            runner.responses[execKey("deck-v2-k8s-a", KubeRestartRepair.script(for: step))] = CommandResult(exitCode: 0, stdout: "")
        }
        let client = ContainerClient(cliPath: cli, runner: runner)
        let stopped = KubeCluster(name: "deck-v2-k8s-a", nodes: [
            KubeClusterNode(name: "deck-v2-k8s-a", cluster: "deck-v2-k8s-a", role: .controlPlaneWorker, state: .stopped, ipAddress: nil),
        ])
        let report = try await client.startClusterAndRepair(stopped, apiWait: 0)
        XCTAssertNil(report.failure)
        XCTAssertEqual(report.address, "192.168.64.61", "the address comes from the node list read after the start")
        XCTAssertTrue(report.fixedAddresses)
        XCTAssertEqual(runner.calls.first, [cli, "start", "deck-v2-k8s-a"])
    }

    func testStartSucceedsWhenTheRepairFails() async throws {
        let runner = MockRunner()
        runner.responses["start deck-v2-k8s-a"] = CommandResult(exitCode: 0, stdout: "deck-v2-k8s-a")
        runner.responses["list --all --format json"] = CommandResult(exitCode: 0, stdout: KubeFixtures.clusterContainers)
        let client = ContainerClient(cliPath: cli, runner: runner)
        let stopped = KubeCluster(name: "deck-v2-k8s-a", nodes: [
            KubeClusterNode(name: "deck-v2-k8s-a", cluster: "deck-v2-k8s-a", role: .controlPlaneWorker, state: .stopped),
        ])
        let report = try await client.startClusterAndRepair(stopped, apiWait: 0)
        XCTAssertNotNil(report.failure)
        XCTAssertTrue(report.summary.hasPrefix("Could not check the cluster network."))
    }
}

// MARK: - Live

/// Runs against the real `container cluster` plugin. Off unless DECK_LIVE_KUBERNETES=1.
/// Makes `deck-k8s-*` clusters (about a minute each with the node image pulled) and
/// deletes them. Needs kubectl for applying kindnet and making a test pod.
/// Note: `container cluster create` adds the cluster to ~/.kube/config and delete removes it.
final class KubernetesRestartLiveTests: XCTestCase {
    private let cli = "/usr/local/bin/container"
    private var kubectl: String?
    private var directory: URL!

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["DECK_LIVE_KUBERNETES"] == "1" else {
            throw XCTSkip("Set DECK_LIVE_KUBERNETES=1 to run the live Kubernetes test.")
        }
        guard FileManager.default.isExecutableFile(atPath: cli) else { throw XCTSkip("container is not installed") }
        kubectl = KubeTools.detect().kubectl
        guard kubectl != nil else { throw XCTSkip("kubectl is not installed") }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("deck-k8s-live-\(UUID().uuidString)")
        setenv(KubernetesConfig.directoryOverrideVariable, directory.path, 1)
    }

    override func tearDown() {
        unsetenv(KubernetesConfig.directoryOverrideVariable)
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: Helpers

    @discardableResult
    private func kubectl(_ config: KubeConfigFile, _ context: String, _ args: [String], stdin: String? = nil) async throws -> CommandResult {
        let result = try await ProcessRunner().run(kubectl!, ["--kubeconfig", config.path, "--context", context] + args, stdin: stdin.map { Data($0.utf8) })
        return result
    }

    private func create(_ options: KubeClusterOptions, client: ContainerClient) async throws -> KubeCluster {
        let started = Date()
        for try await _ in client.createCluster(options) {}
        print("[live] created \(options.name) in \(Int(Date().timeIntervalSince(started))) s")
        return try await cluster(options.name, client: client)
    }

    private func cluster(_ name: String, client: ContainerClient) async throws -> KubeCluster {
        let list = try await client.listClusters()
        return try XCTUnwrap(list.first(where: { $0.name == name }))
    }

    private func waitUntil(_ seconds: TimeInterval, _ what: String, _ check: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if (try? await check()) == true { return }
            try await Task.sleep(for: .seconds(2))
        }
        XCTFail("Timed out after \(Int(seconds)) s: \(what)")
        throw CancellationError()
    }

    private func restart(_ cluster: KubeCluster, client: ContainerClient) async throws -> KubeCluster {
        try await client.stopCluster(cluster)
        let stopped = try await self.cluster(cluster.name, client: client)
        XCTAssertEqual(stopped.state, .stopped)
        return stopped
    }

    private func allReady(_ api: KubeAPIClient) async throws -> Bool {
        let nodes = try await api.nodes()
        return !nodes.isEmpty && nodes.allSatisfy { $0.ready == true }
    }

    /// The pod resolves the API service name through cluster DNS and reaches it through
    /// 10.96.0.1, which needs kube-proxy, kindnet and CoreDNS to all work. kindnet adds the
    /// routes to other nodes within its 10 s loop, so a few tries are allowed.
    private func checkServices(_ config: KubeConfigFile, _ name: String, pod: String, tries: Int = 4) async throws {
        let started = Date()
        var logs = ""
        for attempt in 1...tries {
            _ = try await kubectl(config, name, ["delete", "pod", pod, "--ignore-not-found", "--wait=true"])
            let run = try await kubectl(config, name, [
                "run", pod, "--image=docker.io/library/busybox:1.36", "--restart=Never", "--",
                "sh", "-c", "nslookup kubernetes.default.svc.cluster.local && wget -q -T 5 --no-check-certificate -O- https://10.96.0.1/livez; echo; echo services-ok",
            ])
            XCTAssertTrue(run.succeeded, run.failureMessage)
            try await waitUntil(180, "pod \(pod) finished") {
                let phase = try await kubectl(config, name, ["get", "pod", pod, "-o", "jsonpath={.status.phase}"]).stdout
                return phase == "Succeeded" || phase == "Failed"
            }
            logs = try await kubectl(config, name, ["logs", pod]).stdout
            let node = try await kubectl(config, name, ["get", "pod", pod, "-o", "jsonpath={.spec.nodeName}"]).stdout
            print("[live] try \(attempt) on \(node) after \(Int(Date().timeIntervalSince(started))) s: \(logs.replacingOccurrences(of: "\n", with: " | "))")
            if logs.contains("Address: 10.96.0.1"), logs.contains("services-ok") { return }
            try await Task.sleep(for: .seconds(15))
        }
        XCTFail("DNS and Services did not work: \(logs)")
    }

    // MARK: Tests

    /// A cluster made without a CNI, stopped and started, then kindnet applied: the node
    /// must turn Ready (it never did before the repair). Then pod logs: a pod that prints
    /// one line every 5 seconds must show each line within 1 second.
    func testLiveNoCNIRestartThenKindnetAndLogLatency() async throws {
        let client = ContainerClient(cliPath: cli)
        guard await client.clusterSupported() else { throw XCTSkip("This container tool has no cluster command.") }
        let name = "deck-k8s-cni-live"
        try? await client.deleteCluster(name)
        var cluster = try await create(KubeClusterOptions(name: name, workers: 0, cni: .none, cpus: 2, memory: "3G"), client: client)
        do {
            let before = cluster.controlPlane?.ipAddress
            cluster = try await restart(cluster, client: client)
            let report = try await client.startClusterAndRepair(cluster)
            cluster = try await self.cluster(name, client: client)
            print("[live] address \(before ?? "-") -> \(cluster.controlPlane?.ipAddress ?? "-"), repair: \(report.steps.map(\.title))")
            XCTAssertNil(report.failure)
            XCTAssertFalse(report.apiUnreachable)
            if before != cluster.controlPlane?.ipAddress {
                XCTAssertTrue(report.fixedAddresses, "the node moved, so kube-proxy had to be repointed")
            }
            // A second run finds nothing to do.
            let again = try await client.repairClusterAfterStart(cluster, apiWait: 30)
            XCTAssertFalse(again.fixedAddresses)

            let config = try await client.appKubeconfig(name)
            let api = try await KubeAPIClient.make(config, context: name)
            let readyBefore = try await allReady(api)
            XCTAssertFalse(readyBefore, "no CNI yet")
            let manifest = try XCTUnwrap(KubeTools.bundledKindnetManifest(cliPath: cli))
            try await KubeTools.apply(kubectl: kubectl!, kubeconfig: config.path, context: name, manifest: manifest)
            let applied = Date()
            try await waitUntil(150, "node Ready after kindnet") { try await allReady(api) }
            print("[live] node Ready \(Int(Date().timeIntervalSince(applied))) s after kindnet")
            try await checkServices(config, name, pod: "deck-dns-check")

            // Log latency.
            let ticker = "deck-ticker"
            let run = try await kubectl(config, name, [
                "run", ticker, "--image=docker.io/library/busybox:1.36", "--restart=Never", "--",
                "sh", "-c", "i=0; while true; do i=$((i+1)); echo tick $i; sleep 5; done",
            ])
            XCTAssertTrue(run.succeeded, run.failureMessage)
            try await waitUntil(180, "ticker running") {
                try await api.pods(namespace: "default").first(where: { $0.name == ticker })?.status == "Running"
            }

            // Same stream the app uses, with kubelet timestamps kept, to measure each line.
            var latencies: [TimeInterval] = []
            let stamped = api.transport.lines(api.logRequest(namespace: "default", pod: ticker, container: nil, follow: true, tail: 0, timestamps: true))
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            for try await line in stamped {
                let arrived = Date()
                let (stamp, text) = KubeLogFollower.split(line)
                let trimmed = stamp.map { s -> String in
                    // ISO8601DateFormatter reads at most milliseconds.
                    guard let dot = s.firstIndex(of: ".") else { return s }
                    return String(s[..<dot]) + "." + s[s.index(after: dot)...].dropLast().prefix(3) + "Z"
                }
                let written = try XCTUnwrap(trimmed.flatMap { formatter.date(from: $0) }, line)
                latencies.append(arrived.timeIntervalSince(written))
                print("[live] \(text) after \(String(format: "%.3f", arrived.timeIntervalSince(written))) s")
                if latencies.count == 4 { break }
            }
            XCTAssertEqual(latencies.count, 4)
            for latency in latencies { XCTAssertLessThan(latency, 1.0, "each line shows within a second") }

            // And through podLogs as the log view reads it: tail first, then each new line on its own.
            var arrivals: [Date] = []
            var texts: [String] = []
            for try await line in api.podLogs(namespace: "default", pod: ticker, follow: true, tail: 2) {
                arrivals.append(Date())
                texts.append(line)
                if texts.count == 5 { break }
            }
            XCTAssertTrue(texts.allSatisfy { $0.hasPrefix("tick ") }, "\(texts)")
            // Lines 3, 4 and 5 are new: about 5 s apart, not held back and sent together.
            XCTAssertGreaterThan(arrivals[3].timeIntervalSince(arrivals[2]), 3.5)
            XCTAssertGreaterThan(arrivals[4].timeIntervalSince(arrivals[3]), 3.5)
        } catch {
            try? await client.deleteCluster(name)
            throw error
        }
        try await client.deleteCluster(name)
    }

    /// A cluster made with kindnet and one worker survives stop and start: started the
    /// plain way the check finds the stale addresses, the repair fixes them, and DNS and
    /// Services work again on both nodes.
    func testLiveKindnetClusterSurvivesRestart() async throws {
        let client = ContainerClient(cliPath: cli)
        guard await client.clusterSupported() else { throw XCTSkip("This container tool has no cluster command.") }
        let name = "deck-k8s-kn-live"
        try? await client.deleteCluster(name)
        var cluster = try await create(KubeClusterOptions(name: name, workers: 1, cni: .kindnet, cpus: 2, memory: "2G"), client: client)
        do {
            var config = try await client.appKubeconfig(name)
            var api = try await KubeAPIClient.make(config, context: name)
            try await waitUntil(120, "nodes Ready") { try await allReady(api) }
            let fresh = try await client.clusterRepairPlan(cluster, apiWait: 30)
            XCTAssertEqual(fresh.steps, [], "a new cluster needs nothing")

            let before = cluster.nodes.map { $0.ipAddress ?? "-" }
            cluster = try await restart(cluster, client: client)
            try await client.startCluster(cluster)
            cluster = try await self.cluster(name, client: client)
            print("[live] addresses \(before) -> \(cluster.nodes.map { $0.ipAddress ?? "-" })")
            let plan = try await client.clusterRepairPlan(cluster, apiWait: 90)
            print("[live] stale after a plain start: \(plan.steps.map(\.title))")
            if before.first != cluster.controlPlane?.ipAddress {
                XCTAssertTrue(plan.steps.contains(where: \.fixesAddress))
                XCTAssertTrue(plan.steps.contains(where: { if case .workerKubelet = $0 { return true } else { return false } }))
            }
            let report = try await client.repairClusterAfterStart(cluster)
            XCTAssertEqual(report.steps, plan.steps)

            config = try await client.appKubeconfig(name)
            api = try await KubeAPIClient.make(config, context: name)
            try await waitUntil(150, "nodes Ready after the repair") { try await allReady(api) }
            try await waitUntil(150, "CoreDNS Ready") {
                let pods = try await api.pods(namespace: "kube-system").filter { $0.name.hasPrefix("coredns") }
                return !pods.isEmpty && pods.allSatisfy { $0.status == "Running" && $0.readyCount == $0.containerCount }
            }
            try await checkServices(config, name, pod: "deck-dns-check")
        } catch {
            try? await client.deleteCluster(name)
            throw error
        }
        try await client.deleteCluster(name)
    }
}
