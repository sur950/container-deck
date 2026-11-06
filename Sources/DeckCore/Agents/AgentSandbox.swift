import Foundation

/// Running an agent profile in a sandbox: which image, how the CLI gets installed, which hosts
/// the allow list opens, and the `container exec` line the terminal runs.
///
/// The CLI is installed on first start (npm or pip) into a named volume per tool mounted at
/// `/deck`, so later runs and new sandboxes for the same tool start at once. `HOME` lives in the
/// same volume, so an agent's own sign in inside the sandbox is kept too. Provider keys are never
/// written into the container or its labels: the terminal reads them from the Keychain and hands
/// them to `container exec --env NAME`, which takes the value from its own environment.
public enum AgentSandboxRecipe {
    public enum Installer: Sendable, Equatable {
        case npm(String)
        case pip(String)
    }

    public static let cachePath = "/deck"
    public static let homePath = "/deck/home"
    public static let npmPrefix = "/deck/tools"
    public static let venvPath = "/deck/venv"
    public static let namePrefix = "deck-agent-"
    public static let npmHosts = ["registry.npmjs.org"]
    public static let pipHosts = ["pypi.org", "files.pythonhosted.org"]

    public static func installer(_ tool: AgentTool) -> Installer? {
        switch tool {
        case .claude: return .npm("@anthropic-ai/claude-code")
        case .codex: return .npm("@openai/codex")
        case .gemini: return .npm("@google/gemini-cli")
        case .qwen: return .npm("@qwen-code/qwen-code")
        case .amp: return .npm("@sourcegraph/amp")
        case .opencode: return .npm("opencode-ai")
        case .aider: return .pip("aider-chat")
        default: return nil
        }
    }

    public static func supports(_ tool: AgentTool) -> Bool { installer(tool) != nil }

    public static func template(for tool: AgentTool) -> SandboxTemplate? {
        guard let installer = installer(tool) else { return nil }
        if case .pip = installer { return SandboxConfig.template(id: "agent-python") }
        return SandboxConfig.template(id: "agent-node")
    }

    /// Named volume with the installed CLI and the sandbox home folder for one tool.
    public static func cacheVolume(_ tool: AgentTool) -> String {
        "deck-agent-cache-" + tool.rawValue.lowercased()
    }

    /// `deck-agent-<profile name>`, valid as a sandbox name.
    public static func sandboxName(for profile: AgentProfile) -> String {
        let slug = MCPLaunch.suggestedName(profile.name).replacingOccurrences(of: "_", with: "-")
        let base = slug.isEmpty ? profile.id.uuidString.prefix(8).lowercased() : slug
        var name = namePrefix + String(base.prefix(46 - namePrefix.count))
        while name.hasSuffix("-") || name.hasSuffix(".") { name.removeLast() }
        return SandboxSpec.isValidName(name) ? name : namePrefix + profile.id.uuidString.prefix(8).lowercased()
    }

    // MARK: Allow list

    /// Hosts the agent itself talks to, for this model choice. Empty for local models (the relay handles them).
    public static func providerHosts(_ tool: AgentTool, model: AgentModelChoice) -> [String] {
        switch model {
        case .local: return []
        case .providerKey(let provider): return hosts(provider)
        case .account:
            switch tool {
            case .claude: return ["*.anthropic.com", "*.claude.ai", "*.claude.com"]
            case .codex: return ["*.openai.com", "*.chatgpt.com"]
            case .gemini: return ["generativelanguage.googleapis.com", "cloudcode-pa.googleapis.com", "oauth2.googleapis.com",
                                  "www.googleapis.com", "accounts.google.com"]
            case .qwen: return ["*.qwen.ai", "*.aliyuncs.com"]
            case .amp: return ["*.ampcode.com"]
            case .opencode: return ["*.opencode.ai"]
            default: return []
            }
        }
    }

    static func hosts(_ provider: HostedProvider) -> [String] {
        switch provider {
        case .anthropic: return ["api.anthropic.com"]
        case .openai: return ["api.openai.com"]
        case .gemini: return ["generativelanguage.googleapis.com"]
        }
    }

    public static func packageHosts(_ tool: AgentTool) -> [String] {
        switch installer(tool) {
        case .npm: return npmHosts
        case .pip: return pipHosts
        case nil: return []
        }
    }

    /// The default allow list: what the agent needs plus the package registry for the install.
    public static func defaultAllowList(_ tool: AgentTool, model: AgentModelChoice) -> [String] {
        var seen = Set<String>()
        return (providerHosts(tool, model: model) + packageHosts(tool)).filter { seen.insert($0).inserted }
    }

    // MARK: Spec

    public static func spec(for profile: AgentProfile) throws -> SandboxSpec {
        guard let template = template(for: profile.tool) else { throw AgentLaunchError.sandboxNotSupported(profile.tool.title) }
        var model: SandboxModel?
        if case .local(let local) = profile.model {
            let endpoint = local.endpoint
            let text = local.kind == .ollama ? endpoint.root : endpoint.baseURL
            guard let url = URL(string: text) else { throw AgentLaunchError.noModel(profile.tool.title) }
            model = SandboxModel(kind: local.kind == .ollama ? .ollama : .openAI, url: url, name: local.model)
        }
        let options = profile.sandbox
        var allow = defaultAllowList(profile.tool, model: profile.model)
        for host in options.extraHosts.compactMap(EgressPolicy.normalize) where !allow.contains(host) { allow.append(host) }
        let workspace = (profile.workspace ?? "").isEmpty ? nil : profile.workspace
        return SandboxSpec(
            name: sandboxName(for: profile), templateID: template.id, image: template.image,
            workspace: workspace, workspaceReadOnly: options.workspaceReadOnly,
            cpus: options.cpus, memoryMB: options.memoryMB, egress: options.egressMode,
            allowList: options.egressMode == .allowList ? allow : [], model: model,
            extraMounts: [MountSpec(kind: .volume, source: cacheVolume(profile.tool), destination: cachePath)],
            extraLabels: [SandboxConfig.labelAgent: profile.tool.rawValue, SandboxConfig.labelProfile: profile.id.uuidString.lowercased()]
        )
    }

    // MARK: Reuse

    public enum Action: String, Sendable, Equatable {
        /// No sandbox yet.
        case create
        /// Same settings, stopped.
        case start
        /// Same settings, running.
        case reuse
        /// Settings changed. Remove and create again (the cache volume stays).
        case recreate
    }

    public static func action(existing: Sandbox?, spec: SandboxSpec) -> Action {
        guard let existing else { return .create }
        let workspaceSame = existing.workspace == spec.workspace && (spec.workspace == nil || existing.workspaceReadOnly == spec.workspaceReadOnly)
        let allowSame = spec.egress != .allowList || Set(existing.allowList) == Set(spec.effectiveAllowList)
        let modelSame = existing.model?.url == spec.model?.url && existing.model?.kind == spec.model?.kind && existing.model?.name == spec.model?.name
        let same = normalizedImage(existing.image) == normalizedImage(spec.image) && workspaceSame && existing.egress == spec.egress
            && allowSame && modelSame && existing.agentTool == spec.extraLabels[SandboxConfig.labelAgent]
        guard same else { return .recreate }
        return existing.isRunning ? .reuse : .start
    }

    static func normalizedImage(_ image: String) -> String {
        var name = image.trimmingCharacters(in: .whitespaces)
        for prefix in ["docker.io/library/", "docker.io/", "index.docker.io/library/"] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
        }
        if !name.contains(":") && !name.contains("@") { name += ":latest" }
        return name
    }

    // MARK: Exec

    /// Runs inside the container: loads the sandbox env, installs the CLI the first time, then starts it.
    public static func bootstrapScript(_ tool: AgentTool) -> String {
        guard let binary = tool.binaries.first, let installer = installer(tool) else { return "exec \"$@\"" }
        let install: String
        switch installer {
        case .npm(let package):
            install = "npm install -g --prefix \(npmPrefix) --no-fund --no-audit --loglevel=error \(package)"
        case .pip(let package):
            install = "{ [ -x \(venvPath)/bin/pip ] || python3 -m venv \(venvPath); } && \(venvPath)/bin/pip install --quiet --disable-pip-version-check \(package)"
        }
        return """
        [ -r \(SandboxConfig.envScript) ] && . \(SandboxConfig.envScript)
        export HOME=\(homePath)
        export PATH="\(npmPrefix)/bin:\(venvPath)/bin:$PATH"
        mkdir -p "$HOME" \(npmPrefix)
        if ! command -v \(binary) >/dev/null 2>&1; then
          echo "Installing \(tool.title) in the sandbox. Only the first run does this."
          \(install) || { echo "The install failed. Check the allow list on the sandbox's Egress tab."; exit 1; }
        fi
        cd \(SandboxConfig.workspacePath) 2>/dev/null || cd "$HOME"
        exec "$@"
        """
    }

    /// Model variables and arguments as seen from inside the sandbox (local models go through the relay).
    public static func modelParts(_ profile: AgentProfile, sandbox: Sandbox) throws -> AgentCommandParts {
        guard case .local(let local) = profile.model else { return try AgentLauncher.modelParts(profile.tool, model: profile.model) }
        guard let url = sandbox.containerModelURL else { throw AgentLaunchError.noModel(profile.tool.title) }
        var text = url.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        let base = local.kind == .ollama ? text + "/v1" : text
        // `codex --oss` looks at localhost, so a relayed Ollama uses the plain OpenAI style provider.
        let kind: AgentModelEndpoint.Kind = profile.tool == .codex && local.kind == .ollama ? .other : local.kind
        let endpoint = AgentModelEndpoint(name: local.server, kind: kind, baseURL: base, models: [local.model])
        guard let parts = LocalAgentRecipe.parts(profile.tool, endpoint: endpoint, model: local.model) else {
            throw AgentLaunchError.noModel(profile.tool.title)
        }
        return parts
    }

    /// `container exec` arguments. `secretKeys` are passed by name only, the value comes from the environment.
    public static func execArguments(container: String, tool: AgentTool, parts: AgentCommandParts, secretKeys: [String]) -> [String] {
        var args = ["exec", "--interactive", "--tty"]
        for env in parts.env { args += ["--env", "\(env.key)=\(env.value)"] }
        for key in secretKeys { args += ["--env", key] }
        args += [container, "/bin/sh", "-c", bootstrapScript(tool), "deck-agent"]
        args += [tool.binaries.first ?? tool.rawValue] + parts.args
        return args
    }

    /// The terminal command for a profile in its sandbox.
    public static func terminalCommand(_ profile: AgentProfile, sandbox: Sandbox, cliPath: String) throws -> String {
        let parts = try modelParts(profile, sandbox: sandbox)
        var lines: [String] = []
        var secrets: [String] = []
        if let provider = profile.model.provider {
            guard AgentLauncher.providers(for: profile.tool).contains(provider) else {
                throw AgentLaunchError.providerNotSupported(profile.tool.title, provider.title)
            }
            lines.append(AgentLauncher.keyExport(provider))
            secrets.append(provider.environmentVariable)
        }
        lines.append(SandboxPlanner.shellQuote([cliPath] + execArguments(container: sandbox.container.id, tool: profile.tool,
                                                                         parts: parts, secretKeys: secrets)))
        return lines.joined(separator: "\n")
    }
}

/// Steps of starting a profile in a sandbox, for the launch sheet.
public enum AgentSandboxStep: String, Sendable, CaseIterable {
    case volume = "Preparing the tool cache"
    case sandbox = "Creating the sandbox"
    case starting = "Starting the sandbox"
    case network = "Starting the network guard"
    case terminal = "Opening the terminal"
}

public extension ContainerClient {
    /// Creates an agent tool's cache volume when it is missing.
    func ensureAgentCacheVolume(_ name: String, labels: [String: String] = [:]) async throws {
        if try await listVolumes().contains(where: { $0.name == name }) { return }
        try await createVolume(name: name, labels: labels)
    }
}
