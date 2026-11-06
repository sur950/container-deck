import Foundation

// Slim views of Kubernetes objects, read from the REST API (JSON). Only the fields
// the app shows are decoded, and every field is optional, so new API versions
// and odd objects never break the list.

public struct KubeNamespace: Identifiable, Sendable, Hashable {
    public var id: String { name }
    public var name: String
    public var phase: String
    public var createdAt: Date?
}

public struct KubeNodeStatus: Identifiable, Sendable, Hashable {
    public var id: String { name }
    public var name: String
    /// nil when the node has no Ready condition yet.
    public var ready: Bool?
    public var reason: String?
    public var message: String?
    public var kubeletVersion: String?
    public var internalIP: String?
    public var roles: [String]
    public var cpuCapacity: String?
    public var memoryCapacity: String?
    public var osImage: String?
    public var containerRuntime: String?

    /// The kubelet says the network plugin is missing: the cluster was made without a CNI
    /// or the CNI is still starting.
    public var waitingForCNI: Bool {
        guard ready != true else { return false }
        let text = "\(reason ?? "") \(message ?? "")".lowercased()
        return text.contains("cni") || text.contains("networkpluginnotready") || text.contains("network plugin")
    }

    public var statusText: String {
        switch ready {
        case .some(true): return "Ready"
        case .some(false): return waitingForCNI ? "Waiting for CNI" : "Not ready"
        case .none: return "Unknown"
        }
    }
}

public struct KubeContainerPort: Sendable, Hashable {
    public var name: String?
    public var port: Int
    public var proto: String
}

public struct KubePod: Identifiable, Sendable, Hashable {
    public var id: String { "\(namespace)/\(name)" }
    public var namespace: String
    public var name: String
    public var phase: String
    /// kubectl style status: Running, Pending, ContainerCreating, CrashLoopBackOff, Completed, Terminating.
    public var status: String
    public var readyCount: Int
    public var containerCount: Int
    public var restarts: Int
    public var node: String?
    public var podIP: String?
    public var createdAt: Date?
    public var containers: [String]
    public var ports: [KubeContainerPort]
    public var ownerKind: String?
    public var ownerName: String?
    public var message: String?

    public var readyText: String { "\(readyCount)/\(containerCount)" }

    public var health: KubeHealth {
        switch status {
        case "Running": return readyCount == containerCount ? .good : .waiting
        case "Completed", "Succeeded": return .done
        case "Pending", "ContainerCreating", "PodInitializing", "Terminating": return .waiting
        default:
            return status.hasPrefix("Init:") ? .waiting : .bad
        }
    }
}

public struct KubeDeployment: Identifiable, Sendable, Hashable {
    public var id: String { "\(namespace)/\(name)" }
    public var namespace: String
    public var name: String
    public var desired: Int
    public var ready: Int
    public var updated: Int
    public var available: Int
    public var images: [String]
    public var createdAt: Date?

    public var readyText: String { "\(ready)/\(desired)" }

    public var health: KubeHealth {
        if desired == 0 { return .done }
        if ready >= desired { return .good }
        return available > 0 ? .waiting : .bad
    }
}

public struct KubeServicePort: Sendable, Hashable {
    public var name: String?
    public var port: Int
    public var targetPort: String?
    public var nodePort: Int?
    public var proto: String

    /// "80/TCP" or "80:30080/TCP".
    public var text: String {
        let node = nodePort.map { ":\($0)" } ?? ""
        return "\(port)\(node)/\(proto)"
    }
}

public struct KubeService: Identifiable, Sendable, Hashable {
    public var id: String { "\(namespace)/\(name)" }
    public var namespace: String
    public var name: String
    public var type: String
    public var clusterIP: String?
    public var ports: [KubeServicePort]
    public var selector: [String: String]
    public var createdAt: Date?

    public var portsText: String {
        ports.isEmpty ? "-" : ports.map(\.text).joined(separator: ", ")
    }
}

public struct KubeEvent: Identifiable, Sendable, Hashable {
    public var id: String
    public var namespace: String
    public var type: String
    public var reason: String
    public var message: String
    /// "Pod/web-1".
    public var object: String
    public var count: Int
    public var lastSeen: Date?

    public var isWarning: Bool { type == "Warning" }
}

/// Simple health used to color rows.
public enum KubeHealth: Sendable, Hashable {
    case good, waiting, bad, done
}

// MARK: - Decoding

enum KubeRaw {
    struct List<T: Decodable>: Decodable {
        var items: [T]?
    }

    struct Meta: Decodable {
        struct Owner: Decodable { var kind: String?; var name: String? }
        var name: String?
        var namespace: String?
        var uid: String?
        var creationTimestamp: String?
        var deletionTimestamp: String?
        var labels: [String: String]?
        var ownerReferences: [Owner]?
    }

    struct Namespace: Decodable {
        struct Status: Decodable { var phase: String? }
        var metadata: Meta?
        var status: Status?
    }

    struct Node: Decodable {
        struct Condition: Decodable { var type: String?; var status: String?; var reason: String?; var message: String? }
        struct Address: Decodable { var type: String?; var address: String? }
        struct Info: Decodable { var kubeletVersion: String?; var osImage: String?; var containerRuntimeVersion: String? }
        struct Status: Decodable {
            var conditions: [Condition]?
            var addresses: [Address]?
            var capacity: [String: String]?
            var nodeInfo: Info?
        }
        var metadata: Meta?
        var status: Status?
    }

    struct Port: Decodable { var name: String?; var containerPort: Int?; var `protocol`: String? }

    struct Pod: Decodable {
        struct Container: Decodable { var name: String?; var ports: [Port]? }
        struct Spec: Decodable {
            var nodeName: String?
            var containers: [Container]?
            var initContainers: [Container]?
        }
        struct StateDetail: Decodable { var reason: String?; var message: String?; var exitCode: Int? }
        struct ContainerState: Decodable { var waiting: StateDetail?; var running: StateDetail?; var terminated: StateDetail? }
        struct ContainerStatus: Decodable {
            var name: String?
            var ready: Bool?
            var restartCount: Int?
            var state: ContainerState?
        }
        struct Condition: Decodable { var type: String?; var status: String?; var reason: String?; var message: String? }
        struct Status: Decodable {
            var phase: String?
            var reason: String?
            var message: String?
            var podIP: String?
            var conditions: [Condition]?
            var containerStatuses: [ContainerStatus]?
            var initContainerStatuses: [ContainerStatus]?
        }
        var metadata: Meta?
        var spec: Spec?
        var status: Status?
    }

    struct Deployment: Decodable {
        struct Container: Decodable { var image: String? }
        struct PodSpec: Decodable { var containers: [Container]? }
        struct Template: Decodable { var spec: PodSpec? }
        struct Spec: Decodable { var replicas: Int?; var template: Template? }
        struct Status: Decodable {
            var replicas: Int?
            var readyReplicas: Int?
            var updatedReplicas: Int?
            var availableReplicas: Int?
        }
        var metadata: Meta?
        var spec: Spec?
        var status: Status?
    }

    struct Service: Decodable {
        enum IntOrString: Decodable {
            case int(Int), string(String)
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let value = try? c.decode(Int.self) { self = .int(value) } else { self = .string(try c.decode(String.self)) }
            }
            var text: String {
                switch self {
                case .int(let value): return String(value)
                case .string(let value): return value
                }
            }
        }
        struct Port: Decodable {
            var name: String?
            var port: Int?
            var targetPort: IntOrString?
            var nodePort: Int?
            var `protocol`: String?
        }
        struct Spec: Decodable {
            var type: String?
            var clusterIP: String?
            var ports: [Port]?
            var selector: [String: String]?
        }
        var metadata: Meta?
        var spec: Spec?
    }

    struct Event: Decodable {
        struct Object: Decodable { var kind: String?; var name: String? }
        struct Series: Decodable { var count: Int?; var lastObservedTime: String? }
        var metadata: Meta?
        var type: String?
        var reason: String?
        var message: String?
        var note: String?
        var involvedObject: Object?
        var regarding: Object?
        var count: Int?
        var series: Series?
        var lastTimestamp: String?
        var eventTime: String?
        var firstTimestamp: String?
    }

    struct Version: Decodable { var gitVersion: String? }
}

public enum KubeParser {
    static func list<T: Decodable>(_ type: T.Type, _ data: Data, what: String) throws -> [T] {
        do {
            return try JSONDecoder().decode(KubeRaw.List<T>.self, from: data).items ?? []
        } catch {
            throw DeckError.parse(what)
        }
    }

    static func date(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        return DeckDate.parse(text)
    }

    public static func namespaces(_ data: Data) throws -> [KubeNamespace] {
        try list(KubeRaw.Namespace.self, data, what: "the namespace list").compactMap { item in
            guard let name = item.metadata?.name else { return nil }
            return KubeNamespace(name: name, phase: item.status?.phase ?? "Active", createdAt: date(item.metadata?.creationTimestamp))
        }
        .sorted { $0.name < $1.name }
    }

    public static func nodes(_ data: Data) throws -> [KubeNodeStatus] {
        try list(KubeRaw.Node.self, data, what: "the node list").compactMap { item in
            guard let name = item.metadata?.name else { return nil }
            let ready = item.status?.conditions?.first(where: { $0.type == "Ready" })
            let roles = (item.metadata?.labels ?? [:]).keys
                .filter { $0.hasPrefix("node-role.kubernetes.io/") }
                .map { String($0.dropFirst("node-role.kubernetes.io/".count)) }
                .sorted()
            return KubeNodeStatus(
                name: name,
                ready: ready.map { $0.status == "True" },
                reason: ready?.reason,
                message: ready?.message,
                kubeletVersion: item.status?.nodeInfo?.kubeletVersion,
                internalIP: item.status?.addresses?.first(where: { $0.type == "InternalIP" })?.address,
                roles: roles,
                cpuCapacity: item.status?.capacity?["cpu"],
                memoryCapacity: item.status?.capacity?["memory"],
                osImage: item.status?.nodeInfo?.osImage,
                containerRuntime: item.status?.nodeInfo?.containerRuntimeVersion
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func pods(_ data: Data) throws -> [KubePod] {
        try list(KubeRaw.Pod.self, data, what: "the pod list").compactMap(pod)
            .sorted { ($0.namespace, $0.name) < ($1.namespace, $1.name) }
    }

    static func pod(_ item: KubeRaw.Pod) -> KubePod? {
        guard let name = item.metadata?.name else { return nil }
        let statuses = item.status?.containerStatuses ?? []
        let containers = (item.spec?.containers ?? []).compactMap(\.name)
        let ports = (item.spec?.containers ?? []).flatMap { $0.ports ?? [] }.compactMap { port -> KubeContainerPort? in
            guard let number = port.containerPort else { return nil }
            return KubeContainerPort(name: port.name, port: number, proto: port.protocol ?? "TCP")
        }
        let owner = item.metadata?.ownerReferences?.first
        return KubePod(
            namespace: item.metadata?.namespace ?? "default",
            name: name,
            phase: item.status?.phase ?? "Unknown",
            status: podStatus(item),
            readyCount: statuses.filter { $0.ready == true }.count,
            containerCount: max(containers.count, statuses.count),
            restarts: statuses.compactMap(\.restartCount).reduce(0, +),
            node: item.spec?.nodeName,
            podIP: item.status?.podIP,
            createdAt: date(item.metadata?.creationTimestamp),
            containers: containers,
            ports: ports,
            ownerKind: owner?.kind,
            ownerName: owner?.name,
            message: item.status?.message ?? item.status?.conditions?.first(where: { $0.status == "False" && $0.message != nil })?.message
        )
    }

    /// Same idea as the STATUS column of `kubectl get pods`.
    static func podStatus(_ item: KubeRaw.Pod) -> String {
        if item.metadata?.deletionTimestamp != nil { return "Terminating" }
        var status = item.status?.reason ?? item.status?.phase ?? "Unknown"
        let initCount = item.spec?.initContainers?.count ?? 0
        for (index, initStatus) in (item.status?.initContainerStatuses ?? []).enumerated() {
            if let terminated = initStatus.state?.terminated, terminated.exitCode == 0 { continue }
            if let reason = initStatus.state?.terminated?.reason ?? initStatus.state?.waiting?.reason, reason != "PodInitializing" {
                return "Init:\(reason)"
            }
            return "Init:\(index)/\(initCount)"
        }
        var running = false
        for container in (item.status?.containerStatuses ?? []).reversed() {
            if let reason = container.state?.waiting?.reason, !reason.isEmpty {
                status = reason
            } else if let terminated = container.state?.terminated {
                status = terminated.reason ?? "Terminated"
            } else if container.state?.running != nil, container.ready == true {
                running = true
            }
        }
        if status == "Completed", running { status = "Running" }
        if status == "Succeeded" { status = "Completed" }
        return status
    }

    public static func deployments(_ data: Data) throws -> [KubeDeployment] {
        try list(KubeRaw.Deployment.self, data, what: "the deployment list").compactMap { item in
            guard let name = item.metadata?.name else { return nil }
            return KubeDeployment(
                namespace: item.metadata?.namespace ?? "default",
                name: name,
                desired: item.spec?.replicas ?? 1,
                ready: item.status?.readyReplicas ?? 0,
                updated: item.status?.updatedReplicas ?? 0,
                available: item.status?.availableReplicas ?? 0,
                images: (item.spec?.template?.spec?.containers ?? []).compactMap(\.image),
                createdAt: date(item.metadata?.creationTimestamp)
            )
        }
        .sorted { ($0.namespace, $0.name) < ($1.namespace, $1.name) }
    }

    public static func services(_ data: Data) throws -> [KubeService] {
        try list(KubeRaw.Service.self, data, what: "the service list").compactMap { item in
            guard let name = item.metadata?.name else { return nil }
            return KubeService(
                namespace: item.metadata?.namespace ?? "default",
                name: name,
                type: item.spec?.type ?? "ClusterIP",
                clusterIP: item.spec?.clusterIP,
                ports: (item.spec?.ports ?? []).compactMap { port in
                    guard let number = port.port else { return nil }
                    return KubeServicePort(name: port.name, port: number, targetPort: port.targetPort?.text, nodePort: port.nodePort, proto: port.protocol ?? "TCP")
                },
                selector: item.spec?.selector ?? [:],
                createdAt: date(item.metadata?.creationTimestamp)
            )
        }
        .sorted { ($0.namespace, $0.name) < ($1.namespace, $1.name) }
    }

    /// Newest first.
    public static func events(_ data: Data) throws -> [KubeEvent] {
        try list(KubeRaw.Event.self, data, what: "the event list").enumerated().map { index, item in
            let object = item.involvedObject ?? item.regarding
            let seen = date(item.series?.lastObservedTime) ?? date(item.lastTimestamp) ?? date(item.eventTime)
                ?? date(item.firstTimestamp) ?? date(item.metadata?.creationTimestamp)
            return KubeEvent(
                id: item.metadata?.uid ?? "\(index)",
                namespace: item.metadata?.namespace ?? "default",
                type: item.type ?? "Normal",
                reason: item.reason ?? "",
                message: (item.message ?? item.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                object: "\(object?.kind ?? "")/\(object?.name ?? "")",
                count: item.series?.count ?? item.count ?? 1,
                lastSeen: seen
            )
        }
        .sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
    }

    public static func version(_ data: Data) -> String? {
        (try? JSONDecoder().decode(KubeRaw.Version.self, from: data))?.gitVersion
    }

    /// The message of a Kubernetes Status error body, if any.
    public static func statusMessage(_ data: Data) -> String? {
        struct Status: Decodable { var message: String?; var reason: String? }
        guard let status = try? JSONDecoder().decode(Status.self, from: data) else { return nil }
        return status.message ?? status.reason
    }
}
