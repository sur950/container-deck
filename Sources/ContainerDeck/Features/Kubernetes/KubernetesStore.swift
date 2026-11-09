import SwiftUI
import AppKit
import DeckCore

extension PrefKey {
    /// Namespace picked in the Workloads tab ("" means all).
    static let kubeNamespace = "kubeNamespace"
    /// Last tab of the cluster detail.
    static let kubeDetailTab = "kubeDetailTab"
}

/// A cluster that is being made right now. Lives in the store, so closing the sheet
/// does not stop it.
struct KubeCreateJob: Identifiable, Equatable {
    var id: String { options.name }
    var options: KubeClusterOptions
    var lines: [String] = []
    var failed: String?
    var finished = false
    var startedAt = Date()

    /// "[2/4] Running kubeadm init" becomes "Running kubeadm init".
    var step: String {
        guard let last = lines.last(where: { $0.hasPrefix("[") }) ?? lines.last else { return "Starting" }
        var text = last
        if let close = text.firstIndex(of: "]"), text.hasPrefix("[") {
            text = String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        // Drop the trailing "[12s]" timer.
        if let open = text.lastIndex(of: "["), text.hasSuffix("s]") {
            text = String(text[..<open]).trimmingCharacters(in: .whitespaces)
        }
        return text.isEmpty ? "Starting" : text
    }

    /// 0...1 from "[2/4]".
    var progress: Double? {
        guard let last = lines.last(where: { $0.hasPrefix("[") }),
              let close = last.firstIndex(of: "]") else { return nil }
        let parts = last[last.index(after: last.startIndex)..<close].split(separator: "/")
        guard parts.count == 2, let done = Double(parts[0]), let total = Double(parts[1]), total > 0 else { return nil }
        return min(1, max(0, (done - 0.5) / total))
    }
}

/// API connection for one running cluster.
struct KubeConnection {
    var api: KubeAPIClient
    var kubeconfig: String
    var context: String
    var hostPort: Int?
}

/// Shared state for the Kubernetes screen. One instance for the app, so cluster
/// creation and port forwards keep going when you switch screens.
@Observable
@MainActor
final class KubernetesStore {
    static let shared = KubernetesStore()

    var clusters: [KubeCluster] = []
    /// nil until checked. false when the container tool has no `cluster` command.
    var supported: Bool?
    var loaded = false
    var loadError: String?
    var tools = KubeTools.detect()
    var forwards: [KubePortForward] = []
    var jobs: [String: KubeCreateJob] = [:]
    /// Ready state per node from the API, by cluster.
    var nodeStatus: [String: [KubeNodeStatus]] = [:]
    var apiVersion: [String: String] = [:]
    var apiError: [String: String] = [:]
    /// Clusters whose stored addresses are stale after a restart outside the app.
    var repairNeeded: Set<String> = []
    /// Clusters being repaired right now.
    var repairing: Set<String> = []

    @ObservationIgnored let forwarder = KubePortForwarder()
    @ObservationIgnored let recipes = KubeClusterRecipes()
    @ObservationIgnored private var connections: [String: KubeConnection] = [:]
    @ObservationIgnored private var connecting: [String: Task<KubeConnection, Error>] = [:]
    @ObservationIgnored private var sequencer = 0
    /// Control plane address last checked for stale addresses, by cluster.
    @ObservationIgnored private var repairChecked: [String: String] = [:]
    @ObservationIgnored private var quitObserver: NSObjectProtocol?

    private init() {
        forwarder.onChange = { list in
            Task { @MainActor in KubernetesStore.shared.forwards = list }
        }
        let forwarder = self.forwarder
        quitObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in
            forwarder.stopAllBlocking()
        }
    }

    // MARK: - Clusters

    func reload(_ client: ContainerClient) async {
        sequencer += 1
        let ticket = sequencer
        if supported == nil {
            supported = await client.clusterSupported()
        }
        guard supported == true else {
            loaded = true
            return
        }
        do {
            let list = try await client.listClusters()
            guard ticket == sequencer else { return }
            if list != clusters {
                withAnimation(.easeInOut(duration: 0.25)) { clusters = list }
            }
            loadError = nil
            pruneKubeconfigs(keeping: Set(list.map(\.name)).union(jobs.keys))
            // Forget connections of clusters that are gone or moved to another port.
            for (name, connection) in connections {
                let cluster = list.first(where: { $0.name == name })
                if cluster == nil || cluster?.state != .running || cluster?.apiServerHostPort != connection.hostPort {
                    connections[name] = nil
                }
            }
        } catch {
            if KubeClusterParser.isUnsupported(error) {
                supported = false
            } else if clusters.isEmpty {
                loadError = error.localizedDescription
            }
        }
        loaded = true
    }

    /// Removes private kubeconfigs of clusters deleted outside the app.
    private func pruneKubeconfigs(keeping names: Set<String>) {
        let folder = KubernetesConfig.appDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for file in files where file.hasSuffix(".kubeconfig") {
            let name = String(file.dropLast(".kubeconfig".count))
            if !names.contains(name) {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
                recipes.remove(name)
            }
        }
    }

    func recheckSupport(_ client: ContainerClient) async {
        supported = nil
        tools = KubeTools.detect()
        await reload(client)
    }

    /// Clusters plus the ones being made that do not have nodes yet.
    var pendingJobs: [KubeCreateJob] {
        jobs.values
            .filter { job in !clusters.contains(where: { $0.name == job.options.name }) || !job.finished }
            .sorted { $0.startedAt < $1.startedAt }
    }

    // MARK: - Create

    func create(_ options: KubeClusterOptions, client: ContainerClient, state: AppState) {
        jobs[options.name] = KubeCreateJob(options: options)
        recipes.save(options)
        Task {
            do {
                for try await line in client.createCluster(options) {
                    guard let clean = ResourceLog.clean(line) else { continue }
                    var job = jobs[options.name] ?? KubeCreateJob(options: options)
                    // Progress lines repeat with a new timer, keep one per step.
                    if let last = job.lines.last, Self.sameStep(last, clean) {
                        job.lines[job.lines.count - 1] = clean
                    } else {
                        job.lines.append(clean)
                    }
                    if job.lines.count > 400 { job.lines.removeFirst(job.lines.count - 400) }
                    jobs[options.name] = job
                }
                jobs[options.name]?.finished = true
                state.showToast("Cluster \(options.name) is ready.", style: .success)
                await reload(client)
                try? await Task.sleep(for: .seconds(2))
                jobs[options.name] = nil
            } catch {
                ComponentHealth.report(component: .container, feature: "Creating a Kubernetes cluster", error: error)
                let explained = KubeClusterParser.explain(error)
                jobs[options.name]?.failed = explained.localizedDescription
                jobs[options.name]?.finished = true
                recipes.remove(options.name)
                state.showError(explained)
                await reload(client)
            }
        }
    }

    /// True while `cluster create` still runs for this name. The node exists before
    /// Kubernetes is up, so the cluster is not usable yet.
    func isCreating(_ name: String) -> Bool {
        guard let job = jobs[name] else { return false }
        return !job.finished
    }

    func dismissJob(_ name: String) {
        jobs[name] = nil
    }

    static func sameStep(_ a: String, _ b: String) -> Bool {
        func key(_ text: String) -> String? {
            guard text.hasPrefix("["), let close = text.firstIndex(of: "]") else { return nil }
            var rest = String(text[text.index(after: close)...])
            if let open = rest.lastIndex(of: "["), rest.hasSuffix("s]") { rest = String(rest[..<open]) }
            return String(text[...close]) + rest.trimmingCharacters(in: .whitespaces)
        }
        guard let left = key(a), let right = key(b) else { return false }
        return left == right
    }

    // MARK: - Cluster actions

    func delete(_ cluster: KubeCluster, client: ContainerClient) async throws {
        forwarder.stopAll(cluster: cluster.name)
        connections[cluster.name] = nil
        do {
            try await client.deleteCluster(cluster.name)
        } catch {
            ComponentHealth.report(component: .container, feature: "Deleting a Kubernetes cluster", error: error)
            throw error
        }
        recipes.remove(cluster.name)
        nodeStatus[cluster.name] = nil
        apiVersion[cluster.name] = nil
        apiError[cluster.name] = nil
    }

    /// Starts the nodes, then fixes what the restart left stale (the node's new address in
    /// kube-proxy and the workers, and the network settings). See KubeRestartRepair.swift.
    func start(_ cluster: KubeCluster, client: ContainerClient, state: AppState) async throws {
        repairing.insert(cluster.name)
        defer { repairing.remove(cluster.name) }
        let report: KubeRepairReport
        do {
            report = try await client.startClusterAndRepair(cluster)
        } catch {
            ComponentHealth.report(component: .container, feature: "Starting a Kubernetes cluster", error: error)
            throw error
        }
        connections[cluster.name] = nil
        repairNeeded.remove(cluster.name)
        repairChecked[cluster.name] = report.address
        if report.failure != nil || report.apiUnreachable {
            state.showToast(report.summary, style: .info)
        } else if report.fixedAddresses {
            state.showToast(report.summary, style: .success)
        }
    }

    /// Fixes stale addresses in a running cluster (started outside the app).
    func repair(_ cluster: KubeCluster, client: ContainerClient, state: AppState) async {
        repairing.insert(cluster.name)
        defer { repairing.remove(cluster.name) }
        do {
            let report = try await client.repairClusterAfterStart(cluster, apiWait: 20)
            repairNeeded.remove(cluster.name)
            repairChecked[cluster.name] = report.address
            state.showToast(report.summary, style: report.apiUnreachable ? .info : .success)
            try? await Task.sleep(for: .seconds(3))
            await refreshStatus(cluster, client: client)
        } catch {
            state.showError(error)
        }
    }

    /// Checks once per control plane address whether a restart outside the app left stale
    /// addresses behind. Read only.
    private func checkRepair(_ cluster: KubeCluster, client: ContainerClient) {
        guard let address = cluster.controlPlane?.ipAddress, repairChecked[cluster.name] != address,
              !repairing.contains(cluster.name) else { return }
        repairChecked[cluster.name] = address
        Task {
            guard let plan = try? await client.clusterRepairPlan(cluster), plan.apiReady else {
                repairChecked[cluster.name] = nil
                return
            }
            if plan.steps.contains(where: \.fixesAddress) {
                repairNeeded.insert(cluster.name)
            } else {
                repairNeeded.remove(cluster.name)
            }
        }
    }

    func recreateOptions(_ cluster: KubeCluster) -> KubeClusterOptions {
        KubeClusterOptions.recreate(cluster, saved: recipes.recipe(for: cluster.name))
    }

    /// Deletes the cluster and makes it again with the same settings.
    func recreate(_ cluster: KubeCluster, client: ContainerClient, state: AppState) async throws {
        let options = recreateOptions(cluster)
        try await delete(cluster, client: client)
        await reload(client)
        create(options, client: client, state: state)
    }

    // MARK: - API

    /// Connects to a running cluster's API. Writes a private kubeconfig the first time.
    func connection(_ cluster: KubeCluster, client: ContainerClient) async throws -> KubeConnection {
        if let existing = connections[cluster.name] { return existing }
        if let running = connecting[cluster.name] { return try await running.value }
        let name = cluster.name
        let port = cluster.apiServerHostPort
        let task = Task<KubeConnection, Error> {
            let file = try await client.appKubeconfig(name)
            let api = try await KubeAPIClient.make(file, context: name)
            return KubeConnection(api: api, kubeconfig: file.path, context: name, hostPort: port)
        }
        connecting[name] = task
        defer { connecting[name] = nil }
        let result = try await task.value
        connections[name] = result
        return result
    }

    func forgetConnection(_ name: String) {
        connections[name] = nil
    }

    /// Node readiness and version, for the overview and the "Waiting for CNI" state.
    func refreshStatus(_ cluster: KubeCluster, client: ContainerClient) async {
        guard cluster.state == .running, !isCreating(cluster.name) else {
            nodeStatus[cluster.name] = nil
            apiError[cluster.name] = nil
            repairNeeded.remove(cluster.name)
            repairChecked[cluster.name] = nil
            return
        }
        do {
            let connection = try await connection(cluster, client: client)
            async let nodes = connection.api.nodes()
            async let version = connection.api.version()
            let list = try await nodes
            if nodeStatus[cluster.name] != list { nodeStatus[cluster.name] = list }
            if let value = try? await version { apiVersion[cluster.name] = value }
            apiError[cluster.name] = nil
            checkRepair(cluster, client: client)
        } catch {
            apiError[cluster.name] = error.localizedDescription
            // Credentials or port may have changed after a restart. Try fresh next time.
            connections[cluster.name] = nil
        }
    }

    func waitingForCNI(_ cluster: KubeCluster) -> Bool {
        guard cluster.state == .running, let nodes = nodeStatus[cluster.name], !nodes.isEmpty else { return false }
        return nodes.contains(where: \.waitingForCNI)
    }

    func version(_ cluster: KubeCluster) -> String? {
        apiVersion[cluster.name] ?? cluster.imageVersion ?? recipes.recipe(for: cluster.name).flatMap {
            KubernetesConfig.version(fromNodeImage: $0.nodeImage.isEmpty ? KubernetesConfig.defaultNodeImage : $0.nodeImage)
        }
    }

    // MARK: - Port forwards

    func startForward(_ cluster: KubeCluster, client: ContainerClient, namespace: String, kind: String, name: String, remotePort: Int, localPort: Int) async throws {
        guard let kubectl = tools.kubectl else {
            throw DeckError.commandFailed("kubectl is not installed. Install it with Homebrew (brew install kubectl), then try again.")
        }
        let connection = try await connection(cluster, client: client)
        forwarder.start(
            kubectl: kubectl, kubeconfig: connection.kubeconfig, context: connection.context, cluster: cluster.name,
            namespace: namespace, kind: kind, name: name, remotePort: remotePort, localPort: localPort
        )
    }

    func forwards(for cluster: String) -> [KubePortForward] {
        forwards.filter { $0.cluster == cluster }
    }
}
