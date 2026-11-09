import XCTest
@testable import DeckCore

/// Feature pass against a real container service, one backend at a time, for checking a
/// new release (1.7) and the older ones side by side. Opt in:
///
///     DECK_LIVE_17=1 DECK_LIVE_BACKEND=direct|cli [DECK_CONTAINER_CLI=<container>] \
///         [DECK_LIVE_LABEL="1.7.1 direct"] swift test --filter Container17LiveTests
///
/// Creates only `deck-17-test-*` resources and removes them. Prune steps run only when every
/// item a prune would remove is one of ours. Each feature is a step. A failed step is
/// recorded and the pass goes on, then the test fails listing them. The results are
/// written to `/tmp/deck-17/matrix/<label>.json`. With a side by side release, also set
/// `CONTAINER_APP_ROOT` and `KUBECONFIG` so nothing touches the installed one.
final class Container17LiveTests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private var cliPath: String { env["DECK_CONTAINER_CLI"] ?? "/usr/local/bin/container" }
    private var forceCLI: Bool { env["DECK_LIVE_BACKEND"] == "cli" }
    private var tag: String { forceCLI ? "c" : "d" }
    private var only: Set<String> { Set((env["DECK_LIVE_ONLY"] ?? "").split(separator: ",").map(String.init)) }

    private final class Matrix: @unchecked Sendable {
        var rows: [(feature: String, ok: Bool, note: String)] = []
    }
    private let matrix = Matrix()

    private func step(_ feature: String, _ body: () async throws -> String) async {
        let group = String(feature.split(separator: ":").first ?? "")
        if !only.isEmpty && !only.contains(group) { return }
        let started = Date()
        do {
            let note = try await body()
            matrix.rows.append((feature, true, note + String(format: " (%.1fs)", Date().timeIntervalSince(started))))
            print("PASS \(feature) \(note)")
        } catch {
            matrix.rows.append((feature, false, error.localizedDescription))
            print("FAIL \(feature) \(error.localizedDescription)")
        }
    }

    private struct Check: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }
    private func expect(_ condition: Bool, _ text: @autoclosure () -> String) throws {
        if !condition { throw Check(text()) }
    }

    private func makeClient() async throws -> ContainerClient {
        let plain = ContainerClient(cliPath: cliPath)
        let version = try await plain.cli.version()
        let api = DirectAPIClient()
        let force = forceCLI
        let selector = BackendSelector(client: api, forceCLI: { force })
        let router = ContainerBackendRouter(cli: plain.withPlatformVersion(version), api: api, selector: selector)
        return plain.routed(through: router).withPlatformVersion(version)
    }

    func testFeaturePass() async throws {
        try XCTSkipUnless(env["DECK_LIVE_17"] == "1", "Set DECK_LIVE_17=1 to run the live feature pass")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: cliPath), "No container CLI at \(cliPath)")
        let client = try await makeClient()
        let version = client.platformVersion
        let features = ContainerPlatformFeatures(version: version)
        let label = env["DECK_LIVE_LABEL"] ?? "\(version.map { "\($0)" } ?? "unknown") \(forceCLI ? "cli" : "direct")"
        let p = "deck-17-test-\(tag)"
        let scratch = URL(fileURLWithPath: "/tmp/deck-17/live-\(tag)-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        await cleanup(client, prefix: p)

        // MARK: System
        await step("system: backend") {
            let status = await client.backendStatus()
            let expected: ContainerBackend = forceCLI ? .cli : .directAPI
            try expect(status?.backend == expected, "backend \(String(describing: status?.backend)), \(status?.summary ?? "")")
            return status?.summary ?? ""
        }
        await step("system: properties and kernel") {
            let props = try await client.systemProperties()
            let kernel = KernelSource.from(properties: props)
            try expect(kernel != nil, "no kernel properties")
            return kernel?.binaryPath ?? ""
        }
        await step("system: setup checks") {
            let report = await SetupService(runner: ProcessRunner(), environment: .live(customCLIPath: cliPath)).runChecks()
            let failing = report.checks.filter { !$0.isOptional && !$0.state.isPassing }
            try expect(failing.isEmpty, "failing: \(failing.map { "\($0.title): \($0.state.message)" })")
            return report.check(.kernel)?.state.message ?? ""
        }
        await step("system: disk usage") {
            let usage = try await client.diskUsage()
            return "images \(usage.images.total)"
        }
        await step("system: dns domains") {
            let domains = try await client.dnsDomains()
            return domains.isEmpty ? "none" : domains.joined(separator: ",")
        }

        // MARK: Images
        await step("images: pull with progress") {
            var lines = 0
            for try await _ in client.pullImage("docker.io/library/alpine:latest") { lines += 1 }
            let images = try await client.listImages()
            try expect(images.contains { $0.reference.contains("library/alpine:latest") }, "alpine not listed")
            return "\(lines) progress lines"
        }
        await step("images: inspect and tag") {
            let detail = try await client.inspectImage("docker.io/library/alpine:latest")
            try await client.tagImage("docker.io/library/alpine:latest", as: "\(p)-tag:latest")
            let images = try await client.listImages()
            try expect(images.contains { $0.reference.contains("\(p)-tag:latest") }, "tag not listed")
            return detail.summary.digest.prefix(19) + ""
        }
        await step("images: save") {
            let file = scratch.appendingPathComponent("alpine.tar")
            try await client.saveImage("\(p)-tag:latest", to: file)
            let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
            try expect(size > 1_000_000, "archive is \(size) bytes")
            return "\(size / 1_000_000) MB"
        }
        await step("images: build with BuildKit") {
            let context = scratch.appendingPathComponent("ctx")
            try FileManager.default.createDirectory(at: context, withIntermediateDirectories: true)
            try "FROM docker.io/library/alpine:latest\nRUN echo built-by-deck > /hello\nCMD [\"cat\", \"/hello\"]\n"
                .write(to: context.appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)
            var last = ""
            for try await line in client.build(BuildOptions(contextDir: context.path, tags: ["\(p)-build:latest"])) { last = line }
            let images = try await client.listImages()
            try expect(images.contains { $0.reference.contains("\(p)-build:latest") }, "built image not listed, last: \(last)")
            return "ok"
        }

        // MARK: Containers
        let web = "\(p)-web"
        await step("containers: run") {
            let id = try await client.runContainer(RunOptions(image: "docker.io/library/alpine:latest", name: web,
                command: ["sh", "-c", "while true; do echo tick; sleep 1; done"], labels: ["deck.test": "17"]))
            try await Task.sleep(nanoseconds: 1_500_000_000)
            let list = try await client.listContainers(all: false)
            try expect(list.contains { $0.id == web && $0.isRunning }, "not running after run")
            return id.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        await step("containers: inspect") {
            let detail = try await client.inspectContainer(web)
            try expect(detail.summary.labels["deck.test"] == "17", "labels \(detail.summary.labels)")
            return detail.summary.ipAddress ?? ""
        }
        await step("containers: logs") {
            var lines: [String] = []
            for try await line in client.logs(web, options: LogOptions(follow: false, tail: 5)) { lines.append(line) }
            try expect(lines.contains { $0.contains("tick") }, "logs \(lines)")
            return "\(lines.count) lines"
        }
        await step("containers: exec") {
            let out = try await client.exec(web, ["echo", "hello-17"])
            try expect(out.stdout.contains("hello-17"), out.stdout + out.stderr)
            return "ok"
        }
        await step("containers: files and copy") {
            let files = try await client.listFiles(web, path: "/etc")
            try expect(files.contains { $0.name == "hostname" }, "no /etc/hostname in \(files.prefix(5).map(\.name))")
            let local = scratch.appendingPathComponent("note.txt")
            try "copied-17".write(to: local, atomically: true, encoding: .utf8)
            try await client.copyToContainer(web, from: local, path: "/tmp/")
            let back = scratch.appendingPathComponent("back")
            try FileManager.default.createDirectory(at: back, withIntermediateDirectories: true)
            try await client.copyFromContainer(web, path: "/tmp/note.txt", to: back)
            let text = (try? String(contentsOf: back.appendingPathComponent("note.txt"), encoding: .utf8)) ?? ""
            try expect(text == "copied-17", "round trip gave '\(text)'")
            return "\(files.count) files in /etc"
        }
        await step("containers: stats") {
            _ = try await client.stats([web])
            try await Task.sleep(nanoseconds: 1_200_000_000)
            let stats = try await client.stats([web])
            try expect(stats.first?.memoryUsageBytes ?? 0 > 0, "no memory reading")
            return String(format: "cpu %.1f%%, mem %d KB", stats[0].cpuPercent, stats[0].memoryUsageBytes / 1024)
        }
        await step("containers: stop, start, restart, kill") {
            try await client.stopContainer(web)
            var state = try await client.inspectContainer(web).summary.state
            try expect(state == .stopped, "after stop: \(state)")
            try await client.startContainer(web)
            state = try await client.inspectContainer(web).summary.state
            try expect(state == .running, "after start: \(state)")
            try await client.restartContainer(web)
            state = try await client.inspectContainer(web).summary.state
            try expect(state == .running, "after restart: \(state)")
            try await client.killContainer(web)
            try await Task.sleep(nanoseconds: 1_000_000_000)
            state = try await client.inspectContainer(web).summary.state
            try expect(state == .stopped, "after kill: \(state)")
            return "ok"
        }
        await step("containers: edit and recreate") {
            try await client.startContainer(web)
            let before = try await client.captureForRecreate(web)
            var changed = before.options
            changed.env.append(EnvVar(key: "DECK17", value: "yes"))
            let outcome = try await client.performRecreate(RecreatePlan(old: before, new: changed))
            try expect(outcome == .recreated(id: web), "outcome \(outcome)")
            let out = try await client.exec(web, ["printenv", "DECK17"])
            try expect(out.stdout.contains("yes"), "env after recreate: \(out.stdout)")
            return "ok"
        }
        await step("containers: bare shell keep alive") {
            let name = "\(p)-shell"
            let image = try await client.inspectImage("docker.io/library/alpine:latest").config
            let options = RunOptions(image: "docker.io/library/alpine:latest", name: name).applyingKeepRunning(true, image: image)
            try expect(options.command == BareShell.keepRunningCommand || options.entrypoint == "sleep", "keep alive not applied: \(options.command)")
            _ = try await client.runContainer(options)
            try await Task.sleep(nanoseconds: 6_000_000_000)
            let state = try await client.inspectContainer(name).summary.state
            try expect(state == .running, "shell container \(state) after 6 s")
            try await client.deleteContainer(name, force: true)
            return "ok"
        }
        await step("containers: delete") {
            try await client.deleteContainer(web, force: true)
            let list = try await client.listContainers(all: true)
            try expect(!list.contains { $0.id == web }, "still listed")
            return "ok"
        }

        // MARK: Volumes and networks
        await step("volumes: create, browse, delete") {
            let vol = "\(p)-vol"
            try await client.createVolume(name: vol, size: "64M")
            try expect(try await client.listVolumes().contains { $0.name == vol }, "not listed")
            let box = "\(p)-volbox"
            _ = try await client.runContainer(RunOptions(image: "docker.io/library/alpine:latest", name: box,
                command: ["sh", "-c", "echo data > /data/file.txt; sleep 300"], mounts: [MountSpec(kind: .volume, source: vol, destination: "/data")]))
            try await Task.sleep(nanoseconds: 1_500_000_000)
            let files = try await client.listFiles(box, path: "/data")
            try expect(files.contains { $0.name == "file.txt" }, "volume files \(files.map(\.name))")
            let used = try await client.listVolumes().first { $0.name == vol }?.usedBy ?? []
            try expect(used.contains(box), "usedBy \(used)")
            try await client.deleteContainer(box, force: true)
            try await client.deleteVolume(vol)
            return "ok"
        }
        await step("networks: create and delete") {
            let net = "\(p)-net"
            try await client.createNetwork(name: net, subnet: nil, internal: false)
            try expect(try await client.listNetworks().contains { $0.name == net }, "not listed")
            try await client.deleteNetwork(net)
            try expect(!(try await client.listNetworks().contains { $0.name == net }), "still listed")
            return "ok"
        }
        await step("volumes: prune keeps chat volumes") {
            let chat = "\(p)-chat"
            let loose = "\(p)-loose"
            try await client.createVolume(name: chat, labels: [ChatVolumeSync.roleLabel: ChatVolumeSync.roleValue])
            try await client.createVolume(name: loose)
            let others = try await prunableOthers(client, prefix: "deck-17-test-")
            guard others.isEmpty else {
                try? await client.deleteVolume(chat); try? await client.deleteVolume(loose)
                return "skipped, prune would also remove \(others)"
            }
            let removed = try await client.pruneVolumes()
            let left = try await client.listVolumes().map(\.name)
            try expect(removed.contains(loose) && !left.contains(loose), "loose volume not pruned: \(removed)")
            try expect(left.contains(chat), "chat volume was pruned")
            try await client.deleteVolume(chat)
            return "removed \(removed)"
        }

        // MARK: Compose
        await step("compose: up and down with a healthcheck") {
            let project = "\(p)-stack"
            let file = scratch.appendingPathComponent("compose.yaml")
            try """
            name: \(project)
            services:
              web:
                image: docker.io/library/alpine:latest
                command: ["sh", "-c", "touch /tmp/ready; sleep 600"]
                healthcheck:
                  test: ["CMD", "test", "-f", "/tmp/ready"]
                  interval: 2s
                  retries: 10
              worker:
                image: docker.io/library/alpine:latest
                command: ["sh", "-c", "echo worker up; sleep 600"]
                depends_on:
                  web:
                    condition: service_healthy
            """.write(to: file, atomically: true, encoding: .utf8)
            let runner = ComposeRunner(client: client, pollInterval: 0.5)
            let plan = try ComposePlanner.plan(try ComposeParser.load(file: file))
            try await runner.up(plan, events: { _ in })
            let ps = try await runner.ps(project: project, plan: plan)
            try expect(Set(ps.map(\.service)) == ["web", "worker"], "services \(ps.map(\.service))")
            try expect(ps.allSatisfy { $0.container.isRunning }, "not all running")
            try await runner.down(project: project, removeVolumes: true, plan: plan, events: { _ in })
            let left = try await runner.ps(project: project)
            try expect(left.isEmpty, "left \(left.map(\.service))")
            return "ok"
        }

        // MARK: Machines
        await step("machines: create, stop, start, delete") {
            let name = "\(p)-m"
            try? await client.deleteMachine(name)
            try await client.createMachine(MachineOptions(name: name, image: MachineImages.recommended, cpus: 1, memory: "1G", homeMount: "none", boot: true),
                                           extras: MachineCreateExtras(user: "deck", home: "/home/deck"))
            var machine = try await client.listMachines().first { $0.name == name }
            try expect(machine?.state == .running, "after create: \(String(describing: machine?.state))")
            try await client.stopMachine(name)
            machine = try await client.listMachines().first { $0.name == name }
            try expect(machine?.state == .stopped, "after stop: \(String(describing: machine?.state))")
            try await client.bootMachine(name)
            machine = try await client.listMachines().first { $0.name == name }
            try expect(machine?.state == .running, "after start: \(String(describing: machine?.state))")
            try await client.stopMachine(name)
            try await client.deleteMachine(name)
            let containers = try await client.listContainers(all: true)
            try expect(!containers.contains { $0.id == name }, "the machine shows in the container list")
            return "ok"
        }

        // MARK: Sandboxes
        await step("sandboxes: create, kill, start, delete") {
            let name = "\(p)-sbx"
            let spec = SandboxSpec(name: name, templateID: "alpine", image: "docker.io/library/alpine:latest", cpus: 1, memoryMB: 512, egress: .isolated)
            _ = try await client.createSandbox(spec, apiKey: nil)
            func find() async throws -> Sandbox? {
                ContainerClient.sandboxes(in: try await client.listContainers(all: true)).first { $0.name == name }
            }
            var box = try await find()
            try expect(box?.isRunning == true, "not running after create")
            try await client.killSandbox(try XCTUnwrap(box))
            box = try await find()
            try expect(box?.isRunning == false, "running after the kill switch")
            try await client.startSandbox(try XCTUnwrap(box), apiKey: nil)
            box = try await find()
            try expect(box?.isRunning == true, "not running after start")
            try await client.removeSandbox(try XCTUnwrap(box))
            try expect(try await find() == nil, "still listed after delete")
            return "ok"
        }

        // MARK: Kubernetes
        await kubernetes(client, features: features, prefix: p)

        // MARK: Prune images (only our own dangling images)
        await step("images: delete and prune") {
            try await client.deleteImage("\(p)-tag:latest")
            try await client.deleteImage("\(p)-build:latest")
            let left = try await client.listImages().map(\.reference)
            try expect(!left.contains { $0.contains(p) }, "left \(left.filter { $0.contains(p) })")
            let dangling = try await client.listImages().filter { $0.reference.hasPrefix("sha256:") || $0.reference.contains("<none>") }
            guard dangling.isEmpty else { return "deleted, prune skipped (\(dangling.count) other dangling images)" }
            try await client.pruneImages(all: false)
            return "deleted and pruned"
        }

        await cleanup(client, prefix: p)
        write(label: label)
        let failed = matrix.rows.filter { !$0.ok }
        XCTAssertTrue(failed.isEmpty, failed.map { "\($0.feature): \($0.note)" }.joined(separator: "\n"))
    }

    /// A prune never removes the image a cluster node uses (`DECK_LIVE_PRUNE=1`, a running
    /// cluster named in `DECK_PRUNE_CLUSTER`). Both prunes run, then the cluster is stopped and
    /// started, which needs its node image.
    func testPruneKeepsClusterNodeImage() async throws {
        try XCTSkipUnless(env["DECK_LIVE_PRUNE"] == "1", "Set DECK_LIVE_PRUNE=1")
        let name = try XCTUnwrap(env["DECK_PRUNE_CLUSTER"])
        let client = try await makeClient()
        let junk = "deck-17-test-\(tag)-junk:latest"
        for try await _ in client.pullImage("docker.io/library/alpine:latest") {}
        try await client.tagImage("docker.io/library/alpine:latest", as: junk)
        func nodeImagePresent() async throws -> Bool {
            try await client.listImages().contains { $0.reference.contains("kindest/node") }
        }
        let before = try await nodeImagePresent()
        XCTAssertTrue(before, "the cluster's node image is listed")
        let users = try await client.imageUsers()
        XCTAssertTrue(users.contains { $0.name == name && $0.kind == .clusterNode }, "\(users)")
        let plain = try await client.pruneImages(all: false)
        let afterPlain = try await nodeImagePresent()
        XCTAssertTrue(afterPlain, "plain prune kept kindest/node, removed \(plain)")
        let all = try await client.pruneImages(all: true)
        let afterAll = try await nodeImagePresent()
        XCTAssertTrue(afterAll, "prune --all kept kindest/node, removed \(all)")
        XCTAssertTrue(all.contains { $0.contains("deck-17-test-\(tag)-junk") }, "unused tag removed: \(all)")
        let first = try await client.listClusters().first { $0.name == name }
        try await client.stopCluster(try XCTUnwrap(first))
        let stopped = try await client.listClusters().first { $0.name == name }
        let cluster = try XCTUnwrap(stopped)
        let report = try await client.startClusterAndRepair(cluster, apiWait: 90)
        let running = try await client.listClusters().first { $0.name == name }?.state
        XCTAssertEqual(running, .running, report.summary)
        print("PRUNE removed plain=\(plain) all=\(all), cluster after restart: \(String(describing: running)), \(report.summary)")
    }

    /// Reads what the app sees and optionally starts things, for the upgrade and downgrade
    /// check (`DECK_LIVE_PROBE=1`, `DECK_PROBE_START=a,b`, `DECK_PROBE_START_CLUSTER=name`).
    /// Writes `/tmp/deck-17/probe-<label>.json`.
    func testProbe() async throws {
        try XCTSkipUnless(env["DECK_LIVE_PROBE"] == "1", "Set DECK_LIVE_PROBE=1")
        let client = try await makeClient()
        var notes: [String] = []
        for id in (env["DECK_PROBE_START"] ?? "").split(separator: ",").map(String.init) {
            do { try await client.startContainer(id); notes.append("started \(id)") } catch { notes.append("start \(id) failed: \(error.localizedDescription)") }
        }
        if let name = env["DECK_PROBE_START_CLUSTER"], !name.isEmpty {
            do {
                guard let cluster = try await client.listClusters().first(where: { $0.name == name }) else { throw Check("cluster \(name) not listed") }
                let report = try await client.startClusterAndRepair(cluster, apiWait: 90)
                notes.append("cluster \(name): \(report.summary)")
            } catch { notes.append("cluster \(name) start failed: \(error.localizedDescription)") }
        }
        let containers = (try? await client.listContainers(all: true)) ?? []
        let clusters = (try? await client.listClusters()) ?? []
        let images = (try? await client.listImages()) ?? []
        let volumes = (try? await client.listVolumes()) ?? []
        let networks = (try? await client.listNetworks()) ?? []
        let out: [String: Any] = [
            "version": client.platformVersion.map { "\($0)" } ?? "",
            "backend": await client.backendStatus()?.summary ?? "",
            "containers": containers.map { "\($0.id) \($0.state.rawValue) \($0.image)" },
            "clusters": clusters.map { "\($0.name) \($0.state.rawValue) nodes=\($0.nodes.map { "\($0.name):\($0.state.rawValue)" }) shared=\(String(describing: $0.sharedImageStore))" },
            "images": images.map(\.reference),
            "volumes": volumes.map { "\($0.name) usedBy=\($0.usedBy)" },
            "networks": networks.map(\.name),
            "notes": notes,
        ]
        let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
        let label = (env["DECK_LIVE_LABEL"] ?? "probe").replacingOccurrences(of: " ", with: "-")
        try data.write(to: URL(fileURLWithPath: "/tmp/deck-17/probe-\(label).json"))
        print(String(decoding: data, as: UTF8.self))
    }

    // MARK: - Kubernetes

    private func kubernetes(_ client: ContainerClient, features: ContainerPlatformFeatures, prefix p: String) async {
        let name = "\(p)-k"
        // 1.7: the direct pass makes a plain cluster (manual image load), the CLI pass one that
        // shares the local image store.
        let shared = features.clusterSharedImageStore && forceCLI
        var made = false
        await step("kubernetes: create") {
            try? await client.deleteCluster(name)
            var options = KubeClusterOptions(name: name, workers: 0, cni: .kindnet, cpus: 2, memory: "3G")
            options.sharedImageStore = shared
            var last = ""
            for try await line in client.createCluster(options) { last = line }
            made = true
            return "shared store \(shared), last: \(last.suffix(60))"
        }
        guard made else { return }
        await step("kubernetes: list and nodes") {
            let cluster = try await cluster(client, name)
            try expect(cluster.state == .running, "state \(cluster.state)")
            try expect(cluster.apiServerHostPort != nil, "no API port")
            if features.clusterListJSON { try expect(cluster.sharedImageStore == shared, "sharedImageStore \(String(describing: cluster.sharedImageStore))") }
            let containers = try await client.listContainers(all: true)
            let inList = containers.contains { $0.id == name }
            try expect(inList == !features.listHidesClusterNodes, "node in container list: \(inList)")
            return "\(cluster.nodes.count) node, version \(cluster.imageVersion ?? "?")"
        }
        let kubeDir = URL(fileURLWithPath: "/tmp/deck-17/kube-\(tag)")
        setenv(KubernetesConfig.directoryOverrideVariable, kubeDir.path, 1)
        defer { unsetenv(KubernetesConfig.directoryOverrideVariable); try? FileManager.default.removeItem(at: kubeDir) }
        await step("kubernetes: workloads and pod logs") {
            let config = try await client.appKubeconfig(name)
            let api = try await KubeAPIClient.make(config, context: name)
            let pods = try await api.pods(namespace: "kube-system")
            try expect(pods.contains { $0.name.hasPrefix("kube-apiserver") }, "pods \(pods.map(\.name))")
            _ = try await api.deployments()
            _ = try await api.services()
            var lines = 0
            if let apiserver = pods.first(where: { $0.name.hasPrefix("kube-apiserver") }) {
                for try await _ in api.podLogs(namespace: "kube-system", pod: apiserver.name, follow: false, tail: 5) { lines += 1 }
            }
            try expect(lines > 0, "no pod log lines")
            return "\(pods.count) pods"
        }
        await step("kubernetes: port forward") {
            guard let kubectl = ["/opt/homebrew/bin/kubectl", "/usr/local/bin/kubectl"].first(where: FileManager.default.isExecutableFile) else {
                return "skipped, no kubectl"
            }
            let config = KubernetesConfig.appKubeconfig(for: name)
            let forwarder = KubePortForwarder()
            let id = forwarder.start(kubectl: kubectl, kubeconfig: config.path, context: name, cluster: name,
                                     namespace: "kube-system", kind: "deployment", name: "coredns", remotePort: 9153)
            defer { forwarder.stop(id) }
            for _ in 0..<40 {
                if let forward = forwarder.all.first(where: { $0.id == id }), forward.localPort > 0, forward.isActive {
                    return "127.0.0.1:\(forward.localPort)"
                }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            throw Check("no local port: \(String(describing: forwarder.all.first?.state))")
        }
        await step("kubernetes: load image") {
            let image = "\(p)-build:latest"
            try await client.loadImage(intoCluster: name, image: image)
            let node = try await client.exec(name, ["/usr/local/bin/ctr", "--namespace", "k8s.io", "images", "list", "-q"])
            try expect(node.stdout.contains("\(p)-build"), "not in containerd: \(node.stdout.prefix(300))")
            return features.clusterLoadImage ? "cluster load-image" : "save, copy, ctr import"
        }
        await step("kubernetes: pod runs the local image") {
            guard let kubectl = ["/opt/homebrew/bin/kubectl", "/usr/local/bin/kubectl"].first(where: FileManager.default.isExecutableFile) else {
                return "skipped, no kubectl"
            }
            let config = KubernetesConfig.appKubeconfig(for: name).path
            let pod = "deck17-local"
            let runner = ProcessRunner()
            let base = ["--kubeconfig", config, "--context", name]
            _ = try await runner.run(kubectl, base + ["delete", "pod", pod, "--ignore-not-found"])
            let run = try await runner.run(kubectl, base + ["run", pod, "--image=\(p)-build:latest", "--image-pull-policy=Never", "--restart=Never"])
            try expect(run.succeeded, run.stderr)
            var phase = ""
            for _ in 0..<60 {
                phase = (try await runner.run(kubectl, base + ["get", "pod", pod, "-o", "jsonpath={.status.phase}"])).stdout
                if phase == "Succeeded" || phase == "Failed" { break }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            let logs = (try await runner.run(kubectl, base + ["logs", pod])).stdout
            _ = try await runner.run(kubectl, base + ["delete", "pod", pod, "--ignore-not-found"])
            try expect(phase == "Succeeded" && logs.contains("built-by-deck"), "phase \(phase), logs \(logs.prefix(200))")
            return shared ? "from the shared image store" : "from the loaded image"
        }
        await step("kubernetes: stop and start") {
            var cluster = try await cluster(client, name)
            try await client.stopCluster(cluster)
            cluster = try await self.cluster(client, name)
            try expect(cluster.state == .stopped, "after stop: \(cluster.state)")
            let report = try await client.startClusterAndRepair(cluster, apiWait: 90)
            cluster = try await self.cluster(client, name)
            try expect(cluster.state == .running, "after start: \(cluster.state)")
            return report.summary
        }
        await step("kubernetes: delete") {
            try await client.deleteCluster(name)
            let left = try await client.listClusters()
            try expect(!left.contains { $0.name == name }, "still listed")
            return "ok"
        }
    }

    private func cluster(_ client: ContainerClient, _ name: String) async throws -> KubeCluster {
        guard let found = try await client.listClusters().first(where: { $0.name == name }) else { throw Check("cluster \(name) not listed") }
        return found
    }

    // MARK: - Helpers

    /// Unused volumes a prune would remove that are not ours.
    private func prunableOthers(_ client: ContainerClient, prefix: String) async throws -> [String] {
        let containers = try await client.listContainers(all: true)
        let users = ContainerOutputParser.volumeUsers(try await client.inspectContainers(containers.map(\.id)))
        return ContainerClient.prunableVolumes(try await client.listVolumeSummaries(), users: users).filter { !$0.hasPrefix(prefix) }
    }

    /// Removes anything left from an earlier run with this prefix.
    private func cleanup(_ client: ContainerClient, prefix: String) async {
        if let clusters = try? await client.listClusters() {
            for cluster in clusters where cluster.name.hasPrefix(prefix) { try? await client.deleteCluster(cluster.name) }
        }
        if let machines = try? await client.listMachines() {
            for machine in machines where machine.name.hasPrefix(prefix) {
                try? await client.stopMachine(machine.name)
                try? await client.deleteMachine(machine.name)
            }
        }
        if let containers = try? await client.listContainers(all: true) {
            for container in containers where container.id.hasPrefix(prefix) { try? await client.deleteContainer(container.id, force: true) }
        }
        if let volumes = try? await client.listVolumes() {
            for volume in volumes where volume.name.hasPrefix(prefix) { try? await client.deleteVolume(volume.name) }
        }
        if let networks = try? await client.listNetworks() {
            for network in networks where network.name.hasPrefix(prefix) { try? await client.deleteNetwork(network.name) }
        }
    }

    private func write(label: String) {
        let folder = URL(fileURLWithPath: "/tmp/deck-17/matrix")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let rows = matrix.rows.map { ["feature": $0.feature, "ok": $0.ok ? "pass" : "fail", "note": $0.note] }
        if let data = try? JSONSerialization.data(withJSONObject: ["label": label, "rows": rows], options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent(label.replacingOccurrences(of: " ", with: "-") + ".json"))
        }
    }
}
