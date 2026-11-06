import XCTest
@testable import DeckCore

/// Real system checks for Agents and MCP. Off unless DECK_LIVE_MCP=1.
/// - Discovery reads the real agent configs, read only, and checks they are unchanged after.
/// - Writes run against COPIES of the real configs in /tmp.
/// - Keychain round trip with a test item that is removed after.
/// - Real MCP servers in containers (SSE, streamable HTTP, stdio, stdio with a Keychain secret).
final class AgentsLiveTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DECK_LIVE_MCP"] == "1", "Set DECK_LIVE_MCP=1 to run")
    }

    let cli = "/usr/local/bin/container"

    private func hashes(_ paths: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for path in paths {
            if let data = FileManager.default.contents(atPath: path) { out[path] = AgentConfigWriter.hash(String(decoding: data, as: UTF8.self)) }
        }
        return out
    }

    func testRealDiscoveryIsReadOnly() throws {
        let locations = AgentConfigLocations()
        let paths = [locations.claudeJSON, locations.claudeDesktop, locations.cursor, locations.vscodeUser, locations.vscodeSettings,
                     locations.codex, locations.gemini]
        let before = hashes(paths)
        let result = AgentConfigDiscovery(locations: locations).discover()
        // Names and counts only, never values.
        for file in result.files where file.exists {
            print("LIVE MCP file \(file.agent.title): \(file.path) servers=\(file.serverCount) problem=\(file.problem ?? "none")")
        }
        for server in result.servers {
            print("LIVE MCP server \(server.agent.title) [\(server.scope.title)] \(server.name) \(server.transport.title) env=\(server.envKeys.count)")
        }
        print("LIVE MCP projects checked: \(result.projects.count)")
        let after = hashes(paths)
        // ~/.claude.json is rewritten by a running Claude Code session all the time, so only check the others.
        for path in paths where path != locations.claudeJSON {
            XCTAssertEqual(before[path], after[path], path)
        }
    }

    func testWritesOnCopiesOfRealConfigs() throws {
        let real = AgentConfigLocations()
        let home = "/tmp/deck-v2-mcp-copies-\(UUID().uuidString.prefix(6))"
        defer { try? FileManager.default.removeItem(atPath: home) }
        let copy = AgentConfigLocations(home: home)
        let pairs = [(real.claudeJSON, copy.claudeJSON), (real.claudeDesktop, copy.claudeDesktop), (real.cursor, copy.cursor),
                     (real.vscodeUser, copy.vscodeUser), (real.codex, copy.codex), (real.gemini, copy.gemini)]
        for (from, to) in pairs where FileManager.default.fileExists(atPath: from) {
            try FileManager.default.createDirectory(atPath: (to as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: from, toPath: to)
        }
        let writer = AgentConfigWriter(locations: copy, backupsFolder: URL(fileURLWithPath: home + "/backups"))
        let entry = MCPServerEntry.stdio("deck-v2-mcp-live", command: cli, args: ["run", "--interactive", "--rm", "mcp/time"])
        for agent in AgentKind.allCases {
            let path = copy.file(for: agent, scope: .user)
            let before = FileManager.default.contents(atPath: path)
            let plan = try writer.planConnect(entry, agent: agent)
            let record = try writer.apply(plan)
            // Only our server was added: everything else reads the same.
            if !agent.isTOML, let before {
                let key = agent.serversPath(scope: .user)[0]
                let original = try JSONCEditor(text: String(decoding: before, as: UTF8.self)).foundationValue() as? [String: Any] ?? [:]
                var after = try JSONCEditor(text: plan.updated).foundationValue() as? [String: Any] ?? [:]
                var servers = after[key] as? [String: Any] ?? [:]
                servers["deck-v2-mcp-live"] = nil
                after[key] = servers.isEmpty && original[key] == nil ? nil : servers
                XCTAssertTrue(NSDictionary(dictionary: after).isEqual(to: original), agent.title)
            }
            print("LIVE MCP copy \(agent.title): \(plan.action.rawValue), \(plan.diff.filter { $0.kind == .added }.count) lines added, \(plan.diff.filter { $0.kind == .removed }.count) removed")
            try writer.undo(record)
            XCTAssertEqual(FileManager.default.contents(atPath: path), before, agent.title)
        }
    }

    func testKeychainRoundTrip() async throws {
        let store = KeychainSecretStore()
        let service = "deck-v2-mcp-live-test"
        let secret = "sk-" + String(repeating: "x", count: 240)
        try await store.set(secret, service: service, account: "probe")
        defer { Task { try? await store.delete(service: service, account: "probe") } }
        XCTAssertTrue(store.contains(service: service, account: "probe"))
        let read = try await store.value(service: service, account: "probe")
        XCTAssertEqual(read, secret)
        try await store.delete(service: service, account: "probe")
        XCTAssertFalse(store.contains(service: service, account: "probe"))
    }

    func testSSEServerInContainer() async throws {
        let client = ContainerClient(cliPath: cli)
        let port = MCPLaunch.freePort(startingAt: 18_390, used: [])
        let server = MCPInstalledServer(name: "deck-v2-mcp-sse", image: "mcp/everything", transport: .sse,
                                        command: ["node", "dist/sse.js"], containerPort: 3001, hostPort: port, path: "/sse")
        try await client.startMCPServer(server)
        defer { Task { try? await client.stopMCPServer(server) } }
        let url = try XCTUnwrap(MCPLaunch.url(server).flatMap(URL.init(string:)))
        var result: MCPHandshakeResult?
        for _ in 0..<20 {
            result = try? await MCPHandshake.sse(url: url)
            if result != nil { break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        let answer = try XCTUnwrap(result)
        print("LIVE MCP sse: \(answer.summary) protocol \(answer.protocolVersion) in \(answer.milliseconds) ms")
        XCTAssertEqual(answer.serverName, "example-servers/everything")
        XCTAssertGreaterThan(answer.toolCount ?? 0, 0)
        try await client.stopMCPServer(server)
    }

    func testStreamableHTTPServerInContainer() async throws {
        // A tiny streamable HTTP MCP server, written here so the test runs on any machine.
        let folder = "/tmp/deck-v2-mcp-srv-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try Self.tinyServerScript.write(toFile: folder + "/server.js", atomically: true, encoding: .utf8)
        let client = ContainerClient(cliPath: cli)
        let port = MCPLaunch.freePort(startingAt: 18_395, used: [])
        let server = MCPInstalledServer(name: "deck-v2-mcp-http", image: "mcp/everything", transport: .http,
                                        command: ["node", "/srv/server.js"], containerPort: 8000, hostPort: port, path: "/mcp",
                                        secretKeys: ["DECK_TEST_SECRET"],
                                        mounts: [MountSpec(kind: .bind, source: folder, destination: "/srv", readOnly: true)])
        try await client.startMCPServer(server, secrets: ["DECK_TEST_SECRET": "abc"])
        defer { Task { try? await client.stopMCPServer(server) } }
        let url = try XCTUnwrap(MCPLaunch.url(server).flatMap(URL.init(string:)))
        var result: MCPHandshakeResult?
        for _ in 0..<20 {
            result = try? await MCPHandshake.http(url: url)
            if result != nil { break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        let answer = try XCTUnwrap(result)
        print("LIVE MCP http: \(answer.summary) protocol \(answer.protocolVersion) in \(answer.milliseconds) ms")
        XCTAssertEqual(answer.serverName, "deck-tiny")
        XCTAssertEqual(answer.toolCount, 2)
        // The secret reached the container through the env file.
        let env = try await client.exec(MCPLaunch.containerName(server), ["printenv", "DECK_TEST_SECRET"])
        XCTAssertEqual(env.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "abc")
        try await client.stopMCPServer(server)
        let list = try await client.listContainers()
        XCTAssertFalse(list.contains { $0.name == MCPLaunch.containerName(server) })
    }

    func testStdioServerAsAgentWouldSpawnIt() async throws {
        let server = MCPInstalledServer(name: "deck-v2-mcp-time", image: "mcp/time", transport: .stdio)
        let entry = MCPLaunch.entry(server, cliPath: cli)
        let answer = try await MCPHandshake.stdio(executable: try XCTUnwrap(entry.command), arguments: entry.args, environment: entry.env)
        print("LIVE MCP stdio: \(answer.summary) in \(answer.milliseconds) ms")
        XCTAssertEqual(answer.serverName, "mcp-time")
        XCTAssertGreaterThan(answer.toolCount ?? 0, 0)
    }

    func testStdioServerWithKeychainSecret() async throws {
        let store = KeychainSecretStore()
        let server = MCPInstalledServer(name: "deck-v2-mcp-secret", image: "mcp/time", transport: .stdio, secretKeys: ["DECK_TEST_SECRET"])
        let account = MCPLaunch.secretAccount(server: server.name, key: "DECK_TEST_SECRET")
        try await store.set("from-keychain", service: AgentsConfig.secretService, account: account)
        defer { Task { try? await store.delete(service: AgentsConfig.secretService, account: account) } }
        let entry = MCPLaunch.entry(server, cliPath: cli)
        XCTAssertEqual(entry.command, "/bin/sh")
        XCTAssertFalse(entry.args.joined().contains("from-keychain"))
        let answer = try await MCPHandshake.stdio(executable: "/bin/sh", arguments: entry.args, environment: entry.env)
        XCTAssertEqual(answer.serverName, "mcp-time")
        try await store.delete(service: AgentsConfig.secretService, account: account)
    }

    func testRealToolDetection() async {
        let tools = await AgentToolDetector().detect()
        for tool in tools where tool.installed {
            print("LIVE MCP tool \(tool.tool.title) \(tool.version ?? "") signIn=\(tool.signIn == nil ? "no" : "yes")")
        }
        let endpoints = await ProbingModelEndpointSource().endpoints()
        for endpoint in endpoints { print("LIVE MCP model endpoint \(endpoint.name) \(endpoint.baseURL) models=\(endpoint.models.count)") }
    }

    /// Answers initialize (name "deck-tiny"), notifications (202), tools/list (2 tools) and DELETE.
    static let tinyServerScript = #"""
    const http = require("http");
    http.createServer((req, res) => {
      if (req.method === "DELETE") { res.writeHead(200); return res.end(); }
      let body = "";
      req.on("data", c => body += c);
      req.on("end", () => {
        let msg = {};
        try { msg = JSON.parse(body || "{}"); } catch (e) { res.writeHead(400); return res.end(); }
        if (msg.id === undefined) { res.writeHead(202); return res.end(); }
        let result = {};
        if (msg.method === "initialize") {
          result = { protocolVersion: (msg.params && msg.params.protocolVersion) || "2025-03-26",
                     capabilities: { tools: {} }, serverInfo: { name: "deck-tiny", version: "1.0.0" } };
        } else if (msg.method === "tools/list") {
          result = { tools: [
            { name: "echo", description: "Echo", inputSchema: { type: "object" } },
            { name: "time", description: "Time", inputSchema: { type: "object" } } ] };
        }
        res.writeHead(200, { "Content-Type": "application/json", "Mcp-Session-Id": "deck-tiny-1" });
        res.end(JSON.stringify({ jsonrpc: "2.0", id: msg.id, result }));
      });
    }).listen(8000, "0.0.0.0");
    """#
}
