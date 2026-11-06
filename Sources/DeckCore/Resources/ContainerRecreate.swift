import Foundation

// Edit and Recreate, done safely.
//
// `container` has no rename and no "update", so changing a setting means a new
// container. The old one is captured in full from `container inspect` first.
// If the new one fails to start, the old one is made again from that capture,
// with the same name, and started when it was running.
//
// Pure parts (capture, checks, plan) are plain functions for tests. The
// `ContainerClient` extension at the bottom runs the plan.

// MARK: - Defaults

/// What `container run` uses when no `--cpus` or `--memory` is given.
public struct RunDefaults: Sendable, Hashable {
    public var cpus: Int
    public var memoryBytes: UInt64

    /// Built into `container` 1.x when `config.toml` sets nothing.
    public static let builtIn = RunDefaults(cpus: 4, memoryBytes: 1_073_741_824)

    public init(cpus: Int, memoryBytes: UInt64) {
        self.cpus = cpus
        self.memoryBytes = memoryBytes
    }

    /// Reads `container.cpus` and `container.memory` from `system property list`.
    public init(properties: [SystemProperty]) {
        var result = RunDefaults.builtIn
        if let text = properties.first(where: { $0.key == "container.cpus" })?.value, let cpus = Int(text), cpus > 0 {
            result.cpus = cpus
        }
        if let text = properties.first(where: { $0.key == "container.memory" })?.value,
           let bytes = RunDefaults.parseMemory(text), bytes > 0 {
            result.memoryBytes = bytes
        }
        self = result
    }

    /// Bytes from "1gb", "2048mb", "512M", "1G", "1GiB" or a plain number of bytes.
    public static func parseMemory(_ text: String) -> UInt64? {
        var value = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !value.isEmpty else { return nil }
        for suffix in ["ib", "b"] where value.hasSuffix(suffix) && value.count > suffix.count {
            value.removeLast(suffix.count)
            break
        }
        let units: [Character: UInt64] = ["k": 1 << 10, "m": 1 << 20, "g": 1 << 30, "t": 1 << 40, "p": 1 << 50]
        var multiplier: UInt64 = 1
        if let last = value.last, let unit = units[last] {
            multiplier = unit
            value.removeLast()
        }
        guard let number = Double(value), number >= 0 else { return nil }
        return UInt64(number * Double(multiplier))
    }

    /// "1G", "512M" or "64K" text for `--memory` and `--shm-size`.
    public static func memoryText(_ bytes: UInt64) -> String {
        let mib: UInt64 = 1 << 20
        if bytes >= 1 << 30, bytes % (1 << 30) == 0 { return "\(bytes >> 30)G" }
        if bytes % mib == 0 { return "\(bytes / mib)M" }
        if bytes % 1024 == 0 { return "\(bytes / 1024)K" }
        return "\((bytes + mib - 1) / mib)M"
    }
}

// MARK: - Capture

/// Everything needed to make a container again.
public struct RecreateCapture: Sendable, Hashable {
    public var id: String
    public var options: RunOptions
    public var wasRunning: Bool

    public init(id: String, options: RunOptions, wasRunning: Bool) {
        self.id = id
        self.options = options
        self.wasRunning = wasRunning
    }
}

public extension RunOptions {
    /// The `container run` options that make this container again.
    /// Values that match the image or the system defaults are left out, so
    /// the new container follows the same defaults as the old one.
    init(recreating detail: ContainerDetail, imageConfig: ImageConfigInfo?, defaults: RunDefaults = .builtIn) {
        let summary = detail.summary
        let config = imageConfig
        let extras = InspectExtras(rawJSON: detail.rawJSON)

        // Process: entrypoint plus command.
        let process = summary.command.isEmpty ? detail.entrypoint + detail.arguments : summary.command
        var entrypoint: String?
        var command: [String] = []
        if let config {
            let imageProcess = config.entrypoint + config.cmd
            if process.isEmpty || process == imageProcess {
                command = []
            } else if !config.entrypoint.isEmpty, process.starts(with: config.entrypoint) {
                let rest = Array(process.dropFirst(config.entrypoint.count))
                command = rest == config.cmd ? [] : rest
            } else if config.entrypoint.isEmpty {
                // No image entrypoint: the words after the image are the whole process.
                command = process
            } else if let first = process.first {
                entrypoint = first
                command = Array(process.dropFirst())
            }
        } else if let first = process.first {
            // Image unknown: say it all.
            entrypoint = first
            command = Array(process.dropFirst())
        }

        // Env: only what the person set, not the image values.
        let imageEnv = Set((config?.env ?? []).map { "\($0.key)=\($0.value)" })
        let env = detail.env.filter { item in
            let line = "\(item.key)=\(item.value)"
            return !imageEnv.contains(line) && line != RunOptions.defaultPathLine
        }

        var mounts: [MountSpec] = []
        var tmpfs: [String] = []
        for mount in detail.mounts {
            switch mount.type.lowercased() {
            case "bind", "virtiofs":
                mounts.append(MountSpec(kind: .bind, source: mount.source, destination: mount.destination, readOnly: mount.readOnly))
            case "volume", "block":
                mounts.append(MountSpec(kind: .volume, source: mount.source, destination: mount.destination, readOnly: mount.readOnly))
            case "tmpfs":
                if !mount.destination.isEmpty { tmpfs.append(mount.destination) }
            default:
                break
            }
        }

        // Resources: explicit only when they differ from the defaults.
        var cpus: Int?
        if let value = summary.cpus, value > 0, value != defaults.cpus { cpus = value }
        var memory: String?
        if let bytes = summary.memoryBytes, bytes > 0, bytes != defaults.memoryBytes {
            memory = RunDefaults.memoryText(bytes)
        }

        // Networks: what the container asked for, not the live attachment
        // (live MAC addresses are made up at start).
        var network: String?
        var mac: String?
        var extraNetworks: [String] = []
        if let wanted = extras.networks {
            for (index, item) in wanted.enumerated() {
                if index == 0 {
                    network = item.name == "default" ? nil : item.name
                    mac = item.mac
                } else {
                    extraNetworks.append(item.spec)
                }
            }
        } else if let first = detail.networks.first?.network, first != "default" {
            network = first
        }

        // Working folder: "/" is what the CLI reports when nobody set one.
        var workingDir = detail.workingDir
        let imageDir = CLIText.nonEmpty(config?.workingDir)
        if workingDir == imageDir || (imageDir == nil && workingDir == "/") { workingDir = nil }

        // User: root ("0:0") is the default when the image sets none.
        var user = CLIText.nonEmpty(detail.user)
        let imageUser = CLIText.nonEmpty(config?.user)
        if user == imageUser || (imageUser == nil && (user == "0:0" || user == "0" || user == "root")) { user = nil }

        let platform = summary.platform.contains("amd64") ? "linux/amd64" : nil

        self.init(
            image: summary.image,
            name: summary.name,
            command: command,
            entrypoint: entrypoint,
            env: env,
            ports: summary.ports,
            mounts: mounts,
            cpus: cpus,
            memory: memory,
            network: network,
            workingDir: workingDir,
            labels: summary.labels,
            detach: true,
            autoRemove: false, // `inspect` does not say, so the safe choice is to keep it.
            platform: platform,
            user: user,
            readOnlyRootfs: detail.readOnlyRootfs,
            macAddress: mac,
            extraNetworks: extraNetworks,
            tmpfs: tmpfs,
            capAdd: extras.capAdd,
            capDrop: extras.capDrop,
            dnsServers: extras.dnsServers,
            dnsSearch: extras.dnsSearch,
            dnsOptions: extras.dnsOptions,
            dnsDomain: extras.dnsDomain,
            noDNS: extras.noDNS,
            ulimits: extras.ulimits,
            useInit: extras.useInit,
            rosetta: platform == nil && (extras.rosetta ?? detail.rosetta),
            ssh: extras.ssh,
            tty: extras.tty,
            interactive: false,
            shmSize: extras.shmBytes.map(RunDefaults.memoryText),
            publishSockets: extras.publishSockets,
            maskedPaths: extras.maskedPaths,
            readOnlyPaths: extras.readOnlyPaths,
            runtime: extras.runtime,
            virtualization: extras.virtualization
        )
    }

    /// PATH the runtime gives every Linux container.
    static let defaultPathLine = "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
}

/// Inspect fields that `ContainerDetail` does not carry. Read from the raw JSON.
struct InspectExtras {
    struct Network {
        var name: String
        var mac: String?
        var mtu: Int?

        var spec: String {
            var text = name
            if let mac { text += ",mac=\(mac)" }
            if let mtu, mtu != InspectExtras.defaultMTU { text += ",mtu=\(mtu)" }
            return text
        }
    }

    static let defaultMTU = 1280

    var networks: [Network]?
    var capAdd: [String] = []
    var capDrop: [String] = []
    var dnsServers: [String] = []
    var dnsSearch: [String] = []
    var dnsOptions: [String] = []
    var dnsDomain: String?
    var noDNS = false
    var ulimits: [String] = []
    var useInit = false
    var rosetta: Bool?
    var ssh = false
    var tty = false
    var shmBytes: UInt64?
    var publishSockets: [String] = []
    var maskedPaths: [String]?
    var readOnlyPaths: [String]?
    var runtime: String?
    var virtualization = false

    init(rawJSON: String) {
        guard let root = CLIJSON.object(rawJSON) else { return }
        let item = (root as? [Any])?.first ?? root
        guard let object = item as? [String: Any], let config = object["configuration"] as? [String: Any] else { return }

        if let list = config["networks"] as? [[String: Any]] {
            networks = list.compactMap { entry in
                guard let name = CLIText.nonEmpty(entry["network"] as? String) else { return nil }
                let options = entry["options"] as? [String: Any] ?? [:]
                return Network(
                    name: name,
                    mac: CLIText.nonEmpty(options["macAddress"] as? String),
                    mtu: (options["mtu"] as? NSNumber)?.intValue
                )
            }
        }
        capAdd = Self.strings(config["capAdd"])
        capDrop = Self.strings(config["capDrop"])
        if let dns = config["dns"] as? [String: Any] {
            dnsServers = Self.strings(dns["nameservers"])
            dnsSearch = Self.strings(dns["searchDomains"])
            dnsOptions = Self.strings(dns["options"])
            dnsDomain = CLIText.nonEmpty(dns["domain"] as? String)
        } else if config["dns"] == nil, config["capAdd"] != nil {
            // 1.x always writes "dns" unless the container was made with --no-dns.
            noDNS = true
        }
        if let process = config["initProcess"] as? [String: Any] {
            tty = (process["terminal"] as? Bool) ?? false
            if let limits = process["rlimits"] as? [[String: Any]] {
                ulimits = limits.compactMap(Self.ulimit)
            }
        }
        useInit = (config["useInit"] as? Bool) ?? false
        rosetta = config["rosetta"] as? Bool
        ssh = (config["ssh"] as? Bool) ?? false
        virtualization = (config["virtualization"] as? Bool) ?? false
        if let size = (config["shmSize"] as? NSNumber)?.uint64Value, size > 0 { shmBytes = size }
        if let sockets = config["publishedSockets"] as? [[String: Any]] {
            publishSockets = sockets.compactMap { entry in
                guard let host = CLIText.nonEmpty(entry["hostPath"] as? String),
                      let inner = CLIText.nonEmpty(entry["containerPath"] as? String) else { return nil }
                return "\(host):\(inner)"
            }
        }
        if config["maskedPaths"] != nil { maskedPaths = Self.strings(config["maskedPaths"]) }
        if config["readonlyPaths"] != nil { readOnlyPaths = Self.strings(config["readonlyPaths"]) }
        if let handler = CLIText.nonEmpty(config["runtimeHandler"] as? String), !handler.hasPrefix("container-runtime-") {
            runtime = handler
        }
    }

    private static func strings(_ value: Any?) -> [String] {
        (value as? [Any] ?? []).compactMap { $0 as? String }
    }

    /// {"limit": "RLIMIT_NOFILE", "soft": 1024, "hard": 2048} to "nofile=1024:2048".
    private static func ulimit(_ entry: [String: Any]) -> String? {
        guard var name = CLIText.nonEmpty(entry["limit"] as? String) else { return nil }
        if name.uppercased().hasPrefix("RLIMIT_") { name = String(name.dropFirst(7)) }
        name = name.lowercased()
        guard let soft = (entry["soft"] as? NSNumber)?.uint64Value else { return nil }
        let hard = (entry["hard"] as? NSNumber)?.uint64Value ?? soft
        return "\(name)=\(soft):\(hard)"
    }
}

// MARK: - Arguments

public extension ContainerClient {
    /// Flags for the RunOptions fields added for Edit and Recreate.
    /// Empty for options that do not set them.
    static func extraRunArguments(_ options: RunOptions) -> [String] {
        var args: [String] = []
        if let user = CLIText.nonEmpty(options.user) { args += ["--user", user] }
        if options.readOnlyRootfs { args.append("--read-only") }
        for path in options.tmpfs where !path.isEmpty { args += ["--tmpfs", path] }
        for cap in options.capAdd where !cap.isEmpty { args += ["--cap-add", cap] }
        for cap in options.capDrop where !cap.isEmpty { args += ["--cap-drop", cap] }
        if options.noDNS {
            args.append("--no-dns")
        } else {
            for server in options.dnsServers where !server.isEmpty { args += ["--dns", server] }
            if let domain = CLIText.nonEmpty(options.dnsDomain) { args += ["--dns-domain", domain] }
            for domain in options.dnsSearch where !domain.isEmpty { args += ["--dns-search", domain] }
            for option in options.dnsOptions where !option.isEmpty { args += ["--dns-option", option] }
        }
        for limit in options.ulimits where !limit.isEmpty { args += ["--ulimit", limit] }
        if options.useInit { args.append("--init") }
        if options.rosetta { args.append("--rosetta") }
        if options.ssh { args.append("--ssh") }
        if options.tty { args.append("--tty") }
        if options.interactive { args.append("--interactive") }
        if let size = CLIText.nonEmpty(options.shmSize) { args += ["--shm-size", size] }
        for socket in options.publishSockets where !socket.isEmpty { args += ["--publish-socket", socket] }
        if let paths = options.maskedPaths {
            args += ["--masked-path", "NONE"]
            for path in paths where !path.isEmpty { args += ["--masked-path", path] }
        }
        if let paths = options.readOnlyPaths {
            args += ["--read-only-path", "NONE"]
            for path in paths where !path.isEmpty { args += ["--read-only-path", path] }
        }
        if let runtime = CLIText.nonEmpty(options.runtime) { args += ["--runtime", runtime] }
        if options.virtualization { args.append("--virtualization") }
        return args
    }

    /// `container create` arguments: like run, without detach and auto remove.
    func createArguments(_ options: RunOptions) -> [String] {
        var copy = options
        copy.detach = false
        var args = runArguments(copy)
        if let first = args.first, first == "run" { args[0] = "create" }
        return args
    }

    /// A command a person can paste into Terminal. Every word is quoted for `sh`.
    func shellCommandLine(_ arguments: [String]) -> String {
        (["container"] + arguments).map(CLIText.shellQuoted).joined(separator: " ")
    }
}

// MARK: - Checks

/// A reason the recreate should not start. Nothing has been changed yet.
public struct RecreateIssue: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case image, name, port, volume, terminal
    }
    public var kind: Kind
    public var message: String

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }
}

public enum RecreateCheck {
    /// Problems with the new settings that would make the new container fail.
    /// `others` are the other containers (the old one is left out by id).
    public static func issues(
        new options: RunOptions, replacing oldID: String, others: [ContainerDetail]
    ) -> [RecreateIssue] {
        var result: [RecreateIssue] = []
        let rest = others.filter { $0.summary.id != oldID }

        if let name = CLIText.nonEmpty(options.name) {
            if !isValidName(name) {
                result.append(RecreateIssue(.name, "The name \(name) can only use letters, numbers, dots, dashes and underscores."))
            } else if rest.contains(where: { $0.summary.id == name }) {
                result.append(RecreateIssue(.name, "Another container is already named \(name)."))
            }
        }

        var seen: [PortMapping] = []
        for port in options.ports {
            if seen.contains(where: { overlaps($0, port) }) {
                result.append(RecreateIssue(.port, "Mac port \(port.hostPort)/\(port.proto) is listed twice."))
            }
            seen.append(port)
            if let owner = rest.first(where: { $0.summary.isRunning && $0.summary.ports.contains { overlaps($0, port) } }) {
                result.append(RecreateIssue(.port, "Mac port \(port.hostPort)/\(port.proto) is used by \(owner.summary.name)."))
            }
        }

        for mount in options.mounts where mount.kind == .volume {
            if let owner = rest.first(where: { detail in
                detail.summary.isRunning && detail.mounts.contains { ($0.type == "volume" || $0.type == "block") && $0.source == mount.source }
            }) {
                result.append(RecreateIssue(.volume, "Volume \(mount.source) is in use by \(owner.summary.name). A volume works with one running container at a time."))
            }
        }

        if options.tty {
            result.append(RecreateIssue(.terminal, "This container uses a terminal (--tty). Recreate it from Terminal."))
        }
        return result
    }

    /// Same Mac port and protocol on addresses that clash.
    public static func overlaps(_ a: PortMapping, _ b: PortMapping) -> Bool {
        guard a.hostPort == b.hostPort, a.proto.lowercased() == b.proto.lowercased() else { return false }
        let all: Set<String> = ["", "0.0.0.0", "::"]
        let left = a.hostAddress ?? ""
        let right = b.hostAddress ?? ""
        return all.contains(left) || all.contains(right) || left == right
    }

    /// Letters, numbers, ".", "-" and "_", starting with a letter or number.
    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, CharacterSet.alphanumerics.contains(first), first.isASCII else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// True when the image is already on this Mac.
    public static func imageIsLocal(_ reference: String, images: [ImageSummary]) -> Bool {
        let wanted = ImageSummary(reference: reference.trimmingCharacters(in: .whitespaces))
        return images.contains { image in
            image.reference == wanted.reference
                || (image.shortName == wanted.shortName && image.tag == wanted.tag)
        }
    }
}

// MARK: - Plan

/// The steps of one Edit and Recreate, and the steps that undo it.
public struct RecreatePlan: Sendable, Hashable {
    public enum Step: Sendable, Hashable {
        case stop(String)
        case delete(String)
        case run(RunOptions)
        case create(RunOptions)
    }

    public var old: RecreateCapture
    public var new: RunOptions

    public init(old: RecreateCapture, new: RunOptions) {
        self.old = old
        var replacement = new
        replacement.detach = true
        self.new = replacement
    }

    /// Stop (when running), delete, then run the new one.
    public var steps: [Step] {
        (old.wasRunning ? [.stop(old.id)] : []) + [.delete(old.id), .run(new)]
    }

    /// Makes the old container again. Started only when it was running.
    public var restoreSteps: [Step] {
        var options = old.options
        options.detach = true
        return [old.wasRunning ? .run(options) : .create(options)]
    }

    public func arguments(_ step: Step, client: ContainerClient) -> [String] {
        switch step {
        case .stop(let id): return ["stop", id]
        case .delete(let id): return ["delete", "--force", id]
        case .run(let options): return client.runArguments(options)
        case .create(let options): return client.createArguments(options)
        }
    }

    /// CLI error text without the "[3/6] Fetching kernel [0s]" progress lines.
    public static func cleanFailure(_ message: String) -> String {
        let lines = message.components(separatedBy: .newlines).filter { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { return false }
            return text.range(of: #"^\[\d+/\d+\]"#, options: .regularExpression) == nil
        }
        let result = lines.joined(separator: "\n")
        return result.isEmpty ? message.trimmingCharacters(in: .whitespacesAndNewlines) : result
    }

    /// The command that brings the old container back by hand.
    public func restoreCommand(client: ContainerClient) -> String {
        restoreSteps.map { client.shellCommandLine(arguments($0, client: client)) }.joined(separator: " && ")
    }
}

/// How a recreate ended.
public enum RecreateOutcome: Sendable, Equatable {
    /// The new container runs.
    case recreated(id: String)
    /// The new one failed. The old one is back (and running when it was).
    case restored(failure: String, running: Bool)
    /// The new one failed and the old one could not be made again.
    /// `command` brings it back by hand.
    case notRestored(failure: String, restoreFailure: String, command: String)
}

// MARK: - Running the plan

public extension ContainerClient {
    /// Reads everything needed to make this container again.
    func captureForRecreate(_ id: String) async throws -> RecreateCapture {
        let detail = try await inspectContainer(id)
        let config = try? await inspectImage(detail.summary.image).config
        let defaults = (try? await systemProperties()).map(RunDefaults.init(properties:)) ?? .builtIn
        let options = RunOptions(recreating: detail, imageConfig: config, defaults: defaults)
        return RecreateCapture(id: detail.summary.id, options: options, wasRunning: detail.summary.isRunning)
    }

    /// Checks the new settings before anything is changed. Pulls the image
    /// when it is not on this Mac yet. Returns the problems found.
    func checkRecreate(_ plan: RecreatePlan, progress: @escaping @Sendable (String) -> Void = { _ in }) async -> [RecreateIssue] {
        var issues: [RecreateIssue] = []
        let all = (try? await listContainers(all: true)) ?? []
        let others = all.filter { $0.id != plan.old.id }
        let details = ((try? await inspectContainers(others.filter(\.isRunning).map(\.id))) ?? [])
        // Stopped ones only matter for the name, which the summary has.
        let stopped = others.filter { !$0.isRunning }.map { ContainerDetail(summary: $0) }
        issues += RecreateCheck.issues(new: plan.new, replacing: plan.old.id, others: details + stopped)

        let image = plan.new.image.trimmingCharacters(in: .whitespaces)
        let images = (try? await listImages()) ?? []
        if !RecreateCheck.imageIsLocal(image, images: images) {
            progress("Getting \(image)…")
            do {
                for try await _ in pullImage(image, platform: plan.new.platform) {}
            } catch {
                issues.append(RecreateIssue(.image, "Could not get the image \(image). \(error.localizedDescription)"))
            }
        }
        return issues
    }

    /// Stops and deletes the old container, then runs the new one. When the
    /// new one fails, the old one is made again. Throws only when the old
    /// container could not be removed, and then nothing was lost.
    func performRecreate(_ plan: RecreatePlan, progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> RecreateOutcome {
        let oldID = plan.old.id
        if plan.old.wasRunning {
            progress("Stopping \(oldID)…")
            try? await stopContainer(oldID)
        }
        progress("Removing \(oldID)…")
        do {
            try await deleteContainer(oldID, force: true)
        } catch {
            if plan.old.wasRunning { try? await startContainer(oldID) }
            throw DeckError.commandFailed("Could not remove \(oldID), so nothing was changed. \(error.localizedDescription)")
        }

        let before = (try? await listContainers(all: true)).map { Set($0.map(\.id)) }
        progress("Starting the new container…")
        do {
            let returned = try await runContainer(plan.new)
            let id = CLIText.nonEmpty(returned) ?? CLIText.nonEmpty(plan.new.name) ?? ""
            return .recreated(id: id)
        } catch {
            let failure = RecreatePlan.cleanFailure(error.localizedDescription)
            progress("Restoring \(oldID)…")
            // A failed run can leave a half made container with the new name.
            if let name = CLIText.nonEmpty(plan.new.name), name == oldID || (before.map { !$0.contains(name) } ?? false) {
                try? await deleteContainer(name, force: true)
            }
            do {
                for step in plan.restoreSteps {
                    try await run(plan.arguments(step, client: self))
                }
                return .restored(failure: failure, running: plan.old.wasRunning)
            } catch {
                return .notRestored(
                    failure: failure,
                    restoreFailure: RecreatePlan.cleanFailure(error.localizedDescription),
                    command: plan.restoreCommand(client: self)
                )
            }
        }
    }
}
