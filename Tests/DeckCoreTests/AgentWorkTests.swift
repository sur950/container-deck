import XCTest
@testable import DeckCore

/// Agent paths, sessions, profiles and sandbox launches. Everything runs in a temp folder
/// with fake content, never the real agent folders.
final class AgentWorkTests: XCTestCase {
    var root: String!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "deck-agent-work-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    @discardableResult
    func write(_ relative: String, _ text: String, mode: Int? = nil) throws -> String {
        let path = (root as NSString).appendingPathComponent(relative)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        if let mode { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path) }
        return path
    }

    var home: String { root + "/home" }

    func resolver(env: [String: String] = [:], shell: [String: String] = [:], overrides: AgentPathOverrides = AgentPathOverrides()) -> AgentPathResolver {
        AgentPathResolver(home: home, environment: env, shellEnvironment: shell, overrides: overrides,
                          applicationFolders: [root + "/Apps"], systemFolders: [])
    }

    // MARK: Resolver order

    func testExecutableOrderOverrideThenStandardThenPath() throws {
        try write("pathbin/claude", "#!/bin/sh\n", mode: 0o755)
        var r = resolver(env: ["PATH": root + "/pathbin"])
        XCTAssertEqual(r.executable(.claude).source, .path)
        XCTAssertEqual(r.executable(.claude).path, root + "/pathbin/claude")

        try write("home/.local/bin/claude", "#!/bin/sh\n", mode: 0o755)
        XCTAssertEqual(r.executable(.claude).source, .standard)
        XCTAssertEqual(r.executable(.claude).path, home + "/.local/bin/claude")

        let custom = try write("custom/claude-dev", "#!/bin/sh\n", mode: 0o755)
        r.overrides[.claude] = AgentPathOverride(executable: custom)
        XCTAssertEqual(r.executable(.claude).source, .override)
        XCTAssertEqual(r.executable(.claude).path, custom)
        XCTAssertTrue(r.executable(.claude).exists)

        r.overrides[.claude] = AgentPathOverride(executable: root + "/missing/claude")
        XCTAssertEqual(r.executable(.claude).source, .override)
        XCTAssertFalse(r.executable(.claude).exists)
        XCTAssertEqual(r.executable(.codex).source, .missing)
    }

    func testToolsFolderReplacesSearch() throws {
        try write("pathbin/gemini", "#!/bin/sh\n", mode: 0o755)
        try write("tools/claude", "#!/bin/sh\n", mode: 0o755)
        var r = resolver(env: ["PATH": root + "/pathbin"])
        r.toolsFolder = root + "/tools"
        XCTAssertEqual(r.executable(.claude).path, root + "/tools/claude")
        XCTAssertNil(r.executable(.gemini).path)
    }

    func testConfigOrderOverrideThenEnvironmentThenShellThenStandard() throws {
        var r = resolver()
        XCTAssertEqual(r.configFile(.claude)?.path, home + "/.claude.json")
        XCTAssertEqual(r.configFile(.claude)?.source, .standard)
        XCTAssertEqual(r.sessionsFolder(.claude)?.path, home + "/.claude/projects")

        r.shellEnvironment = ["CLAUDE_CONFIG_DIR": home + "/shell-claude"]
        XCTAssertEqual(r.configFile(.claude)?.path, home + "/shell-claude/.claude.json")
        XCTAssertEqual(r.configFile(.claude)?.source, .shellConfig)
        XCTAssertEqual(r.configFile(.claude)?.variable, "CLAUDE_CONFIG_DIR")
        XCTAssertEqual(r.sessionsFolder(.claude)?.path, home + "/shell-claude/projects")

        r.environment = ["CLAUDE_CONFIG_DIR": "~/env-claude"]
        XCTAssertEqual(r.configFile(.claude)?.path, home + "/env-claude/.claude.json")
        XCTAssertEqual(r.configFile(.claude)?.source, .environment)

        r.overrides[.claude] = AgentPathOverride(config: root + "/mine.json", sessions: root + "/sessions")
        XCTAssertEqual(r.configFile(.claude)?.path, root + "/mine.json")
        XCTAssertEqual(r.configFile(.claude)?.source, .override)
        XCTAssertEqual(r.sessionsFolder(.claude)?.path, root + "/sessions")
        XCTAssertEqual(r.locations.claudeJSON, root + "/mine.json")
    }

    func testCodexAndGeminiVariables() {
        let r = resolver(env: ["CODEX_HOME": root + "/cx", "GEMINI_CLI_HOME": root + "/gh"])
        XCTAssertEqual(r.configFile(.codex)?.path, root + "/cx/config.toml")
        XCTAssertEqual(r.sessionsFolder(.codex)?.path, root + "/cx/sessions")
        XCTAssertEqual(r.codexSessionIndex, root + "/cx/session_index.jsonl")
        XCTAssertEqual(r.configFile(.gemini)?.path, root + "/gh/.gemini/settings.json")
        XCTAssertEqual(r.locations.codex, root + "/cx/config.toml")
        XCTAssertEqual(r.locations.gemini, root + "/gh/.gemini/settings.json")
        XCTAssertNil(r.sessionsFolder(.gemini))
        XCTAssertNil(r.configFile(.aider))
        // Cursor app and CLI share one file, owned by the app row.
        XCTAssertTrue(AgentTool.cursorApp.ownsConfigFile)
        XCTAssertFalse(AgentTool.cursorAgent.ownsConfigFile)
    }

    func testOverridesSaveAndLoad() {
        let defaults = UserDefaults(suiteName: "deck-agent-paths-\(UUID().uuidString)")!
        var overrides = AgentPathOverrides()
        overrides[.codex] = AgentPathOverride(executable: "/x/codex")
        overrides[.claude] = AgentPathOverride()
        overrides.save(to: defaults)
        let loaded = AgentPathOverrides.load(from: defaults)
        XCTAssertEqual(loaded[.codex].executable, "/x/codex")
        XCTAssertTrue(loaded[.claude].isEmpty)
        XCTAssertEqual(loaded.tools.count, 1)
    }

    func testSettingsFieldRule() throws {
        try write("home/.local/bin/claude", "#!/bin/sh\n", mode: 0o755)
        let r = resolver()
        let detected = r.executable(.claude)
        XCTAssertTrue(detected.exists)
        // Found: the field shows the detected path.
        XCTAssertEqual(r.fieldValue(override: nil, detected: detected), home + "/.local/bin/claude")
        // Typing the detected path (or ~ form) stores nothing, so later detection still applies.
        XCTAssertNil(r.overrideToStore(home + "/.local/bin/claude", detected: detected))
        XCTAssertNil(r.overrideToStore("~/.local/bin/claude", detected: detected))
        // Reset clears the field, which stores nothing.
        XCTAssertNil(r.overrideToStore("  ", detected: detected))
        // A different path becomes the override and shows in the field.
        XCTAssertEqual(r.overrideToStore("/opt/x/claude", detected: detected), "/opt/x/claude")
        XCTAssertEqual(r.fieldValue(override: "/opt/x/claude", detected: detected), "/opt/x/claude")
        var overrides = AgentPathOverrides()
        overrides[.claude] = AgentPathOverride(executable: r.overrideToStore(home + "/.local/bin/claude", detected: detected))
        XCTAssertTrue(overrides.tools.isEmpty)
        // Not found: empty field with the usual place as placeholder.
        let missing = r.executable(.codex)
        XCTAssertEqual(r.fieldValue(override: nil, detected: missing), "")
        XCTAssertEqual(r.overrideToStore("/x/codex", detected: missing), "/x/codex")
        XCTAssertEqual(AgentPathResolver(home: home, systemFolders: ["/opt/homebrew/bin"]).usualExecutablePath(.codex), "/opt/homebrew/bin/codex")
        XCTAssertEqual(r.usualExecutablePath(.cursorApp), root + "/Apps/Cursor.app")
    }

    func testShellConfigParsing() throws {
        let text = """
        # setup
        export CLAUDE_CONFIG_DIR="$HOME/.claude-work"
        export CODEX_HOME=~/codex-home # comment
        export GEMINI_CLI_HOME=$(pwd)/g
        export OTHER=1
        CLAUDE_CONFIG_DIR=/not/exported
        export CODEX_HOME='/later/wins'
        """
        var values: [String: String] = [:]
        ShellConfigEnvironment.parse(text, names: ["CLAUDE_CONFIG_DIR", "CODEX_HOME", "GEMINI_CLI_HOME"], home: "/Users/x", into: &values)
        XCTAssertEqual(values["CLAUDE_CONFIG_DIR"], "/Users/x/.claude-work")
        XCTAssertEqual(values["CODEX_HOME"], "/later/wins")
        XCTAssertNil(values["GEMINI_CLI_HOME"])
        XCTAssertNil(values["OTHER"])

        try write("home/.zshrc", "export CODEX_HOME=\"${HOME}/cx\"\n")
        XCTAssertEqual(ShellConfigEnvironment.read(home: home, names: ["CODEX_HOME"])["CODEX_HOME"], home + "/cx")
    }

    func testDetectorUsesResolver() async throws {
        try write("tools/claude", "#!/bin/sh\necho '9.8.7 (Claude Code)'\n", mode: 0o755)
        var r = resolver()
        r.toolsFolder = root + "/tools"
        let found = await AgentToolDetector(resolver: r, runner: ProcessRunner()).detect()
        XCTAssertEqual(found.first { $0.tool == .claude }?.version, "9.8.7")
        XCTAssertEqual(found.first { $0.tool == .claude }?.path, root + "/tools/claude")
        XCTAssertNil(found.first { $0.tool == .gemini }?.path)
    }

    // MARK: Processes

    func testPSParsing() {
        let text = """
          101     1    01:28:35   0.0  42992 /usr/sbin/somed
        20308  3475 01-01:13:25   0.0 279136 claude --dangerously-skip-permissions
          555   20308       00:05  12,5   2048 npx -y @modelcontextprotocol/server-filesystem /tmp
        bad line
        """
        let rows = ProcessListParser.parse(text)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[1].pid, 20308)
        XCTAssertEqual(rows[1].elapsed, 86_400 + 3_600 + 13 * 60 + 25)
        XCTAssertEqual(rows[1].command, "claude --dangerously-skip-permissions")
        XCTAssertEqual(rows[2].cpu, 12.5)
        XCTAssertEqual(ProcessListParser.elapsedSeconds("05"), 5)
        XCTAssertNil(ProcessListParser.elapsedSeconds("x:1"))
        XCTAssertEqual(ProcessListParser.lsofFolder("p20308\nfcwd\nn/Users/x/app\n"), "/Users/x/app")
    }

    func testProcArgsParsing() {
        var bytes: [UInt8] = [3, 0, 0, 0]
        bytes += Array("/usr/bin/node".utf8) + [0, 0, 0]
        bytes += Array("node".utf8) + [0] + Array("/opt/x/gemini".utf8) + [0] + Array("--yolo".utf8) + [0]
        bytes += Array("PATH=/bin".utf8) + [0]
        XCTAssertEqual(SystemProcessInspector.parseProcArgs(bytes), ["node", "/opt/x/gemini", "--yolo"])
        XCTAssertNil(SystemProcessInspector.parseProcArgs([1, 0]))
    }

    func testMatcherFindsTopSessionsAndMCPChildren() {
        let claudeExe = root + "/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe"
        let rows = [
            ProcessRow(pid: 10, ppid: 1, elapsed: 600, cpu: 3, rssKB: 1000, command: "claude"),
            ProcessRow(pid: 11, ppid: 10, elapsed: 500, cpu: 0, rssKB: 10, command: "npx -y @modelcontextprotocol/server-filesystem /tmp"),
            ProcessRow(pid: 12, ppid: 10, elapsed: 400, cpu: 0, rssKB: 10, command: "/bin/zsh -c npm test"),
            ProcessRow(pid: 13, ppid: 10, elapsed: 300, cpu: 0, rssKB: 10, command: "claude helper"),
            ProcessRow(pid: 14, ppid: 10, elapsed: 300, cpu: 0, rssKB: 10, command: "/usr/local/bin/container run -i --rm --label deck.mcp=github ghcr.io/x"),
            ProcessRow(pid: 15, ppid: 10, elapsed: 300, cpu: 0, rssKB: 10, command: "node /opt/mcp-weather/index.js"),
            ProcessRow(pid: 20, ppid: 1, elapsed: 60, cpu: 1, rssKB: 500, command: "node /opt/homebrew/bin/claude"),
            ProcessRow(pid: 30, ppid: 1, elapsed: 60, cpu: 1, rssKB: 500, command: "/Users/x/.vscode/ext/codex app-server"),
            ProcessRow(pid: 40, ppid: 1, elapsed: 60, cpu: 1, rssKB: 500, command: "vim claude.md"),
        ]
        let exes: [Int32: String] = [10: claudeExe, 13: claudeExe, 11: "/opt/homebrew/bin/node", 12: "/bin/zsh", 14: "/usr/local/bin/container",
                                     15: "/opt/homebrew/bin/node", 20: "/opt/homebrew/bin/node", 30: "/Users/x/.vscode/ext/codex", 40: "/usr/bin/vim"]
        let args: [Int32: [String]] = [
            10: ["claude"], 13: ["claude", "helper"],
            11: ["npx", "-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
            12: ["/bin/zsh", "-c", "npm test mcp"],
            14: ["/usr/local/bin/container", "run", "-i", "--rm", "--label", "deck.mcp=github", "ghcr.io/x"],
            15: ["node", "/opt/mcp-weather/index.js"],
            20: ["node", "/opt/homebrew/bin/claude", "--resume", "abc"],
            30: ["/Users/x/.vscode/ext/codex", "app-server"], 40: ["vim", "claude.md"],
        ]
        let servers = [MCPServerEntry.stdio("files", command: "npx", args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"])]
        let now = Date()
        let sessions = AgentProcessMatcher.sessions(rows: rows, tool: .claude, toolPath: "/opt/homebrew/bin/claude", servers: servers, now: now) { pid in
            (exes[pid], args[pid])
        }
        XCTAssertEqual(sessions.map(\.pid).sorted(), [10, 20])
        let main = sessions.first { $0.pid == 10 }!
        XCTAssertEqual(main.started.timeIntervalSince1970, now.addingTimeInterval(-600).timeIntervalSince1970, accuracy: 0.01)
        XCTAssertEqual(main.memoryBytes, 1000 * 1024)
        XCTAssertEqual(main.mcpServers.map(\.pid), [11, 14, 15])
        XCTAssertEqual(main.mcpServers.map(\.name), ["files", "github", nil])
        XCTAssertTrue(sessions.first { $0.pid == 20 }!.command.hasPrefix("node /opt/homebrew/bin/claude"))
        // Servers started through an interpreter (npx is a node script) still match their config entry.
        XCTAssertEqual(AgentProcessMatcher.mcpServer(arguments: ["node", "/opt/homebrew/bin/npx", "-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
                                                     servers: servers), .some("files"))
        XCTAssertEqual(AgentProcessMatcher.mcpServer(arguments: ["/bin/sh", "/x/mcp-notes", "--stdio"], servers: []), .some(nil))
        XCTAssertNil(AgentProcessMatcher.mcpServer(arguments: ["/bin/zsh", "-c", "grep mcp"], servers: []))
        XCTAssertNil(AgentProcessMatcher.mcpServer(arguments: ["sleep", "30"], servers: []))
        // Codex inside VS Code is not the Codex CLI at another path.
        XCTAssertTrue(AgentProcessMatcher.sessions(rows: rows, tool: .codex, toolPath: "/opt/homebrew/bin/codex", servers: []) { (exes[$0], args[$0]) }.isEmpty)
    }

    func testMatcherMasksSecretsInCommands() {
        let rows = [ProcessRow(pid: 5, ppid: 1, elapsed: 1, cpu: 0, rssKB: 1, command: "aider")]
        let sessions = AgentProcessMatcher.sessions(rows: rows, tool: .aider, toolPath: root + "/bin/aider", servers: []) { _ in
            ("/usr/bin/python3", ["python3", self.root + "/bin/aider", "--api-key", "anthropic=sk-ant-0123456789abcdef"])
        }
        XCTAssertEqual(sessions.count, 1)
        XCTAssertFalse(sessions[0].command.contains("sk-ant"))
    }

    // MARK: Recent sessions

    func testClaudeSessionMetadata() throws {
        let lines = [
            #"{"type":"permission-mode","permissionMode":"default","sessionId":"s-1"}"#,
            #"{"type":"user","cwd":"/work/app","sessionId":"s-1","message":{"role":"user","content":"fake prompt"}}"#,
            #"{"type":"assistant","cwd":"/work/app","sessionId":"s-1","requestId":"req_1","message":{"id":"m1"}}"#,
            #"{"type":"assistant","cwd":"/work/app","sessionId":"s-1","requestId":"req_1","message":{"id":"m1"}}"#,
            #"{"type":"user","cwd":"/work/app","sessionId":"s-1","toolUseResult":{},"message":{"content":[{"type":"tool_result"}]}}"#,
            #"{"type":"user","cwd":"/work/app","isMeta":true,"sessionId":"s-1"}"#,
            #"{"type":"assistant","isSidechain":true,"requestId":"req_9","sessionId":"s-1"}"#,
            #"{"type":"ai-title","aiTitle":"Fix the build","sessionId":"s-1"}"#,
            #"{"type":"user","cwd":"/work/app","sessionId":"s-1","message":{"role":"user","content":"second"}}"#,
            #"{"type":"assistant","cwd":"/work/app","sessionId":"s-1","requestId":"req_2"}"#,
        ]
        let path = try write("home/.claude/projects/-work-app/s-1.jsonl", lines.joined(separator: "\n") + "\n")
        let record = AgentSessionHistory.parseClaude(Data(lines.joined(separator: "\n").utf8), file: path, modified: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(record?.sessionID, "s-1")
        XCTAssertEqual(record?.folder, "/work/app")
        XCTAssertEqual(record?.messageCount, 4)
        XCTAssertEqual(record?.title, "Fix the build")

        let withCustom = lines + [#"{"type":"custom-title","customTitle":"My name","sessionId":"s-1"}"#]
        XCTAssertEqual(AgentSessionHistory.parseClaude(Data(withCustom.joined(separator: "\n").utf8), file: path, modified: Date())?.title, "My name")

        try write("home/.claude/projects/-work-other/s-2.jsonl", #"{"type":"summary","summary":"Old summary"}"# + "\n" + lines[1])
        let cache = AgentSessionCache()
        let list = AgentSessionHistory.sessions(for: .claude, resolver: resolver(), cache: cache)
        XCTAssertEqual(Set(list.map(\.sessionID)), ["s-1", "s-2"])
        XCTAssertEqual(list.first { $0.sessionID == "s-2" }?.title, "Old summary")
        XCTAssertEqual(AgentSessionHistory.sessions(for: .claude, resolver: resolver(), cache: cache).count, 2)
    }

    func testCodexSessionMetadata() throws {
        let lines = [
            #"{"timestamp":"2026-03-07T14:48:45Z","type":"session_meta","payload":{"id":"019c-aaaa","cwd":"/work/api","cli_version":"0.1"}}"#,
            #"{"type":"turn_context","payload":{"cwd":"/work/api"}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"fake"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant"}}"#,
            #"{"type":"event_msg","payload":{"type":"agent_message","message":"fake"}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count"}}"#,
        ]
        try write("home/.codex/sessions/2026/03/07/rollout-2026-03-07T14-48-45-019c-aaaa.jsonl", lines.joined(separator: "\n"))
        try write("home/.codex/session_index.jsonl", #"{"id":"019c-aaaa","thread_name":"Old","updated_at":"x"}"# + "\n" + #"{"id":"019c-aaaa","thread_name":"Add tests","updated_at":"y"}"#)
        let list = AgentSessionHistory.sessions(for: .codex, resolver: resolver())
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].sessionID, "019c-aaaa")
        XCTAssertEqual(list[0].folder, "/work/api")
        XCTAssertEqual(list[0].messageCount, 2)
        XCTAssertEqual(list[0].title, "Add tests")
        XCTAssertTrue(AgentSessionHistory.sessions(for: .gemini, resolver: resolver()).isEmpty)
    }

    func testResumeCommands() {
        let claude = AgentSessionRecord(tool: .claude, sessionID: "abc-1", folder: "/work/my app", lastActivity: Date(), messageCount: 2, title: nil, file: "")
        XCTAssertEqual(AgentSessionHistory.resumeCommand(claude, executable: "/opt/homebrew/bin/claude"),
                       "cd '/work/my app' && /opt/homebrew/bin/claude --resume abc-1")
        let codex = AgentSessionRecord(tool: .codex, sessionID: "019c", folder: nil, lastActivity: Date(), messageCount: 2, title: nil, file: "")
        XCTAssertEqual(AgentSessionHistory.resumeCommand(codex, executable: "codex"), "codex resume 019c")
        var other = codex
        other.tool = .gemini
        XCTAssertNil(AgentSessionHistory.resumeCommand(other, executable: "gemini"))
    }

    // MARK: Profiles

    func testProfileRoundTripHasNoSecrets() throws {
        let local = AgentLocalModel(server: "Ollama", kind: .ollama, baseURL: "http://127.0.0.1:11434/v1", model: "qwen3:8b")
        for model in [AgentModelChoice.account, .providerKey(.anthropic), .local(local)] {
            let stamp = Date(timeIntervalSince1970: 1_800_000_000)
            let profile = AgentProfile(name: "Work", tool: .claude, model: model, mcpServers: ["files"], workspace: "/work/app", place: .sandbox,
                                       sandbox: AgentSandboxOptions(extraHosts: ["github.com"]), createdAt: stamp, updatedAt: stamp)
            let data = try AgentProfileStore.encode(profile)
            let back = try AgentProfileStore.decode(data)
            XCTAssertEqual(back, profile)
            let text = String(decoding: data, as: UTF8.self).lowercased()
            XCTAssertFalse(text.contains("sk-"))
            XCTAssertFalse(text.contains("api_key"))
        }
    }

    func testProfileStore() throws {
        let store = AgentProfileStore(folder: URL(fileURLWithPath: root + "/profiles"))
        XCTAssertTrue(store.load().isEmpty)
        let b = AgentProfile(name: "B", tool: .codex)
        let a = AgentProfile(name: "A", tool: .claude)
        try store.save(b)
        try store.save(a)
        try write("profiles/broken.json", "{")
        XCTAssertEqual(store.load().map(\.name), ["A", "B"])
        let copy = AgentProfileStore.duplicate(a, existing: store.load())
        XCTAssertNotEqual(copy.id, a.id)
        XCTAssertEqual(copy.name, "A copy")
        try store.save(copy)
        XCTAssertEqual(AgentProfileStore.duplicate(a, existing: store.load()).name, "A copy 2")
        try store.delete(b)
        XCTAssertEqual(store.load().map(\.name), ["A", "A copy"])
    }

    // MARK: Launch on this Mac

    func testClaudeMacPlanUsesPerRunMCPConfigAndKeychainKey() throws {
        let profile = AgentProfile(name: "Work", tool: .claude, model: .providerKey(.anthropic), mcpServers: ["files"],
                                   onlyProfileServers: true, workspace: "/work/my app")
        let entries = [MCPServerEntry.stdio("files", command: "npx", args: ["-y", "server-files"])]
        let plan = try AgentLauncher.macPlan(profile, executable: "/opt/homebrew/bin/claude", entries: entries, runFolder: URL(fileURLWithPath: root))
        let lines = plan.command.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "cd '/work/my app' || exit 1")
        XCTAssertTrue(lines[1].hasPrefix("ANTHROPIC_API_KEY=\"$(/usr/bin/security find-generic-password -s \(AgentsConfig.providerKeyService) -a anthropic -w)\""))
        XCTAssertEqual(lines[2], "export ANTHROPIC_API_KEY")
        let file = try XCTUnwrap(plan.files.first)
        XCTAssertEqual(lines[3], "/opt/homebrew/bin/claude --mcp-config \(file.path) --strict-mcp-config")
        XCTAssertTrue(file.contents.contains("\"mcpServers\""))
        XCTAssertTrue(file.contents.contains("\"server-files\""))
        try AgentLauncher.writeFiles(plan)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testCodexMacPlanUsesConfigOverrides() throws {
        let local = AgentLocalModel(server: "LM Studio", kind: .lmStudio, baseURL: "http://127.0.0.1:1234/v1", model: "qwen")
        let profile = AgentProfile(name: "C", tool: .codex, model: .local(local))
        let entries = [MCPServerEntry.remote("web", transport: .http, url: "http://127.0.0.1:18300/mcp")]
        let plan = try AgentLauncher.macPlan(profile, executable: "/usr/local/bin/codex", entries: entries, runFolder: URL(fileURLWithPath: root))
        XCTAssertTrue(plan.files.isEmpty)
        XCTAssertEqual(plan.command, "/usr/local/bin/codex -c 'mcp_servers.web.url=\"http://127.0.0.1:18300/mcp\"' -c model_provider=local -c "
                       + "'model_providers.local={name=\"Local\",base_url=\"http://127.0.0.1:1234/v1\"}' -m qwen")
    }

    func testAgentsWithoutPerRunMCPGetANote() throws {
        let profile = AgentProfile(name: "G", tool: .gemini, model: .account, mcpServers: ["files"])
        let plan = try AgentLauncher.macPlan(profile, executable: "/opt/homebrew/bin/gemini",
                                             entries: [.stdio("files", command: "npx")], runFolder: URL(fileURLWithPath: root))
        XCTAssertEqual(plan.command, "/opt/homebrew/bin/gemini")
        XCTAssertEqual(plan.notes.count, 1)
        XCTAssertEqual(AgentMCPRunSupport.of(.gemini), .none)
        XCTAssertThrowsError(try AgentLauncher.macPlan(profile, executable: nil, entries: [], runFolder: URL(fileURLWithPath: root)))
        let wrongKey = AgentProfile(name: "G", tool: .gemini, model: .providerKey(.openai))
        XCTAssertThrowsError(try AgentLauncher.macPlan(wrongKey, executable: "/x/gemini", entries: [], runFolder: URL(fileURLWithPath: root)))
    }

    func testAiderLocalPlan() throws {
        let local = AgentLocalModel(server: "Ollama", kind: .ollama, baseURL: "http://127.0.0.1:11434/v1", model: "qwen3:8b")
        let profile = AgentProfile(name: "A", tool: .aider, model: .local(local))
        let plan = try AgentLauncher.macPlan(profile, executable: "/x/aider", entries: [], runFolder: URL(fileURLWithPath: root))
        XCTAssertEqual(plan.command, "OLLAMA_API_BASE=http://127.0.0.1:11434 /x/aider --model ollama_chat/qwen3:8b")
    }

    // MARK: Sandbox

    func testSandboxSpecForProfile() throws {
        let id = UUID()
        let profile = AgentProfile(id: id, name: "Claude Work!", tool: .claude, model: .account, workspace: "/work/app", place: .sandbox,
                                   sandbox: AgentSandboxOptions(extraHosts: ["https://github.com/x", "bad host!"]))
        let spec = try AgentSandboxRecipe.spec(for: profile)
        XCTAssertEqual(spec.name, "deck-agent-claude-work")
        XCTAssertTrue(SandboxSpec.isValidName(spec.name))
        XCTAssertEqual(spec.image, "node:22-slim")
        XCTAssertEqual(spec.templateID, "agent-node")
        XCTAssertEqual(spec.egress, .allowList)
        XCTAssertEqual(spec.allowList, ["*.anthropic.com", "*.claude.ai", "*.claude.com", "registry.npmjs.org", "github.com"])
        XCTAssertFalse(spec.workspaceReadOnly)
        XCTAssertEqual(spec.extraMounts.first?.source, "deck-agent-cache-claude")
        XCTAssertEqual(spec.extraMounts.first?.kind, .volume)
        let options = SandboxPlanner.runOptions(spec, gateway: "192.168.70.1", subnet: nil, hasKey: false)
        XCTAssertEqual(options.labels[SandboxConfig.labelAgent], "claude")
        XCTAssertEqual(options.labels[SandboxConfig.labelProfile], id.uuidString.lowercased())
        XCTAssertTrue(options.mounts.contains { $0.destination == "/deck" && $0.kind == .volume })
        XCTAssertTrue(options.mounts.contains { $0.destination == SandboxConfig.workspacePath && !$0.readOnly })
        XCTAssertFalse(options.env.contains { $0.key.hasSuffix("API_KEY") })

        let aider = try AgentSandboxRecipe.spec(for: AgentProfile(name: "a", tool: .aider, model: .providerKey(.openai), place: .sandbox))
        XCTAssertEqual(aider.image, "python:3.12-slim")
        XCTAssertEqual(aider.allowList, ["api.openai.com", "pypi.org", "files.pythonhosted.org"])
        XCTAssertNil(aider.workspace)
        XCTAssertThrowsError(try AgentSandboxRecipe.spec(for: AgentProfile(name: "g", tool: .goose)))
        XCTAssertEqual(AgentSandboxRecipe.template(for: .claude)?.shell, "/bin/bash")
        XCTAssertEqual(SandboxConfig.template(id: "agent-python")?.image, "python:3.12-slim")
    }

    func testEgressDefaults() {
        let local = AgentLocalModel(server: "Ollama", kind: .ollama, baseURL: "http://127.0.0.1:11434/v1", model: "m")
        XCTAssertEqual(AgentSandboxRecipe.defaultAllowList(.claude, model: .local(local)), ["registry.npmjs.org"])
        XCTAssertEqual(AgentSandboxRecipe.defaultAllowList(.claude, model: .providerKey(.anthropic)), ["api.anthropic.com", "registry.npmjs.org"])
        XCTAssertEqual(AgentSandboxRecipe.defaultAllowList(.codex, model: .account), ["*.openai.com", "*.chatgpt.com", "registry.npmjs.org"])
        XCTAssertEqual(AgentSandboxRecipe.defaultAllowList(.gemini, model: .providerKey(.gemini)),
                       ["generativelanguage.googleapis.com", "registry.npmjs.org"])
        XCTAssertEqual(AgentSandboxRecipe.defaultAllowList(.aider, model: .local(local)), ["pypi.org", "files.pythonhosted.org"])
        for host in AgentSandboxRecipe.defaultAllowList(.gemini, model: .account) {
            XCTAssertNotNil(EgressPolicy.normalize(host), host)
        }
        let policy = EgressPolicy(entries: AgentSandboxRecipe.defaultAllowList(.claude, model: .account))
        XCTAssertTrue(policy.allows(host: "api.anthropic.com", port: 443))
        XCTAssertTrue(policy.allows(host: "claude.ai", port: 443))
        XCTAssertTrue(policy.allows(host: "registry.npmjs.org", port: 443))
        XCTAssertFalse(policy.allows(host: "example.com", port: 443))
    }

    func sandbox(spec: SandboxSpec, state: ContainerRunState, gateway: String = "192.168.70.1") -> Sandbox {
        let options = SandboxPlanner.runOptions(spec, gateway: gateway, subnet: "192.168.70.0/24", hasKey: false)
        let summary = ContainerSummary(id: spec.name, name: spec.name, image: "docker.io/library/" + spec.image, state: state, labels: options.labels)
        return Sandbox(container: summary)!
    }

    func testReuseDecision() throws {
        var profile = AgentProfile(name: "w", tool: .claude, model: .account, workspace: "/work/app", place: .sandbox)
        let spec = try AgentSandboxRecipe.spec(for: profile)
        XCTAssertEqual(AgentSandboxRecipe.action(existing: nil, spec: spec), .create)
        XCTAssertEqual(AgentSandboxRecipe.action(existing: sandbox(spec: spec, state: .running), spec: spec), .reuse)
        XCTAssertEqual(AgentSandboxRecipe.action(existing: sandbox(spec: spec, state: .stopped), spec: spec), .start)
        profile.workspace = "/work/other"
        XCTAssertEqual(AgentSandboxRecipe.action(existing: sandbox(spec: spec, state: .running), spec: try AgentSandboxRecipe.spec(for: profile)), .recreate)
        profile.workspace = "/work/app"
        profile.sandbox.extraHosts = ["github.com"]
        XCTAssertEqual(AgentSandboxRecipe.action(existing: sandbox(spec: spec, state: .running), spec: try AgentSandboxRecipe.spec(for: profile)), .recreate)
    }

    func testSandboxExecCommandPassesKeyByNameOnly() throws {
        let profile = AgentProfile(name: "w", tool: .claude, model: .providerKey(.anthropic), place: .sandbox)
        let spec = try AgentSandboxRecipe.spec(for: profile)
        let box = sandbox(spec: spec, state: .running)
        let command = try AgentSandboxRecipe.terminalCommand(profile, sandbox: box, cliPath: "/usr/local/bin/container")
        XCTAssertTrue(command.hasPrefix(AgentLauncher.keyExport(.anthropic) + "\n"))
        XCTAssertTrue(command.contains("\nexport ANTHROPIC_API_KEY\n/usr/local/bin/container exec --interactive --tty --env ANTHROPIC_API_KEY \(spec.name) /bin/sh -c '"))
        XCTAssertTrue(command.hasSuffix("' deck-agent claude"))
        XCTAssertFalse(command.contains("ANTHROPIC_API_KEY="  + "sk"))
        let script = AgentSandboxRecipe.bootstrapScript(.claude)
        XCTAssertTrue(script.contains("npm install -g --prefix /deck/tools"))
        XCTAssertTrue(script.contains("@anthropic-ai/claude-code"))
        XCTAssertTrue(script.contains("command -v claude"))
        XCTAssertTrue(script.hasSuffix("exec \"$@\""))
        XCTAssertTrue(AgentSandboxRecipe.bootstrapScript(.aider).contains("pip install --quiet --disable-pip-version-check aider-chat"))
    }

    func testSandboxLocalModelGoesThroughRelay() throws {
        let local = AgentLocalModel(server: "Ollama", kind: .ollama, baseURL: "http://127.0.0.1:11434/v1", model: "qwen3:8b")
        let claude = AgentProfile(name: "w", tool: .claude, model: .local(local), place: .sandbox)
        let spec = try AgentSandboxRecipe.spec(for: claude)
        XCTAssertEqual(spec.model?.url.absoluteString, "http://127.0.0.1:11434")
        let box = sandbox(spec: spec, state: .running)
        let parts = try AgentSandboxRecipe.modelParts(claude, sandbox: box)
        XCTAssertEqual(parts.env.first { $0.key == "ANTHROPIC_BASE_URL" }?.value, "http://192.168.70.1:\(SandboxConfig.relayPort)")
        let args = AgentSandboxRecipe.execArguments(container: box.container.id, tool: .claude, parts: parts, secretKeys: [])
        XCTAssertTrue(args.contains("ANTHROPIC_BASE_URL=http://192.168.70.1:\(SandboxConfig.relayPort)"))
        XCTAssertEqual(Array(args.suffix(3)), ["claude", "--model", "qwen3:8b"])

        let codex = AgentProfile(name: "c", tool: .codex, model: .local(local), place: .sandbox)
        let codexParts = try AgentSandboxRecipe.modelParts(codex, sandbox: sandbox(spec: try AgentSandboxRecipe.spec(for: codex), state: .running))
        XCTAssertFalse(codexParts.args.contains("--oss"))
        XCTAssertTrue(codexParts.args.contains { $0.contains("http://192.168.70.1:\(SandboxConfig.relayPort)/v1") })
    }
}
