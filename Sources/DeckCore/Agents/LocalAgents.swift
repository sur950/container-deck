import Foundation

// MARK: - Agent tools on this Mac

/// Coding agents we look for. Command line tools by binary name, apps by bundle path.
public enum AgentTool: String, Sendable, Hashable, CaseIterable, Identifiable {
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
public struct AgentToolDetector: Sendable {
    public var home: String
    public var pathEnv: String
    public var applicationFolders: [String]
    let runner: any CommandRunning

    public init(home: String = NSHomeDirectory(), pathEnv: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
                applicationFolders: [String] = ["/Applications", NSHomeDirectory() + "/Applications"],
                runner: any CommandRunning = CancellableRunner()) {
        self.home = home
        self.pathEnv = pathEnv
        self.applicationFolders = applicationFolders
        self.runner = runner
    }

    public var searchFolders: [String] {
        let h = home
        var folders = pathEnv.split(separator: ":").map(String.init)
        folders += ["/opt/homebrew/bin", "/usr/local/bin", "\(h)/.local/bin", "\(h)/.npm-global/bin", "\(h)/.bun/bin",
                    "\(h)/.cargo/bin", "\(h)/.volta/bin", "\(h)/.pyenv/shims", "\(h)/.asdf/shims", "\(h)/.claude/local",
                    "\(h)/.opencode/bin", "\(h)/go/bin", "\(h)/.amp/bin"]
        let nvm = "\(h)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            folders += versions.sorted().reversed().map { "\(nvm)/\($0)/bin" }
        }
        var seen = Set<String>()
        return folders.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    public func locate(_ tool: AgentTool) -> String? {
        let fm = FileManager.default
        for app in tool.appNames {
            for folder in applicationFolders {
                let path = (folder as NSString).appendingPathComponent(app)
                if fm.fileExists(atPath: path) { return path }
            }
        }
        for binary in tool.binaries {
            for folder in searchFolders {
                let path = (folder as NSString).appendingPathComponent(binary)
                if fm.isExecutableFile(atPath: path) { return path }
            }
        }
        return nil
    }

    /// Every tool with path, version (best effort, 5 s limit) and sign in state.
    public func detect(withVersions: Bool = true) async -> [DetectedAgentTool] {
        let signIns = AgentSignInDetector(home: home)
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
    public var home: String

    public init(home: String = NSHomeDirectory()) {
        self.home = home
    }

    private func json(_ relative: String) -> [String: Any]? {
        let path = (home as NSString).appendingPathComponent(relative)
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONCEditor(text: String(decoding: data, as: UTF8.self)).foundationValue() as? [String: Any]
    }

    private func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: (home as NSString).appendingPathComponent(relative))
    }

    public func signIn(for tool: AgentTool) -> String? {
        switch tool {
        case .claude:
            if let account = json(".claude.json")?["oauthAccount"] as? [String: Any] {
                if let email = account["emailAddress"] as? String { return "Claude account \(email)" }
                return "Claude account"
            }
            return nil
        case .codex:
            guard let auth = json(".codex/auth.json") else { return nil }
            if auth["tokens"] is [String: Any] { return "ChatGPT account" }
            if let key = auth["OPENAI_API_KEY"] as? String, !key.isEmpty { return "API key" }
            return nil
        case .gemini:
            if let active = json(".gemini/google_accounts.json")?["active"] as? String, !active.isEmpty {
                return "Google account \(active)"
            }
            return exists(".gemini/oauth_creds.json") ? "Google account" : nil
        case .cursorAgent:
            return exists(".cursor/cli-config.json") ? "Set up" : nil
        default:
            return nil
        }
    }
}

// MARK: - Local models

/// An OpenAI compatible model server on this Mac.
public struct AgentModelEndpoint: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable { case ollama, lmStudio, mlx, other }
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

/// How to start an agent tool against a local model. Plain shell lines, shown before they run.
public enum LocalAgentRecipe {
    public static func supports(_ tool: AgentTool, endpoint: AgentModelEndpoint) -> Bool {
        command(tool, endpoint: endpoint, model: "m") != nil
    }

    public static func command(_ tool: AgentTool, endpoint: AgentModelEndpoint, model: String) -> String? {
        let q = MCPLaunch.shellQuote
        let isOllama = endpoint.kind == .ollama
        switch tool {
        case .aider:
            if isOllama { return "OLLAMA_API_BASE=\(q(endpoint.root)) aider --model \(q("ollama_chat/" + model))" }
            return "OPENAI_API_BASE=\(q(endpoint.baseURL)) OPENAI_API_KEY=local aider --model \(q("openai/" + model))"
        case .codex:
            if isOllama { return "codex --oss -m \(q(model))" }
            return "codex -c model_provider=local -c \(q("model_providers.local={name=\"Local\",base_url=\"\(endpoint.baseURL)\"}")) -m \(q(model))"
        case .goose:
            if isOllama { return "GOOSE_PROVIDER=ollama OLLAMA_HOST=\(q(endpoint.root)) GOOSE_MODEL=\(q(model)) goose session" }
            return "GOOSE_PROVIDER=openai OPENAI_HOST=\(q(endpoint.root)) OPENAI_API_KEY=local GOOSE_MODEL=\(q(model)) goose session"
        case .claude:
            // Ollama serves the Anthropic Messages API too.
            guard isOllama else { return nil }
            return "ANTHROPIC_BASE_URL=\(q(endpoint.root)) ANTHROPIC_AUTH_TOKEN=ollama ANTHROPIC_API_KEY='' claude --model \(q(model))"
        default:
            return nil
        }
    }
}
