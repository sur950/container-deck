import Foundation

// MARK: - Agent tools on this Mac

/// Coding agents we look for. Command line tools by binary name, apps by bundle path.
public enum AgentTool: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case claude, codex, gemini, cursorAgent, aider, goose, opencode, crush, amp, qwen
    case claudeDesktop, cursorApp, vscodeApp

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex CLI"
        case .gemini: return "Gemini CLI"
        case .cursorAgent: return "Cursor CLI"
        case .aider: return "Aider"
        case .goose: return "Goose"
        case .opencode: return "opencode"
        case .crush: return "Crush"
        case .amp: return "Amp"
        case .qwen: return "Qwen Code"
        case .claudeDesktop: return "Claude Desktop"
        case .cursorApp: return "Cursor"
        case .vscodeApp: return "VS Code"
        }
    }

    public var binaries: [String] {
        switch self {
        case .claude: return ["claude"]
        case .codex: return ["codex"]
        case .gemini: return ["gemini"]
        case .cursorAgent: return ["cursor-agent"]
        case .aider: return ["aider"]
        case .goose: return ["goose"]
        case .opencode: return ["opencode"]
        case .crush: return ["crush"]
        case .amp: return ["amp"]
        case .qwen: return ["qwen"]
        case .claudeDesktop, .cursorApp, .vscodeApp: return []
        }
    }

    public var appNames: [String] {
        switch self {
        case .claudeDesktop: return ["Claude.app"]
        case .cursorApp: return ["Cursor.app"]
        case .vscodeApp: return ["Visual Studio Code.app", "Visual Studio Code - Insiders.app"]
        default: return []
        }
    }

    public var isApp: Bool { !appNames.isEmpty }

    /// Agent config this tool reads MCP servers from, when we can write it.
    public var configAgent: AgentKind? {
        switch self {
        case .claude: return .claudeCode
        case .codex: return .codex
        case .gemini: return .gemini
        case .cursorAgent, .cursorApp: return .cursor
        case .claudeDesktop: return .claudeDesktop
        case .vscodeApp: return .vscode
        default: return nil
        }
    }

    /// Hosted provider the tool uses by default.
    public var provider: HostedProvider? {
        switch self {
        case .claude, .claudeDesktop: return .anthropic
        case .codex: return .openai
        case .gemini: return .gemini
        default: return nil
        }
    }

    public var installCommand: String? {
        switch self {
        case .claude: return "npm install -g @anthropic-ai/claude-code"
        case .codex: return "npm install -g @openai/codex"
        case .gemini: return "npm install -g @google/gemini-cli"
        case .cursorAgent: return "curl https://cursor.com/install -fsS | bash"
        case .aider: return "python3 -m pip install aider-install && aider-install"
        case .goose: return "brew install block-goose-cli"
        case .opencode: return "brew install sst/tap/opencode"
        case .crush: return "brew install charmbracelet/tap/crush"
        case .amp: return "npm install -g @sourcegraph/amp"
        case .qwen: return "npm install -g @qwen-code/qwen-code"
        default: return nil
        }
    }
}

/// One tool found on this Mac.
public struct DetectedAgentTool: Sendable, Hashable, Identifiable {
    public var tool: AgentTool
    public var path: String?
    public var version: String?
    public var signIn: String?
    public var id: String { tool.rawValue }
    public var installed: Bool { path != nil }
}

/// Finds agent tools. GUI apps do not get the shell PATH, so common install folders are searched.
/// Paths come from `AgentPathResolver` (Settings overrides first).
public struct AgentToolDetector: Sendable {
    public var resolver: AgentPathResolver
    let runner: any CommandRunning

    public init(resolver: AgentPathResolver = .standard(), runner: any CommandRunning = CancellableRunner()) {
        self.resolver = resolver
        self.runner = runner
    }

    /// Tests: a home folder, a PATH and app folders, no shared install folders.
    public init(home: String, pathEnv: String, applicationFolders: [String], runner: any CommandRunning = CancellableRunner()) {
        self.init(resolver: AgentPathResolver(home: home, environment: ["PATH": pathEnv], applicationFolders: applicationFolders, systemFolders: []),
                  runner: runner)
    }

    public var home: String { resolver.home }

    public var searchFolders: [String] { resolver.searchFolders }

    public func locate(_ tool: AgentTool) -> String? {
        let found = resolver.executable(tool)
        return found.exists ? found.path : nil
    }

    /// Every tool with path, version (best effort, 5 s limit) and sign in state.
    public func detect(withVersions: Bool = true) async -> [DetectedAgentTool] {
        let signIns = AgentSignInDetector(resolver: resolver)
        return await withTaskGroup(of: DetectedAgentTool.self) { group in
            for tool in AgentTool.allCases {
                group.addTask {
                    let path = locate(tool)
                    var version: String?
                    if withVersions, let path, !tool.isApp {
                        version = await self.version(path)
                    }
                    return DetectedAgentTool(tool: tool, path: path, version: version, signIn: path == nil ? nil : signIns.signIn(for: tool))
                }
            }
            var found: [DetectedAgentTool] = []
            for await item in group { found.append(item) }
            return found.sorted { AgentTool.allCases.firstIndex(of: $0.tool)! < AgentTool.allCases.firstIndex(of: $1.tool)! }
        }
    }

    func version(_ path: String) async -> String? {
        let runner = self.runner
        let task = Task { try await runner.run(path, ["--version"]) }
        let timeout = Task {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            task.cancel()
        }
        defer { timeout.cancel() }
        guard let result = try? await task.value, result.succeeded else { return nil }
        let line = (result.stdout + "\n" + result.stderr).split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let line else { return nil }
        if let version = SemanticVersion.firstMatch(in: String(line)) {
            return "\(version.major).\(version.minor).\(version.patch)"
        }
        return String(line.prefix(30))
    }
}

/// Reads whether an agent is signed in, from files it keeps. Only presence is checked,
/// tokens are never read into the app. The Claude account email is shown when present.
public struct AgentSignInDetector: Sendable {
    public var resolver: AgentPathResolver

    public init(home: String = NSHomeDirectory()) {
        self.init(resolver: AgentPathResolver(home: home, environment: [:]))
    }

    public init(resolver: AgentPathResolver) {
        self.resolver = resolver
    }

    private func json(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONCEditor(text: String(decoding: data, as: UTF8.self)).foundationValue() as? [String: Any]
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    private func inside(_ base: ResolvedAgentPath, _ name: String) -> String {
        ((base.path ?? resolver.home) as NSString).appendingPathComponent(name)
    }

    public func signIn(for tool: AgentTool) -> String? {
        switch tool {
        case .claude:
            if let account = json(resolver.locations.claudeJSON)?["oauthAccount"] as? [String: Any] {
                if let email = account["emailAddress"] as? String { return "Claude account \(email)" }
                return "Claude account"
            }
            return nil
        case .codex:
            guard let auth = json(inside(resolver.codexHome, "auth.json")) else { return nil }
            if auth["tokens"] is [String: Any] { return "ChatGPT account" }
            if let key = auth["OPENAI_API_KEY"] as? String, !key.isEmpty { return "API key" }
            return nil
        case .gemini:
            if let active = json(inside(resolver.geminiHome, "google_accounts.json"))?["active"] as? String, !active.isEmpty {
                return "Google account \(active)"
            }
            return exists(inside(resolver.geminiHome, "oauth_creds.json")) ? "Google account" : nil
        case .cursorAgent:
            return exists((resolver.home as NSString).appendingPathComponent(".cursor/cli-config.json")) ? "Set up" : nil
        default:
            return nil
        }
    }
}

// MARK: - Local models

/// An OpenAI compatible model server on this Mac.
public struct AgentModelEndpoint: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable, Codable { case ollama, lmStudio, mlx, other }
    public var name: String
    public var kind: Kind
    /// Base URL ending in /v1.
    public var baseURL: String
    public var models: [String]
    public var id: String { baseURL }

    public init(name: String, kind: Kind, baseURL: String, models: [String]) {
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.models = models
    }

    /// Host and port without the /v1 path.
    public var root: String {
        baseURL.hasSuffix("/v1") ? String(baseURL.dropLast(3)) : baseURL
    }
}

/// Source of local model endpoints. The Local AI area provides the real list.
/// `ProbingModelEndpointSource` is a small fallback that checks the usual ports.
public protocol AgentModelEndpointSource: Sendable {
    func endpoints() async -> [AgentModelEndpoint]
}

public struct ProbingModelEndpointSource: AgentModelEndpointSource {
    public struct Probe: Sendable {
        public var name: String
        public var kind: AgentModelEndpoint.Kind
        public var port: Int
    }

    public var probes: [Probe]
    let session: URLSession

    public init(probes: [Probe]? = nil, session: URLSession? = nil) {
        self.probes = probes ?? [
            Probe(name: "Ollama", kind: .ollama, port: 11434),
            Probe(name: "LM Studio", kind: .lmStudio, port: 1234),
            Probe(name: "MLX server", kind: .mlx, port: 8080),
        ]
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 2
            config.timeoutIntervalForResource = 3
            self.session = URLSession(configuration: config)
        }
    }

    public func endpoints() async -> [AgentModelEndpoint] {
        await withTaskGroup(of: AgentModelEndpoint?.self) { group in
            for probe in probes {
                group.addTask { await self.check(probe) }
            }
            var found: [AgentModelEndpoint] = []
            for await item in group { if let item { found.append(item) } }
            return found.sorted { $0.name < $1.name }
        }
    }

    func check(_ probe: Probe) async -> AgentModelEndpoint? {
        let base = "http://127.0.0.1:\(probe.port)/v1"
        guard let url = URL(string: base + "/models"),
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let models = Self.modelIDs(data)
        return AgentModelEndpoint(name: probe.name, kind: probe.kind, baseURL: base, models: models)
    }

    /// ids from an OpenAI style `{"data": [{"id": ...}]}` list.
    public static func modelIDs(_ data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["data"] as? [[String: Any]] else { return [] }
        return items.compactMap { $0["id"] as? String }.sorted()
    }
}

/// Variables and arguments for one agent run, without the program itself.
public struct AgentCommandParts: Sendable, Hashable {
    public var env: [EnvVar]
    public var args: [String]

    public init(env: [EnvVar] = [], args: [String] = []) {
        self.env = env
        self.args = args
    }

    /// `KEY=value ... program args`, quoted for a shell.
    public func commandLine(program: String) -> String {
        let q = MCPLaunch.shellQuote
        let vars = env.map { "\($0.key)=\(q($0.value))" }
        return (vars + [q(program)] + args.map(q)).joined(separator: " ")
    }
}

/// How to start an agent tool against a local model. Plain shell lines, shown before they run.
public enum LocalAgentRecipe {
    public static func supports(_ tool: AgentTool, endpoint: AgentModelEndpoint) -> Bool {
        parts(tool, endpoint: endpoint, model: "m") != nil
    }

    public static func supports(_ tool: AgentTool, kind: AgentModelEndpoint.Kind) -> Bool {
        supports(tool, endpoint: AgentModelEndpoint(name: "", kind: kind, baseURL: "http://127.0.0.1:1/v1", models: []))
    }

    public static func command(_ tool: AgentTool, endpoint: AgentModelEndpoint, model: String) -> String? {
        guard let parts = parts(tool, endpoint: endpoint, model: model), let binary = tool.binaries.first else { return nil }
        return parts.commandLine(program: binary)
    }

    /// The same settings as `command`, split into variables and arguments.
    public static func parts(_ tool: AgentTool, endpoint: AgentModelEndpoint, model: String) -> AgentCommandParts? {
        let isOllama = endpoint.kind == .ollama
        switch tool {
        case .aider:
            if isOllama { return AgentCommandParts(env: [EnvVar(key: "OLLAMA_API_BASE", value: endpoint.root)], args: ["--model", "ollama_chat/" + model]) }
            return AgentCommandParts(env: [EnvVar(key: "OPENAI_API_BASE", value: endpoint.baseURL), EnvVar(key: "OPENAI_API_KEY", value: "local")],
                                     args: ["--model", "openai/" + model])
        case .codex:
            if isOllama { return AgentCommandParts(args: ["--oss", "-m", model]) }
            return AgentCommandParts(args: ["-c", "model_provider=local", "-c",
                                            "model_providers.local={name=\"Local\",base_url=\"\(endpoint.baseURL)\"}", "-m", model])
        case .goose:
            if isOllama {
                return AgentCommandParts(env: [EnvVar(key: "GOOSE_PROVIDER", value: "ollama"), EnvVar(key: "OLLAMA_HOST", value: endpoint.root),
                                               EnvVar(key: "GOOSE_MODEL", value: model)], args: ["session"])
            }
            return AgentCommandParts(env: [EnvVar(key: "GOOSE_PROVIDER", value: "openai"), EnvVar(key: "OPENAI_HOST", value: endpoint.root),
                                           EnvVar(key: "OPENAI_API_KEY", value: "local"), EnvVar(key: "GOOSE_MODEL", value: model)],
                                     args: ["session"])
        case .claude:
            // Ollama serves the Anthropic Messages API too.
            guard isOllama else { return nil }
            return AgentCommandParts(env: [EnvVar(key: "ANTHROPIC_BASE_URL", value: endpoint.root), EnvVar(key: "ANTHROPIC_AUTH_TOKEN", value: "ollama"),
                                           EnvVar(key: "ANTHROPIC_API_KEY", value: "")], args: ["--model", model])
        default:
            return nil
        }
    }
}
