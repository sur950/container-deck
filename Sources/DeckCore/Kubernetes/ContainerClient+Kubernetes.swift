import Foundation

// Calls for Apple's `container cluster` plugin (EXPERIMENTAL).
//
// 1.4 to 1.6:
//   cluster create [--name] [--rm] [--cpus] [--memory] [--node-image] [--cni <path>|NONE] [--workers N]
//   cluster delete --name X, cluster list (node table only), cluster load-image --name X <image> [--platform] [--node ...]
//   cluster write-config --name X [--kubeconfig <path>]
//   Nodes are plain containers: `container list --all` shows them and start, stop and delete work on them.
// 1.7 (ContainerPlatformFeatures.clusterService):
//   cluster create adds --shared-image-store and --workers count=<n>,cpus=<n>,memory=<size>
//   cluster list is one row per cluster, --nodes for the node table, --format json for records
//   cluster load-image is gone (--shared-image-store replaces it)
//   `container list` hides nodes and start, stop, kill and delete answer "not found" for them,
//   so nodes are listed and started over the direct API (ContainerBackendRouter.clusterNode).
// There is no start or stop command in any release. Nodes are started and stopped one by one.

public extension ContainerClient {
    /// True when this container tool has the cluster plugin (`cluster`, or `k8s` in 1.4.0 to 1.6.0).
    func clusterSupported() async -> Bool {
        let command = await platformFeatures().clusterCommand
        guard let result = try? await runner.run(cli.path, [command, "--help"]) else { return false }
        if result.succeeded { return true }
        return !KubeClusterParser.isUnsupportedText(result.failureMessage) && result.stdout.contains(command)
    }

    /// Clusters and their nodes, for the release in use.
    ///
    /// 1.6 and older: the container list (fast, has labels and dates), else the plugin's node table.
    /// 1.7 and newer: the cluster nodes (direct API, or the records and `container inspect`)
    /// merged with `cluster list --format json`, else the `cluster list --nodes` table.
    func listClusters() async throws -> [KubeCluster] {
        let features = await platformFeatures()
        guard features.clusterListJSON else {
            do {
                return KubeClusterParser.clusters(from: try await listClusterNodes(features: features))
            } catch {
                do {
                    let result = try await run([features.clusterCommand, "list"])
                    return KubeClusterParser.parseTable(result.stdout)
                } catch {
                    throw clusterFailure("cluster list", KubeClusterParser.explain(error))
                }
            }
        }

        var recordError: Error?
        var records: [KubeClusterRecord]?
        do {
            records = try await clusterRecords()
        } catch {
            recordError = error
        }
        if let router, let nodes = try? await router.listClusterNodes() {
            return KubeClusterParser.clusters(nodes: nodes, records: records ?? [])
        }
        if let records {
            let nodes = await inspectClusterNodes(KubeClusterParser.nodeNames(records))
            return KubeClusterParser.clusters(nodes: nodes, records: records)
        }
        // Newer release with another JSON shape, or a broken plugin: try the node table.
        if let table = try? await run([features.clusterCommand, "list", "--nodes"]), case let parsed = KubeClusterParser.parseTable(table.stdout),
           !parsed.isEmpty || table.stdout.hasPrefix("CLUSTER") {
            return parsed
        }
        let error = recordError ?? DeckError.commandFailed("The cluster list could not be read.")
        let explained = KubeClusterParser.explain(error)
        if explained is KubeClusterNameError || KubeClusterParser.isUnsupportedText(error.localizedDescription) { throw explained }
        throw clusterFailure("cluster list", features.explainFailure("Could not read the Kubernetes clusters.", details: error.localizedDescription))
    }

    /// `container cluster list --format json` (1.7).
    func clusterRecords() async throws -> [KubeClusterRecord] {
        let result = try await run([await platformFeatures().clusterCommand, "list", "--format", "json"])
        return try KubeClusterParser.parseClusterJSON(result.stdout)
    }

    /// Every cluster node as a container, running or not. On 1.7 `container list` hides
    /// them, so the CLI path reads the cluster records and inspects their nodes.
    func listClusterNodes() async throws -> [ContainerSummary] {
        if let router { return try await router.listClusterNodes() }
        return try await listClusterNodes(features: await platformFeatures())
    }

    private func listClusterNodes(features: ContainerPlatformFeatures) async throws -> [ContainerSummary] {
        if let router, !features.listHidesClusterNodes { return try await router.listClusterNodes() }
        guard features.listHidesClusterNodes else {
            return try await listContainers(all: true).filter(KubeClusterParser.isClusterNode)
        }
        let records = try await clusterRecords()
        return await inspectClusterNodes(KubeClusterParser.nodeNames(records))
    }

    /// `container inspect` for the node names that still have a container. One call for all,
    /// then one per node when that fails (a `--rm` node that is gone fails the whole call).
    private func inspectClusterNodes(_ names: [String]) async -> [ContainerSummary] {
        guard !names.isEmpty else { return [] }
        let plain = withoutRouter
        if let all = try? await plain.inspectContainers(names) {
            return all.map(\.summary).filter(KubeClusterParser.isClusterNode)
        }
        var found: [ContainerSummary] = []
        for name in names {
            if let one = try? await plain.inspectContainers([name]) {
                found += one.map(\.summary).filter(KubeClusterParser.isClusterNode)
            }
        }
        return found
    }

    /// Every Kubernetes failure that may come from the installed container release goes
    /// through here. Reports a cluster failure that looks like a changed container version, so Settings,
    /// Components can offer the tested version (`ComponentHealth`). Returns the error unchanged.
    internal func clusterFailure(_ feature: String, _ error: Error) -> Error {
        ComponentHealth.report(component: "container", feature: "Kubernetes \(feature)", error: error)
        return error
    }

    /// This client without the router (the CLI path only).
    internal var withoutRouter: ContainerClient {
        var copy = self
        copy.router = nil
        return copy
    }

    /// `container cluster create` arguments (without the leading "container").
    /// Throws `KubeClusterNameError` when the name would break the plugin (see `KubernetesConfig.nameProblem`).
    func createClusterArguments(_ options: KubeClusterOptions, features: ContainerPlatformFeatures? = nil) throws -> [String] {
        let name = Self.clusterName(options)
        if let problem = KubernetesConfig.nameProblem(name) {
            throw KubeClusterNameError(name: name, problem: problem)
        }
        return createClusterHintArguments(options, features: features)
    }

    /// The same arguments without the name check. Only for showing the command, never for running it.
    ///
    /// From 1.7, `--cpus` and `--memory` size only the control plane and workers get the
    /// plugin default (a quarter of the Mac) unless given as `--workers count=<n>,cpus=<n>,memory=<size>`.
    /// The sheet's sizes are per node, so on 1.7 they are passed for the workers too.
    /// `features` nil keeps the 1.6 form.
    func createClusterHintArguments(_ options: KubeClusterOptions, features given: ContainerPlatformFeatures? = nil) -> [String] {
        let features = given ?? knownFeatures
        var args = [features.clusterCommand, "create"]
        args += ["--name", Self.clusterName(options)]
        if let cpus = options.cpus, cpus > 0 { args += ["--cpus", String(cpus)] }
        if let memory = CLIText.nonEmpty(options.memory) { args += ["--memory", memory] }
        let image = options.nodeImage.trimmingCharacters(in: .whitespaces)
        if !image.isEmpty, image != KubernetesConfig.defaultNodeImage { args += ["--node-image", image] }
        switch options.cni {
        case .kindnet: break
        case .none: if features.clusterCNINone { args += ["--cni", KubernetesConfig.noCNI] }
        case .manifest(let path):
            let trimmed = path.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, features.clusterCNIManifest { args += ["--cni", trimmed] }
        }
        if options.workers > 0, features.clusterWorkers {
            let count = min(options.workers, KubernetesConfig.maxWorkers)
            var group = [String(count)]
            if given?.clusterWorkerGroups == true {
                if let cpus = options.cpus, cpus > 0 { group.append("cpus=\(cpus)") }
                if let memory = CLIText.nonEmpty(options.memory) { group.append("memory=\(memory)") }
            }
            args += ["--workers", group.count == 1 ? group[0] : "count=" + group.joined(separator: ",")]
        }
        if options.removeOnStop { args.append("--rm") }
        if options.sharedImageStore { args.append("--shared-image-store") }
        return args
    }

    /// Creates and starts a cluster. Lines are the plugin's progress ("[1/4] Starting cluster").
    /// Takes about a minute with the image already pulled. `--shared-image-store` is left
    /// out on releases without it (a recipe saved on 1.7, used after a downgrade).
    func createCluster(_ options: KubeClusterOptions) -> AsyncThrowingStream<String, Error> {
        let client = self
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let features = await client.platformFeatures()
                    var adjusted = options
                    if adjusted.sharedImageStore, !features.clusterSharedImageStore {
                        adjusted.sharedImageStore = false
                    }
                    for try await line in client.stream(try client.withPlatformVersion(features.version).createClusterArguments(adjusted, features: features)) {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The trimmed name, or the plugin default when empty.
    private static func clusterName(_ options: KubeClusterOptions) -> String {
        let name = options.name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? KubernetesConfig.defaultClusterName : name
    }

    func deleteClusterArguments(_ name: String) -> [String] {
        [knownFeatures.clusterCommand, "delete", "--name", name]
    }

    /// Stops and deletes every node and removes the cluster from `~/.kube/config`.
    func deleteCluster(_ name: String) async throws {
        do {
            try await run(await withResolvedPlatformVersion().deleteClusterArguments(name))
        } catch {
            throw KubeClusterParser.explain(error)
        }
        try? FileManager.default.removeItem(at: KubernetesConfig.appKubeconfig(for: name))
    }

    /// Starts a stopped cluster: control plane first, then workers. The node start
    /// script fixes the API certificate when the node got a new IP, but not the addresses
    /// stored inside the cluster. Use `startClusterAndRepair` for those (KubeRestartRepair.swift).
    func startCluster(_ cluster: KubeCluster) async throws {
        let features = await platformFeatures()
        for node in KubeClusterActions.startOrder(cluster) where node.state != .running {
            try await clusterNode(.start, node.name, features: features)
        }
    }

    /// Stops workers first, then the control plane.
    func stopCluster(_ cluster: KubeCluster) async throws {
        let features = await platformFeatures()
        for node in KubeClusterActions.startOrder(cluster).reversed() where node.state == .running {
            try await clusterNode(.stop, node.name, features: features)
        }
    }

    /// Starts, stops, kills or deletes one cluster node. 1.6 and older: the usual container
    /// calls. 1.7 and newer: straight through the daemon, because the CLI refuses
    /// (`ContainerBackendRouter.clusterNode`).
    func clusterNode(_ action: ClusterNodeAction, _ name: String, features: ContainerPlatformFeatures? = nil) async throws {
        let features = await resolve(features)
        guard features.lifecycleSkipsClusterNodes else {
            switch action {
            case .start: try await startContainer(name)
            case .stop: try await stopContainer(name)
            case .kill: try await killContainer(name)
            case .delete(let force): try await deleteContainer(name, force: force)
            }
            return
        }
        let router = self.router ?? ContainerBackendRouter(cliPath: cli.path)
        do {
            try await router.clusterNode(action, name, features: features)
        } catch {
            throw clusterFailure("cluster node \(action.verb)", error)
        }
    }

    private func resolve(_ features: ContainerPlatformFeatures?) async -> ContainerPlatformFeatures {
        if let features { return features }
        return await platformFeatures()
    }

    /// `cluster load-image` arguments (1.4 to 1.6).
    func loadImageArguments(cluster: String, image: String, platform: String? = nil, nodes: [String] = []) -> [String] {
        let features = knownFeatures
        var args = [features.clusterCommand, "load-image", "--name", cluster]
        if let platform = CLIText.nonEmpty(platform) { args += ["--platform", platform] }
        // The k8s plugin before 1.6.0 has no --node. It has one node, so all nodes is the same.
        if features.clusterLoadImageNodes { for node in nodes where !node.isEmpty { args += ["--node", node] } }
        args.append(image.trimmingCharacters(in: .whitespaces))
        return args
    }

    /// Copies a local image into the nodes' containerd, so pods can use it without a registry
    /// (set `imagePullPolicy: Never` or `IfNotPresent`).
    ///
    /// 1.4 to 1.6: `cluster load-image`. 1.7 removed it, so the app does what it did: save the
    /// image to an archive, copy it into each node and import it with containerd's `ctr`.
    /// A cluster made with `--shared-image-store` does not need this (`KubeCluster.sharedImageStore`).
    func loadImage(intoCluster cluster: String, image: String, platform: String? = nil, nodes: [String] = []) async throws {
        let features = await platformFeatures()
        if features.clusterLoadImage {
            do {
                try await run(withPlatformVersion(features.version).loadImageArguments(cluster: cluster, image: image, platform: platform, nodes: nodes))
            } catch {
                throw KubeClusterParser.explain(error)
            }
            return
        }
        var targets = nodes.filter { !$0.isEmpty }
        if targets.isEmpty {
            guard let found = try await listClusters().first(where: { $0.name == cluster }) else {
                throw DeckError.commandFailed("Cluster \(cluster) was not found.")
            }
            targets = KubeClusterActions.startOrder(found).filter { $0.state == .running }.map(\.name)
            guard !targets.isEmpty else { throw DeckError.commandFailed("Start cluster \(cluster) first, then load the image.") }
        }
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("deck-cluster-image-\(UUID().uuidString).tar")
        defer { try? FileManager.default.removeItem(at: archive) }
        do {
            try await run(Self.clusterImageSaveArguments(image: image, platform: platform, archive: archive.path))
            for node in targets {
                for step in Self.clusterImageImportSteps(node: node, archive: archive.path) {
                    try await run(step)
                }
            }
        } catch {
            throw clusterFailure("cluster load image", features.explainFailure("Could not load \(image) into cluster \(cluster).", details: error.localizedDescription))
        }
    }

    /// `image save` for the manual load (1.7). The platform defaults to the node's, linux/arm64.
    static func clusterImageSaveArguments(image: String, platform: String?, archive: String) -> [String] {
        ["image", "save", "--platform", CLIText.nonEmpty(platform) ?? "linux/arm64", "--output", archive,
         image.trimmingCharacters(in: .whitespaces)]
    }

    /// Copy the archive into a node, import it into the `k8s.io` namespace the kubelet uses, remove it.
    static func clusterImageImportSteps(node: String, archive: String) -> [[String]] {
        let inside = KubernetesConfig.nodeImageArchivePath
        return [
            ["copy", archive, "\(node):\(inside)"],
            ["exec", node, KubernetesConfig.nodeCtrPath, "--namespace", "k8s.io", "images", "import", inside],
            ["exec", node, "rm", "-f", inside]
        ]
    }

    /// The commands the manual load runs, for the hint under the Load Image sheet (1.7).
    func manualLoadHint(image: String, nodes: [String]) -> [String] {
        let archive = "/tmp/image.tar"
        var lines = [commandLine(Self.clusterImageSaveArguments(image: image, platform: nil, archive: archive))]
        for node in nodes {
            lines += Self.clusterImageImportSteps(node: node, archive: archive).map(commandLine)
        }
        return lines
    }

    func writeKubeconfigArguments(_ cluster: String, path: String? = nil) -> [String] {
        var args = [knownFeatures.clusterCommand, "write-config", "--name", cluster]
        if let path = CLIText.nonEmpty(path) { args += ["--kubeconfig", path] }
        return args
    }

    /// Writes or updates the cluster's entry in a kubeconfig file. nil means `~/.kube/config`.
    /// A file that held nothing else also gets this cluster as its current context, so
    /// `kubectl --kubeconfig <file>` works without `--context`.
    func writeKubeconfig(_ cluster: String, to file: URL? = nil) async throws {
        let existed = file.map { FileManager.default.fileExists(atPath: $0.path) } ?? true
        do {
            try await run(await withResolvedPlatformVersion().writeKubeconfigArguments(cluster, path: file?.path))
        } catch {
            throw KubeClusterParser.explain(error)
        }
        if let file, !existed {
            KubeConfigFile.setCurrentContextIfMissing(cluster, in: file)
            KubeConfigFile.makePrivate(file)
        }
    }

    /// Writes the private kubeconfig the app uses for the Kubernetes API and reads it.
    func appKubeconfig(_ cluster: String) async throws -> KubeConfigFile {
        let file = KubernetesConfig.appKubeconfig(for: cluster)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: file)
        try await writeKubeconfig(cluster, to: file)
        KubeConfigFile.makePrivate(file)
        return try KubeConfigFile.load(file)
    }
}

/// A cluster name the plugin cannot use.
public struct KubeClusterNameError: LocalizedError, Equatable, Sendable {
    public let name: String
    public let problem: KubernetesConfig.NameProblem

    public init(name: String, problem: KubernetesConfig.NameProblem) {
        self.name = name
        self.problem = problem
    }

    public var errorDescription: String? {
        "The cluster name \"\(name)\" does not work with Kubernetes. \(problem.message)"
    }
}

/// Pure helpers for cluster actions.
public enum KubeClusterActions {
    /// Control plane first, then workers in name order.
    public static func startOrder(_ cluster: KubeCluster) -> [KubeClusterNode] {
        let control = cluster.nodes.filter { $0.role.isControlPlane }
        let workers = cluster.nodes.filter { !$0.role.isControlPlane }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return control + workers
    }
}
