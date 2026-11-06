import Foundation
import CryptoKit

/// Values the app passes in from Settings.
public struct ComposePlanSettings: Sendable, Hashable {
    public var activeProfiles: Set<String>
    /// Used when a service sets no cpus.
    public var defaultCPUs: Int?
    /// Used when a service sets no memory limit. Like "1G".
    public var defaultMemory: String?
    /// Only these services and what they depend on (`up web worker`). nil means all.
    public var services: Set<String>?

    public init(activeProfiles: Set<String> = [], defaultCPUs: Int? = nil, defaultMemory: String? = nil, services: Set<String>? = nil) {
        self.activeProfiles = activeProfiles
        self.defaultCPUs = defaultCPUs
        self.defaultMemory = defaultMemory
        self.services = services
    }
}

public struct ComposeNetworkPlan: Sendable, Hashable, Identifiable {
    public var key: String
    /// Name on the platform, like "shop_default".
    public var name: String
    public var external: Bool
    public var isInternal: Bool
    public var subnet: String?

    public var id: String { name }

    public init(key: String, name: String, external: Bool = false, isInternal: Bool = false, subnet: String? = nil) {
        self.key = key
        self.name = name
        self.external = external
        self.isInternal = isInternal
        self.subnet = subnet
    }

    public var createArguments: [String] {
        var args = ["network", "create"]
        if let subnet { args += ["--subnet", subnet] }
        if isInternal { args.append("--internal") }
        args.append(name)
        return args
    }
}

public struct ComposeVolumePlan: Sendable, Hashable, Identifiable {
    public var key: String
    /// Name on the platform, like "shop_data".
    public var name: String
    public var external: Bool
    public var labels: [String: String]

    public var id: String { name }

    public init(key: String, name: String, external: Bool = false, labels: [String: String] = [:]) {
        self.key = key
        self.name = name
        self.external = external
        self.labels = labels
    }

    public var createArguments: [String] {
        var args = ["volume", "create"]
        for (key, value) in labels.sorted(by: { $0.key < $1.key }) {
            args += ["--label", "\(key)=\(value)"]
        }
        args.append(name)
        return args
    }
}

public struct ComposeServicePlan: Sendable, Hashable, Identifiable {
    public var service: ComposeService
    public var containerName: String
    public var options: RunOptions
    /// Set when the image is built from the file.
    public var build: BuildOptions?
    public var configHash: String

    public var id: String { service.name }
    public var name: String { service.name }
    /// `stop_signal`, for `container stop --signal`.
    public var stopSignal: String? { service.stopSignal }
    /// `stop_grace_period` rounded up to whole seconds, for `container stop --time`.
    public var stopTimeout: Int? { service.stopGracePeriod.map { Int($0.rounded(.up)) } }

    public init(service: ComposeService, containerName: String, options: RunOptions, build: BuildOptions?, configHash: String) {
        self.service = service
        self.containerName = containerName
        self.options = options
        self.build = build
        self.configHash = configHash
    }
}

/// One CLI command shown in the preview.
public struct ComposeCommand: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var arguments: [String]

    public init(id: String, title: String, arguments: [String]) {
        self.id = id
        self.title = title
        self.arguments = arguments
    }
}

public struct ComposePlan: Sendable, Hashable {
    public var project: ComposeProject
    public var settings: ComposePlanSettings
    /// Active services in start order.
    public var services: [ComposeServicePlan]
    /// Services left out by profiles.
    public var skipped: [String]
    public var networks: [ComposeNetworkPlan]
    public var volumes: [ComposeVolumePlan]

    public var projectName: String { project.name }

    public func service(_ name: String) -> ComposeServicePlan? {
        services.first { $0.name == name }
    }

    /// Every command Up runs, in order. `runArguments` turns options into
    /// `container run` arguments (pass `client.runArguments`).
    public func commands(runArguments: (RunOptions) -> [String]) -> [ComposeCommand] {
        var result: [ComposeCommand] = []
        for network in networks where !network.external {
            result.append(ComposeCommand(id: "network-\(network.name)", title: "Network \(network.name)", arguments: network.createArguments))
        }
        for volume in volumes where !volume.external {
            result.append(ComposeCommand(id: "volume-\(volume.name)", title: "Volume \(volume.name)", arguments: volume.createArguments))
        }
        for service in services {
            if let build = service.build {
                result.append(ComposeCommand(id: "build-\(service.name)", title: "Build \(service.name)", arguments: ComposePlanner.buildArguments(build)))
            }
            result.append(ComposeCommand(id: "run-\(service.name)", title: "Run \(service.name)", arguments: runArguments(service.options)))
            for (index, hook) in service.service.postStart.enumerated() {
                result.append(ComposeCommand(
                    id: "post-start-\(service.name)-\(index)",
                    title: "post_start hook of \(service.name)",
                    arguments: hook.execArguments(container: service.containerName)
                ))
            }
        }
        return result
    }
}

public enum ComposePlanner {

    /// Builds the run plan. Throws ComposeError.cycle for dependency loops.
    public static func plan(_ project: ComposeProject, settings: ComposePlanSettings = ComposePlanSettings()) throws -> ComposePlan {
        let ordered = try ComposeOrder.sorted(project.services)
        var active = activeServiceNames(project, profiles: settings.activeProfiles)
        if let only = settings.services, !only.isEmpty {
            let unknown = only.filter { project.service($0) == nil }.sorted()
            if !unknown.isEmpty {
                throw ComposeError.failed(unknown.count == 1 ? "No such service: \(unknown[0])." : "No such services: \(unknown.joined(separator: ", ")).")
            }
            active = withDependencies(project, only)
        }

        var networks: [ComposeNetworkPlan] = []
        var volumes: [ComposeVolumePlan] = []
        var servicePlans: [ComposeServicePlan] = []

        for service in ordered where active.contains(service.name) {
            // Network
            let networkKey = service.networks.first ?? "default"
            let netPlan = networkPlan(project, key: networkKey)
            if !networks.contains(where: { $0.name == netPlan.name }) {
                networks.append(netPlan)
            }
            // Volumes
            for mount in service.volumes where mount.kind == .volume || mount.kind == .anonymous {
                let volPlan = mount.kind == .volume
                    ? volumePlan(project, key: mount.source)
                    : anonymousVolumePlan(project: project.name, service: service.name, target: mount.target)
                if !volumes.contains(where: { $0.name == volPlan.name }) {
                    volumes.append(volPlan)
                }
            }
            servicePlans.append(servicePlan(service, project: project, network: netPlan.name, settings: settings))
        }

        let skipped = project.services.map(\.name).filter { !active.contains($0) }
        return ComposePlan(
            project: project, settings: settings, services: servicePlans,
            skipped: skipped, networks: networks, volumes: volumes
        )
    }

    /// Services with no profiles, services in an active profile, and everything they depend on.
    public static func activeServiceNames(_ project: ComposeProject, profiles: Set<String>) -> Set<String> {
        var active = Set(project.services.filter { $0.profiles.isEmpty || !profiles.isDisjoint(with: $0.profiles) }.map(\.name))
        var queue = Array(active)
        while let name = queue.popLast() {
            for dependency in project.service(name)?.dependsOn ?? [] where !active.contains(dependency.service) {
                if project.service(dependency.service) != nil {
                    active.insert(dependency.service)
                    queue.append(dependency.service)
                }
            }
        }
        return active
    }

    /// `names` plus everything they depend on, all the way down.
    static func withDependencies(_ project: ComposeProject, _ names: Set<String>) -> Set<String> {
        var result = names
        var queue = Array(names)
        while let name = queue.popLast() {
            for dependency in project.service(name)?.dependsOn ?? [] where !result.contains(dependency.service) {
                if project.service(dependency.service) != nil {
                    result.insert(dependency.service)
                    queue.append(dependency.service)
                }
            }
        }
        return result
    }

    /// Volume name for an anonymous mount like `- /data`. Stable for the same
    /// project, service and path, so a second Up reuses it and `down -v` removes it.
    public static func anonymousVolumeName(project: String, service: String, target: String) -> String {
        let digest = SHA256.hash(data: Data(target.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        let safeService = String(service.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : "_" })
        return "\(project)_\(safeService)_anon_\(digest)"
    }

    static func anonymousVolumePlan(project: String, service: String, target: String) -> ComposeVolumePlan {
        ComposeVolumePlan(
            key: "\(service):\(target)",
            name: anonymousVolumeName(project: project, service: service, target: target),
            labels: [ComposeLabel.project: project, ComposeLabel.anonymousVolume: service]
        )
    }

    public static func defaultContainerName(project: String, service: String) -> String {
        "\(project)-\(service)"
    }

    /// Image name for services built from the file without an `image` key.
    public static func builtImageName(project: String, service: String) -> String {
        "\(project)-\(service.lowercased()):latest"
    }

    static func networkPlan(_ project: ComposeProject, key: String) -> ComposeNetworkPlan {
        let definition = project.networks.first { $0.key == key } ?? ComposeNetworkDefinition(key: key)
        let name: String
        if definition.external {
            name = definition.name ?? key
        } else {
            name = String((definition.name ?? "\(project.name)_\(key)").lowercased().prefix(63))
        }
        return ComposeNetworkPlan(key: key, name: name, external: definition.external, isInternal: definition.isInternal, subnet: definition.subnet)
    }

    static func volumePlan(_ project: ComposeProject, key: String) -> ComposeVolumePlan {
        let definition = project.volumes.first { $0.key == key } ?? ComposeVolumeDefinition(key: key)
        if definition.external {
            return ComposeVolumePlan(key: key, name: definition.name ?? key, external: true)
        }
        var labels = definition.labels
        labels[ComposeLabel.project] = project.name
        return ComposeVolumePlan(key: key, name: definition.name ?? "\(project.name)_\(key)", labels: labels)
    }

    static func servicePlan(_ service: ComposeService, project: ComposeProject, network: String, settings: ComposePlanSettings) -> ComposeServicePlan {
        let containerName = service.containerName ?? defaultContainerName(project: project.name, service: service.name)
        let image = service.image ?? builtImageName(project: project.name, service: service.name)

        var options = RunOptions(image: image, name: containerName)
        if let entrypoint = service.entrypoint, let first = entrypoint.first {
            options.entrypoint = first
            options.command = Array(entrypoint.dropFirst()) + (service.command ?? [])
        } else if service.entrypoint != nil, let command = service.command, let first = command.first {
            // `entrypoint: []` or "" drops the image entrypoint. Apple's CLI cannot clear it
            // with an empty --entrypoint, so the command's first word becomes the entrypoint.
            options.entrypoint = first
            options.command = Array(command.dropFirst())
        } else {
            options.command = service.command ?? []
        }
        options.env = service.environment
        options.ports = service.ports.map(\.mapping)
        options.mounts = service.volumes.compactMap { (mount: ComposeVolumeMount) -> MountSpec? in
            switch mount.kind {
            case .bind:
                return MountSpec(kind: .bind, source: mount.source, destination: mount.target, readOnly: mount.readOnly)
            case .volume:
                let name = volumePlan(project, key: mount.source).name
                return MountSpec(kind: .volume, source: name, destination: mount.target, readOnly: mount.readOnly)
            case .anonymous:
                let name = anonymousVolumeName(project: project.name, service: service.name, target: mount.target)
                return MountSpec(kind: .volume, source: name, destination: mount.target, readOnly: mount.readOnly)
            case .tmpfs:
                return nil
            }
        }
        options.tmpfs = service.tmpfs + service.volumes.filter { $0.kind == .tmpfs }.map { (mount: ComposeVolumeMount) -> String in
            mount.source.isEmpty ? mount.target : "\(mount.target):\(mount.source)"
        }
        options.user = service.user
        options.readOnlyRootfs = service.readOnly
        options.useInit = service.initProcess
        options.capAdd = service.capAdd
        options.capDrop = service.capDrop
        options.dnsServers = service.dns
        options.dnsSearch = service.dnsSearch
        options.dnsOptions = service.dnsOptions
        options.shmSize = service.shmSize
        options.ulimits = service.ulimits
        options.macAddress = service.macAddress
        if let cpus = service.cpus {
            options.cpus = max(1, Int(cpus.rounded(.up)))
        } else {
            options.cpus = settings.defaultCPUs
        }
        options.memory = service.memory ?? settings.defaultMemory
        options.network = network
        options.workingDir = service.workingDir
        options.platform = service.platform
        options.detach = true

        var labels = service.labels
        labels[ComposeLabel.project] = project.name
        labels[ComposeLabel.service] = service.name
        options.labels = labels

        var build: BuildOptions?
        if let source = service.build {
            build = BuildOptions(
                contextDir: source.context,
                dockerfile: source.dockerfile,
                tags: [image],
                buildArgs: source.args,
                platform: service.platform ?? "linux/arm64",
                target: source.target
            )
        }

        let hash = configHash(options, build: build)
        options.labels[ComposeLabel.configHash] = hash
        options.labels[ComposeLabel.file] = project.file.path
        if project.files.count > 1 {
            options.labels[ComposeLabel.files] = project.files.map(\.path).joined(separator: ",")
        }
        if let signal = service.stopSignal, !signal.isEmpty { options.labels[ComposeLabel.stopSignal] = signal }
        if let grace = service.stopGracePeriod { options.labels[ComposeLabel.stopTimeout] = String(Int(grace.rounded(.up))) }

        return ComposeServicePlan(service: service, containerName: containerName, options: options, build: build, configHash: hash)
    }

    /// SHA256 of everything that shapes the container. Stable across key order
    /// in the file. The hash and file labels are left out.
    public static func configHash(_ options: RunOptions, build: BuildOptions?) -> String {
        var labels = options.labels
        labels[ComposeLabel.configHash] = nil
        labels[ComposeLabel.file] = nil
        labels[ComposeLabel.files] = nil
        labels[ComposeLabel.stopSignal] = nil
        labels[ComposeLabel.stopTimeout] = nil
        // Settings added later only count when set, so stacks started before they
        // existed keep their hash and are not recreated.
        var extra: [String] = []
        if let user = options.user, !user.isEmpty { extra.append("user=\(user)") }
        if options.readOnlyRootfs { extra.append("read-only") }
        if options.useInit { extra.append("init") }
        extra += options.tmpfs.map { "tmpfs=\($0)" }
        extra += options.capAdd.map { "cap-add=\($0)" }
        extra += options.capDrop.map { "cap-drop=\($0)" }
        extra += options.dnsServers.map { "dns=\($0)" }
        extra += options.dnsSearch.map { "dns-search=\($0)" }
        extra += options.dnsOptions.map { "dns-option=\($0)" }
        if let shm = options.shmSize, !shm.isEmpty { extra.append("shm=\(shm)") }
        extra += options.ulimits.map { "ulimit=\($0)" }
        if let mac = options.macAddress, !mac.isEmpty { extra.append("mac=\(mac)") }
        let input = ComposeHashInput(
            image: options.image,
            name: options.name ?? "",
            command: options.command,
            entrypoint: options.entrypoint ?? "",
            env: options.env.map { "\($0.key)=\($0.value)" }.sorted(),
            ports: options.ports.map(\.publishArgument).sorted(),
            mounts: options.mounts.map { "\($0.kind.rawValue):\($0.source):\($0.destination):\($0.readOnly ? "ro" : "rw")" }.sorted(),
            cpus: options.cpus ?? 0,
            memory: options.memory ?? "",
            network: options.network ?? "",
            workingDir: options.workingDir ?? "",
            labels: labels,
            platform: options.platform ?? "",
            build: build.map { (b: BuildOptions) -> [String] in
                [b.contextDir, b.dockerfile ?? "", b.target ?? "", b.platform]
                    + b.buildArgs.map { "\($0.key)=\($0.value)" }.sorted()
            } ?? [],
            extra: extra.isEmpty ? nil : extra
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(input)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// `container build` arguments for display.
    public static func buildArguments(_ build: BuildOptions) -> [String] {
        var args = ["build"]
        for tag in build.tags { args += ["--tag", tag] }
        if let dockerfile = build.dockerfile { args += ["--file", dockerfile] }
        for arg in build.buildArgs { args += ["--build-arg", "\(arg.key)=\(arg.value)"] }
        if let target = build.target { args += ["--target", target] }
        args += ["--platform", build.platform]
        args.append(build.contextDir)
        return args
    }
}

private struct ComposeHashInput: Encodable {
    var image: String
    var name: String
    var command: [String]
    var entrypoint: String
    var env: [String]
    var ports: [String]
    var mounts: [String]
    var cpus: Int
    var memory: String
    var network: String
    var workingDir: String
    var labels: [String: String]
    var platform: String
    var build: [String]
    /// nil is left out of the JSON, which keeps old hashes stable.
    var extra: [String]?
}
