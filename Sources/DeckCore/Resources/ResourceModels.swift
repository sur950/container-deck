import Foundation

// Shared app models. These are OUR models, not Apple's JSON.
// ContainerClient maps the `container --format json` output into these.
// Owners may ADD fields (with defaults). Do not rename or remove fields.

// MARK: - Containers

public enum ContainerRunState: String, Sendable, Hashable, Codable {
    case running, stopped, stopping, unknown
}

public struct PortMapping: Sendable, Hashable, Codable {
    public var hostAddress: String?
    public var hostPort: Int
    public var containerPort: Int
    public var proto: String // "tcp" or "udp"

    public init(hostAddress: String? = nil, hostPort: Int, containerPort: Int, proto: String = "tcp") {
        self.hostAddress = hostAddress
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.proto = proto
    }

    /// "8080:80/tcp" style text used by `--publish`.
    public var publishArgument: String {
        let host = hostAddress.map { "\($0):" } ?? ""
        return "\(host)\(hostPort):\(containerPort)/\(proto)"
    }
}

public struct ContainerSummary: Identifiable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var image: String
    public var state: ContainerRunState
    public var ipAddress: String?
    public var hostname: String?
    public var ports: [PortMapping]
    public var platform: String
    public var cpus: Int?
    public var memoryBytes: UInt64?
    public var createdAt: Date?
    public var labels: [String: String]
    /// Full init process: executable then arguments.
    public var command: [String]
    /// When the container last started. nil when it never ran or is stopped on older CLIs.
    public var startedAt: Date?

    public init(
        id: String, name: String, image: String, state: ContainerRunState,
        ipAddress: String? = nil, hostname: String? = nil, ports: [PortMapping] = [],
        platform: String = "linux/arm64", cpus: Int? = nil, memoryBytes: UInt64? = nil,
        createdAt: Date? = nil, labels: [String: String] = [:], command: [String] = [],
        startedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.image = image
        self.state = state
        self.ipAddress = ipAddress
        self.hostname = hostname
        self.ports = ports
        self.platform = platform
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        self.createdAt = createdAt
        self.labels = labels
        self.command = command
        self.startedAt = startedAt
    }

    public var isRunning: Bool { state == .running }
}

public struct EnvVar: Sendable, Hashable, Codable, Identifiable {
    public var key: String
    public var value: String
    public var id: String { key }

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

public struct MountInfo: Sendable, Hashable, Codable {
    public var type: String // "bind", "volume", "tmpfs"
    public var source: String
    public var destination: String
    public var readOnly: Bool

    public init(type: String, source: String, destination: String, readOnly: Bool = false) {
        self.type = type
        self.source = source
        self.destination = destination
        self.readOnly = readOnly
    }
}

public struct NetworkAttachment: Sendable, Hashable, Codable {
    public var network: String
    public var ipAddress: String?
    public var gateway: String?
    public var macAddress: String?
    public var hostname: String?

    public init(network: String, ipAddress: String? = nil, gateway: String? = nil, macAddress: String? = nil, hostname: String? = nil) {
        self.network = network
        self.ipAddress = ipAddress
        self.gateway = gateway
        self.macAddress = macAddress
        self.hostname = hostname
    }
}

public struct ContainerDetail: Sendable, Hashable {
    public var summary: ContainerSummary
    public var entrypoint: [String]
    public var workingDir: String?
    public var env: [EnvVar]
    public var mounts: [MountInfo]
    public var networks: [NetworkAttachment]
    public var rosetta: Bool
    /// Pretty printed JSON from `container inspect`.
    public var rawJSON: String
    /// Init process arguments without the executable.
    public var arguments: [String]
    /// User the init process runs as ("0:0", "nginx").
    public var user: String?
    /// Root filesystem mounted read only.
    public var readOnlyRootfs: Bool

    public init(
        summary: ContainerSummary, entrypoint: [String] = [], workingDir: String? = nil,
        env: [EnvVar] = [], mounts: [MountInfo] = [], networks: [NetworkAttachment] = [],
        rosetta: Bool = false, rawJSON: String = "", arguments: [String] = [], user: String? = nil,
        readOnlyRootfs: Bool = false
    ) {
        self.summary = summary
        self.entrypoint = entrypoint
        self.workingDir = workingDir
        self.env = env
        self.mounts = mounts
        self.networks = networks
        self.rosetta = rosetta
        self.rawJSON = rawJSON
        self.arguments = arguments
        self.user = user
        self.readOnlyRootfs = readOnlyRootfs
    }
}

public struct ContainerStats: Sendable, Hashable {
    public var id: String
    public var cpuPercent: Double
    public var memoryUsageBytes: UInt64
    public var memoryLimitBytes: UInt64
    public var netRxBytes: UInt64
    public var netTxBytes: UInt64
    public var blockReadBytes: UInt64
    public var blockWriteBytes: UInt64
    public var pids: Int
    public var timestamp: Date
    /// Cumulative CPU time from the CLI. Two readings give a percent (`StatsMath`).
    public var cpuUsageUsec: UInt64?
    /// Percent the CLI worked out itself (`cpuUtilization`, or the live table). nil when it gave none.
    public var reportedCPUPercent: Double?

    public init(
        id: String, cpuPercent: Double = 0, memoryUsageBytes: UInt64 = 0, memoryLimitBytes: UInt64 = 0,
        netRxBytes: UInt64 = 0, netTxBytes: UInt64 = 0, blockReadBytes: UInt64 = 0, blockWriteBytes: UInt64 = 0,
        pids: Int = 0, timestamp: Date = Date(), cpuUsageUsec: UInt64? = nil, reportedCPUPercent: Double? = nil
    ) {
        self.id = id
        self.cpuPercent = cpuPercent
        self.memoryUsageBytes = memoryUsageBytes
        self.memoryLimitBytes = memoryLimitBytes
        self.netRxBytes = netRxBytes
        self.netTxBytes = netTxBytes
        self.blockReadBytes = blockReadBytes
        self.blockWriteBytes = blockWriteBytes
        self.pids = pids
        self.timestamp = timestamp
        self.cpuUsageUsec = cpuUsageUsec
        self.reportedCPUPercent = reportedCPUPercent
    }
}

public struct LogOptions: Sendable, Hashable {
    public var follow: Bool
    public var tail: Int?
    public var boot: Bool

    public init(follow: Bool = true, tail: Int? = 500, boot: Bool = false) {
        self.follow = follow
        self.tail = tail
        self.boot = boot
    }
}

public struct MountSpec: Sendable, Hashable, Codable, Identifiable {
    public enum Kind: String, Sendable, Hashable, Codable { case bind, volume }
    public var id = UUID()
    public var kind: Kind
    public var source: String // host path or volume name
    public var destination: String
    public var readOnly: Bool

    public init(kind: Kind, source: String, destination: String, readOnly: Bool = false) {
        self.kind = kind
        self.source = source
        self.destination = destination
        self.readOnly = readOnly
    }
}

/// Everything the Run sheet can set. `arguments()` builds the `container run` args.
public struct RunOptions: Sendable, Hashable {
    public var image: String
    public var name: String?
    public var command: [String]
    public var entrypoint: String?
    public var env: [EnvVar]
    public var ports: [PortMapping]
    public var mounts: [MountSpec]
    public var cpus: Int?
    /// Memory like "2G" or "512M".
    public var memory: String?
    public var network: String?
    public var workingDir: String?
    public var labels: [String: String]
    public var detach: Bool
    public var autoRemove: Bool
    /// "linux/amd64" runs with Rosetta. nil means native.
    public var platform: String?

    // Added for a faithful Edit and Recreate. All default to "not set".

    /// `--user`, like "nginx", "1000" or "1000:1000". nil uses the image user.
    public var user: String?
    /// `--read-only`: mount the root filesystem read only.
    public var readOnlyRootfs: Bool
    /// MAC address on the first network (`--network <name>,mac=<mac>`).
    public var macAddress: String?
    /// More `--network` values after the first, like "backend" or "backend,mac=02:42:ac:11:00:02".
    public var extraNetworks: [String]
    /// `--tmpfs` paths inside the container.
    public var tmpfs: [String]
    /// `--cap-add` and `--cap-drop` Linux capabilities.
    public var capAdd: [String]
    public var capDrop: [String]
    /// `--dns`, `--dns-search`, `--dns-option`, `--dns-domain`.
    public var dnsServers: [String]
    public var dnsSearch: [String]
    public var dnsOptions: [String]
    public var dnsDomain: String?
    /// `--no-dns`: do not set up DNS in the container.
    public var noDNS: Bool
    /// `--ulimit` values like "nofile=1024:2048".
    public var ulimits: [String]
    /// `--init`: run a small init process that reaps children.
    public var useInit: Bool
    /// `--rosetta`: Rosetta inside a native container.
    public var rosetta: Bool
    /// `--ssh`: forward the SSH agent socket.
    public var ssh: Bool
    /// `--tty` and `--interactive`.
    public var tty: Bool
    public var interactive: Bool
    /// `--shm-size`, like "64M".
    public var shmSize: String?
    /// `--publish-socket` values, "host_path:container_path".
    public var publishSockets: [String]
    /// Full list of masked paths. nil keeps the runtime defaults. A list
    /// (even empty) is written as `--masked-path NONE` plus each path.
    public var maskedPaths: [String]?
    /// Full list of read only paths, same rules as `maskedPaths`.
    public var readOnlyPaths: [String]?
    /// `--runtime` handler. nil uses the default.
    public var runtime: String?
    /// `--virtualization`: nested virtualization.
    public var virtualization: Bool

    public init(
        image: String, name: String? = nil, command: [String] = [], entrypoint: String? = nil,
        env: [EnvVar] = [], ports: [PortMapping] = [], mounts: [MountSpec] = [], cpus: Int? = nil,
        memory: String? = nil, network: String? = nil, workingDir: String? = nil,
        labels: [String: String] = [:], detach: Bool = true, autoRemove: Bool = false, platform: String? = nil,
        user: String? = nil, readOnlyRootfs: Bool = false, macAddress: String? = nil, extraNetworks: [String] = [],
        tmpfs: [String] = [], capAdd: [String] = [], capDrop: [String] = [],
        dnsServers: [String] = [], dnsSearch: [String] = [], dnsOptions: [String] = [], dnsDomain: String? = nil,
        noDNS: Bool = false, ulimits: [String] = [], useInit: Bool = false, rosetta: Bool = false, ssh: Bool = false,
        tty: Bool = false, interactive: Bool = false, shmSize: String? = nil, publishSockets: [String] = [],
        maskedPaths: [String]? = nil, readOnlyPaths: [String]? = nil, runtime: String? = nil, virtualization: Bool = false
    ) {
        self.user = user
        self.readOnlyRootfs = readOnlyRootfs
        self.macAddress = macAddress
        self.extraNetworks = extraNetworks
        self.tmpfs = tmpfs
        self.capAdd = capAdd
        self.capDrop = capDrop
        self.dnsServers = dnsServers
        self.dnsSearch = dnsSearch
        self.dnsOptions = dnsOptions
        self.dnsDomain = dnsDomain
        self.noDNS = noDNS
        self.ulimits = ulimits
        self.useInit = useInit
        self.rosetta = rosetta
        self.ssh = ssh
        self.tty = tty
        self.interactive = interactive
        self.shmSize = shmSize
        self.publishSockets = publishSockets
        self.maskedPaths = maskedPaths
        self.readOnlyPaths = readOnlyPaths
        self.runtime = runtime
        self.virtualization = virtualization
        self.image = image
        self.name = name
        self.command = command
        self.entrypoint = entrypoint
        self.env = env
        self.ports = ports
        self.mounts = mounts
        self.cpus = cpus
        self.memory = memory
        self.network = network
        self.workingDir = workingDir
        self.labels = labels
        self.detach = detach
        self.autoRemove = autoRemove
        self.platform = platform
    }
}

// MARK: - Images

public struct ImageSummary: Identifiable, Sendable, Hashable {
    /// Full reference, for example "docker.io/library/nginx:latest".
    public var id: String { reference }
    public var reference: String
    public var digest: String
    public var sizeBytes: UInt64
    public var createdAt: Date?
    public var platforms: [String]
    /// Filled by the caller from the container list.
    public var usedBy: [String]

    public init(reference: String, digest: String = "", sizeBytes: UInt64 = 0, createdAt: Date? = nil, platforms: [String] = [], usedBy: [String] = []) {
        self.reference = reference
        self.digest = digest
        self.sizeBytes = sizeBytes
        self.createdAt = createdAt
        self.platforms = platforms
        self.usedBy = usedBy
    }

    /// "nginx" from "docker.io/library/nginx:latest".
    public var shortName: String {
        var name = reference
        if let at = name.firstIndex(of: "@") { name = String(name[..<at]) }
        if let colon = name.lastIndex(of: ":"), !name[colon...].contains("/") { name = String(name[..<colon]) }
        for prefix in ["docker.io/library/", "docker.io/"] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
        }
        return name
    }

    /// "latest" from "docker.io/library/nginx:latest".
    public var tag: String {
        var name = reference
        if let at = name.firstIndex(of: "@") { name = String(name[..<at]) }
        if let colon = name.lastIndex(of: ":"), !name[colon...].contains("/") {
            return String(name[name.index(after: colon)...])
        }
        return "latest"
    }
}

public struct ImageLayer: Sendable, Hashable, Identifiable {
    public var id: String { digest }
    public var digest: String
    public var sizeBytes: UInt64
    public var createdBy: String?

    public init(digest: String, sizeBytes: UInt64 = 0, createdBy: String? = nil) {
        self.digest = digest
        self.sizeBytes = sizeBytes
        self.createdBy = createdBy
    }
}

public struct ImageConfigInfo: Sendable, Hashable {
    public var entrypoint: [String]
    public var cmd: [String]
    public var env: [EnvVar]
    public var workingDir: String?
    public var exposedPorts: [String]
    public var labels: [String: String]
    public var user: String?

    public init(entrypoint: [String] = [], cmd: [String] = [], env: [EnvVar] = [], workingDir: String? = nil, exposedPorts: [String] = [], labels: [String: String] = [:], user: String? = nil) {
        self.entrypoint = entrypoint
        self.cmd = cmd
        self.env = env
        self.workingDir = workingDir
        self.exposedPorts = exposedPorts
        self.labels = labels
        self.user = user
    }
}

public struct ImageDetail: Sendable, Hashable {
    public var summary: ImageSummary
    public var layers: [ImageLayer]
    public var config: ImageConfigInfo
    public var rawJSON: String

    public init(summary: ImageSummary, layers: [ImageLayer] = [], config: ImageConfigInfo = ImageConfigInfo(), rawJSON: String = "") {
        self.summary = summary
        self.layers = layers
        self.config = config
        self.rawJSON = rawJSON
    }
}

public struct BuildOptions: Sendable, Hashable {
    public var contextDir: String
    /// Path to the Dockerfile. nil means "<context>/Dockerfile".
    public var dockerfile: String?
    public var tags: [String]
    public var buildArgs: [EnvVar]
    /// "linux/arm64" or "linux/amd64".
    public var platform: String
    public var target: String?
    public var noCache: Bool

    public init(contextDir: String, dockerfile: String? = nil, tags: [String] = [], buildArgs: [EnvVar] = [], platform: String = "linux/arm64", target: String? = nil, noCache: Bool = false) {
        self.contextDir = contextDir
        self.dockerfile = dockerfile
        self.tags = tags
        self.buildArgs = buildArgs
        self.platform = platform
        self.target = target
        self.noCache = noCache
    }
}

// MARK: - Volumes and networks

public struct VolumeSummary: Identifiable, Sendable, Hashable {
    public var id: String { name }
    public var name: String
    public var sizeBytes: UInt64?
    public var createdAt: Date?
    public var labels: [String: String]
    /// Path of the backing disk image on the Mac, when known.
    public var backingPath: String?
    public var usedBy: [String]
    /// Created on the fly by `-v /path` without a name.
    public var isAnonymous: Bool

    public init(name: String, sizeBytes: UInt64? = nil, createdAt: Date? = nil, labels: [String: String] = [:], backingPath: String? = nil, usedBy: [String] = [], isAnonymous: Bool = false) {
        self.name = name
        self.sizeBytes = sizeBytes
        self.createdAt = createdAt
        self.labels = labels
        self.backingPath = backingPath
        self.usedBy = usedBy
        self.isAnonymous = isAnonymous
    }
}

public struct NetworkSummary: Identifiable, Sendable, Hashable {
    public var id: String { name }
    public var name: String
    public var subnet: String?
    public var gateway: String?
    /// Host only network, no internet access.
    public var isInternal: Bool
    public var state: String
    public var labels: [String: String]
    public var attachedContainers: [String]
    public var ipv6Subnet: String?
    public var createdAt: Date?
    /// Built in networks (like "default") cannot be deleted.
    public var isBuiltin: Bool

    public init(name: String, subnet: String? = nil, gateway: String? = nil, isInternal: Bool = false, state: String = "running", labels: [String: String] = [:], attachedContainers: [String] = [], ipv6Subnet: String? = nil, createdAt: Date? = nil, isBuiltin: Bool = false) {
        self.name = name
        self.subnet = subnet
        self.gateway = gateway
        self.isInternal = isInternal
        self.state = state
        self.labels = labels
        self.attachedContainers = attachedContainers
        self.ipv6Subnet = ipv6Subnet
        self.createdAt = createdAt
        self.isBuiltin = isBuiltin
    }

    public var isDefault: Bool { name == "default" }
}

// MARK: - System

public struct UsageBucket: Sendable, Hashable {
    public var total: Int
    public var active: Int
    public var sizeBytes: UInt64
    public var reclaimableBytes: UInt64

    public init(total: Int = 0, active: Int = 0, sizeBytes: UInt64 = 0, reclaimableBytes: UInt64 = 0) {
        self.total = total
        self.active = active
        self.sizeBytes = sizeBytes
        self.reclaimableBytes = reclaimableBytes
    }
}

public struct DiskUsage: Sendable, Hashable {
    public var images: UsageBucket
    public var containers: UsageBucket
    public var volumes: UsageBucket

    public init(images: UsageBucket = UsageBucket(), containers: UsageBucket = UsageBucket(), volumes: UsageBucket = UsageBucket()) {
        self.images = images
        self.containers = containers
        self.volumes = volumes
    }

    public var totalBytes: UInt64 { images.sizeBytes + containers.sizeBytes + volumes.sizeBytes }
    public var reclaimableBytes: UInt64 { images.reclaimableBytes + containers.reclaimableBytes + volumes.reclaimableBytes }
}

public struct SystemProperty: Sendable, Hashable, Identifiable {
    public var id: String { key }
    public var key: String
    public var value: String
    public var description: String?

    public init(key: String, value: String, description: String? = nil) {
        self.key = key
        self.value = value
        self.description = description
    }
}

// MARK: - Machines

public struct MachineSummary: Identifiable, Sendable, Hashable {
    public var id: String { name }
    public var name: String
    public var image: String
    public var state: ContainerRunState
    public var cpus: Int?
    public var memoryBytes: UInt64?
    public var ipAddress: String?
    public var hostname: String?
    public var isDefault: Bool
    public var homeMount: String?

    public init(name: String, image: String = "", state: ContainerRunState = .unknown, cpus: Int? = nil, memoryBytes: UInt64? = nil, ipAddress: String? = nil, hostname: String? = nil, isDefault: Bool = false, homeMount: String? = nil) {
        self.name = name
        self.image = image
        self.state = state
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        self.ipAddress = ipAddress
        self.hostname = hostname
        self.isDefault = isDefault
        self.homeMount = homeMount
    }
}

public struct MachineOptions: Sendable, Hashable {
    public var name: String
    public var image: String
    public var cpus: Int?
    public var memory: String?
    /// "rw", "ro" or "none".
    public var homeMount: String
    public var boot: Bool

    public init(name: String, image: String, cpus: Int? = nil, memory: String? = nil, homeMount: String = "rw", boot: Bool = true) {
        self.name = name
        self.image = image
        self.cpus = cpus
        self.memory = memory
        self.homeMount = homeMount
        self.boot = boot
    }
}

// MARK: - Files inside a container

public struct FileEntry: Identifiable, Sendable, Hashable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var isDirectory: Bool
    public var isSymlink: Bool
    public var sizeBytes: UInt64
    public var modified: Date?
    public var permissions: String

    public init(name: String, path: String, isDirectory: Bool, isSymlink: Bool = false, sizeBytes: UInt64 = 0, modified: Date? = nil, permissions: String = "") {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.sizeBytes = sizeBytes
        self.modified = modified
        self.permissions = permissions
    }
}

// MARK: - Docker Hub

public struct HubRepository: Identifiable, Sendable, Hashable {
    public var id: String { fullName }
    /// "nginx" for official images, "grafana/grafana" otherwise.
    public var fullName: String
    public var description: String
    public var starCount: Int
    public var pullCount: Int
    public var isOfficial: Bool

    public init(fullName: String, description: String = "", starCount: Int = 0, pullCount: Int = 0, isOfficial: Bool = false) {
        self.fullName = fullName
        self.description = description
        self.starCount = starCount
        self.pullCount = pullCount
        self.isOfficial = isOfficial
    }
}

public struct HubTag: Identifiable, Sendable, Hashable {
    public var id: String { name }
    public var name: String
    public var sizeBytes: UInt64
    public var lastUpdated: Date?
    public var platforms: [String]

    public init(name: String, sizeBytes: UInt64 = 0, lastUpdated: Date? = nil, platforms: [String] = []) {
        self.name = name
        self.sizeBytes = sizeBytes
        self.lastUpdated = lastUpdated
        self.platforms = platforms
    }
}

public struct HubPage<Item: Sendable>: Sendable {
    public var items: [Item]
    public var nextPage: Int?

    public init(items: [Item], nextPage: Int?) {
        self.items = items
        self.nextPage = nextPage
    }
}
