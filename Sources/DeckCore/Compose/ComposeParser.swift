import Foundation

/// Reads a compose file into a ComposeProject and lists every key we cannot honour.
public enum ComposeParser {

    /// Reads a compose file from disk with its sibling `.env` and the process environment.
    /// `extraFiles` merge on top in order (like more `-f` flags). Without them the
    /// override file next to `file` (`compose.override.yaml` and friends) is merged
    /// when it exists. `envFiles` replaces the sibling `.env` (like `--env-file`).
    public static func load(
        file: URL,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        extraFiles: [URL] = [],
        envFiles: [URL]? = nil
    ) throws -> ComposeProject {
        var others = extraFiles.filter { $0.standardizedFileURL.path != file.standardizedFileURL.path }
        if others.isEmpty, let override = ComposeFileLocator().overrideFile(in: file.deletingLastPathComponent()) {
            others = [override]
        }
        return try load(files: [file] + others, processEnvironment: processEnvironment, envFiles: envFiles)
    }

    /// Reads exactly these compose files and merges them in order, the way
    /// `docker compose -f a.yaml -f b.yaml` does. Relative paths in all of them
    /// resolve against `projectDirectory` (the folder of the first file by default),
    /// and so does `.env`. Included and extended files use their own folders.
    public static func load(
        files: [URL],
        projectDirectory: URL? = nil,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        envFiles: [URL]? = nil,
        readFile: @escaping (URL) -> String? = { try? String(contentsOf: $0, encoding: .utf8) }
    ) throws -> ComposeProject {
        guard let first = files.first else { throw ComposeError.failed("No compose file was given.") }
        if readFile(first) == nil {
            throw ComposeError.failed("Could not read \(first.lastPathComponent).")
        }
        let directory = (projectDirectory ?? first.deletingLastPathComponent()).standardizedFileURL
        var dotEnv: [String: String] = [:]
        if let envFiles {
            for envFile in envFiles {
                guard let envText = readFile(envFile) else {
                    throw ComposeError.failed("Could not read the env file \(envFile.path).")
                }
                dotEnv.merge(DotEnvParser.dictionary(envText, lookup: processEnvironment)) { _, new in new }
            }
        } else {
            let dotEnvText = readFile(directory.appendingPathComponent(".env")) ?? ""
            dotEnv = DotEnvParser.dictionary(dotEnvText, lookup: processEnvironment)
        }
        let environment = ComposeInterpolator.environment(dotEnv: dotEnv, process: processEnvironment)
        return try parse(files: files, projectDirectory: directory, environment: environment, processEnvironment: processEnvironment, readFile: readFile)
    }

    /// Parses compose YAML. `environment` fills in variables and inherited values.
    /// `readFile` reads env_file entries and files named by `include` and `extends` (swapped in tests).
    public static func parse(
        _ yaml: String,
        file: URL,
        environment: [String: String] = [:],
        readFile: @escaping (URL) -> String? = { try? String(contentsOf: $0, encoding: .utf8) }
    ) throws -> ComposeProject {
        let path = file.standardizedFileURL.path
        let reader: (URL) -> String? = { url in
            url.standardizedFileURL.path == path ? yaml : readFile(url)
        }
        return try parse(files: [file], projectDirectory: file.deletingLastPathComponent(), environment: environment,
                         processEnvironment: environment, readFile: reader)
    }

    static func parse(
        files: [URL],
        projectDirectory: URL,
        environment: [String: String],
        processEnvironment: [String: String],
        readFile: @escaping (URL) -> String?
    ) throws -> ComposeProject {
        var loader = ComposeLoader(readFile: readFile, processEnvironment: processEnvironment)
        let root = try loader.load(files, projectDirectory: projectDirectory, environment: environment)
        var reader = ComposeFileReader(
            file: files[0], environment: environment, readFile: readFile,
            sources: loader.sources, projectDirectory: projectDirectory
        )
        reader.problems = loader.problems
        var project = reader.read(root)
        project.files = files.map(\.standardizedFileURL)
        project.includedFiles = loader.includedFiles
        return project
    }

    /// Lower case letters, digits, dashes and underscores, like Docker.
    public static func normalizeProjectName(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_")
        var name = String(raw.lowercased().filter { allowed.contains($0) })
        while let first = name.first, first == "-" || first == "_" {
            name.removeFirst()
        }
        return name.isEmpty ? "compose" : name
    }
}

// MARK: - Units

public enum ComposeUnits {
    /// "1m30s", "10s", "500ms", "1h". A plain number is seconds.
    public static func duration(_ text: String) -> TimeInterval? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if t.isEmpty { return nil }
        if let plain = Double(t) { return plain }
        var total = 0.0
        var number = ""
        var unit = ""
        var parsedAny = false
        func flush() -> Bool {
            guard let value = Double(number) else { return false }
            let multiplier: Double
            switch unit {
            case "h": multiplier = 3600
            case "m": multiplier = 60
            case "s": multiplier = 1
            case "ms": multiplier = 0.001
            case "us", "µs": multiplier = 0.000001
            case "ns": multiplier = 0.000000001
            default: return false
            }
            total += value * multiplier
            number = ""
            unit = ""
            parsedAny = true
            return true
        }
        for c in t {
            if c.isNumber || c == "." {
                if !unit.isEmpty {
                    guard flush() else { return nil }
                }
                number.append(c)
            } else {
                unit.append(c)
            }
        }
        if !number.isEmpty || !unit.isEmpty {
            guard flush() else { return nil }
        }
        return parsedAny ? total : nil
    }

    /// "512m", "1g", "1gb", "512MiB" or bytes, as "512M" or "1G" for `--memory`.
    public static func memory(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        let numberPart = String(t.prefix { $0.isNumber || $0 == "." })
        var unit = String(t.dropFirst(numberPart.count)).trimmingCharacters(in: .whitespaces)
        guard let value = Double(numberPart), value > 0 else { return nil }
        if unit.hasSuffix("ib") {
            unit = String(unit.dropLast(2))
        } else if unit.count == 2 && unit.hasSuffix("b") {
            unit = String(unit.dropLast())
        } else if unit == "b" {
            unit = ""
        }
        let multiplier: Double
        switch unit {
        case "": multiplier = 1
        case "k": multiplier = 1024
        case "m": multiplier = 1024 * 1024
        case "g": multiplier = 1024 * 1024 * 1024
        case "t": multiplier = 1024 * 1024 * 1024 * 1024
        default: return nil
        }
        let bytes = value * multiplier
        let gib = 1024.0 * 1024 * 1024
        let mib = 1024.0 * 1024
        if bytes >= gib, bytes.truncatingRemainder(dividingBy: gib) == 0 {
            return "\(Int(bytes / gib))G"
        }
        return "\(max(1, Int((bytes / mib).rounded(.up))))M"
    }
}

// MARK: - Reader

/// Walks the YAML tree. Collects problems as it goes.
struct ComposeFileReader {
    let file: URL
    let environment: [String: String]
    let readFile: (URL) -> String?
    /// Lines in the tree carry their file. Problems and paths use it.
    let sources: ComposeSources
    /// Folder of the project: its name and the base for relative paths.
    let directory: URL
    var problems: [ComposeProblem] = []

    private var declaredVolumes: Set<String> = []
    private var declaredNetworks: Set<String> = ["default"]

    init(file: URL, environment: [String: String], readFile: @escaping (URL) -> String?, sources: ComposeSources? = nil, projectDirectory: URL? = nil) {
        self.file = file
        self.environment = environment
        self.readFile = readFile
        self.directory = projectDirectory ?? file.deletingLastPathComponent()
        if let sources {
            self.sources = sources
        } else {
            var single = ComposeSources()
            _ = single.add(file, baseDirectory: self.directory)
            self.sources = single
        }
    }

    /// Folder relative paths at this (stored) line resolve against.
    func baseDirectory(_ line: Int) -> URL {
        sources.source(forLine: line)?.baseDirectory ?? directory
    }

    mutating func problem(_ kind: ComposeProblem.Kind, _ service: String?, _ key: String, _ line: Int, _ message: String) {
        problems.append(ComposeProblem(kind: kind, service: service, key: key, line: line, message: message))
    }

    // MARK: Top level

    mutating func read(_ root: ComposeNode) -> ComposeProject {
        let folderName = directory.lastPathComponent
        var rawName = folderName
        if let name = root["name"]?.text, !name.isEmpty { rawName = name }
        if let fromEnv = environment["COMPOSE_PROJECT_NAME"], !fromEnv.isEmpty { rawName = fromEnv }
        let projectName = ComposeParser.normalizeProjectName(rawName)

        var volumes: [ComposeVolumeDefinition] = []
        var networks: [ComposeNetworkDefinition] = []
        var services: [ComposeService] = []

        // Read volumes and networks first so services can check names.
        if let node = root.entry("volumes") {
            volumes = readVolumes(node)
            declaredVolumes = Set(volumes.map(\.key))
        }
        if let node = root.entry("networks") {
            networks = readNetworks(node)
            declaredNetworks.formUnion(networks.map(\.key))
        }

        for entry in root.entries ?? [] {
            switch entry.key {
            case "name", "version", "volumes", "networks":
                break
            case "services":
                guard let serviceEntries = entry.node.entries else {
                    problem(.invalid, nil, "services", entry.line, "services must be a map of service names.")
                    continue
                }
                for serviceEntry in serviceEntries {
                    services.append(readService(serviceEntry))
                }
            case "secrets", "configs":
                problem(.notBuilt, nil, entry.key, entry.line, "Top level \(entry.key) are not built yet.")
            default:
                if entry.key.hasPrefix("x-") { continue }
                problem(.notBuilt, nil, entry.key, entry.line, "Unknown top level key \(entry.key).")
            }
        }

        if root["services"] == nil {
            problem(.invalid, nil, "services", root.line, "The file has no services.")
        }

        validate(services)

        problems.sort { ($0.line, $0.key) < ($1.line, $1.key) }
        // Stored lines carry the file. Split them into file and plain line.
        let located = problems.map { problem -> ComposeProblem in
            var problem = problem
            let place = sources.decode(problem.line)
            problem.line = place.line
            problem.file = place.file
            return problem
        }
        var unique: [ComposeProblem] = []
        for problem in located where !unique.contains(problem) { unique.append(problem) }
        for index in services.indices {
            services[index].line = sources.decode(services[index].line).line
        }
        return ComposeProject(
            name: projectName, file: file, services: services,
            volumes: volumes, networks: networks, problems: unique
        )
    }

    private mutating func readVolumes(_ entry: ComposeEntry) -> [ComposeVolumeDefinition] {
        guard let entries = entry.node.entries else {
            if !entry.node.isNull { problem(.invalid, nil, "volumes", entry.line, "volumes must be a map.") }
            return []
        }
        var result: [ComposeVolumeDefinition] = []
        for item in entries {
            var definition = ComposeVolumeDefinition(key: item.key)
            let path = "volumes.\(item.key)"
            for field in item.node.entries ?? [] {
                switch field.key {
                case "name":
                    definition.name = field.node.text
                case "external":
                    if let flag = field.node.bool {
                        definition.external = flag
                    } else if let externalName = field.node["name"]?.text {
                        definition.external = true
                        definition.name = externalName
                    }
                case "labels":
                    for pair in field.node.keyValues ?? [] {
                        definition.labels[pair.key] = pair.value ?? ""
                    }
                case "driver":
                    if let driver = field.node.text, driver != "local" {
                        problem(.notPossible, nil, "\(path).driver", field.line, "Volume driver \(driver) is not possible. Only local volumes exist.")
                    }
                case "driver_opts":
                    problem(.notBuilt, nil, "\(path).driver_opts", field.line, "Volume driver options are not built yet.")
                default:
                    if field.key.hasPrefix("x-") { continue }
                    problem(.notBuilt, nil, "\(path).\(field.key)", field.line, "Unknown volume key \(field.key).")
                }
            }
            result.append(definition)
        }
        return result
    }

    private mutating func readNetworks(_ entry: ComposeEntry) -> [ComposeNetworkDefinition] {
        guard let entries = entry.node.entries else {
            if !entry.node.isNull { problem(.invalid, nil, "networks", entry.line, "networks must be a map.") }
            return []
        }
        var result: [ComposeNetworkDefinition] = []
        for item in entries {
            var definition = ComposeNetworkDefinition(key: item.key)
            let path = "networks.\(item.key)"
            for field in item.node.entries ?? [] {
                switch field.key {
                case "name":
                    definition.name = field.node.text
                case "external":
                    if let flag = field.node.bool {
                        definition.external = flag
                    } else if let externalName = field.node["name"]?.text {
                        definition.external = true
                        definition.name = externalName
                    }
                case "internal":
                    definition.isInternal = field.node.bool ?? false
                case "ipam":
                    if let config = field.node["config"]?.items?.first, let subnet = config["subnet"]?.text {
                        definition.subnet = subnet
                    }
                    if (field.node["config"]?.items?.count ?? 0) > 1 {
                        problem(.notBuilt, nil, "\(path).ipam", field.line, "Only the first subnet is used.")
                    }
                case "driver":
                    if let driver = field.node.text, driver != "bridge" {
                        problem(.notPossible, nil, "\(path).driver", field.line, "Network driver \(driver) is not possible.")
                    }
                case "attachable":
                    break
                case "driver_opts", "enable_ipv6", "labels":
                    problem(.notBuilt, nil, "\(path).\(field.key)", field.line, "Network \(field.key) is not built yet.")
                default:
                    if field.key.hasPrefix("x-") { continue }
                    problem(.notBuilt, nil, "\(path).\(field.key)", field.line, "Unknown network key \(field.key).")
                }
            }
            result.append(definition)
        }
        return result
    }

    // MARK: Services

    private static let notPossible: [String: String] = [
        "privileged": "Privileged mode is not possible. Each container runs in its own small VM.",
        "devices": "Host devices cannot be passed to a container.",
        "device_cgroup_rules": "Device rules are not possible.",
        "ipc": "Shared IPC is not possible. Each container has its own kernel.",
        "pid": "Shared PID space is not possible. Each container has its own kernel.",
        "uts": "Shared UTS is not possible. Each container has its own kernel.",
        "userns_mode": "User namespace modes are not possible.",
        "cgroup": "cgroup modes are not possible.",
        "cgroup_parent": "cgroup parents are not possible.",
        "gpus": "GPUs cannot be passed to a container.",
        "runtime": "Other runtimes are not possible.",
        "isolation": "Isolation modes are not possible.",
        "security_opt": "Security options are not possible.",
        "sysctls": "sysctls are not possible.",
        "oom_kill_disable": "OOM settings are not possible. Use mem_limit.",
        "oom_score_adj": "OOM settings are not possible. Use mem_limit.",
        "mem_swappiness": "Swap settings are not possible. Use mem_limit.",
        "memswap_limit": "Swap settings are not possible. Use mem_limit.",
        "mem_reservation": "Memory reservations are not possible. Use mem_limit.",
        "cpu_shares": "CPU shares are not possible. Use cpus.",
        "cpu_quota": "CPU quotas are not possible. Use cpus.",
        "cpu_period": "CPU periods are not possible. Use cpus.",
        "cpuset": "CPU pinning is not possible. Use cpus.",
        "cpu_count": "cpu_count is not possible. Use cpus.",
        "cpu_percent": "cpu_percent is not possible. Use cpus.",
        "cpu_rt_runtime": "Realtime CPU settings are not possible.",
        "cpu_rt_period": "Realtime CPU settings are not possible.",
        "blkio_config": "Disk IO limits are not possible.",
        "storage_opt": "Storage options are not possible.",
        "pids_limit": "PID limits are not possible.",
        "logging": "Log drivers are not possible. Logs stay with the container tool.",
        "volumes_from": "volumes_from is not possible. Share a named volume instead."
    ]

    private static let notBuilt: [String: String] = [
        "stdin_open": "stdin_open is not built yet. Use the Terminal button.",
        "tty": "tty is not built yet. Use the Terminal button.",
        "hostname": "Custom hostnames are not built yet.",
        "domainname": "Custom domain names are not built yet.",
        "secrets": "Secrets are not built yet.",
        "configs": "Configs are not built yet.",
        "scale": "Scaling is not built yet. One container runs.",
        "annotations": "Annotations are not built yet.",
        "attach": "attach is not built yet.",
        "group_add": "Extra groups are not built yet.",
        "develop": "Watch mode is not built yet.",
        "links": "Link aliases are not built yet. Services can still reach each other by name.",
        "external_links": "External links are not built yet.",
        "credential_spec": "Credential specs are not built yet.",
        "label_file": "Label files are not built yet.",
        "use_api_socket": "The API socket is not built yet.",
        "provider": "Providers are not built yet.",
        "models": "Models are not built yet."
    ]

    private mutating func readService(_ entry: ComposeEntry) -> ComposeService {
        let name = entry.key
        var service = ComposeService(name: name, line: entry.line)
        let base = "services.\(name)"

        if name.range(of: "^[a-zA-Z0-9][a-zA-Z0-9_.-]*$", options: .regularExpression) == nil {
            problem(.invalid, name, base, entry.line, "Service name \(name) can only use letters, digits, dots, dashes and underscores.")
        }
        guard let fields = entry.node.entries else {
            problem(.invalid, name, base, entry.line, "Service \(name) must be a map of settings.")
            return service
        }

        var envFromFiles: [EnvVar] = []
        var envInline: [EnvVar] = []

        for field in fields {
            let key = field.key
            let path = "\(base).\(key)"
            let node = field.node
            switch key {
            case "image":
                service.image = node.text
            case "build":
                service.build = readBuild(node, service: name, path: path, line: field.line)
            case "command":
                service.command = readCommand(node)
            case "entrypoint":
                service.entrypoint = readCommand(node)
            case "environment":
                for pair in node.keyValues ?? [] {
                    if let value = pair.value {
                        envInline.append(EnvVar(key: pair.key, value: value))
                    } else if let inherited = environment[pair.key] {
                        envInline.append(EnvVar(key: pair.key, value: inherited))
                    }
                }
            case "env_file":
                envFromFiles += readEnvFiles(node, service: name, path: path, line: field.line, into: &service)
            case "ports":
                for item in node.items ?? [] {
                    service.ports += readPort(item, service: name, path: path)
                }
            case "expose":
                // Every port is reachable on the container IP, nothing to do.
                break
            case "volumes":
                for item in node.items ?? [] {
                    if let mount = readVolume(item, service: name, path: path) {
                        service.volumes.append(mount)
                    }
                }
            case "networks":
                readServiceNetworks(node, service: &service, path: path, line: field.line)
            case "network_mode":
                if let mode = node.text, mode != "bridge", mode != "default" {
                    problem(.notPossible, name, path, field.line, "Network mode \(mode) is not possible. Each container gets its own IP.")
                }
            case "depends_on":
                service.dependsOn = readDependsOn(node, service: name, path: path)
            case "healthcheck":
                service.healthcheck = readHealthcheck(node, service: name, path: path, line: field.line)
            case "profiles":
                service.profiles = node.stringList ?? []
            case "labels":
                for pair in node.keyValues ?? [] {
                    service.labels[pair.key] = pair.value ?? ""
                }
            case "working_dir":
                service.workingDir = node.text
            case "cpus":
                if let text = node.text, let value = Double(text), value > 0 {
                    service.cpus = value
                } else {
                    problem(.invalid, name, path, field.line, "cpus must be a number.")
                }
            case "mem_limit":
                if let text = node.text, let memory = ComposeUnits.memory(text) {
                    service.memory = memory
                } else {
                    problem(.invalid, name, path, field.line, "mem_limit must be a size like 512m or 1g.")
                }
            case "deploy":
                readDeploy(node, service: &service, path: path)
            case "platform":
                service.platform = node.text
            case "container_name":
                if let text = node.text {
                    service.containerName = text
                    if text.range(of: "^[a-zA-Z0-9][a-zA-Z0-9_.-]+$", options: .regularExpression) == nil {
                        problem(.invalid, name, path, field.line, "Container name \(text) can only use letters, digits, dots, dashes and underscores.")
                    }
                }
            case "restart":
                service.restart = node.text
                if let policy = node.text, policy != "no" {
                    problem(.notPossible, name, path, field.line, "Restart policy \(policy) is not possible. Containers do not restart on their own.")
                }
            case "user":
                service.user = node.text
            case "tmpfs":
                for spec in node.stringList ?? [] where !spec.isEmpty {
                    if spec.hasPrefix("/") {
                        service.tmpfs.append(spec)
                    } else {
                        problem(.invalid, name, path, field.line, "tmpfs path \(spec) must start with /.")
                    }
                }
            case "read_only":
                service.readOnly = node.bool ?? false
            case "init":
                service.initProcess = node.bool ?? false
            case "cap_add":
                service.capAdd = node.stringList ?? []
            case "cap_drop":
                service.capDrop = node.stringList ?? []
            case "dns":
                service.dns = node.stringList ?? []
            case "dns_search":
                service.dnsSearch = node.stringList ?? []
            case "dns_opt":
                service.dnsOptions = node.stringList ?? []
            case "shm_size":
                if let text = node.text, let size = ComposeUnits.memory(text) {
                    service.shmSize = size
                } else {
                    problem(.invalid, name, path, field.line, "shm_size must be a size like 64m or 1g.")
                }
            case "ulimits":
                service.ulimits = readUlimits(node, service: name, path: path)
            case "mac_address":
                service.macAddress = node.text
            case "stop_signal":
                service.stopSignal = node.text
            case "stop_grace_period":
                if let text = node.text, let seconds = ComposeUnits.duration(text) {
                    service.stopGracePeriod = seconds
                } else {
                    problem(.invalid, name, path, field.line, "stop_grace_period must be a duration like 10s or 1m30s.")
                }
            case "pull_policy":
                if let text = node.text {
                    if let policy = ComposePullPolicy(composeValue: text) {
                        service.pullPolicy = policy
                    } else if text == "daily" || text == "weekly" || text.hasPrefix("every_") {
                        service.pullPolicy = .missing
                        problem(.notBuilt, name, path, field.line, "Timed pull policy \(text) is not built yet. Missing images are pulled.")
                    } else {
                        problem(.invalid, name, path, field.line, "pull_policy \(text) is not valid. Use always, never, missing or build.")
                    }
                }
            case "post_start", "pre_stop":
                let hooks = readHooks(node, service: name, path: path)
                if key == "post_start" { service.postStart = hooks } else { service.preStop = hooks }
            case "extra_hosts":
                for pair in node.keyValues ?? [] {
                    // "host:ip" in lists, "host=ip" or "host: ip" otherwise.
                    var host = pair.key
                    var ip = pair.value
                    if ip == nil, let colon = host.firstIndex(of: ":") {
                        ip = String(host[host.index(after: colon)...])
                        host = String(host[..<colon])
                    }
                    if let ip, !ip.isEmpty, ip != "host-gateway" {
                        service.extraHosts.append("\(ip) \(host)")
                    } else {
                        problem(.notBuilt, name, path, pair.line, "extra_hosts entry \(pair.key) is not built yet.")
                    }
                }
            default:
                if key.hasPrefix("x-") { continue }
                if let message = Self.notPossible[key] {
                    problem(.notPossible, name, path, field.line, message)
                } else if let message = Self.notBuilt[key] {
                    problem(.notBuilt, name, path, field.line, message)
                } else {
                    problem(.notBuilt, name, path, field.line, "Unknown key \(key).")
                }
            }
        }

        // Later values win, environment beats env_file.
        var merged: [EnvVar] = []
        for item in envFromFiles + envInline {
            merged.removeAll { $0.key == item.key }
            merged.append(item)
        }
        service.environment = merged

        if service.image == nil && service.build == nil {
            problem(.invalid, name, base, entry.line, "Service \(name) needs an image or a build.")
        }
        if service.pullPolicy == .build && service.build == nil, let line = fields.first(where: { $0.key == "pull_policy" })?.line {
            problem(.invalid, name, "\(base).pull_policy", line, "pull_policy build needs a build section.")
        }
        return service
    }

    private func readCommand(_ node: ComposeNode) -> [String]? {
        if node.isNull { return nil }
        if let text = node.text { return ShellWords.split(text) }
        if let items = node.items { return items.map { $0.text ?? "" } }
        return nil
    }

    /// `nofile: 1024` or `nofile: {soft: 1024, hard: 2048}` as "nofile=1024:2048".
    private mutating func readUlimits(_ node: ComposeNode, service: String, path: String) -> [String] {
        var result: [String] = []
        for entry in node.entries ?? [] {
            if let value = entry.node.int {
                result.append("\(entry.key)=\(value):\(value)")
            } else if let soft = entry.node["soft"]?.int, let hard = entry.node["hard"]?.int {
                result.append("\(entry.key)=\(soft):\(hard)")
            } else {
                problem(.invalid, service, "\(path).\(entry.key)", entry.line, "ulimit \(entry.key) needs a number or soft and hard numbers.")
            }
        }
        return result
    }

    /// `post_start` and `pre_stop` lists. Privileged hooks are refused.
    private mutating func readHooks(_ node: ComposeNode, service: String, path: String) -> [ComposeHook] {
        guard let items = node.items else {
            problem(.invalid, service, path, node.line, "Hooks must be a list.")
            return []
        }
        var hooks: [ComposeHook] = []
        for item in items {
            guard item.entries != nil else {
                problem(.invalid, service, path, item.line, "Each hook needs a command.")
                continue
            }
            guard let commandNode = item["command"], let command = readCommand(commandNode), !command.isEmpty else {
                problem(.invalid, service, path, item.line, "Each hook needs a command.")
                continue
            }
            var hook = ComposeHook(command: command, workingDir: item["working_dir"]?.text, user: item["user"]?.text)
            for pair in item["environment"]?.keyValues ?? [] {
                if let value = pair.value ?? environment[pair.key] {
                    hook.environment.append(EnvVar(key: pair.key, value: value))
                }
            }
            for field in item.entries ?? [] {
                switch field.key {
                case "command", "working_dir", "user", "environment":
                    break
                case "privileged":
                    if field.node.bool == true {
                        problem(.invalid, service, "\(path).privileged", field.line, "Privileged hooks are not possible here. Each container runs in its own small VM. Remove privileged from the hook.")
                    }
                default:
                    if field.key.hasPrefix("x-") { continue }
                    problem(.notBuilt, service, "\(path).\(field.key)", field.line, "Hook option \(field.key) is not built yet.")
                }
            }
            hooks.append(hook)
        }
        return hooks
    }

    private func resolvePath(_ raw: String, relativeTo base: URL) -> String {
        if raw.hasPrefix("~") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return URL(fileURLWithPath: home + raw.dropFirst()).standardizedFileURL.path
        }
        if raw.hasPrefix("/") {
            return URL(fileURLWithPath: raw).standardizedFileURL.path
        }
        return base.appendingPathComponent(raw).standardizedFileURL.path
    }

    private mutating func readBuild(_ node: ComposeNode, service: String, path: String, line: Int) -> ComposeBuild? {
        if let context = node.text {
            if context.contains("://") || context.hasPrefix("git@") {
                problem(.notBuilt, service, path, line, "Building from a remote context is not built yet.")
                return nil
            }
            return ComposeBuild(context: resolvePath(context, relativeTo: baseDirectory(node.line)))
        }
        guard let fields = node.entries else { return nil }
        let rawContext = node["context"]?.text ?? "."
        if rawContext.contains("://") || rawContext.hasPrefix("git@") {
            problem(.notBuilt, service, "\(path).context", line, "Building from a remote context is not built yet.")
            return nil
        }
        var build = ComposeBuild(context: resolvePath(rawContext, relativeTo: baseDirectory(node.entry("context")?.node.line ?? node.line)))
        let contextURL = URL(fileURLWithPath: build.context)
        for field in fields {
            switch field.key {
            case "context":
                break
            case "dockerfile":
                if let file = field.node.text {
                    build.dockerfile = resolvePath(file, relativeTo: contextURL)
                }
            case "args":
                for pair in field.node.keyValues ?? [] {
                    if let value = pair.value ?? environment[pair.key] {
                        build.args.append(EnvVar(key: pair.key, value: value))
                    }
                }
            case "target":
                build.target = field.node.text
            default:
                if field.key.hasPrefix("x-") { continue }
                problem(.notBuilt, service, "\(path).\(field.key)", field.line, "Build option \(field.key) is not built yet.")
            }
        }
        return build
    }

    private mutating func readEnvFiles(_ node: ComposeNode, service: String, path: String, line: Int, into target: inout ComposeService) -> [EnvVar] {
        var specs: [(path: String, required: Bool, line: Int)] = []
        if let text = node.text {
            specs.append((text, true, node.line))
        } else {
            for item in node.items ?? [] {
                if let text = item.text {
                    specs.append((text, true, item.line))
                } else if let filePath = item["path"]?.text {
                    specs.append((filePath, item["required"]?.bool ?? true, item.line))
                }
            }
        }
        var result: [EnvVar] = []
        for spec in specs {
            let resolved = resolvePath(spec.path, relativeTo: baseDirectory(spec.line))
            target.envFiles.append(resolved)
            guard let text = readFile(URL(fileURLWithPath: resolved)) else {
                if spec.required {
                    problem(.invalid, service, path, spec.line, "env_file \(spec.path) was not found.")
                }
                continue
            }
            result += DotEnvParser.parse(text, lookup: environment)
        }
        return result
    }

    private mutating func readPort(_ node: ComposeNode, service: String, path: String) -> [ComposePort] {
        var spec: String
        if let text = node.text {
            spec = text
        } else if node.entries != nil {
            guard let target = node["target"]?.text else {
                problem(.invalid, service, path, node.line, "A port needs a target.")
                return []
            }
            let proto = node["protocol"]?.text ?? "tcp"
            let published = node["published"]?.text ?? ""
            var hostPart = ""
            if let ip = node["host_ip"]?.text {
                hostPart = (ip.contains(":") ? "[\(ip)]" : ip) + ":"
            }
            spec = "\(hostPart)\(published):\(target)/\(proto)"
            if let mode = node["mode"]?.text, mode != "ingress", mode != "host" {
                problem(.notBuilt, service, path, node.line, "Port mode \(mode) is not built yet.")
            }
        } else {
            return []
        }
        spec = spec.trimmingCharacters(in: .whitespaces)
        let parsed = Self.parsePortSpec(spec)
        if let error = parsed.error {
            problem(.invalid, service, path, node.line, error)
            return []
        }
        for port in parsed.ports where port.published == nil {
            problem(.notBuilt, service, path, node.line, "Random host ports are not built yet. Port \(port.target) uses host port \(port.target).")
        }
        return parsed.ports
    }

    /// Short port syntax: "80", "8080:80", "127.0.0.1:8080:80/udp", "8000-8002:8000-8002".
    static func parsePortSpec(_ input: String) -> (ports: [ComposePort], error: String?) {
        var s = input
        var proto = "tcp"
        if let slash = s.lastIndex(of: "/") {
            proto = String(s[s.index(after: slash)...]).lowercased()
            s = String(s[..<slash])
        }
        guard proto == "tcp" || proto == "udp" else {
            return ([], "Port protocol \(proto) is not supported.")
        }
        var hostIP: String?
        var published = ""
        var target = ""
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            hostIP = String(s[s.index(after: s.startIndex)..<close])
            var rest = String(s[s.index(after: close)...])
            if rest.hasPrefix(":") { rest.removeFirst() }
            let parts = rest.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else { return ([], "Port \(input) is not valid.") }
            published = parts[0]
            target = parts[1]
        } else {
            let parts = s.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            switch parts.count {
            case 1:
                target = parts[0]
            case 2:
                published = parts[0]
                target = parts[1]
            case 3:
                hostIP = parts[0].isEmpty ? nil : parts[0]
                published = parts[1]
                target = parts[2]
            default:
                return ([], "Port \(input) is not valid.")
            }
        }

        func range(_ text: String) -> ClosedRange<Int>? {
            let bits = text.split(separator: "-").map { Int($0.trimmingCharacters(in: .whitespaces)) }
            if bits.count == 1, let a = bits[0], (1...65535).contains(a) { return a...a }
            if bits.count == 2, let a = bits[0], let b = bits[1], a <= b, (1...65535).contains(a), (1...65535).contains(b) { return a...b }
            return nil
        }

        guard let targets = range(target) else { return ([], "Port \(input) is not valid.") }
        var publishedRange: ClosedRange<Int>?
        if !published.isEmpty {
            guard let r = range(published) else { return ([], "Port \(input) is not valid.") }
            guard r.count == targets.count else {
                return ([], "Port \(input) has ranges of different sizes.")
            }
            publishedRange = r
        }
        guard targets.count <= 1000 else { return ([], "Port range \(input) is too large.") }

        var ports: [ComposePort] = []
        for (offset, port) in targets.enumerated() {
            let host = publishedRange.map { $0.lowerBound + offset }
            ports.append(ComposePort(hostIP: hostIP, published: host, target: port, proto: proto))
        }
        return (ports, nil)
    }

    private mutating func readVolume(_ node: ComposeNode, service: String, path: String) -> ComposeVolumeMount? {
        if let text = node.text {
            let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            switch parts.count {
            case 1:
                guard parts[0].hasPrefix("/") else {
                    problem(.invalid, service, path, node.line, "Volume \(text) is not valid. An anonymous volume needs an absolute path.")
                    return nil
                }
                return ComposeVolumeMount(kind: .anonymous, source: "", target: parts[0])
            case 2, 3:
                let readOnly = parts.count == 3 && parts[2].split(separator: ",").contains("ro")
                return mount(source: parts[0], target: parts[1], type: nil, readOnly: readOnly, service: service, path: path, line: node.line)
            default:
                problem(.invalid, service, path, node.line, "Volume \(text) is not valid.")
                return nil
            }
        }
        guard node.entries != nil else { return nil }
        let type = node["type"]?.text ?? "volume"
        guard let target = node["target"]?.text else {
            problem(.invalid, service, path, node.line, "A volume needs a target.")
            return nil
        }
        let readOnly = node["read_only"]?.bool ?? false
        if node["volume"]?["subpath"] != nil {
            problem(.notBuilt, service, path, node.line, "Volume subpaths are not built yet.")
        }
        switch type {
        case "volume", "bind":
            guard let source = node["source"]?.text, !source.isEmpty else {
                if type == "volume" {
                    return ComposeVolumeMount(kind: .anonymous, source: "", target: target, readOnly: readOnly)
                }
                problem(.invalid, service, path, node.line, "A bind mount needs a source.")
                return nil
            }
            return mount(source: source, target: target, type: type, readOnly: readOnly, service: service, path: path, line: node.line)
        case "tmpfs":
            // Kept as a mount for display. The planner turns it into `--tmpfs target:options`.
            var options: [String] = []
            if let size = node["tmpfs"]?["size"]?.text {
                if let value = ComposeUnits.memory(size) {
                    options.append("size=\(value.lowercased())")
                } else {
                    problem(.invalid, service, path, node.line, "tmpfs size \(size) is not valid.")
                }
            }
            if let mode = node["tmpfs"]?["mode"]?.text { options.append("mode=\(mode)") }
            if readOnly { options.append("ro") }
            return ComposeVolumeMount(kind: .tmpfs, source: options.joined(separator: ","), target: target, readOnly: readOnly)
        default:
            problem(.notPossible, service, path, node.line, "Mount type \(type) is not possible.")
            return nil
        }
    }

    private mutating func mount(source: String, target: String, type: String?, readOnly: Bool, service: String, path: String, line: Int) -> ComposeVolumeMount? {
        let looksLikePath = source.hasPrefix("/") || source.hasPrefix(".") || source.hasPrefix("~")
        if type == "bind" || (type == nil && looksLikePath) {
            return ComposeVolumeMount(kind: .bind, source: resolvePath(source, relativeTo: baseDirectory(line)), target: target, readOnly: readOnly)
        }
        if !declaredVolumes.contains(source) {
            problem(.invalid, service, path, line, "Volume \(source) is not listed under the top level volumes.")
        }
        return ComposeVolumeMount(kind: .volume, source: source, target: target, readOnly: readOnly)
    }

    private mutating func readServiceNetworks(_ node: ComposeNode, service: inout ComposeService, path: String, line: Int) {
        var names: [String] = []
        if let list = node.items {
            names = list.compactMap(\.text)
        } else if let entries = node.entries {
            for entry in entries {
                names.append(entry.key)
                for field in entry.node.entries ?? [] {
                    switch field.key {
                    case "aliases":
                        service.networkAliases += field.node.stringList ?? []
                    case "mac_address":
                        if entry.key == entries.first?.key { service.macAddress = field.node.text }
                    default:
                        problem(.notBuilt, service.name, "\(path).\(entry.key).\(field.key)", field.line, "Network option \(field.key) is not built yet.")
                    }
                }
            }
        }
        for name in names where !declaredNetworks.contains(name) {
            problem(.invalid, service.name, path, line, "Network \(name) is not listed under the top level networks.")
        }
        if names.count > 1 {
            problem(.notBuilt, service.name, path, line, "More than one network is not built yet. Only \(names[0]) is used.")
        }
        service.networks = names
    }

    private mutating func readDependsOn(_ node: ComposeNode, service: String, path: String) -> [ComposeDependency] {
        var result: [ComposeDependency] = []
        if let list = node.items {
            for item in list {
                if let name = item.text { result.append(ComposeDependency(service: name)) }
            }
        } else if let entries = node.entries {
            for entry in entries {
                var dependency = ComposeDependency(service: entry.key)
                if let raw = entry.node["condition"]?.text {
                    if let condition = ComposeDependency.Condition(rawValue: raw) {
                        dependency.condition = condition
                    } else {
                        problem(.invalid, service, "\(path).\(entry.key).condition", entry.line, "Condition \(raw) is not valid.")
                    }
                }
                if let required = entry.node["required"]?.bool {
                    dependency.required = required
                }
                if entry.node["restart"]?.bool == true {
                    problem(.notBuilt, service, "\(path).\(entry.key).restart", entry.line, "Restarting with a dependency is not built yet.")
                }
                result.append(dependency)
            }
        }
        return result
    }

    private mutating func readHealthcheck(_ node: ComposeNode, service: String, path: String, line: Int) -> ComposeHealthcheck? {
        guard node.entries != nil else { return nil }
        if node["disable"]?.bool == true { return ComposeHealthcheck(command: []) }
        var check = ComposeHealthcheck(command: [])
        if let test = node["test"] {
            if let text = test.text {
                check.command = ["/bin/sh", "-c", text]
            } else if let items = test.items?.compactMap(\.text), let first = items.first {
                switch first {
                case "NONE": check.command = []
                case "CMD": check.command = Array(items.dropFirst())
                case "CMD-SHELL": check.command = ["/bin/sh", "-c", items.dropFirst().joined(separator: " ")]
                default: check.command = items
                }
            }
        } else {
            problem(.notBuilt, service, path, line, "A healthcheck without test would use the image's HEALTHCHECK, which is not read yet. Add a test.")
        }
        func seconds(_ key: String) -> TimeInterval? {
            guard let text = node[key]?.text else { return nil }
            return ComposeUnits.duration(text)
        }
        for key in ["interval", "timeout", "start_period"] {
            if let field = node.entry(key), seconds(key) == nil {
                problem(.invalid, service, "\(path).\(key)", field.line, "\(key) must be a duration like 10s.")
            }
        }
        if let interval = seconds("interval") { check.interval = interval }
        if let timeout = seconds("timeout") { check.timeout = timeout }
        if let start = seconds("start_period") { check.startPeriod = start }
        if let retries = node["retries"]?.int { check.retries = max(1, retries) }
        return check
    }

    private mutating func readDeploy(_ node: ComposeNode, service: inout ComposeService, path: String) {
        for field in node.entries ?? [] {
            switch field.key {
            case "resources":
                for part in field.node.entries ?? [] {
                    switch part.key {
                    case "limits":
                        if service.cpus == nil, let text = part.node["cpus"]?.text, let value = Double(text), value > 0 {
                            service.cpus = value
                        }
                        if service.memory == nil, let text = part.node["memory"]?.text {
                            service.memory = ComposeUnits.memory(text)
                        }
                        for limit in part.node.entries ?? [] where limit.key != "cpus" && limit.key != "memory" {
                            problem(.notPossible, service.name, "\(path).resources.limits.\(limit.key)", limit.line, "Limit \(limit.key) is not possible.")
                        }
                    case "reservations":
                        problem(.notPossible, service.name, "\(path).resources.reservations", part.line, "Reservations are not possible. Use limits.")
                    default:
                        problem(.notBuilt, service.name, "\(path).resources.\(part.key)", part.line, "Unknown key \(part.key).")
                    }
                }
            case "replicas":
                if let count = field.node.int, count > 1 {
                    problem(.notBuilt, service.name, "\(path).replicas", field.line, "Replicas are not built yet. One container runs.")
                }
            case "restart_policy":
                problem(.notPossible, service.name, "\(path).restart_policy", field.line, "Restart policies are not possible. Containers do not restart on their own.")
            case "labels":
                for pair in field.node.keyValues ?? [] {
                    service.labels[pair.key] = pair.value ?? ""
                }
            default:
                problem(.notBuilt, service.name, "\(path).\(field.key)", field.line, "Swarm setting \(field.key) is not built yet.")
            }
        }
    }

    // MARK: Checks across services

    private mutating func validate(_ services: [ComposeService]) {
        let byName = Dictionary(services.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        for service in services {
            for dependency in service.dependsOn {
                guard let target = byName[dependency.service] else {
                    if dependency.required {
                        problem(.invalid, service.name, "services.\(service.name).depends_on", service.line, "\(service.name) depends on \(dependency.service), which is not in the file.")
                    }
                    continue
                }
                if dependency.condition == .healthy, target.healthcheck == nil || target.healthcheck?.isDisabled == true {
                    problem(.invalid, service.name, "services.\(service.name).depends_on", service.line, "\(service.name) waits for \(target.name) to be healthy, but \(target.name) has no healthcheck.")
                }
            }
        }
        do {
            _ = try ComposeOrder.sorted(services)
        } catch ComposeError.cycle(let names) {
            let line = services.first { names.contains($0.name) }?.line ?? 0
            problem(.invalid, nil, "depends_on", line, "These services depend on each other in a loop: \(names.joined(separator: ", ")).")
        } catch {}
    }
}

// MARK: - Order

public enum ComposeOrder {
    /// Services in start order. Dependencies first, file order otherwise.
    /// Throws ComposeError.cycle when services depend on each other in a loop.
    public static func sorted(_ services: [ComposeService]) throws -> [ComposeService] {
        let names = Set(services.map(\.name))
        var remaining = services
        var done: Set<String> = []
        var ordered: [ComposeService] = []
        while !remaining.isEmpty {
            guard let index = remaining.firstIndex(where: { service in
                service.dependsOn.allSatisfy { !names.contains($0.service) || done.contains($0.service) }
            }) else {
                throw ComposeError.cycle(findCycle(in: remaining, known: names))
            }
            let next = remaining.remove(at: index)
            ordered.append(next)
            done.insert(next.name)
        }
        return ordered
    }

    private static func findCycle(in remaining: [ComposeService], known: Set<String>) -> [String] {
        let byName = Dictionary(remaining.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        guard var current = remaining.first else { return [] }
        var path: [String] = []
        while !path.contains(current.name) {
            path.append(current.name)
            guard let next = current.dependsOn.compactMap({ byName[$0.service] }).first else { break }
            current = next
        }
        if let start = path.firstIndex(of: current.name) {
            return Array(path[start...])
        }
        return remaining.map(\.name)
    }
}
