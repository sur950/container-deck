import Foundation

/// Everything the create form collects.
public struct SandboxSpec: Sendable, Hashable {
    public var name: String
    public var templateID: String
    public var image: String
    /// Folder on this Mac mounted at /workspace. nil for none.
    public var workspace: String?
    public var workspaceReadOnly: Bool
    public var cpus: Int
    public var memoryMB: Int
    public var egress: SandboxEgress
    /// Normalized allow list entries (only used for `.allowList`).
    public var allowList: [String]
    public var model: SandboxModel?
    /// Extra plain variables (not secrets).
    public var env: [EnvVar]
    /// More mounts, like an agent's cache volume.
    public var extraMounts: [MountSpec]
    /// More labels, like the agent tool and profile.
    public var extraLabels: [String: String]
    /// Makes and mounts the `<name>-chat` volume for chat history. On unless turned off.
    public var saveChatHistory = true

    public init(
        name: String, templateID: String = "alpine", image: String, workspace: String? = nil, workspaceReadOnly: Bool = true,
        cpus: Int = SandboxConfig.defaultCPUs, memoryMB: Int = SandboxConfig.defaultMemoryMB,
        egress: SandboxEgress = .isolated, allowList: [String] = [], model: SandboxModel? = nil, env: [EnvVar] = [],
        extraMounts: [MountSpec] = [], extraLabels: [String: String] = [:]
    ) {
        self.name = name
        self.templateID = templateID
        self.image = image
        self.workspace = workspace
        self.workspaceReadOnly = workspaceReadOnly
        self.cpus = cpus
        self.memoryMB = memoryMB
        self.egress = egress
        self.allowList = allowList
        self.model = model
        self.env = env
        self.extraMounts = extraMounts
        self.extraLabels = extraLabels
    }

    public var networkName: String { name + SandboxConfig.networkSuffix }

    /// Same rule as the container tool for names, kept short so `<name>-net` still fits.
    public static func isValidName(_ name: String) -> Bool {
        name.range(of: "^[a-z0-9](?:[a-z0-9._-]{0,45}[a-z0-9])?$", options: .regularExpression) != nil
    }

    /// The allow list the proxy enforces, with the model host added when the model goes through the proxy.
    public var effectiveAllowList: [String] {
        var list = allowList
        if let model, case .proxy(let host) = SandboxModelRoute.route(for: model.url, egress: egress), !list.contains(host) {
            list.append(host)
        }
        return list
    }
}

/// A sandbox read back from a labelled container.
public struct Sandbox: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var container: ContainerSummary
    public var templateID: String?
    public var egress: SandboxEgress
    public var allowList: [String]
    public var networkName: String
    public var gateway: String?
    public var subnet: String?
    public var workspace: String?
    public var workspaceReadOnly: Bool
    public var model: SandboxModel?
    public var proxyPort: UInt16
    public var relayPort: UInt16
    /// Agent tool the sandbox was made for, by an agent profile.
    public var agentTool: String?
    public var profileID: String?
    /// The chat history volume this sandbox mounts, when it was made with one.
    public var chatVolume: String?
    /// False when it was made with "Save chat history" turned off.
    public var savesChatHistoryByDefault: Bool

    public var isRunning: Bool { container.state == .running }
    public var image: String { container.image }

    public init?(container: ContainerSummary) {
        let labels = container.labels
        guard labels[SandboxConfig.label] != nil else { return nil }
        self.container = container
        name = container.name.isEmpty ? container.id : container.name
        templateID = labels[SandboxConfig.labelTemplate]
        egress = SandboxEgress(rawValue: labels[SandboxConfig.labelEgress] ?? "") ?? .isolated
        allowList = (labels[SandboxConfig.labelAllow] ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        networkName = labels[SandboxConfig.labelNetwork] ?? (name + SandboxConfig.networkSuffix)
        gateway = labels[SandboxConfig.labelGateway].flatMap { $0.isEmpty ? nil : $0 }
        subnet = labels[SandboxConfig.labelSubnet].flatMap { $0.isEmpty ? nil : $0 }
        workspace = labels[SandboxConfig.labelWorkspace].flatMap { $0.isEmpty ? nil : $0 }
        workspaceReadOnly = labels[SandboxConfig.labelWorkspaceMode] != "rw"
        if let kindText = labels[SandboxConfig.labelModelKind], let kind = SandboxModelKind(rawValue: kindText),
           let urlText = labels[SandboxConfig.labelModelURL], let url = URL(string: urlText) {
            let modelName = labels[SandboxConfig.labelModelName].flatMap { $0.isEmpty ? nil : $0 }
            model = SandboxModel(kind: kind, url: url, name: modelName, hasKey: labels[SandboxConfig.labelHasKey] == "1")
        } else {
            model = nil
        }
        proxyPort = labels[SandboxConfig.labelProxyPort].flatMap(UInt16.init) ?? SandboxConfig.proxyPort
        relayPort = labels[SandboxConfig.labelRelayPort].flatMap(UInt16.init) ?? SandboxConfig.relayPort
        agentTool = labels[SandboxConfig.labelAgent].flatMap { $0.isEmpty ? nil : $0 }
        profileID = labels[SandboxConfig.labelProfile].flatMap { $0.isEmpty ? nil : $0 }
        chatVolume = labels[SandboxConfig.labelChatVolume].flatMap { $0.isEmpty ? nil : $0 }
        savesChatHistoryByDefault = labels[SandboxConfig.labelChatHistory] != "off"
    }

    public var template: SandboxTemplate? { SandboxConfig.template(id: templateID) }

    public var modelRoute: SandboxModelRoute? {
        model.map { SandboxModelRoute.route(for: $0.url, egress: egress) }
    }

    /// The model base URL used from inside the container (relay address when relayed).
    public var containerModelURL: URL? {
        guard let model, let route = modelRoute else { return nil }
        return route.containerURL(for: model.url, gateway: gateway ?? "127.0.0.1", relayPort: relayPort)
    }

    /// What the app must run for this sandbox while it is up. nil when nothing is needed.
    public var gatewayPlan: SandboxGatewayPlan? {
        guard let gateway else { return nil }
        var relay: SandboxGateway.Relay?
        if let route = modelRoute, case .relay(let host, let port) = route {
            relay = SandboxGateway.Relay(port: relayPort, targetHost: host, targetPort: port)
        }
        let proxy: UInt16? = egress == .allowList ? proxyPort : nil
        guard proxy != nil || relay != nil else { return nil }
        var always: Set<String> = []
        if relay != nil { always.insert("\(gateway):\(relayPort)") }
        return SandboxGatewayPlan(bindHost: gateway, proxyPort: proxy, relay: relay, allowList: allowList, alwaysAllowed: always)
    }
}

/// The services a running sandbox needs. Equal plans mean nothing to restart.
public struct SandboxGatewayPlan: Sendable, Hashable {
    public var bindHost: String
    public var proxyPort: UInt16?
    public var relay: SandboxGateway.Relay?
    public var allowList: [String]
    public var alwaysAllowed: Set<String>

    public var policy: EgressPolicy { EgressPolicy(entries: allowList, alwaysAllowed: alwaysAllowed) }

    public func makeGateway(onEvent: @escaping @Sendable (SandboxEgressEvent) -> Void) -> SandboxGateway {
        SandboxGateway(bindHost: bindHost, proxyPort: proxyPort, policy: policy, relay: relay, onEvent: onEvent)
    }
}

/// Pure building of network and run arguments for a sandbox.
public enum SandboxPlanner {
    /// Labels for the sandbox network.
    public static func networkLabels(_ spec: SandboxSpec) -> [String: String] {
        [SandboxConfig.label: SandboxConfig.labelVersion, SandboxConfig.labelEgress: spec.egress.rawValue]
    }

    /// `container run` options. `gateway` and `subnet` come from the created network.
    public static func runOptions(_ spec: SandboxSpec, gateway: String, subnet: String?, hasKey: Bool) -> RunOptions {
        var labels: [String: String] = [
            SandboxConfig.label: SandboxConfig.labelVersion,
            SandboxConfig.labelTemplate: spec.templateID,
            SandboxConfig.labelEgress: spec.egress.rawValue,
            SandboxConfig.labelNetwork: spec.networkName,
            SandboxConfig.labelGateway: gateway,
            SandboxConfig.labelProxyPort: String(SandboxConfig.proxyPort),
            SandboxConfig.labelRelayPort: String(SandboxConfig.relayPort),
        ]
        if let subnet { labels[SandboxConfig.labelSubnet] = subnet }
        if spec.egress == .allowList {
            labels[SandboxConfig.labelAllow] = spec.effectiveAllowList.joined(separator: ",")
        }
        var mounts: [MountSpec] = []
        if let workspace = spec.workspace, !workspace.isEmpty {
            labels[SandboxConfig.labelWorkspace] = workspace
            labels[SandboxConfig.labelWorkspaceMode] = spec.workspaceReadOnly ? "ro" : "rw"
            mounts.append(MountSpec(kind: .bind, source: workspace, destination: SandboxConfig.workspacePath, readOnly: spec.workspaceReadOnly))
        }
        if let model = spec.model {
            labels[SandboxConfig.labelModelKind] = model.kind.rawValue
            labels[SandboxConfig.labelModelURL] = model.url.absoluteString
            if let name = model.name, !name.isEmpty { labels[SandboxConfig.labelModelName] = name }
            if hasKey { labels[SandboxConfig.labelHasKey] = "1" }
        }
        // Chat history volume, read write, so the history lives with the sandbox.
        if spec.saveChatHistory {
            let chatVolume = ChatVolumeSync.sandboxVolume(spec.name)
            labels[SandboxConfig.labelChatVolume] = chatVolume
            mounts.append(MountSpec(kind: .volume, source: chatVolume, destination: SandboxConfig.chatPath))
        } else {
            labels[SandboxConfig.labelChatHistory] = "off"
        }
        mounts += spec.extraMounts
        for (key, value) in spec.extraLabels where labels[key] == nil { labels[key] = value }
        return RunOptions(
            image: spec.image,
            name: spec.name,
            command: SandboxConfig.keepAliveArguments,
            entrypoint: SandboxConfig.keepAliveEntrypoint,
            env: environment(spec, gateway: gateway, hasKey: hasKey),
            mounts: mounts,
            cpus: spec.cpus,
            memory: "\(spec.memoryMB)M",
            network: spec.networkName,
            workingDir: spec.workspace == nil ? nil : SandboxConfig.workspacePath,
            labels: labels,
            detach: true,
            tmpfs: [SandboxConfig.secretsPath]
        )
    }

    /// Plain variables for the container. Keys are never here: they go into the tmpfs file.
    public static func environment(_ spec: SandboxSpec, gateway: String, hasKey: Bool) -> [EnvVar] {
        var env: [EnvVar] = []
        let noProxy = "localhost,127.0.0.1,::1,\(gateway)"
        if spec.egress == .allowList {
            let proxy = "http://\(gateway):\(SandboxConfig.proxyPort)"
            for key in ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"] {
                env.append(EnvVar(key: key, value: proxy))
            }
            env.append(EnvVar(key: "NODE_USE_ENV_PROXY", value: "1"))
        }
        if spec.egress != .open {
            env.append(EnvVar(key: "NO_PROXY", value: noProxy))
            env.append(EnvVar(key: "no_proxy", value: noProxy))
        }
        if let model = spec.model {
            let route = SandboxModelRoute.route(for: model.url, egress: spec.egress)
            let url = route.containerURL(for: model.url, gateway: gateway)
            switch model.kind {
            case .openAI:
                env.append(EnvVar(key: "OPENAI_BASE_URL", value: url.absoluteString))
            case .ollama:
                env.append(EnvVar(key: "OLLAMA_HOST", value: rootURL(url)))
                env.append(EnvVar(key: "OPENAI_BASE_URL", value: rootURL(url) + "/v1"))
            }
            if let name = model.name, !name.isEmpty {
                env.append(EnvVar(key: "DECK_MODEL", value: name))
            }
            if hasKey {
                env.append(EnvVar(key: "OPENAI_API_KEY_FILE", value: SandboxConfig.apiKeyFile))
            } else {
                env.append(EnvVar(key: "OPENAI_API_KEY", value: SandboxConfig.localKeyPlaceholder))
            }
        }
        env.append(EnvVar(key: "ENV", value: SandboxConfig.envScript))
        env.append(EnvVar(key: "BASH_ENV", value: SandboxConfig.envScript))
        for extra in spec.env where !extra.key.isEmpty && !env.contains(where: { $0.key == extra.key }) {
            env.append(extra)
        }
        return env
    }

    /// Scheme, host and port only, no trailing slash.
    static func rootURL(_ url: URL) -> String {
        var parts = URLComponents()
        parts.scheme = url.scheme
        parts.host = url.host
        parts.port = url.port
        return parts.string ?? url.absoluteString
    }

    /// Shell script (no secrets) written to the tmpfs. Exports the key from its file.
    public static let envScriptBody = """
    # Written by \(AppConfig.appName). Lives in memory only.
    if [ -r \(SandboxConfig.apiKeyFile) ]; then
      OPENAI_API_KEY="$(cat \(SandboxConfig.apiKeyFile))"
      export OPENAI_API_KEY
    fi

    """

    /// Runs as root inside the container. Reads the key from stdin and writes the tmpfs files.
    /// The key never appears in arguments or on disk.
    public static let secretScript = """
    set -e
    mkdir -p \(SandboxConfig.secretsPath)
    chmod 755 \(SandboxConfig.secretsPath)
    umask 022
    cat > \(SandboxConfig.apiKeyFile).tmp
    mv \(SandboxConfig.apiKeyFile).tmp \(SandboxConfig.apiKeyFile)
    chmod 644 \(SandboxConfig.apiKeyFile)
    """

    /// Writes only the env script (sandboxes without a key).
    public static var envScriptWriter: String {
        "mkdir -p \(SandboxConfig.secretsPath) && cat > \(SandboxConfig.envScript)"
    }

    /// Terminal command: loads the env script, starts in /workspace when there, prefers the template shell.
    public static func shellArguments(_ sandbox: Sandbox) -> [String] {
        let shell = sandbox.template?.shell ?? "/bin/sh"
        let script = "[ -r \(SandboxConfig.envScript) ] && . \(SandboxConfig.envScript); "
            + "cd \(SandboxConfig.workspacePath) 2>/dev/null; "
            + "if [ -x \(shell) ]; then exec \(shell); else exec /bin/sh; fi"
        return ["exec", "--interactive", "--tty", sandbox.container.id, "/bin/sh", "-c", script]
    }

    /// Quotes arguments for a shell command line.
    public static func shellQuote(_ args: [String]) -> String {
        args.map { arg in
            let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./:=,@")
            if !arg.isEmpty && arg.unicodeScalars.allSatisfy({ safe.contains($0) }) { return arg }
            return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }
}
