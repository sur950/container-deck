import Foundation

// Calls for Apple's `container cluster` plugin (EXPERIMENTAL in container 1.6.1):
//   cluster create [--name] [--rm] [--cpus] [--memory] [--node-image] [--cni <path>|NONE] [--workers N]
//   cluster delete --name X, cluster list (table only), cluster load-image --name X <image> [--platform] [--node ...]
//   cluster write-config --name X [--kubeconfig <path>]
// There is no start or stop command. Nodes are plain containers, so start and stop use them.

public extension ContainerClient {
    /// True when this container tool has the `cluster` command.
    func clusterSupported() async -> Bool {
        guard let result = try? await runner.run(cli.path, ["cluster", "--help"]) else { return false }
        if result.succeeded { return true }
        return !KubeClusterParser.isUnsupportedText(result.failureMessage) && result.stdout.contains("cluster")
    }

    /// Clusters and their nodes. Reads the container list (fast, has labels and dates)
    /// and falls back to the plugin's own table.
    func listClusters() async throws -> [KubeCluster] {
        do {
            let containers = try await listContainers(all: true)
            return KubeClusterParser.clusters(from: containers)
        } catch {
            do {
                let result = try await run(["cluster", "list"])
                return KubeClusterParser.parseTable(result.stdout)
            } catch {
                throw KubeClusterParser.explain(error)
            }
        }
    }

    /// `container cluster create` arguments (without the leading "container").
    func createClusterArguments(_ options: KubeClusterOptions) -> [String] {
        var args = ["cluster", "create"]
        let name = options.name.trimmingCharacters(in: .whitespaces)
        args += ["--name", name.isEmpty ? KubernetesConfig.defaultClusterName : name]
        if let cpus = options.cpus, cpus > 0 { args += ["--cpus", String(cpus)] }
        if let memory = CLIText.nonEmpty(options.memory) { args += ["--memory", memory] }
        let image = options.nodeImage.trimmingCharacters(in: .whitespaces)
        if !image.isEmpty, image != KubernetesConfig.defaultNodeImage { args += ["--node-image", image] }
        switch options.cni {
        case .kindnet: break
        case .none: args += ["--cni", KubernetesConfig.noCNI]
        case .manifest(let path):
            let trimmed = path.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { args += ["--cni", trimmed] }
        }
        if options.workers > 0 { args += ["--workers", String(min(options.workers, KubernetesConfig.maxWorkers))] }
        if options.removeOnStop { args.append("--rm") }
        return args
    }

    /// Creates and starts a cluster. Lines are the plugin's progress ("[1/4] Starting cluster").
    /// Takes about a minute with the image already pulled.
    func createCluster(_ options: KubeClusterOptions) -> AsyncThrowingStream<String, Error> {
        stream(createClusterArguments(options))
    }

    func deleteClusterArguments(_ name: String) -> [String] {
        ["cluster", "delete", "--name", name]
    }

    /// Stops and deletes every node and removes the cluster from `~/.kube/config`.
    func deleteCluster(_ name: String) async throws {
        do {
            try await run(deleteClusterArguments(name))
        } catch {
            throw KubeClusterParser.explain(error)
        }
        try? FileManager.default.removeItem(at: KubernetesConfig.appKubeconfig(for: name))
    }

    /// Starts a stopped cluster: control plane first, then workers. The node start
    /// script fixes the API certificate when the node got a new IP, but not the addresses
    /// stored inside the cluster. Use `startClusterAndRepair` for those (KubeRestartRepair.swift).
    func startCluster(_ cluster: KubeCluster) async throws {
        for node in KubeClusterActions.startOrder(cluster) where node.state != .running {
            try await startContainer(node.name)
        }
    }

    /// Stops workers first, then the control plane.
    func stopCluster(_ cluster: KubeCluster) async throws {
        for node in KubeClusterActions.startOrder(cluster).reversed() where node.state == .running {
            try await stopContainer(node.name)
        }
    }

    func loadImageArguments(cluster: String, image: String, platform: String? = nil, nodes: [String] = []) -> [String] {
        var args = ["cluster", "load-image", "--name", cluster]
        if let platform = CLIText.nonEmpty(platform) { args += ["--platform", platform] }
        for node in nodes where !node.isEmpty { args += ["--node", node] }
        args.append(image.trimmingCharacters(in: .whitespaces))
        return args
    }

    /// Copies a local image into the nodes' containerd, so pods can use it without a registry
    /// (set `imagePullPolicy: Never` or `IfNotPresent`).
    func loadImage(intoCluster cluster: String, image: String, platform: String? = nil, nodes: [String] = []) async throws {
        do {
            try await run(loadImageArguments(cluster: cluster, image: image, platform: platform, nodes: nodes))
        } catch {
            throw KubeClusterParser.explain(error)
        }
    }

    func writeKubeconfigArguments(_ cluster: String, path: String? = nil) -> [String] {
        var args = ["cluster", "write-config", "--name", cluster]
        if let path = CLIText.nonEmpty(path) { args += ["--kubeconfig", path] }
        return args
    }

    /// Writes or updates the cluster's entry in a kubeconfig file. nil means `~/.kube/config`.
    /// A file that held nothing else also gets this cluster as its current context, so
    /// `kubectl --kubeconfig <file>` works without `--context`.
    func writeKubeconfig(_ cluster: String, to file: URL? = nil) async throws {
        let existed = file.map { FileManager.default.fileExists(atPath: $0.path) } ?? true
        do {
            try await run(writeKubeconfigArguments(cluster, path: file?.path))
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
