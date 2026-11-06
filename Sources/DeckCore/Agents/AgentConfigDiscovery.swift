import Foundation

/// Finds MCP servers in agent config files on this Mac. Read only.
public struct AgentConfigDiscovery: Sendable {
    public var locations: AgentConfigLocations
    /// Extra project folders to look in (besides the ones Claude Code knows).
    public var extraProjects: [String]

    public init(locations: AgentConfigLocations = AgentConfigLocations(), extraProjects: [String] = []) {
        self.locations = locations
        self.extraProjects = extraProjects
    }

    public struct Result: Sendable {
        public var servers: [DiscoveredMCPServer]
        public var files: [AgentConfigFileStatus]
        /// Project folders that were checked.
        public var projects: [String]
    }

    public func discover() -> Result {
        var servers: [DiscoveredMCPServer] = []
        var files: [AgentConfigFileStatus] = []
        let fm = FileManager.default

        func read(_ path: String) -> String? {
            guard fm.fileExists(atPath: path), let data = fm.contents(atPath: path) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }

        func scanJSON(_ agent: AgentKind, path: String, scope: AgentConfigScope, keyPath: [String], always: Bool = true) {
            guard let text = read(path) else {
                if always { files.append(AgentConfigFileStatus(agent: agent, path: path, exists: false, serverCount: 0)) }
                return
            }
            do {
                let found = try self.servers(inJSON: text, agent: agent, path: path, scope: scope, keyPath: keyPath)
                servers.append(contentsOf: found)
                files.append(AgentConfigFileStatus(agent: agent, path: path, exists: true, serverCount: found.count))
            } catch {
                files.append(AgentConfigFileStatus(agent: agent, path: path, exists: true, serverCount: 0,
                                                   problem: error.localizedDescription))
            }
        }

        func scanTOML(path: String, scope: AgentConfigScope, always: Bool = true) {
            guard let text = read(path) else {
                if always { files.append(AgentConfigFileStatus(agent: .codex, path: path, exists: false, serverCount: 0)) }
                return
            }
            let found = Self.servers(inTOML: text, path: path, scope: scope)
            servers.append(contentsOf: found)
            files.append(AgentConfigFileStatus(agent: .codex, path: path, exists: true, serverCount: found.count))
        }

        // Claude Code: user and local scopes live in ~/.claude.json.
        var projects: [String] = []
        if let text = read(locations.claudeJSON) {
            let editor = JSONCEditor(text: text)
            do {
                let root = try editor.foundationValue() as? [String: Any] ?? [:]
                var count = 0
                if let user = root["mcpServers"] as? [String: Any] {
                    let found = Self.entries(user, agent: .claudeCode, path: locations.claudeJSON, scope: .user)
                    servers += found
                    count += found.count
                }
                if let projectMap = root["projects"] as? [String: Any] {
                    for (folder, value) in projectMap.sorted(by: { $0.key < $1.key }) {
                        projects.append(folder)
                        if let dict = value as? [String: Any], let local = dict["mcpServers"] as? [String: Any] {
                            let found = Self.entries(local, agent: .claudeCode, path: locations.claudeJSON, scope: .local(folder))
                            servers += found
                            count += found.count
                        }
                    }
                }
                files.append(AgentConfigFileStatus(agent: .claudeCode, path: locations.claudeJSON, exists: true, serverCount: count))
            } catch {
                files.append(AgentConfigFileStatus(agent: .claudeCode, path: locations.claudeJSON, exists: true, serverCount: 0,
                                                   problem: error.localizedDescription))
            }
        } else {
            files.append(AgentConfigFileStatus(agent: .claudeCode, path: locations.claudeJSON, exists: false, serverCount: 0))
        }

        scanJSON(.claudeDesktop, path: locations.claudeDesktop, scope: .user, keyPath: ["mcpServers"])
        scanJSON(.cursor, path: locations.cursor, scope: .user, keyPath: ["mcpServers"])
        scanJSON(.vscode, path: locations.vscodeUser, scope: .user, keyPath: ["servers"])
        scanJSON(.vscode, path: locations.vscodeInsidersUser, scope: .user, keyPath: ["servers"], always: false)
        scanJSON(.vscode, path: locations.vscodeSettings, scope: .user, keyPath: ["mcp", "servers"], always: false)
        scanTOML(path: locations.codex, scope: .user)
        scanJSON(.gemini, path: locations.gemini, scope: .user, keyPath: ["mcpServers"])

        // Project files in every known project folder that still exists.
        var seen = Set<String>()
        let allProjects = (projects + extraProjects).filter { folder in
            var isDir: ObjCBool = false
            return seen.insert(folder).inserted && fm.fileExists(atPath: folder, isDirectory: &isDir) && isDir.boolValue
        }
        for folder in allProjects where folder != locations.home {
            let scope = AgentConfigScope.project(folder)
            for agent in AgentKind.allCases where agent.supportsProjectScope {
                let path = locations.file(for: agent, scope: scope)
                if agent.isTOML {
                    scanTOML(path: path, scope: scope, always: false)
                } else {
                    scanJSON(agent, path: path, scope: scope, keyPath: agent.serversPath(scope: scope), always: false)
                }
            }
        }
        return Result(servers: servers, files: files, projects: allProjects)
    }

    func servers(inJSON text: String, agent: AgentKind, path: String, scope: AgentConfigScope, keyPath: [String]) throws -> [DiscoveredMCPServer] {
        let editor = JSONCEditor(text: text)
        guard let dict = try editor.object(at: keyPath) else { return [] }
        return Self.entries(dict, agent: agent, path: path, scope: scope)
    }

    static func entries(_ dict: [String: Any], agent: AgentKind, path: String, scope: AgentConfigScope) -> [DiscoveredMCPServer] {
        dict.keys.sorted().compactMap { name in
            guard let value = dict[name] as? [String: Any],
                  let entry = AgentEntryFormat.parse(name: name, value, agent: agent) else { return nil }
            let disabled = (value["disabled"] as? Bool) == true || (value["enabled"] as? Bool) == false
            return discovered(entry, agent: agent, path: path, scope: scope, disabled: disabled)
        }
    }

    static func servers(inTOML text: String, path: String, scope: AgentConfigScope) -> [DiscoveredMCPServer] {
        TOMLEditor(text: text).mcpServers().compactMap { server in
            guard let entry = AgentEntryFormat.parse(name: server.name, toml: server.values) else { return nil }
            let disabled = server.values["enabled"] == .bool(false)
            return discovered(entry, agent: .codex, path: path, scope: scope, disabled: disabled)
        }
    }

    static func discovered(_ entry: MCPServerEntry, agent: AgentKind, path: String, scope: AgentConfigScope, disabled: Bool) -> DiscoveredMCPServer {
        DiscoveredMCPServer(
            agent: agent, scope: scope, file: path, name: entry.name, transport: entry.transport,
            target: entry.target, envKeys: entry.env.keys.sorted(), headerKeys: entry.headers.keys.sorted(),
            disabled: disabled, managedServer: MCPLaunch.managedServerName(in: entry), url: entry.url, entry: entry
        )
    }
}
