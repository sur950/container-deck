import Foundation

// Models for a parsed compose file. Everything here is plain data so the
// planner, runner and UI can share it across tasks.

/// Labels Container Deck puts on every container it starts from a compose file.
public enum ComposeLabel {
    public static let project = "com.containerdeck.compose.project"
    public static let service = "com.containerdeck.compose.service"
    public static let configHash = "com.containerdeck.compose.config-hash"
    /// Path of the compose file, so a stack found on the Mac can be opened again.
    public static let file = "com.containerdeck.compose.file"
    /// Every compose file of the project, comma separated, when there is more than one.
    public static let files = "com.containerdeck.compose.files"
    /// `stop_signal` and `stop_grace_period` (seconds), so stop and down honour them
    /// without the file. Left out of the config hash.
    public static let stopSignal = "com.containerdeck.compose.stop-signal"
    public static let stopTimeout = "com.containerdeck.compose.stop-timeout"
    /// Set on volumes made for anonymous volume mounts (`- /data`).
    public static let anonymousVolume = "com.containerdeck.compose.anonymous"
}

/// `pull_policy` of a service, or the `--pull` choice for a whole Up.
public enum ComposePullPolicy: String, Sendable, Hashable, CaseIterable {
    /// Pull only when the image is not on this Mac.
    case missing
    /// Pull every time.
    case always
    /// Never pull. Up fails when the image is missing.
    case never
    /// Build the image every time (services with a `build` section).
    case build

    /// Reads compose values, including the old `if_not_present`.
    public init?(composeValue: String) {
        switch composeValue.lowercased() {
        case "missing", "if_not_present": self = .missing
        case "always": self = .always
        case "never": self = .never
        case "build": self = .build
        default: return nil
        }
    }

    public var title: String {
        switch self {
        case .missing: return "Pull missing images"
        case .always: return "Always pull"
        case .never: return "Never pull"
        case .build: return "Always build"
        }
    }
}

/// A `post_start` or `pre_stop` command, run with `container exec`.
public struct ComposeHook: Sendable, Hashable {
    public var command: [String]
    public var environment: [EnvVar]
    public var workingDir: String?
    public var user: String?

    public init(command: [String], environment: [EnvVar] = [], workingDir: String? = nil, user: String? = nil) {
        self.command = command
        self.environment = environment
        self.workingDir = workingDir
        self.user = user
    }

    /// `container exec` arguments for this hook in `container`.
    public func execArguments(container: String) -> [String] {
        var args = ["exec"]
        for item in environment { args += ["--env", "\(item.key)=\(item.value)"] }
        if let workingDir, !workingDir.isEmpty { args += ["--workdir", workingDir] }
        if let user, !user.isEmpty { args += ["--user", user] }
        args.append(container)
        args += command
        return args
    }
}

/// Something in the file we cannot honour. Shown before the first run.
public struct ComposeProblem: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        /// Apple's runtime cannot do this.
        case notPossible
        /// The runtime could do it, Container Deck does not yet.
        case notBuilt
        /// The file is broken. Up is blocked until it is fixed.
        case invalid

        public var title: String {
            switch self {
            case .notPossible: return "Not possible on this platform"
            case .notBuilt: return "Not built yet"
            case .invalid: return "Needs a fix"
            }
        }
    }

    public var kind: Kind
    /// Service name, nil for top level keys.
    public var service: String?
    /// Dotted path like "services.web.privileged".
    public var key: String
    /// 1 based line in `file`. 0 when unknown.
    public var line: Int
    public var message: String
    /// The compose file the line is in. A project can be made of several files
    /// (`-f`, the override file, `include`, `extends`). nil when unknown.
    public var file: URL?

    public var id: String { "\(kind.rawValue)|\(file?.path ?? "")|\(key)|\(line)|\(message)" }

    public init(kind: Kind, service: String? = nil, key: String, line: Int, message: String, file: URL? = nil) {
        self.kind = kind
        self.service = service
        self.key = key
        self.line = line
        self.message = message
        self.file = file
    }

    /// "compose.override.yaml:12", or the file name alone without a line. nil without a file.
    public func location(relativeTo directory: URL? = nil) -> String? {
        guard let file else { return nil }
        var name = file.lastPathComponent
        if let directory {
            let base = directory.standardizedFileURL.path
            let path = file.standardizedFileURL.path
            let prefix = base.hasSuffix("/") ? base : base + "/"
            if path.hasPrefix(prefix) { name = String(path.dropFirst(prefix.count)) }
        }
        return line > 0 ? "\(name):\(line)" : name
    }
}

public struct ComposeBuild: Sendable, Hashable {
    /// Absolute path of the build context.
    public var context: String
    /// Dockerfile path, absolute. nil means "<context>/Dockerfile".
    public var dockerfile: String?
    public var args: [EnvVar]
    public var target: String?

    public init(context: String, dockerfile: String? = nil, args: [EnvVar] = [], target: String? = nil) {
        self.context = context
        self.dockerfile = dockerfile
        self.args = args
        self.target = target
    }
}

public struct ComposePort: Sendable, Hashable {
    public var hostIP: String?
    /// nil means the file did not pick a host port.
    public var published: Int?
    public var target: Int
    public var proto: String

    public init(hostIP: String? = nil, published: Int? = nil, target: Int, proto: String = "tcp") {
        self.hostIP = hostIP
        self.published = published
        self.target = target
        self.proto = proto
    }

    /// Host port used at run time. Same as the container port when not set.
    public var mapping: PortMapping {
        PortMapping(hostAddress: hostIP, hostPort: published ?? target, containerPort: target, proto: proto)
    }

    public var displayText: String {
        let host = hostIP.map { "\($0):" } ?? ""
        let published = published.map(String.init) ?? "auto"
        return "\(host)\(published):\(target)" + (proto == "tcp" ? "" : "/\(proto)")
    }
}

public struct ComposeVolumeMount: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case bind, volume, tmpfs, anonymous
    }

    public var kind: Kind
    /// Absolute host path for binds, volume key for named volumes.
    public var source: String
    public var target: String
    public var readOnly: Bool

    public init(kind: Kind, source: String, target: String, readOnly: Bool = false) {
        self.kind = kind
        self.source = source
        self.target = target
        self.readOnly = readOnly
    }

    public var displayText: String {
        let ro = readOnly ? ":ro" : ""
        switch kind {
        case .anonymous, .tmpfs: return "\(target) (\(kind.rawValue))"
        default: return "\(source):\(target)\(ro)"
        }
    }
}

public struct ComposeDependency: Sendable, Hashable {
    public enum Condition: String, Sendable, Hashable {
        case started = "service_started"
        case healthy = "service_healthy"
        case completed = "service_completed_successfully"

        public var title: String {
            switch self {
            case .started: return "started"
            case .healthy: return "healthy"
            case .completed: return "completed"
            }
        }
    }

    public var service: String
    public var condition: Condition
    public var required: Bool

    public init(service: String, condition: Condition = .started, required: Bool = true) {
        self.service = service
        self.condition = condition
        self.required = required
    }
}

public struct ComposeHealthcheck: Sendable, Hashable {
    /// Command run inside the container. Empty when disabled.
    public var command: [String]
    public var interval: TimeInterval
    public var timeout: TimeInterval
    public var retries: Int
    public var startPeriod: TimeInterval

    public init(command: [String], interval: TimeInterval = 30, timeout: TimeInterval = 30, retries: Int = 3, startPeriod: TimeInterval = 0) {
        self.command = command
        self.interval = interval
        self.timeout = timeout
        self.retries = retries
        self.startPeriod = startPeriod
    }

    public var isDisabled: Bool { command.isEmpty }
}

public struct ComposeService: Sendable, Hashable, Identifiable {
    public var name: String
    public var image: String?
    public var build: ComposeBuild?
    /// nil keeps the image default.
    public var command: [String]?
    /// nil keeps the image default.
    public var entrypoint: [String]?
    /// env_file values first, then `environment`. Later keys win.
    public var environment: [EnvVar]
    public var envFiles: [String]
    public var ports: [ComposePort]
    public var volumes: [ComposeVolumeMount]
    /// Network keys in file order.
    public var networks: [String]
    public var dependsOn: [ComposeDependency]
    public var healthcheck: ComposeHealthcheck?
    public var profiles: [String]
    public var labels: [String: String]
    public var workingDir: String?
    public var cpus: Double?
    /// Normalised like "512M" or "2G".
    public var memory: String?
    public var platform: String?
    public var containerName: String?
    public var restart: String?
    /// "<ip> <host>" lines added to /etc/hosts.
    public var extraHosts: [String]
    /// Extra names other services can use for this one.
    public var networkAliases: [String]
    /// Line of the service key.
    public var line: Int

    // Keys that map straight to `container run` flags.

    /// `user`, like "1000:1000" or "nginx".
    public var user: String?
    /// `tmpfs` and `type: tmpfs` mounts as `--tmpfs` values ("/run" or "/run:size=64m").
    public var tmpfs: [String] = []
    /// `read_only`: read only root file system.
    public var readOnly: Bool = false
    /// `init`: run a small init process.
    public var initProcess: Bool = false
    public var capAdd: [String] = []
    public var capDrop: [String] = []
    /// `dns`, `dns_search`, `dns_opt`.
    public var dns: [String] = []
    public var dnsSearch: [String] = []
    public var dnsOptions: [String] = []
    /// `shm_size` as "64M".
    public var shmSize: String?
    /// `ulimits` as `--ulimit` values like "nofile=1024:2048".
    public var ulimits: [String] = []
    public var macAddress: String?
    /// `stop_signal`, like "SIGINT".
    public var stopSignal: String?
    /// `stop_grace_period` in seconds.
    public var stopGracePeriod: TimeInterval?
    /// `pull_policy`. nil means pull when missing.
    public var pullPolicy: ComposePullPolicy?
    /// `post_start` hooks, run in order after the container starts.
    public var postStart: [ComposeHook] = []
    /// `pre_stop` hooks, run in order before the container stops.
    public var preStop: [ComposeHook] = []

    public var id: String { name }

    public init(
        name: String, image: String? = nil, build: ComposeBuild? = nil, command: [String]? = nil,
        entrypoint: [String]? = nil, environment: [EnvVar] = [], envFiles: [String] = [],
        ports: [ComposePort] = [], volumes: [ComposeVolumeMount] = [], networks: [String] = [],
        dependsOn: [ComposeDependency] = [], healthcheck: ComposeHealthcheck? = nil, profiles: [String] = [],
        labels: [String: String] = [:], workingDir: String? = nil, cpus: Double? = nil, memory: String? = nil,
        platform: String? = nil, containerName: String? = nil, restart: String? = nil,
        extraHosts: [String] = [], networkAliases: [String] = [], line: Int = 0
    ) {
        self.name = name
        self.image = image
        self.build = build
        self.command = command
        self.entrypoint = entrypoint
        self.environment = environment
        self.envFiles = envFiles
        self.ports = ports
        self.volumes = volumes
        self.networks = networks
        self.dependsOn = dependsOn
        self.healthcheck = healthcheck
        self.profiles = profiles
        self.labels = labels
        self.workingDir = workingDir
        self.cpus = cpus
        self.memory = memory
        self.platform = platform
        self.containerName = containerName
        self.restart = restart
        self.extraHosts = extraHosts
        self.networkAliases = networkAliases
        self.line = line
    }

    /// Image or build context for lists.
    public var imageDescription: String {
        if let image { return build == nil ? image : "\(image) (build)" }
        if let build { return "Build from \(URL(fileURLWithPath: build.context).lastPathComponent)" }
        return "No image"
    }
}

public struct ComposeVolumeDefinition: Sendable, Hashable {
    /// Key under top level `volumes`.
    public var key: String
    /// `name:` override.
    public var name: String?
    public var external: Bool
    public var labels: [String: String]

    public init(key: String, name: String? = nil, external: Bool = false, labels: [String: String] = [:]) {
        self.key = key
        self.name = name
        self.external = external
        self.labels = labels
    }
}

public struct ComposeNetworkDefinition: Sendable, Hashable {
    public var key: String
    public var name: String?
    public var external: Bool
    public var isInternal: Bool
    public var subnet: String?

    public init(key: String, name: String? = nil, external: Bool = false, isInternal: Bool = false, subnet: String? = nil) {
        self.key = key
        self.name = name
        self.external = external
        self.isInternal = isInternal
        self.subnet = subnet
    }
}

public struct ComposeProject: Sendable, Hashable {
    public var name: String
    /// The main compose file (the first one).
    public var file: URL
    /// Every compose file merged into the project, main file first, like `-f` flags.
    public var files: [URL]
    /// Files read through `include` and `extends`.
    public var includedFiles: [URL] = []
    public var services: [ComposeService]
    public var volumes: [ComposeVolumeDefinition]
    public var networks: [ComposeNetworkDefinition]
    public var problems: [ComposeProblem]

    public init(name: String, file: URL, services: [ComposeService] = [], volumes: [ComposeVolumeDefinition] = [], networks: [ComposeNetworkDefinition] = [], problems: [ComposeProblem] = []) {
        self.name = name
        self.file = file
        self.files = [file]
        self.services = services
        self.volumes = volumes
        self.networks = networks
        self.problems = problems
    }

    public var directory: URL { file.deletingLastPathComponent() }

    /// Files merged on top of the main one (`compose.override.yaml` and more `-f` files).
    public var overrideFiles: [URL] { Array(files.dropFirst()) }

    /// Every file the project was read from: merged, included and extended.
    public var allFiles: [URL] {
        var result = files
        for file in includedFiles where !result.contains(file) { result.append(file) }
        return result
    }

    public func service(_ name: String) -> ComposeService? {
        services.first { $0.name == name }
    }

    /// Every profile used by any service, sorted.
    public var allProfiles: [String] {
        Array(Set(services.flatMap(\.profiles))).sorted()
    }

    /// True when a problem blocks Up.
    public var hasBlockingProblems: Bool {
        problems.contains { $0.kind == .invalid }
    }
}

public enum ComposeError: LocalizedError, Equatable {
    case noFile(String)
    case invalidYAML(String)
    case cycle([String])
    case blocked(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .noFile(let dir): return "No compose file found in \(dir) or its parent folders."
        case .invalidYAML(let reason): return "The compose file is not valid YAML. \(reason)"
        case .cycle(let names): return "These services depend on each other in a loop: \(names.joined(separator: ", "))."
        case .blocked(let reason): return reason
        case .failed(let reason): return reason
        }
    }
}
