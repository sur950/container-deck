import Foundation

/// A cluster as the cluster service of container 1.7 records it
/// (`container cluster list --format json`). The service stores what was asked for at
/// create time and adds the live state of each node:
///
///     [{"id": "dev", "configuration": {"name": "dev", "kubernetesVersion": "v1.35.5",
///       "sharedImageStore": true, "remove": false, "creationDate": "2026-11-09T10:06:45Z",
///       "nodes": [{"name": "dev", "kind": "linux", "roles": ["control-plane", "worker"]}], ...},
///       "status": {"state": "running", "nodes": [{"name": "dev", "status": "running",
///       "addresses": ["192.168.64.3"], "ports": ["6445->6443"]}]}}]
///
/// Clusters made by 1.6 and older have no record, so they are not in this list.
public struct KubeClusterRecord: Sendable, Equatable {
    public struct Node: Sendable, Equatable {
        public var name: String
        public var roles: [String]
        /// Live state. A node whose container is gone reads "stopped".
        public var state: ContainerRunState
        public var addresses: [String]
        public var ports: [PortMapping]

        public init(name: String, roles: [String], state: ContainerRunState, addresses: [String] = [], ports: [PortMapping] = []) {
            self.name = name
            self.roles = roles
            self.state = state
            self.addresses = addresses
            self.ports = ports
        }
    }

    public var name: String
    public var kubernetesVersion: String?
    public var sharedImageStore: Bool
    public var removeOnStop: Bool
    public var createdAt: Date?
    public var nodes: [Node]

    public init(name: String, kubernetesVersion: String? = nil, sharedImageStore: Bool = false, removeOnStop: Bool = false,
                createdAt: Date? = nil, nodes: [Node] = []) {
        self.name = name
        self.kubernetesVersion = kubernetesVersion
        self.sharedImageStore = sharedImageStore
        self.removeOnStop = removeOnStop
        self.createdAt = createdAt
        self.nodes = nodes
    }
}

public extension KubeClusterParser {
    /// Reads `container cluster list --format json` (1.7). Unknown keys are ignored and a
    /// node without a status reads stopped, so later releases that add fields still parse.
    /// Throws when the text is not a JSON list.
    static func parseClusterJSON(_ text: String) throws -> [KubeClusterRecord] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let list = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            throw DeckError.parse("The cluster list is not in the expected JSON format.")
        }
        return list.compactMap { item -> KubeClusterRecord? in
            guard let object = item as? [String: Any] else { return nil }
            let configuration = object["configuration"] as? [String: Any] ?? [:]
            guard let name = (configuration["name"] as? String) ?? (object["id"] as? String), !name.isEmpty else { return nil }
            let status = object["status"] as? [String: Any] ?? [:]
            var live: [String: [String: Any]] = [:]
            for case let node as [String: Any] in status["nodes"] as? [Any] ?? [] {
                if let nodeName = node["name"] as? String { live[nodeName] = node }
            }

            var nodes: [KubeClusterRecord.Node] = []
            var seen = Set<String>()
            for case let node as [String: Any] in configuration["nodes"] as? [Any] ?? [] {
                guard let nodeName = node["name"] as? String, seen.insert(nodeName).inserted else { continue }
                nodes.append(recordNode(nodeName, roles: node["roles"] as? [String] ?? [], live: live[nodeName]))
            }
            // A node the service reports but the configuration does not list (should not happen).
            for (nodeName, state) in live.sorted(by: { $0.key < $1.key }) where !seen.contains(nodeName) {
                nodes.append(recordNode(nodeName, roles: [], live: state))
            }

            return KubeClusterRecord(
                name: name,
                kubernetesVersion: configuration["kubernetesVersion"] as? String,
                sharedImageStore: configuration["sharedImageStore"] as? Bool ?? false,
                removeOnStop: configuration["remove"] as? Bool ?? false,
                createdAt: (configuration["creationDate"] as? String).flatMap(DeckDate.parse),
                nodes: nodes
            )
        }
    }

    private static func recordNode(_ name: String, roles: [String], live: [String: Any]?) -> KubeClusterRecord.Node {
        let state = (live?["status"] as? String).flatMap { ContainerRunState(rawValue: $0.lowercased()) } ?? .stopped
        let addresses = (live?["addresses"] as? [String] ?? []).compactMap(MachineParser.cleanIP)
        let ports = parsePorts((live?["ports"] as? [String] ?? []).joined(separator: ","))
        return KubeClusterRecord.Node(name: name, roles: roles, state: state, addresses: addresses, ports: ports)
    }

    /// Node names from the records, control plane first, as the service lists them.
    static func nodeNames(_ records: [KubeClusterRecord]) -> [String] {
        records.flatMap { $0.nodes.map(\.name) }
    }

    /// Clusters from the node containers (labels, sizes, image, dates) plus the records of
    /// the cluster service (1.7). Records add the shared image store setting and the
    /// Kubernetes version, and keep a cluster visible when its node containers are gone
    /// (a `--rm` cluster that stopped), so it can still be deleted. Clusters without a
    /// record (made by 1.6 or older) come from their containers alone.
    static func clusters(nodes containers: [ContainerSummary], records: [KubeClusterRecord]) -> [KubeCluster] {
        var result = clusters(from: containers)
        for record in records {
            if let index = result.firstIndex(where: { $0.name == record.name }) {
                result[index].sharedImageStore = record.sharedImageStore
                result[index].kubernetesVersion = record.kubernetesVersion
                let known = Set(result[index].nodes.map(\.name))
                for node in record.nodes where !known.contains(node.name) {
                    result[index].nodes.append(placeholder(node, cluster: record))
                }
            } else {
                result.append(KubeCluster(
                    name: record.name,
                    nodes: record.nodes.map { placeholder($0, cluster: record) },
                    sharedImageStore: record.sharedImageStore,
                    kubernetesVersion: record.kubernetesVersion
                ))
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A node known only from the record. Its role comes from the record's roles.
    static func placeholder(_ node: KubeClusterRecord.Node, cluster: KubeClusterRecord) -> KubeClusterNode {
        KubeClusterNode(
            name: node.name,
            cluster: cluster.name,
            role: role(node.roles.joined(separator: ",")),
            state: node.state,
            ipAddress: node.addresses.first,
            ports: node.ports,
            createdAt: cluster.createdAt
        )
    }
}
