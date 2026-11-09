import Foundation

// Forgiving copies of the Codable types Apple's `container` prints with
// `--format json`. Shapes from both the 1.x releases and current main are read:
//
//   container list / inspect:   [{id, configuration, status: {state, networks, startedDate}}]
//                         older: [{configuration, status: "running", networks, startedDate}]
//   image list / inspect:       [{id, configuration: {name, descriptor, creationDate}, variants}]
//   volume list:                [{id, configuration: {name, source, ...}}]   older: [{name, source, ...}]
//   network list:               [{id, configuration, status}]                older: [{id, state, config, status}]
//   stats --no-stream:          [{id, cpuUsageUsec, memoryUsageBytes, ..., cpuUtilization?}]
//   system df:                  {images, containers, volumes: {total, active, sizeInBytes, reclaimable}}
//
// Every field is optional. Nothing here throws for a missing or odd field.

// MARK: - Shared pieces

struct CLIPlatform: Decodable {
    var os: String?
    var architecture: String?
    var variant: String?

    private enum CodingKeys: String, CodingKey { case os, architecture, variant }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        os = c.laxString(.os)
        architecture = c.laxString(.architecture)
        variant = c.laxString(.variant)
    }

    /// "linux/arm64" or "linux/arm/v7". nil when incomplete.
    var text: String? {
        guard let os = CLIText.nonEmpty(os), let arch = CLIText.nonEmpty(architecture) else { return nil }
        if let variant = CLIText.nonEmpty(variant) {
            return "\(os)/\(arch)/\(variant)"
        }
        return "\(os)/\(arch)"
    }

    /// Attestation manifests use "unknown/unknown".
    var isUnknown: Bool { os == "unknown" || architecture == "unknown" }
}

struct CLIDescriptor: Decodable {
    var mediaType: String?
    var digest: String?
    var size: UInt64?
    var annotations: [String: String]

    private enum CodingKeys: String, CodingKey { case mediaType, digest, size, annotations }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mediaType = c.laxString(.mediaType)
        digest = c.laxString(.digest)
        size = c.laxUInt64(.size)
        annotations = c.laxMap(.annotations) ?? [:]
    }
}

// MARK: - Containers

struct CLIAttachment: Decodable {
    var network: String?
    var hostname: String?
    var ipv4Address: String?
    var ipv4Gateway: String?
    var ipv6Address: String?
    var macAddress: String?

    private enum CodingKeys: String, CodingKey {
        case network, hostname, ipv4Address, ipv4Gateway, ipv6Address, macAddress, address, gateway
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        network = c.laxString(.network)
        hostname = c.laxString(.hostname)
        ipv4Address = c.laxString([.ipv4Address, .address])
        ipv4Gateway = c.laxString([.ipv4Gateway, .gateway])
        ipv6Address = c.laxString(.ipv6Address)
        macAddress = c.laxString(.macAddress)
    }
}

struct CLIAttachmentConfig: Decodable {
    var network: String?
    var hostname: String?
    var macAddress: String?

    private enum CodingKeys: String, CodingKey { case network, options }
    private enum OptionKeys: String, CodingKey { case hostname, macAddress }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        network = c.laxString(.network)
        if let options = try? c.nestedContainer(keyedBy: OptionKeys.self, forKey: .options) {
            hostname = options.laxString(.hostname)
            macAddress = options.laxString(.macAddress)
        }
    }
}

struct CLIPublishPort: Decodable {
    var hostAddress: String?
    var hostPort: Int?
    var containerPort: Int?
    var proto: String?
    var count: Int?

    private enum CodingKeys: String, CodingKey { case hostAddress, hostPort, containerPort, proto, count }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hostAddress = c.laxString(.hostAddress)
        hostPort = c.laxInt(.hostPort)
        containerPort = c.laxInt(.containerPort)
        proto = c.laxString(.proto)
        count = c.laxInt(.count)
    }
}

/// `ProcessConfiguration.User` is an enum: {"id": {"uid": 0, "gid": 0}} or {"raw": {"userString": "nginx"}}.
struct CLIUser: Decodable {
    var text: String?

    private enum IDKeys: String, CodingKey { case uid, gid }
    private enum RawKeys: String, CodingKey { case userString }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let value = try? single.decode(String.self) {
            text = value
            return
        }
        let c = try decoder.container(keyedBy: CLIKey.self)
        if let ids = try? c.nestedContainer(keyedBy: IDKeys.self, forKey: CLIKey("id")) {
            let uid = ids.laxInt(.uid) ?? 0
            let gid = ids.laxInt(.gid) ?? 0
            text = "\(uid):\(gid)"
        } else if let raw = try? c.nestedContainer(keyedBy: RawKeys.self, forKey: CLIKey("raw")) {
            text = raw.laxString(.userString)
        }
    }
}

struct CLIProcess: Decodable {
    var executable: String?
    var arguments: [String]
    var environment: [String]
    var workingDirectory: String?
    var user: String?
    var terminal: Bool

    private enum CodingKeys: String, CodingKey { case executable, arguments, environment, workingDirectory, user, terminal }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        executable = c.laxString(.executable)
        arguments = c.laxStrings(.arguments) ?? []
        environment = c.laxStrings(.environment) ?? []
        workingDirectory = c.laxString(.workingDirectory)
        user = c.lax(CLIUser.self, .user)?.text
        terminal = c.laxBool(.terminal) ?? false
    }
}

/// `Filesystem.FSType` is an enum: {"virtiofs": {}}, {"tmpfs": {}},
/// {"volume": {"name": ..., "format": ...}} or {"block": {...}}.
struct CLIFilesystem: Decodable {
    var kind: String
    var volumeName: String?
    var source: String?
    var destination: String?
    var options: [String]

    private enum CodingKeys: String, CodingKey { case type, source, destination, options }
    private enum VolumeKeys: String, CodingKey { case name }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = c.laxString(.source)
        destination = c.laxString(.destination)
        options = c.laxStrings(.options) ?? []
        kind = "unknown"
        if let text = c.laxString(.type) {
            kind = text
        } else if let type = try? c.nestedContainer(keyedBy: CLIKey.self, forKey: .type), let first = type.allKeys.first {
            kind = first.stringValue
            if kind == "volume", let volume = try? type.nestedContainer(keyedBy: VolumeKeys.self, forKey: first) {
                volumeName = volume.laxString(.name)
            }
        }
    }

    /// Our names: "bind" (virtiofs share), "volume", "tmpfs", "block".
    var displayKind: String {
        switch kind {
        case "virtiofs": return "bind"
        default: return kind
        }
    }
}

struct CLIContainerConfig: Decodable {
    var id: String?
    var imageReference: String?
    var mounts: [CLIFilesystem]
    var publishedPorts: [CLIPublishPort]
    var labels: [String: String]
    var networks: [CLIAttachmentConfig]
    var rosetta: Bool
    var initProcess: CLIProcess?
    var platform: CLIPlatform?
    var cpus: Int?
    var memoryBytes: UInt64?
    var creationDate: Date?
    var readOnly: Bool

    private enum CodingKeys: String, CodingKey {
        case id, image, mounts, publishedPorts, labels, networks, rosetta, initProcess, platform, resources, creationDate, readOnly
    }
    private enum ImageKeys: String, CodingKey { case reference }
    private enum ResourceKeys: String, CodingKey { case cpus, memoryInBytes }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.laxString(.id)
        if let image = try? c.nestedContainer(keyedBy: ImageKeys.self, forKey: .image) {
            imageReference = image.laxString(.reference)
        } else {
            imageReference = c.laxString(.image)
        }
        mounts = c.laxList(CLIFilesystem.self, .mounts)
        publishedPorts = c.laxList(CLIPublishPort.self, .publishedPorts)
        labels = c.laxMap(.labels) ?? [:]
        networks = c.laxList(CLIAttachmentConfig.self, .networks)
        rosetta = c.laxBool(.rosetta) ?? false
        initProcess = c.lax(CLIProcess.self, .initProcess)
        platform = c.lax(CLIPlatform.self, .platform)
        if let resources = try? c.nestedContainer(keyedBy: ResourceKeys.self, forKey: .resources) {
            cpus = resources.laxInt(.cpus)
            memoryBytes = resources.laxUInt64(.memoryInBytes)
        }
        creationDate = DeckDate.meaningful(c.laxDate(.creationDate))
        readOnly = c.laxBool(.readOnly) ?? false
    }
}

struct CLIContainer: Decodable {
    var id: String?
    var configuration: CLIContainerConfig?
    var state: String?
    var networks: [CLIAttachment]
    var startedDate: Date?

    private enum CodingKeys: String, CodingKey { case id, configuration, status, networks, startedDate }
    private enum StatusKeys: String, CodingKey { case state, networks, startedDate }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.laxString(.id)
        configuration = c.lax(CLIContainerConfig.self, .configuration)
        if let status = try? c.nestedContainer(keyedBy: StatusKeys.self, forKey: .status) {
            // Current main: status is an object.
            state = status.laxString(.state)
            networks = status.laxList(CLIAttachment.self, .networks)
            startedDate = status.laxDate(.startedDate)
        } else {
            // 1.x snapshot: status is a string, networks sit next to it.
            state = c.laxString(.status)
            networks = c.laxList(CLIAttachment.self, .networks)
            startedDate = c.laxDate(.startedDate)
        }
        startedDate = DeckDate.meaningful(startedDate)
    }
}

// MARK: - Stats

struct CLIStats: Decodable {
    var id: String?
    var cpuUsageUsec: UInt64?
    var cpuUtilization: Double?
    var memoryUsageBytes: UInt64?
    var memoryLimitBytes: UInt64?
    var networkRxBytes: UInt64?
    var networkTxBytes: UInt64?
    var blockReadBytes: UInt64?
    var blockWriteBytes: UInt64?
    var numProcesses: Int?

    private enum CodingKeys: String, CodingKey {
        case id, cpuUsageUsec, cpuUtilization, memoryUsageBytes, memoryLimitBytes
        case networkRxBytes, networkTxBytes, blockReadBytes, blockWriteBytes, numProcesses
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.laxString(.id)
        cpuUsageUsec = c.laxUInt64(.cpuUsageUsec)
        cpuUtilization = c.laxDouble(.cpuUtilization)
        memoryUsageBytes = c.laxUInt64(.memoryUsageBytes)
        memoryLimitBytes = c.laxUInt64(.memoryLimitBytes)
        networkRxBytes = c.laxUInt64(.networkRxBytes)
        networkTxBytes = c.laxUInt64(.networkTxBytes)
        blockReadBytes = c.laxUInt64(.blockReadBytes)
        blockWriteBytes = c.laxUInt64(.blockWriteBytes)
        numProcesses = c.laxInt(.numProcesses)
    }
}

// MARK: - Images

struct CLIImageConfig: Decodable {
    var user: String?
    var env: [String]
    var entrypoint: [String]
    var cmd: [String]
    var workingDir: String?
    var labels: [String: String]
    var exposedPorts: [String]

    private enum CodingKeys: String, CodingKey {
        case user = "User", env = "Env", entrypoint = "Entrypoint", cmd = "Cmd"
        case workingDir = "WorkingDir", labels = "Labels", exposedPorts = "ExposedPorts"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        user = c.laxString(.user)
        env = c.laxStrings(.env) ?? []
        entrypoint = c.laxStrings(.entrypoint) ?? []
        cmd = c.laxStrings(.cmd) ?? []
        workingDir = c.laxString(.workingDir)
        labels = c.laxMap(.labels) ?? [:]
        exposedPorts = (c.laxKeys(.exposedPorts) ?? []).sorted()
    }
}

struct CLIHistory: Decodable {
    var created: String?
    var createdBy: String?
    var comment: String?
    var emptyLayer: Bool

    private enum CodingKeys: String, CodingKey {
        case created, createdBy = "created_by", comment, emptyLayer = "empty_layer"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        created = c.laxString(.created)
        createdBy = c.laxString(.createdBy)
        comment = c.laxString(.comment)
        emptyLayer = c.laxBool(.emptyLayer) ?? false
    }
}

/// The OCI image config (`application/vnd.oci.image.config.v1+json`).
struct CLIOCIImage: Decodable {
    var created: String?
    var architecture: String?
    var os: String?
    var variant: String?
    var config: CLIImageConfig?
    var diffIDs: [String]
    var history: [CLIHistory]

    private enum CodingKeys: String, CodingKey { case created, architecture, os, variant, config, rootfs, history }
    private enum RootfsKeys: String, CodingKey { case diffIDs = "diff_ids" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        created = c.laxString(.created)
        architecture = c.laxString(.architecture)
        os = c.laxString(.os)
        variant = c.laxString(.variant)
        config = c.lax(CLIImageConfig.self, .config)
        if let rootfs = try? c.nestedContainer(keyedBy: RootfsKeys.self, forKey: .rootfs) {
            diffIDs = rootfs.laxStrings(.diffIDs) ?? []
        } else {
            diffIDs = []
        }
        history = c.laxList(CLIHistory.self, .history)
    }
}

struct CLIImageVariant: Decodable {
    var platform: CLIPlatform?
    var digest: String?
    var size: UInt64?
    var config: CLIOCIImage?

    private enum CodingKeys: String, CodingKey { case platform, digest, size, config }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        platform = c.lax(CLIPlatform.self, .platform)
        digest = c.laxString(.digest)
        size = c.laxUInt64(.size)
        config = c.lax(CLIOCIImage.self, .config)
    }
}

struct CLIImage: Decodable {
    var reference: String?
    var descriptor: CLIDescriptor?
    var creationDate: Date?
    var variants: [CLIImageVariant]
    var fullSize: String?

    private enum CodingKeys: String, CodingKey {
        case configuration, variants, reference, name, descriptor, creationDate, created, fullSize, size
    }
    private enum ConfigurationKeys: String, CodingKey { case name, reference, descriptor, creationDate }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let conf = try? c.nestedContainer(keyedBy: ConfigurationKeys.self, forKey: .configuration) {
            reference = conf.laxString([.name, .reference])
            descriptor = conf.lax(CLIDescriptor.self, .descriptor)
            creationDate = conf.laxDate(.creationDate)
        }
        if reference == nil { reference = c.laxString([.reference, .name]) }
        if descriptor == nil { descriptor = c.lax(CLIDescriptor.self, .descriptor) }
        if creationDate == nil { creationDate = c.laxDate([.creationDate, .created]) }
        creationDate = DeckDate.meaningful(creationDate)
        variants = c.laxList(CLIImageVariant.self, .variants)
        fullSize = c.laxString([.fullSize, .size])
    }

    /// Variants for real platforms (no attestation manifests).
    var platformVariants: [CLIImageVariant] {
        variants.filter { !($0.platform?.isUnknown ?? true) }
    }
}

// MARK: - Volumes and networks

struct CLIVolume: Decodable {
    var name: String?
    var source: String?
    var creationDate: Date?
    var labels: [String: String]
    var options: [String: String]
    var sizeInBytes: UInt64?

    private enum CodingKeys: String, CodingKey {
        case configuration, name, id, source, creationDate, createdAt, labels, options, sizeInBytes
    }

    init(from decoder: Decoder) throws {
        let outer = try decoder.container(keyedBy: CodingKeys.self)
        let c: KeyedDecodingContainer<CodingKeys>
        if let nested = try? outer.nestedContainer(keyedBy: CodingKeys.self, forKey: .configuration) {
            c = nested
        } else {
            c = outer
        }
        name = c.laxString([.name, .id]) ?? outer.laxString(.id)
        source = c.laxString(.source)
        creationDate = DeckDate.meaningful(c.laxDate([.creationDate, .createdAt]))
        labels = c.laxMap(.labels) ?? [:]
        options = c.laxMap(.options) ?? [:]
        sizeInBytes = c.laxUInt64(.sizeInBytes)
    }
}

struct CLINetwork: Decodable {
    var name: String?
    var mode: String?
    var configSubnet: String?
    var configSubnetV6: String?
    var labels: [String: String]
    var creationDate: Date?
    var statusSubnet: String?
    var statusSubnetV6: String?
    var gateway: String?
    var state: String?

    private enum CodingKeys: String, CodingKey { case id, configuration, config, status, state }
    private enum ConfigKeys: String, CodingKey {
        case name, id, mode, ipv4Subnet, subnet, ipv6Subnet, labels, creationDate
    }
    private enum StatusKeys: String, CodingKey {
        case ipv4Subnet, address, subnet, ipv4Gateway, gateway, ipv6Subnet
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let config = (try? c.nestedContainer(keyedBy: ConfigKeys.self, forKey: .configuration))
            ?? (try? c.nestedContainer(keyedBy: ConfigKeys.self, forKey: .config))
        if let config {
            name = config.laxString([.name, .id])
            mode = config.laxString(.mode)
            configSubnet = config.laxString([.ipv4Subnet, .subnet])
            configSubnetV6 = config.laxString(.ipv6Subnet)
            labels = config.laxMap(.labels) ?? [:]
            creationDate = DeckDate.meaningful(config.laxDate(.creationDate))
        } else {
            labels = [:]
        }
        if name == nil { name = c.laxString(.id) }
        if let status = try? c.nestedContainer(keyedBy: StatusKeys.self, forKey: .status) {
            statusSubnet = status.laxString([.ipv4Subnet, .address, .subnet])
            statusSubnetV6 = status.laxString(.ipv6Subnet)
            gateway = status.laxString([.ipv4Gateway, .gateway])
        }
        state = c.laxString(.state)
    }
}

// MARK: - System

struct CLIUsage: Decodable {
    var total: Int
    var active: Int
    var sizeInBytes: UInt64
    var reclaimable: UInt64

    private enum CodingKeys: String, CodingKey { case total, active, sizeInBytes, reclaimable }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        total = c.laxInt(.total) ?? 0
        active = c.laxInt(.active) ?? 0
        sizeInBytes = c.laxUInt64(.sizeInBytes) ?? 0
        reclaimable = c.laxUInt64(.reclaimable) ?? 0
    }

    var bucket: UsageBucket {
        UsageBucket(total: total, active: active, sizeBytes: sizeInBytes, reclaimableBytes: reclaimable)
    }
}

struct CLIDiskUsage: Decodable {
    var images: CLIUsage?
    var containers: CLIUsage?
    var volumes: CLIUsage?

    private enum CodingKeys: String, CodingKey { case images, containers, volumes }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        images = c.lax(CLIUsage.self, .images)
        containers = c.lax(CLIUsage.self, .containers)
        volumes = c.lax(CLIUsage.self, .volumes)
    }
}

struct CLIRegistry: Decodable {
    var name: String?

    private enum CodingKeys: String, CodingKey { case name, hostname, server, id }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.laxString([.name, .hostname, .server, .id])
    }
}
