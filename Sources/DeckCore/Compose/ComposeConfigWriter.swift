import Foundation
import Yams

/// Writes a parsed project back out as YAML, with variables filled in, paths made
/// absolute and the names Up would use. Used by `container compose config`.
public enum ComposeConfigWriter {

    public static func yaml(_ project: ComposeProject) -> String {
        var root: [(Node, Node)] = [(key("name"), str(project.name))]
        var services: [(Node, Node)] = []
        for service in project.services {
            services.append((key(service.name), serviceNode(service, project: project)))
        }
        root.append((key("services"), .mapping(Node.Mapping(services))))

        let networkKeys = Set(project.services.flatMap { $0.networks.isEmpty ? ["default"] : [$0.networks[0]] })
        var networks: [(Node, Node)] = []
        for key in networkKeys.sorted() {
            let plan = ComposePlanner.networkPlan(project, key: key)
            var fields: [(Node, Node)] = [(self.key("name"), str(plan.name))]
            if plan.external { fields.append((self.key("external"), bool(true))) }
            if plan.isInternal { fields.append((self.key("internal"), bool(true))) }
            if let subnet = plan.subnet {
                let config: Node = .sequence(Node.Sequence([.mapping(Node.Mapping([(self.key("subnet"), str(subnet))]))]))
                fields.append((self.key("ipam"), .mapping(Node.Mapping([(self.key("config"), config)]))))
            }
            networks.append((self.key(key), .mapping(Node.Mapping(fields))))
        }
        if !networks.isEmpty { root.append((key("networks"), .mapping(Node.Mapping(networks)))) }

        var volumes: [(Node, Node)] = []
        for definition in project.volumes {
            let plan = ComposePlanner.volumePlan(project, key: definition.key)
            var fields: [(Node, Node)] = [(key("name"), str(plan.name))]
            if plan.external { fields.append((key("external"), bool(true))) }
            let labels = definition.labels
            if !labels.isEmpty { fields.append((key("labels"), stringMap(labels))) }
            volumes.append((key(definition.key), .mapping(Node.Mapping(fields))))
        }
        if !volumes.isEmpty { root.append((key("volumes"), .mapping(Node.Mapping(volumes)))) }

        let text = (try? Yams.serialize(node: .mapping(Node.Mapping(root)), indent: 2, width: -1)) ?? ""
        return text.hasSuffix("\n") ? text : text + "\n"
    }

    private static func serviceNode(_ s: ComposeService, project: ComposeProject) -> Node {
        var f: [(Node, Node)] = []
        func add(_ name: String, _ node: Node?) { if let node { f.append((key(name), node)) } }
        func addList(_ name: String, _ values: [String]) { if !values.isEmpty { add(name, list(values)) } }

        if let build = s.build {
            var b: [(Node, Node)] = [(key("context"), str(build.context))]
            if let dockerfile = build.dockerfile { b.append((key("dockerfile"), str(dockerfile))) }
            if !build.args.isEmpty { b.append((key("args"), envMap(build.args))) }
            if let target = build.target { b.append((key("target"), str(target))) }
            add("build", .mapping(Node.Mapping(b)))
        }
        add("image", str(s.image ?? ComposePlanner.builtImageName(project: project.name, service: s.name)))
        add("container_name", str(s.containerName ?? ComposePlanner.defaultContainerName(project: project.name, service: s.name)))
        if let entrypoint = s.entrypoint { add("entrypoint", list(entrypoint)) }
        if let command = s.command { add("command", list(command)) }
        if let dir = s.workingDir { add("working_dir", str(dir)) }
        if let user = s.user { add("user", str(user)) }
        if !s.environment.isEmpty { add("environment", envMap(s.environment)) }
        addList("ports", s.ports.map { ($0.hostIP.map { "\($0):" } ?? "") + "\($0.published ?? $0.target):\($0.target)/\($0.proto)" })
        let mounts = s.volumes.filter { $0.kind != .tmpfs }.map { mount -> Node in
            let ro = mount.readOnly ? ":ro" : ""
            switch mount.kind {
            case .anonymous:
                // Long form keeps it anonymous and shows the volume name Up uses.
                var fields: [(Node, Node)] = [(key("type"), str("volume")), (key("target"), str(mount.target))]
                if mount.readOnly { fields.append((key("read_only"), bool(true))) }
                let name = ComposePlanner.anonymousVolumeName(project: project.name, service: s.name, target: mount.target)
                fields.append((key("x-volume-name"), str(name)))
                return .mapping(Node.Mapping(fields))
            default:
                return str("\(mount.source):\(mount.target)\(ro)")
            }
        }
        if !mounts.isEmpty { add("volumes", .sequence(Node.Sequence(mounts))) }
        let tmpfs = s.tmpfs + s.volumes.filter { $0.kind == .tmpfs }.map { $0.source.isEmpty ? $0.target : "\($0.target):\($0.source)" }
        addList("tmpfs", tmpfs)
        addList("networks", s.networks)
        if !s.networkAliases.isEmpty { add("x-network-aliases", list(s.networkAliases)) }
        if !s.dependsOn.isEmpty {
            var deps: [(Node, Node)] = []
            for dependency in s.dependsOn {
                deps.append((key(dependency.service), .mapping(Node.Mapping([
                    (key("condition"), str(dependency.condition.rawValue)),
                    (key("required"), bool(dependency.required))
                ]))))
            }
            add("depends_on", .mapping(Node.Mapping(deps)))
        }
        if let check = s.healthcheck {
            if check.isDisabled {
                add("healthcheck", .mapping(Node.Mapping([(key("disable"), bool(true))])))
            } else {
                add("healthcheck", .mapping(Node.Mapping([
                    (key("test"), list(["CMD"] + check.command)),
                    (key("interval"), str(seconds(check.interval))),
                    (key("timeout"), str(seconds(check.timeout))),
                    (key("retries"), str(String(check.retries))),
                    (key("start_period"), str(seconds(check.startPeriod)))
                ])))
            }
        }
        addList("profiles", s.profiles)
        if !s.labels.isEmpty { add("labels", stringMap(s.labels)) }
        if let cpus = s.cpus { add("cpus", str(String(cpus))) }
        if let memory = s.memory { add("mem_limit", str(memory)) }
        if let platform = s.platform { add("platform", str(platform)) }
        if s.readOnly { add("read_only", bool(true)) }
        if s.initProcess { add("init", bool(true)) }
        addList("cap_add", s.capAdd)
        addList("cap_drop", s.capDrop)
        addList("dns", s.dns)
        addList("dns_search", s.dnsSearch)
        addList("dns_opt", s.dnsOptions)
        if let shm = s.shmSize { add("shm_size", str(shm)) }
        addList("ulimits", s.ulimits)
        if let mac = s.macAddress { add("mac_address", str(mac)) }
        if let signal = s.stopSignal { add("stop_signal", str(signal)) }
        if let grace = s.stopGracePeriod { add("stop_grace_period", str(seconds(grace))) }
        if let policy = s.pullPolicy { add("pull_policy", str(policy.rawValue)) }
        addList("extra_hosts", s.extraHosts.map { line -> String in
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            return parts.count == 2 ? "\(parts[1]):\(parts[0])" : line
        })
        if !s.postStart.isEmpty { add("post_start", hooks(s.postStart)) }
        if !s.preStop.isEmpty { add("pre_stop", hooks(s.preStop)) }
        return .mapping(Node.Mapping(f))
    }

    private static func hooks(_ hooks: [ComposeHook]) -> Node {
        .sequence(Node.Sequence(hooks.map { hook -> Node in
            var fields: [(Node, Node)] = [(key("command"), list(hook.command))]
            if let user = hook.user { fields.append((key("user"), str(user))) }
            if let dir = hook.workingDir { fields.append((key("working_dir"), str(dir))) }
            if !hook.environment.isEmpty { fields.append((key("environment"), envMap(hook.environment))) }
            return .mapping(Node.Mapping(fields))
        }))
    }

    // MARK: Nodes

    private static func key(_ text: String) -> Node { str(text) }

    private static func bool(_ value: Bool) -> Node {
        Node(value ? "true" : "false", Tag(.bool), .plain)
    }

    private static func list(_ values: [String]) -> Node {
        .sequence(Node.Sequence(values.map(str)))
    }

    private static func envMap(_ vars: [EnvVar]) -> Node {
        .mapping(Node.Mapping(vars.map { (str($0.key), str($0.value)) }))
    }

    private static func stringMap(_ map: [String: String]) -> Node {
        .mapping(Node.Mapping(map.sorted { $0.key < $1.key }.map { (str($0.key), str($0.value)) }))
    }

    /// Plain when safe, double quoted when YAML would read it as something else.
    static func str(_ text: String) -> Node {
        Node(text, Tag(.str), needsQuotes(text) ? .doubleQuoted : .plain)
    }

    static func needsQuotes(_ text: String) -> Bool {
        if text.isEmpty { return true }
        let lower = text.lowercased()
        if ["true", "false", "yes", "no", "on", "off", "y", "n", "null", "~"].contains(lower) { return true }
        if Double(text) != nil || Int(text) != nil { return true }
        if text.range(of: #"^[A-Za-z0-9_./@+-][A-Za-z0-9 _./@=+,-]*$"#, options: .regularExpression) == nil { return true }
        if text.hasSuffix(" ") || text.hasPrefix("-") { return true }
        return false
    }

    private static func seconds(_ value: TimeInterval) -> String {
        value == value.rounded() ? "\(Int(value))s" : "\(Int((value * 1000).rounded()))ms"
    }
}
