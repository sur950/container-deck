import Foundation

/// One node of a local cluster. Each node is a container made by the `cluster` plugin.
public struct KubeClusterNode: Identifiable, Sendable, Hashable {
    public enum Role: String, Sendable, Hashable {
        /// Control plane that also runs workloads (a cluster without workers).
        case controlPlaneWorker
        case controlPlane
        case worker

        public var title: String {
            switch self {
            case .controlPlaneWorker: return "Control plane"
            case .controlPlane: return "Control plane"
            case .worker: return "Worker"
            }
        }

        public var isControlPlane: Bool { self != .worker }
    }

    public var id: String { name }
    public var name: String
    public var cluster: String
    public var role: Role
    public var state: ContainerRunState
    public var cpus: Int?
    public var memoryBytes: UInt64?
    public var ipAddress: String?
    public var ports: [PortMapping]
    /// Node image, as the container reports it.
    public var image: String
    public var createdAt: Date?

    public init(
        name: String, cluster: String, role: Role, state: ContainerRunState, cpus: Int? = nil,
        memoryBytes: UInt64? = nil, ipAddress: String? = nil, ports: [PortMapping] = [],
        image: String = "", createdAt: Date? = nil
    ) {
        self.name = name
        self.cluster = cluster
        self.role = role
        self.state = state
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        self.ipAddress = ipAddress
        self.ports = ports
        self.image = image
        self.createdAt = createdAt
    }

    /// "6445->6443", like `container cluster list`.
    public var portsText: String {
        ports.map { "\($0.hostPort)->\($0.containerPort)" }.joined(separator: ", ")
    }
}

/// A local Kubernetes cluster: one control plane node plus optional workers.
public struct KubeCluster: Identifiable, Sendable, Hashable {
    public var id: String { name }
    public var name: String
    public var nodes: [KubeClusterNode]

    public init(name: String, nodes: [KubeClusterNode]) {
        self.name = name
        self.nodes = nodes
    }

    public var controlPlane: KubeClusterNode? { nodes.first(where: { $0.role.isControlPlane }) }
    public var workers: [KubeClusterNode] { nodes.filter { $0.role == .worker } }

    /// Running when every node runs, stopped when none does.
    public var state: KubeClusterState {
        let running = nodes.filter { $0.state == .running }.count
        if nodes.isEmpty { return .stopped }
        if running == nodes.count { return .running }
        if running == 0 {
            return nodes.contains(where: { $0.state == .stopping }) ? .stopping : .stopped
        }
        return .partial
    }

    /// Host port of the API server, "127.0.0.1:<port>".
    public var apiServerHostPort: Int? {
        controlPlane?.ports.first(where: { $0.containerPort == KubernetesConfig.apiServerPort })?.hostPort
    }

    public var apiServerURL: String? {
        apiServerHostPort.map { "https://127.0.0.1:\($0)" }
    }

    /// Kubernetes version from the node image tag, when the image has one.
    public var imageVersion: String? {
        controlPlane.flatMap { KubernetesConfig.version(fromNodeImage: $0.image) }
    }

    public var totalCPUs: Int { nodes.compactMap(\.cpus).reduce(0, +) }
    public var totalMemoryBytes: UInt64 { nodes.compactMap(\.memoryBytes).reduce(0, +) }
    public var createdAt: Date? { controlPlane?.createdAt }
}

public enum KubeClusterState: String, Sendable, Hashable {
    case running, stopped, stopping, partial

    public var title: String {
        switch self {
        case .running: return "Running"
        case .stopped: return "Stopped"
        case .stopping: return "Stopping"
        case .partial: return "Partly running"
        }
    }

    /// Closest container state, for StatusPill.
    public var runState: ContainerRunState {
        switch self {
        case .running: return .running
        case .stopped: return .stopped
        case .stopping: return .stopping
        case .partial: return .unknown
        }
    }
}

/// Which network plugin a new cluster gets.
public enum KubeCNIChoice: Sendable, Hashable, Codable {
    /// kindnet, bundled with the plugin.
    case kindnet
    /// No network plugin. Nodes stay "Waiting for CNI" until you apply one.
    case none
    /// A manifest file on this Mac.
    case manifest(String)

    public var title: String {
        switch self {
        case .kindnet: return "kindnet"
        case .none: return "None"
        case .manifest(let path): return (path as NSString).lastPathComponent
        }
    }
}

/// Everything the create sheet asks for. Also saved so Recreate can make the same cluster.
public struct KubeClusterOptions: Sendable, Hashable, Codable {
    public var name: String
    /// Full node image reference. Empty means the plugin default.
    public var nodeImage: String
    public var workers: Int
    public var cni: KubeCNIChoice
    public var cpus: Int?
    /// Memory with a unit, like "4G".
    public var memory: String?
    public var removeOnStop: Bool

    public init(
        name: String = KubernetesConfig.defaultClusterName, nodeImage: String = "", workers: Int = 0,
        cni: KubeCNIChoice = .kindnet, cpus: Int? = nil, memory: String? = nil, removeOnStop: Bool = false
    ) {
        self.name = name
        self.nodeImage = nodeImage
        self.workers = workers
        self.cni = cni
        self.cpus = cpus
        self.memory = memory
        self.removeOnStop = removeOnStop
    }

    /// Options that would make this cluster again, from what the nodes report.
    public static func recreate(_ cluster: KubeCluster, saved: KubeClusterOptions?) -> KubeClusterOptions {
        if var saved, saved.name == cluster.name {
            saved.workers = cluster.workers.count
            return saved
        }
        let node = cluster.controlPlane
        var image = node?.image ?? ""
        // The plugin needs a tagged image. The default one is listed by digest only,
        // so an untagged image means "use the plugin default".
        if KubernetesConfig.version(fromNodeImage: image) == nil { image = "" }
        return KubeClusterOptions(
            name: cluster.name,
            nodeImage: image,
            workers: cluster.workers.count,
            cni: .kindnet,
            cpus: node?.cpus,
            memory: node?.memoryBytes.map { "\(max(1, $0 / 1_048_576))M" }
        )
    }
}

// MARK: - Grouping and parsing

public enum KubeClusterParser {
    /// Groups the plugin's node containers into clusters. Same rules as the plugin's
    /// `cluster list`: workers are named `<cluster>-worker-<n>`.
    public static func clusters(from containers: [ContainerSummary]) -> [KubeCluster] {
        let nodes = containers.filter { $0.labels[KubernetesConfig.pluginLabel] == KubernetesConfig.pluginName }
        var controlPlanes: [ContainerSummary] = []
        var workers: [ContainerSummary] = []
        for node in nodes {
            if roles(node.labels[KubernetesConfig.roleLabel]).contains(KubernetesConfig.controlPlaneRole) {
                controlPlanes.append(node)
            } else {
                workers.append(node)
            }
        }

        var result: [KubeCluster] = []
        var assigned = Set<String>()
        for cp in controlPlanes.sorted(by: { $0.id < $1.id }) {
            var list = [node(cp, cluster: cp.id)]
            let own = workers.filter { $0.id.hasPrefix("\(cp.id)-worker-") }.sorted(by: workerOrder)
            for worker in own {
                list.append(node(worker, cluster: cp.id))
                assigned.insert(worker.id)
            }
            result.append(KubeCluster(name: cp.id, nodes: list))
        }

        // Workers whose control plane is gone still show, so they can be deleted.
        var orphans: [String: [KubeClusterNode]] = [:]
        for worker in workers where !assigned.contains(worker.id) {
            let name = clusterName(forWorker: worker.id)
            orphans[name, default: []].append(node(worker, cluster: name))
        }
        for (name, list) in orphans.sorted(by: { $0.key < $1.key }) {
            result.append(KubeCluster(name: name, nodes: list.sorted { $0.name < $1.name }))
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// "a-worker-10" sorts after "a-worker-2".
    static func workerOrder(_ a: ContainerSummary, _ b: ContainerSummary) -> Bool {
        a.id.localizedStandardCompare(b.id) == .orderedAscending
    }

    static func clusterName(forWorker id: String) -> String {
        let parts = id.components(separatedBy: "-worker-")
        return parts.count > 1 ? parts.dropLast().joined(separator: "-worker-") : id
    }

    static func roles(_ raw: String?) -> [String] {
        (raw ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func role(_ raw: String?) -> KubeClusterNode.Role {
        let list = roles(raw)
        if list.contains(KubernetesConfig.controlPlaneRole) {
            return list.contains(KubernetesConfig.workerRole) ? .controlPlaneWorker : .controlPlane
        }
        return .worker
    }

    static func node(_ container: ContainerSummary, cluster: String) -> KubeClusterNode {
        KubeClusterNode(
            name: container.id,
            cluster: cluster,
            role: role(container.labels[KubernetesConfig.roleLabel]),
            state: container.state,
            cpus: container.cpus,
            memoryBytes: container.memoryBytes,
            ipAddress: MachineParser.cleanIP(container.ipAddress),
            ports: container.ports,
            image: container.image,
            createdAt: container.createdAt
        )
    }

    /// Parses the table `container cluster list` prints. Used when the container list
    /// is not available. Columns are found from the header, since empty cells are blank.
    public static func parseTable(_ text: String) -> [KubeCluster] {
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let header = lines.first, header.hasPrefix("CLUSTER") else { return [] }
        let names = ["CLUSTER", "NODE", "ROLE", "STATE", "CPUS", "MEMORY", "ADDR", "PORTS"]
        var starts: [Int] = []
        for name in names {
            guard let range = header.range(of: name, range: header.index(header.startIndex, offsetBy: starts.last ?? 0)..<header.endIndex) else { return [] }
            starts.append(header.distance(from: header.startIndex, to: range.lowerBound))
        }

        func cell(_ row: [Character], _ index: Int) -> String {
            let start = starts[index]
            guard start < row.count else { return "" }
            let end = index + 1 < starts.count ? min(starts[index + 1], row.count) : row.count
            return String(row[start..<end]).trimmingCharacters(in: .whitespaces)
        }

        var order: [String] = []
        var grouped: [String: [KubeClusterNode]] = [:]
        for line in lines.dropFirst() {
            let row = Array(line)
            let cluster = cell(row, 0)
            let name = cell(row, 1)
            guard !cluster.isEmpty, !name.isEmpty else { continue }
            let memoryText = cell(row, 5).replacingOccurrences(of: " MB", with: "")
            let node = KubeClusterNode(
                name: name,
                cluster: cluster,
                role: role(cell(row, 2)),
                state: ContainerRunState(rawValue: cell(row, 3).lowercased()) ?? .unknown,
                cpus: Int(cell(row, 4)),
                memoryBytes: UInt64(memoryText).map { $0 * 1_048_576 },
                ipAddress: cell(row, 6).split(separator: ",").first.map(String.init),
                ports: parsePorts(cell(row, 7))
            )
            if grouped[cluster] == nil { order.append(cluster) }
            grouped[cluster, default: []].append(node)
        }
        return order.map { KubeCluster(name: $0, nodes: grouped[$0] ?? []) }
    }

    /// "6445->6443,6446->80".
    static func parsePorts(_ text: String) -> [PortMapping] {
        text.split(separator: ",").compactMap { item in
            let parts = item.components(separatedBy: "->")
            guard parts.count == 2,
                  let host = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                  let container = Int(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
            return PortMapping(hostPort: host, containerPort: container)
        }
    }

    // MARK: - Errors

    /// True when this container tool has no `cluster` command.
    public static func isUnsupported(_ error: Error) -> Bool {
        isUnsupportedText(error.localizedDescription)
    }

    public static func isUnsupportedText(_ text: String) -> Bool {
        let lower = text.lowercased()
        let unknown = lower.contains("unknown command") || lower.contains("unexpected argument")
            || lower.contains("not a valid subcommand") || lower.contains("plugin")
        return unknown && lower.contains("cluster")
    }

    /// Short message for the common failures.
    public static func friendlyMessage(for text: String) -> String? {
        let lower = text.lowercased()
        if lower.contains("not a valid container id") {
            return "Use letters, numbers, dots, dashes and underscores for the cluster name."
        }
        if lower.contains("already exists") {
            return "A container with this name already exists. Pick another cluster name."
        }
        if lower.contains("cni manifest not found") {
            return "The network plugin file was not found."
        }
        if lower.contains("is not a cluster") {
            return "That container is not a cluster made by the cluster plugin."
        }
        if lower.contains("no published port") {
            return "The cluster has no API port on this Mac. Recreate the cluster."
        }
        return nil
    }

    public static func explain(_ error: Error) -> Error {
        let text = error.localizedDescription
        if isUnsupportedText(text) {
            return DeckError.commandFailed("This version of Apple's container tool has no cluster command. Update it to use Kubernetes.")
        }
        if let friendly = friendlyMessage(for: text) {
            return DeckError.commandFailed("\(friendly)\n\nDetails: \(text)")
        }
        return error
    }
}
