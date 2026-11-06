import Foundation

// MARK: - Overrides (Settings, Agents)

/// Paths a person set for one agent tool in Settings. nil or empty means "detect".
public struct AgentPathOverride: Sendable, Hashable, Codable {
    public var executable: String?
    public var config: String?
    public var sessions: String?

    public init(executable: String? = nil, config: String? = nil, sessions: String? = nil) {
        self.executable = executable
        self.config = config
        self.sessions = sessions
    }

    public var isEmpty: Bool {
        [executable, config, sessions].allSatisfy { ($0 ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

/// Every override, keyed by tool. Saved in UserDefaults as JSON under `AgentsConfig.pathOverridesKey`.
public struct AgentPathOverrides: Sendable, Hashable, Codable {
    public var tools: [String: AgentPathOverride]

    public init(tools: [String: AgentPathOverride] = [:]) {
        self.tools = tools
    }

    public subscript(tool: AgentTool) -> AgentPathOverride {
        get { tools[tool.rawValue] ?? AgentPathOverride() }
        set { tools[tool.rawValue] = newValue.isEmpty ? nil : newValue }
    }

    public static func load(from defaults: UserDefaults = .standard) -> AgentPathOverrides {
        guard let data = defaults.data(forKey: AgentsConfig.pathOverridesKey),
              let value = try? JSONDecoder().decode(AgentPathOverrides.self, from: data) else { return AgentPathOverrides() }
        return value
    }

    public func save(to defaults: UserDefaults = .standard) {
        if tools.isEmpty {
            defaults.removeObject(forKey: AgentsConfig.pathOverridesKey)
        } else if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: AgentsConfig.pathOverridesKey)
        }
    }
}

// MARK: - Resolved paths

/// Where a path came from, in the order the resolver tries them.
public enum AgentPathSource: String, Sendable, Hashable {
    case override, environment, shellConfig, standard, path, missing

    public var title: String {
        switch self {
        case .override: return "Set in Settings"
        case .environment: return "From the environment"
        case .shellConfig: return "From your shell config"
        case .standard: return "Usual place"
        case .path: return "Found on PATH"
        case .missing: return "Not found"
        }
    }
}

public struct ResolvedAgentPath: Sendable, Hashable {
    public var path: String?
    public var source: AgentPathSource
    /// The environment variable that set it, when it came from one.
    public var variable: String?
    public var exists: Bool

    public init(path: String?, source: AgentPathSource, variable: String? = nil, exists: Bool) {
        self.path = path
        self.source = source
        self.variable = variable
        self.exists = exists
    }

    static let missing = ResolvedAgentPath(path: nil, source: .missing, exists: false)
}

// MARK: - Shell config

/// Reads `export NAME=value` lines from shell startup files. Nothing is run. Values that need
/// the shell to work them out (other variables, command substitution) are skipped.
public enum ShellConfigEnvironment {
    public static let files = [".zshenv", ".zprofile", ".zshrc", ".bash_profile", ".bashrc", ".profile"]

    public static func read(home: String, names: Set<String>) -> [String: String] {
        var values: [String: String] = [:]
        for file in files {
            let path = (home as NSString).appendingPathComponent(file)
            guard let data = FileManager.default.contents(atPath: path), data.count < 1_000_000 else { continue }
            parse(String(decoding: data, as: UTF8.self), names: names, home: home, into: &values)
        }
        return values
    }

    /// Later lines win, like the shell.
    public static func parse(_ text: String, names: Set<String>, home: String, into values: inout [String: String]) {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("export ") else { continue }
            line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            guard let eq = line.firstIndex(of: "=") else { continue }
            let name = String(line[..<eq])
            guard names.contains(name) else { continue }
            if let value = unquote(String(line[line.index(after: eq)...]), home: home) {
                values[name] = value
            }
        }
    }

    static func unquote(_ raw: String, home: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        var value = ""
        if let quote = text.first, quote == "\"" || quote == "'" {
            text.removeFirst()
            guard let end = text.firstIndex(of: quote) else { return nil }
            value = String(text[..<end])
            if quote == "'" { return value.isEmpty ? nil : value }
        } else {
            // Up to a comment or the end of the command.
            let stop = text.firstIndex { $0 == " " || $0 == "#" || $0 == ";" } ?? text.endIndex
            value = String(text[..<stop])
            if value.hasPrefix("~") { value = home + value.dropFirst() }
        }
        value = value.replacingOccurrences(of: "${HOME}", with: home).replacingOccurrences(of: "$HOME", with: home)
        guard !value.isEmpty, !value.contains("$"), !value.contains("`") else { return nil }
        return value
    }
}

// MARK: - Resolver

/// The one place that decides where an agent's executable, config file and sessions live.
/// Order: Settings override, the agent's own environment variable (the app's environment,
/// then `export` lines in shell config), the usual place, then PATH (executables only).
public struct AgentPathResolver: Sendable {
    public var home: String
    public var environment: [String: String]
    public var shellEnvironment: [String: String]
    public var overrides: AgentPathOverrides
    public var applicationFolders: [String]
    /// Shared install folders tried before the home folders, like /opt/homebrew/bin.
    public var systemFolders: [String]
    /// Debug only: a folder of stand in tools that replaces the normal search.
    public var toolsFolder: String?

    /// Variables the agents read themselves. Checked in each tool's source on 6 Nov 2026:
    /// Claude Code `CLAUDE_CONFIG_DIR` (replaces ~/.claude, `.claude.json` moves inside it),
    /// Codex `CODEX_HOME` (replaces ~/.codex), Gemini CLI `GEMINI_CLI_HOME` (replaces the home folder).
    public static let variables: [AgentTool: String] = [.claude: "CLAUDE_CONFIG_DIR", .codex: "CODEX_HOME", .gemini: "GEMINI_CLI_HOME"]

    public init(home: String = NSHomeDirectory(), environment: [String: String] = ProcessInfo.processInfo.environment,
                shellEnvironment: [String: String] = [:], overrides: AgentPathOverrides = AgentPathOverrides(),
                applicationFolders: [String]? = nil, systemFolders: [String] = ["/opt/homebrew/bin", "/usr/local/bin"],
                toolsFolder: String? = nil) {
        self.home = home
        self.environment = environment
        self.shellEnvironment = shellEnvironment
        self.overrides = overrides
        self.applicationFolders = applicationFolders ?? ["/Applications", (home as NSString).appendingPathComponent("Applications")]
        self.systemFolders = systemFolders
        self.toolsFolder = toolsFolder
    }

    /// The app's resolver: this Mac's environment plus shell config, with the saved overrides.
    public static func standard(overrides: AgentPathOverrides = .load(), home: String = NSHomeDirectory()) -> AgentPathResolver {
        let names = Set(variables.values)
        return AgentPathResolver(home: home, shellEnvironment: ShellConfigEnvironment.read(home: home, names: names), overrides: overrides)
    }

    // MARK: Helpers

    private func expand(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("~") { return home + trimmed.dropFirst() }
        return trimmed
    }

    private func overrideValue(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return expand(value)
    }

    private func join(_ base: String, _ parts: String...) -> String {
        parts.reduce(base) { ($0 as NSString).appendingPathComponent($1) }
    }

    private static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// The value of an agent variable and where it was found.
    public func variable(_ name: String) -> (value: String, source: AgentPathSource)? {
        if let value = environment[name], !value.isEmpty { return (expand(value), .environment) }
        if let value = shellEnvironment[name], !value.isEmpty { return (expand(value), .shellConfig) }
        return nil
    }

    // MARK: Executables

    /// Install folders under the home folder, plus nvm versions.
    public var standardFolders: [String] {
        let h = home
        var folders = systemFolders
        folders += ["\(h)/.local/bin", "\(h)/.npm-global/bin", "\(h)/.bun/bin", "\(h)/.cargo/bin", "\(h)/.volta/bin",
                    "\(h)/.pyenv/shims", "\(h)/.asdf/shims", "\(h)/.claude/local", "\(h)/.opencode/bin", "\(h)/go/bin", "\(h)/.amp/bin"]
        let nvm = "\(h)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            folders += versions.sorted().reversed().map { "\(nvm)/\($0)/bin" }
        }
        return folders
    }

    public var pathFolders: [String] {
        (environment["PATH"] ?? "").split(separator: ":").map(String.init)
    }

    /// Every folder searched for agent tools, for a PATH given to launched commands.
    public var searchFolders: [String] {
        var seen = Set<String>()
        let all = (toolsFolder.map { [$0] } ?? []) + standardFolders + pathFolders
        return all.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    public func executable(_ tool: AgentTool) -> ResolvedAgentPath {
        let fm = FileManager.default
        if let path = overrideValue(overrides[tool].executable) {
            let ok = tool.isApp ? fm.fileExists(atPath: path) : fm.isExecutableFile(atPath: path)
            return ResolvedAgentPath(path: path, source: .override, exists: ok)
        }
        let appFolders = toolsFolder.map { [join($0, "Applications")] } ?? applicationFolders
        for app in tool.appNames {
            for folder in appFolders {
                let path = join(folder, app)
                if fm.fileExists(atPath: path) { return ResolvedAgentPath(path: path, source: .standard, exists: true) }
            }
        }
        let groups: [(folders: [String], source: AgentPathSource)] = toolsFolder.map { [([$0], .standard)] }
            ?? [(standardFolders, .standard), (pathFolders, .path)]
        for group in groups {
            for binary in tool.binaries {
                for folder in group.folders where !folder.isEmpty {
                    let path = join(folder, binary)
                    if fm.isExecutableFile(atPath: path) { return ResolvedAgentPath(path: path, source: group.source, exists: true) }
                }
            }
        }
        return .missing
    }

    // MARK: Agent homes

    private func home(variable name: String, fallback: String, inside: String? = nil) -> ResolvedAgentPath {
        if let found = variable(name) {
            let path = inside.map { join(found.value, $0) } ?? found.value
            return ResolvedAgentPath(path: path, source: found.source, variable: name, exists: Self.exists(path))
        }
        return ResolvedAgentPath(path: fallback, source: .standard, exists: Self.exists(fallback))
    }

    /// Claude Code's config folder (~/.claude).
    public var claudeHome: ResolvedAgentPath { home(variable: "CLAUDE_CONFIG_DIR", fallback: join(home, ".claude")) }
    /// Codex's folder (~/.codex).
    public var codexHome: ResolvedAgentPath { home(variable: "CODEX_HOME", fallback: join(home, ".codex")) }
    /// Gemini CLI's folder (~/.gemini).
    public var geminiHome: ResolvedAgentPath { home(variable: "GEMINI_CLI_HOME", fallback: join(home, ".gemini"), inside: ".gemini") }

    // MARK: Config files

    /// The MCP config file this tool reads. nil when the app does not read its config.
    public func configFile(_ tool: AgentTool) -> ResolvedAgentPath? {
        guard let agent = tool.configAgent else { return nil }
        let owner = AgentTool.primary(for: agent)
        if let path = overrideValue(overrides[owner].config) {
            return ResolvedAgentPath(path: path, source: .override, exists: Self.exists(path))
        }
        let standard = AgentConfigLocations(home: home)
        switch agent {
        case .claudeCode:
            if let found = variable("CLAUDE_CONFIG_DIR") {
                let path = join(found.value, ".claude.json")
                return ResolvedAgentPath(path: path, source: found.source, variable: "CLAUDE_CONFIG_DIR", exists: Self.exists(path))
            }
            return ResolvedAgentPath(path: standard.claudeJSON, source: .standard, exists: Self.exists(standard.claudeJSON))
        case .codex:
            let base = codexHome
            let path = join(base.path ?? "", "config.toml")
            return ResolvedAgentPath(path: path, source: base.source, variable: base.variable, exists: Self.exists(path))
        case .gemini:
            let base = geminiHome
            let path = join(base.path ?? "", "settings.json")
            return ResolvedAgentPath(path: path, source: base.source, variable: base.variable, exists: Self.exists(path))
        case .claudeDesktop:
            return ResolvedAgentPath(path: standard.claudeDesktop, source: .standard, exists: Self.exists(standard.claudeDesktop))
        case .cursor:
            return ResolvedAgentPath(path: standard.cursor, source: .standard, exists: Self.exists(standard.cursor))
        case .vscode:
            return ResolvedAgentPath(path: standard.vscodeUser, source: .standard, exists: Self.exists(standard.vscodeUser))
        }
    }

    /// Config file locations for discovery and the config writer.
    public var locations: AgentConfigLocations {
        var result = AgentConfigLocations(home: home)
        func path(_ tool: AgentTool) -> String? { configFile(tool)?.path }
        result.claudeJSON = path(.claude) ?? result.claudeJSON
        result.codex = path(.codex) ?? result.codex
        result.gemini = path(.gemini) ?? result.gemini
        result.claudeDesktop = path(.claudeDesktop) ?? result.claudeDesktop
        result.cursor = path(.cursorApp) ?? result.cursor
        result.vscodeUser = path(.vscodeApp) ?? result.vscodeUser
        return result
    }

    // MARK: Sessions

    /// Folder where the tool keeps its session files. nil for tools whose format the app does not read.
    public func sessionsFolder(_ tool: AgentTool) -> ResolvedAgentPath? {
        guard AgentSessionHistory.supported.contains(tool) else { return nil }
        if let path = overrideValue(overrides[tool].sessions) {
            return ResolvedAgentPath(path: path, source: .override, exists: Self.exists(path))
        }
        let base = tool == .claude ? claudeHome : codexHome
        let path = join(base.path ?? "", tool == .claude ? "projects" : "sessions")
        return ResolvedAgentPath(path: path, source: base.source, variable: base.variable, exists: Self.exists(path))
    }

    /// Codex keeps session titles in this file next to the sessions folder.
    public var codexSessionIndex: String {
        join(codexHome.path ?? join(home, ".codex"), "session_index.jsonl")
    }
}

public extension AgentTool {
    /// The tool whose Settings row owns the config file of an agent kind (Cursor app and CLI share one file).
    static func primary(for agent: AgentKind) -> AgentTool {
        switch agent {
        case .claudeCode: return .claude
        case .claudeDesktop: return .claudeDesktop
        case .cursor: return .cursorApp
        case .vscode: return .vscodeApp
        case .codex: return .codex
        case .gemini: return .gemini
        }
    }

    /// True when this tool's Settings row shows the config file field.
    var ownsConfigFile: Bool {
        guard let agent = configAgent else { return false }
        return AgentTool.primary(for: agent) == self
    }
}

// MARK: - Settings field rule

public extension AgentPathResolver {
    /// What a Settings field shows: the override, else the detected path when it was found, else empty.
    func fieldValue(override: String?, detected: ResolvedAgentPath) -> String {
        if let override, !override.trimmingCharacters(in: .whitespaces).isEmpty { return override }
        return detected.exists ? (detected.path ?? "") : ""
    }

    /// The override to store for what was typed. nil when it is empty or the same as the detected
    /// path, so later detection changes still apply.
    func overrideToStore(_ typed: String, detected: ResolvedAgentPath) -> String? {
        let trimmed = typed.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let expanded = trimmed.hasPrefix("~") ? home + trimmed.dropFirst() : trimmed
        if detected.exists, let path = detected.path, path == expanded || path == trimmed { return nil }
        return typed
    }

    /// Where the tool usually lives, for the placeholder of a field that found nothing.
    func usualExecutablePath(_ tool: AgentTool) -> String {
        if let app = tool.appNames.first { return ((applicationFolders.first ?? "/Applications") as NSString).appendingPathComponent(app) }
        let folder = systemFolders.first ?? (home as NSString).appendingPathComponent(".local/bin")
        return (folder as NSString).appendingPathComponent(tool.binaries.first ?? tool.rawValue)
    }
}
