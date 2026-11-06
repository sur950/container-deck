import XCTest
@testable import DeckCore

/// Discovery, writes with backup and undo, launch lines, handshake parsing and keys.
/// Every file here lives in a fresh folder under /tmp. Real agent configs are never touched.
final class AgentsDiscoveryWriterTests: XCTestCase {
    var home: String = ""
    var backups: URL!

    override func setUpWithError() throws {
        home = "/tmp/deck-v2-mcp-tests-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        backups = URL(fileURLWithPath: home).appendingPathComponent("backups")
    }

    override func tearDownWithError() throws {
        XCTAssertTrue(home.hasPrefix("/tmp/deck-v2-mcp-tests-"))
        try? FileManager.default.removeItem(atPath: home)
    }

    func write(_ relative: String, _ text: String, mode: Int = 0o644) throws {
        let path = (home as NSString).appendingPathComponent(relative)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }

    func read(_ relative: String) -> String? {
        try? String(contentsOfFile: (home as NSString).appendingPathComponent(relative), encoding: .utf8)
    }

    var project: String { (home as NSString).appendingPathComponent("work/app") }

    func makeFixtureHome() throws {
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        try write(".claude.json", """
        {
          "numStartups": 3,
          "oauthAccount": {"emailAddress": "me@example.com"},
          "mcpServers": {
            "user-http": {"type": "http", "url": "https://api.example.com/mcp", "headers": {"Authorization": "Bearer SECRET"}}
          },
          "projects": {
            "\(project)": {
              "mcpServers": {"local-one": {"type": "stdio", "command": "npx", "args": ["-y", "pkg", "--api-key", "SECRET"], "env": {"TOKEN": "SECRET"}}}
            },
            "/gone/folder": {}
          }
        }
        """, mode: 0o600)
        try write("work/app/.mcp.json", #"{"mcpServers": {"shared": {"command": "/usr/local/bin/container", "args": ["run", "--interactive", "--rm", "--label", "deck.mcp=time", "mcp/time"]}}}"#)
        try write("work/app/.vscode/mcp.json", #"{"servers": {"pw": {"type": "stdio", "command": "npx", "args": ["@playwright/mcp"]}}}"#)
        try write("Library/Application Support/Claude/claude_desktop_config.json", #"{"mcpServers": {}, "preferences": {"x": 1}}"#)
        try write("Library/Application Support/Code/User/settings.json", "{\n  // comment\n  \"mcp\": {\"servers\": {\"old\": {\"type\": \"sse\", \"url\": \"http://localhost:9/sse\"}}},\n}\n")
        try write(".codex/config.toml", "[mcp_servers.graft]\ncommand = \"graft\"\nargs = [\"mcp\"]\n")
        try write(".gemini/settings.json", #"{"mcpServers": {"g": {"httpUrl": "http://localhost:3000/mcp"}}, "theme": "x"}"#)
        try write(".cursor/mcp.json", "{ broken")
    }

    // MARK: Discovery

    func testDiscoversEveryAgentWithoutSecrets() throws {
        try makeFixtureHome()
        let result = AgentConfigDiscovery(locations: AgentConfigLocations(home: home)).discover()
        let names = Set(result.servers.map { "\($0.agent.rawValue):\($0.name)" })
        XCTAssertEqual(names, ["claudeCode:user-http", "claudeCode:local-one", "claudeCode:shared", "vscode:pw", "vscode:old", "codex:graft", "gemini:g"])
        let local = try XCTUnwrap(result.servers.first { $0.name == "local-one" })
        XCTAssertEqual(local.scope, .local(project))
        XCTAssertEqual(local.envKeys, ["TOKEN"])
        XCTAssertFalse(local.target.contains("SECRET"))
        let user = try XCTUnwrap(result.servers.first { $0.name == "user-http" })
        XCTAssertEqual(user.headerKeys, ["Authorization"])
        XCTAssertEqual(result.servers.first { $0.name == "shared" }?.managedServer, "time")
        XCTAssertEqual(result.servers.first { $0.name == "shared" }?.scope, .project(project))
        XCTAssertEqual(result.servers.first { $0.name == "g" }?.transport, .http)
        // Bad file reported, not thrown.
        let cursor = try XCTUnwrap(result.files.first { $0.agent == .cursor })
        XCTAssertNotNil(cursor.problem)
        XCTAssertEqual(result.projects, [project])
        XCTAssertTrue(result.files.contains { $0.agent == .claudeDesktop && $0.exists && $0.serverCount == 0 })
    }

    func testSignInDetectionReadsPresenceOnly() throws {
        try makeFixtureHome()
        try write(".codex/auth.json", #"{"auth_mode": "chatgpt", "OPENAI_API_KEY": null, "tokens": {"id_token": "x"}}"#)
        try write(".gemini/google_accounts.json", #"{"active": "me@gmail.com", "old": []}"#)
        let detector = AgentSignInDetector(home: home)
        XCTAssertEqual(detector.signIn(for: .claude), "Claude account me@example.com")
        XCTAssertEqual(detector.signIn(for: .codex), "ChatGPT account")
        XCTAssertEqual(detector.signIn(for: .gemini), "Google account me@gmail.com")
        XCTAssertNil(detector.signIn(for: .aider))
    }

    // MARK: Writer

    func testConnectWritesBackupAndUndoRestoresBytes() throws {
        try makeFixtureHome()
        let writer = AgentConfigWriter(locations: AgentConfigLocations(home: home), backupsFolder: backups)
        let before = try XCTUnwrap(read(".claude.json"))
        let entry = MCPServerEntry.remote("deck-everything", transport: .sse, url: "http://127.0.0.1:18300/sse")
        let plan = try writer.planConnect(entry, agent: .claudeCode)
        XCTAssertEqual(plan.action, .add)
        XCTAssertFalse(plan.bridged)
        // The last old entry gets a comma (one line changes), then four new lines.
        XCTAssertEqual(plan.diff.filter { $0.kind == .added }.count, 5)
        XCTAssertEqual(plan.diff.filter { $0.kind == .removed }.count, 1)
        // Nothing written by planning.
        XCTAssertEqual(read(".claude.json"), before)

        let record = try writer.apply(plan)
        let after = try XCTUnwrap(read(".claude.json"))
        XCTAssertTrue(after.contains("\"deck-everything\": {\n      \"type\": \"sse\""))
        XCTAssertTrue(after.contains("\"oauthAccount\": {\"emailAddress\": \"me@example.com\"}"))
        let mode = try FileManager.default.attributesOfItem(atPath: home + "/.claude.json")[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        let backup = try XCTUnwrap(record.backupPath)
        XCTAssertEqual(try String(contentsOfFile: backup, encoding: .utf8), before)
        XCTAssertTrue(backup.hasPrefix(backups.path))
        XCTAssertEqual(writer.history().first?.id, record.id)

        try writer.undo(record)
        XCTAssertEqual(read(".claude.json"), before)
        XCTAssertEqual(writer.history().first?.undone, true)
    }

    func testEveryAgentConnectAndDisconnectRoundTrip() throws {
        try makeFixtureHome()
        try write(".cursor/mcp.json", "{\n  \"mcpServers\": {}\n}\n")
        let writer = AgentConfigWriter(locations: AgentConfigLocations(home: home), backupsFolder: backups)
        let entry = MCPServerEntry.stdio("deck-time", command: "/usr/local/bin/container",
                                         args: ["run", "--interactive", "--rm", "--label", "deck.mcp=time", "mcp/time"])
        for agent in AgentKind.allCases {
            let path = AgentConfigLocations(home: home).file(for: agent, scope: .user)
            let before = try? String(contentsOfFile: path, encoding: .utf8)
            try writer.apply(try writer.planConnect(entry, agent: agent))
            let found = AgentConfigDiscovery(locations: AgentConfigLocations(home: home)).discover().servers
            XCTAssertTrue(found.contains { $0.agent == agent && $0.name == "deck-time" && $0.managedServer == "time" }, agent.title)
            // Connecting again is a replace with no change.
            let again = try writer.planConnect(entry, agent: agent)
            XCTAssertEqual(again.action, .replace, agent.title)
            XCTAssertTrue(again.diff.isEmpty, agent.title)
            try writer.apply(try writer.planDisconnect("deck-time", agent: agent))
            let afterText = try? String(contentsOfFile: path, encoding: .utf8)
            if agent == .vscode {
                // The file did not exist: now it holds an empty servers object.
                XCTAssertNil(before)
                XCTAssertEqual(afterText, "{\n  \"servers\": {}\n}\n")
            } else {
                XCTAssertEqual(afterText, before, agent.title)
            }
        }
    }

    func testProjectScopeFiles() throws {
        try makeFixtureHome()
        let locations = AgentConfigLocations(home: home)
        let writer = AgentConfigWriter(locations: locations, backupsFolder: backups)
        let entry = MCPServerEntry.remote("api", transport: .http, url: "http://127.0.0.1:1/mcp")
        let plan = try writer.planConnect(entry, agent: .claudeCode, scope: .project(project))
        XCTAssertEqual(plan.path, project + "/.mcp.json")
        let local = try writer.planConnect(entry, agent: .claudeCode, scope: .local(project))
        XCTAssertEqual(local.path, home + "/.claude.json")
        XCTAssertTrue(local.updated.contains("\"local-one\""))
        XCTAssertEqual(locations.file(for: .vscode, scope: .project(project)), project + "/.vscode/mcp.json")
        XCTAssertEqual(locations.file(for: .codex, scope: .project(project)), project + "/.codex/config.toml")
    }

    func testRefusesStalePreviewAndChangedFileUndo() throws {
        try makeFixtureHome()
        let writer = AgentConfigWriter(locations: AgentConfigLocations(home: home), backupsFolder: backups)
        let entry = MCPServerEntry.stdio("x", command: "c")
        let plan = try writer.planConnect(entry, agent: .gemini)
        try write(".gemini/settings.json", #"{"mcpServers": {}, "theme": "changed"}"#)
        XCTAssertThrowsError(try writer.apply(plan)) { XCTAssertEqual($0 as? AgentConfigWriteError, .fileChanged(plan.path)) }

        let fresh = try writer.planConnect(entry, agent: .gemini)
        let record = try writer.apply(fresh)
        try write(".gemini/settings.json", #"{"edited": "by hand"}"#)
        XCTAssertFalse(writer.isUnchangedSinceWrite(record))
        XCTAssertThrowsError(try writer.undo(record))
        try writer.undo(record, force: true)
        XCTAssertEqual(read(".gemini/settings.json"), #"{"mcpServers": {}, "theme": "changed"}"#)
    }

    func testUndoOfNewFileRemovesIt() throws {
        let writer = AgentConfigWriter(locations: AgentConfigLocations(home: home), backupsFolder: backups)
        let record = try writer.apply(try writer.planConnect(.stdio("x", command: "c"), agent: .cursor))
        XCTAssertNil(record.backupPath)
        XCTAssertNotNil(read(".cursor/mcp.json"))
        try writer.undo(record)
        XCTAssertNil(read(".cursor/mcp.json"))
    }

    func testBrokenFileIsNeverWritten() throws {
        try makeFixtureHome()
        let writer = AgentConfigWriter(locations: AgentConfigLocations(home: home), backupsFolder: backups)
        XCTAssertThrowsError(try writer.planConnect(.stdio("x", command: "c"), agent: .cursor))
        XCTAssertEqual(read(".cursor/mcp.json"), "{ broken")
    }

    func testSymlinkedConfigIsWrittenThroughTheLink() throws {
        try write("dotfiles/gemini.json", #"{"mcpServers": {}}"#)
        try FileManager.default.createDirectory(atPath: home + "/.gemini", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home + "/.gemini/settings.json", withDestinationPath: home + "/dotfiles/gemini.json")
        let writer = AgentConfigWriter(locations: AgentConfigLocations(home: home), backupsFolder: backups)
        try writer.apply(try writer.planConnect(.stdio("x", command: "c"), agent: .gemini))
        let attributes = try FileManager.default.attributesOfItem(atPath: home + "/.gemini/settings.json")
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink)
        XCTAssertTrue(read("dotfiles/gemini.json")?.contains("\"x\"") == true)
    }

    // MARK: Launch lines

    func testStdioLaunchLineAndSecrets() {
        var server = MCPInstalledServer(name: "github", catalogID: "github", image: "ghcr.io/github/github-mcp-server",
                                        transport: .stdio, command: ["stdio"], env: [EnvVar(key: "GITHUB_TOOLSETS", value: "repos")],
                                        mounts: [MountSpec(kind: .bind, source: "/Users/me/code", destination: "/workspace", readOnly: true)])
        var entry = MCPLaunch.entry(server, cliPath: "/usr/local/bin/container")
        XCTAssertEqual(entry.command, "/usr/local/bin/container")
        XCTAssertEqual(entry.args.prefix(7), ["run", "--interactive", "--rm", "--label", "deck.mcp=github", "--label", "deck.mcp.transport=stdio"])
        XCTAssertEqual(entry.args.suffix(4), ["--env", "GITHUB_TOOLSETS", "ghcr.io/github/github-mcp-server", "stdio"])
        XCTAssertEqual(entry.env, ["GITHUB_TOOLSETS": "repos"])
        XCTAssertEqual(MCPLaunch.managedServerName(in: entry), "github")

        server.secretKeys = ["GITHUB_PERSONAL_ACCESS_TOKEN"]
        entry = MCPLaunch.entry(server, cliPath: "/usr/local/bin/container")
        XCTAssertEqual(entry.command, "/bin/sh")
        XCTAssertEqual(entry.args.first, "-c")
        let script = entry.args[1]
        XCTAssertTrue(script.hasPrefix("GITHUB_PERSONAL_ACCESS_TOKEN=\"$(/usr/bin/security find-generic-password -s io.github.sur950.containerdeck.mcp -a github/GITHUB_PERSONAL_ACCESS_TOKEN -w)\" && export GITHUB_PERSONAL_ACCESS_TOKEN && exec /usr/local/bin/container run"))
        XCTAssertTrue(script.contains("--env GITHUB_PERSONAL_ACCESS_TOKEN ghcr.io/github/github-mcp-server stdio"))
        XCTAssertEqual(MCPLaunch.managedServerName(in: entry), "github")
    }

    func testHTTPServerRunArguments() throws {
        let server = MCPInstalledServer(name: "everything", image: "mcp/everything", transport: .sse,
                                        command: ["node", "dist/sse.js"], containerPort: 3001, hostPort: 18300, path: "/sse")
        let client = ContainerClient(cliPath: "/usr/local/bin/container", runner: MockRunner())
        let args = try client.mcpServerRunArguments(server, envFile: "/tmp/x.env")
        XCTAssertEqual(args, ["run", "--detach", "--name", "deck-mcp-everything", "--publish", "127.0.0.1:18300:3001/tcp",
                              "--label", "deck.mcp=everything", "--label", "deck.mcp.transport=sse",
                              "--env-file", "/tmp/x.env", "mcp/everything", "node", "dist/sse.js"])
        XCTAssertEqual(MCPLaunch.url(server), "http://127.0.0.1:18300/sse")
        XCTAssertEqual(MCPLaunch.entry(server, cliPath: "x"), .remote("everything", transport: .sse, url: "http://127.0.0.1:18300/sse"))
        XCTAssertThrowsError(try MCPLaunch.runOptions(MCPInstalledServer(name: "bad name", transport: .http, containerPort: 1, hostPort: 2)))
    }

    func testNamesAndPorts() {
        XCTAssertTrue(MCPLaunch.isValidName("deck_time-2"))
        XCTAssertFalse(MCPLaunch.isValidName("-x"))
        XCTAssertFalse(MCPLaunch.isValidName("a b"))
        XCTAssertEqual(MCPLaunch.suggestedName("Sequential Thinking"), "sequential-thinking")
        XCTAssertEqual(MCPLaunch.freePort(startingAt: 100, used: [100, 101], isFree: { $0 != 102 }), 103)
        XCTAssertEqual(MCPLaunch.shellQuote("it's"), "'it'\\''s'")
    }

    func testRegistrySavesAndLoads() throws {
        let registry = MCPServerRegistry(file: URL(fileURLWithPath: home + "/servers.json"))
        let server = MCPInstalledServer(name: "time", image: "mcp/time", transport: .stdio, secretKeys: ["K"])
        try registry.save([server])
        XCTAssertEqual(registry.load().first?.name, "time")
        XCTAssertFalse(try String(contentsOfFile: home + "/servers.json", encoding: .utf8).contains("value\": \"secret"))
    }

    // MARK: Handshake parsing

    func testHandshakeMessageParsing() throws {
        let sse = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-06-18\",\"serverInfo\":{\"name\":\"demo\",\"version\":\"1.2\"}}}\n\n"
        let message = try XCTUnwrap(MCPHandshake.message(id: 1, in: Data(sse.utf8), contentType: "text/event-stream"))
        let (name, version, proto) = try MCPHandshake.parseInitialize(message)
        XCTAssertEqual([name, version, proto], ["demo", "1.2", "2025-06-18"])
        let json = #"{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"a"},{"name":"b"}]}}"#
        XCTAssertEqual(MCPHandshake.toolCount(MCPHandshake.message(id: 2, in: Data(json.utf8), contentType: "application/json")), 2)
        XCTAssertThrowsError(try MCPHandshake.parseInitialize(["error": ["message": "nope"]])) {
            XCTAssertEqual($0 as? MCPHandshakeError, .serverError("nope"))
        }
        XCTAssertEqual(MCPHandshake.sseDataPayloads("data: a\ndata: b\n\ndata: c\n"), ["a\nb", "c"])
    }

    func testStdioHandshakeWithAFakeServer() async throws {
        // A tiny stdio "server" in sh that answers the two requests.
        let script = """
        read line; echo '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","serverInfo":{"name":"fake","version":"0.1"}}}'
        read note; read list; echo '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"t"}]}}'
        """
        let result = try await MCPHandshake.stdio(executable: "/bin/sh", arguments: ["-c", script], timeout: 10)
        XCTAssertEqual(result.serverName, "fake")
        XCTAssertEqual(result.toolCount, 1)
        do {
            _ = try await MCPHandshake.stdio(executable: "/bin/sh", arguments: ["-c", "echo boom >&2; exit 1"], timeout: 10)
            XCTFail("should fail")
        } catch let error as MCPHandshakeError {
            XCTAssertEqual(error, .exited("boom"))
        }
    }

    // MARK: Keys and local agents

    func testHostedKeysInjectOnlySavedKeys() async throws {
        let memory = MemorySecretStore()
        let keys = HostedKeyStore(store: memory)
        XCTAssertTrue(keys.savedProviders().isEmpty)
        try await keys.save("  sk-ant-test  ", for: .anthropic)
        XCTAssertEqual(keys.savedProviders(), [.anthropic])
        let env = try await keys.environment(for: [.anthropic, .openai])
        XCTAssertEqual(env, [EnvVar(key: "ANTHROPIC_API_KEY", value: "sk-ant-test")])
        do {
            try await keys.save("two\nlines", for: .openai)
            XCTFail("should fail")
        } catch {}
        try await keys.remove(.anthropic)
        XCTAssertFalse(keys.hasKey(.anthropic))
    }

    func testLocalModelRecipes() {
        let ollama = AgentModelEndpoint(name: "Ollama", kind: .ollama, baseURL: "http://127.0.0.1:11434/v1", models: ["qwen3:8b"])
        XCTAssertEqual(LocalAgentRecipe.command(.aider, endpoint: ollama, model: "qwen3:8b"),
                       "OLLAMA_API_BASE=http://127.0.0.1:11434 aider --model ollama_chat/qwen3:8b")
        XCTAssertEqual(LocalAgentRecipe.command(.codex, endpoint: ollama, model: "qwen3:8b"), "codex --oss -m qwen3:8b")
        XCTAssertNotNil(LocalAgentRecipe.command(.claude, endpoint: ollama, model: "qwen3:8b"))
        let mlx = AgentModelEndpoint(name: "MLX", kind: .mlx, baseURL: "http://127.0.0.1:8080/v1", models: [])
        XCTAssertNil(LocalAgentRecipe.command(.claude, endpoint: mlx, model: "m"))
        XCTAssertEqual(LocalAgentRecipe.command(.goose, endpoint: mlx, model: "m"),
                       "GOOSE_PROVIDER=openai OPENAI_HOST=http://127.0.0.1:8080 OPENAI_API_KEY=local GOOSE_MODEL=m goose session")
        XCTAssertFalse(LocalAgentRecipe.supports(.gemini, endpoint: ollama))
        XCTAssertEqual(ProbingModelEndpointSource.modelIDs(Data(#"{"data":[{"id":"b"},{"id":"a"}]}"#.utf8)), ["a", "b"])
    }

    func testToolDetectorFindsFakeBinaries() async throws {
        try write("bin/claude", "#!/bin/sh\necho '2.1.3 (Claude Code)'\n", mode: 0o755)
        try write("Apps/Cursor.app/Contents/Info.plist", "<plist/>")
        let detector = AgentToolDetector(home: home, pathEnv: home + "/bin", applicationFolders: [home + "/Apps"], runner: ProcessRunner())
        let found = await detector.detect()
        XCTAssertEqual(found.first { $0.tool == .claude }?.version, "2.1.3")
        XCTAssertEqual(found.first { $0.tool == .cursorApp }?.installed, true)
    }
}
