import XCTest
@testable import DeckCore

/// JSON and TOML patching, entry formats and diffs. Pure, no files.
final class AgentsConfigEditTests: XCTestCase {

    // MARK: JSONC editor

    func testAddKeepsEverythingElseByteForByte() throws {
        let original = """
        {
          "numStartups": 12,
          "theme": "dark",
          "mcpServers": {
            "old": {
              "command": "old-server"
            }
          },
          "projects": {"/a": {"allowedTools": []}}
        }

        """
        var editor = JSONCEditor(text: original)
        try editor.set(.object([("type", .string("http")), ("url", .string("http://127.0.0.1:1/mcp"))]), forKey: "new", in: ["mcpServers"])
        let expected = """
        {
          "numStartups": 12,
          "theme": "dark",
          "mcpServers": {
            "old": {
              "command": "old-server"
            },
            "new": {
              "type": "http",
              "url": "http://127.0.0.1:1/mcp"
            }
          },
          "projects": {"/a": {"allowedTools": []}}
        }

        """
        XCTAssertEqual(editor.text, expected)
    }

    func testCreatesMissingObjectsOnThePath() throws {
        var editor = JSONCEditor(text: "{\n    \"a\": 1\n}\n")
        try editor.set(.object([("command", .string("x"))]), forKey: "srv", in: ["mcpServers"])
        XCTAssertEqual(editor.text, """
        {
            "a": 1,
            "mcpServers": {
                "srv": {
                    "command": "x"
                }
            }
        }

        """)
    }

    func testEmptyFileAndEmptyObject() throws {
        var empty = JSONCEditor(text: "")
        try empty.set(.object([("command", .string("x")), ("args", .array([]))]), forKey: "s", in: ["servers"])
        XCTAssertEqual(empty.text, "{\n  \"servers\": {\n    \"s\": {\n      \"command\": \"x\",\n      \"args\": []\n    }\n  }\n}\n")

        var braces = JSONCEditor(text: "{\n  \"mcpServers\": {}\n}\n")
        try braces.set(.object([("command", .string("x"))]), forKey: "s", in: ["mcpServers"])
        XCTAssertEqual(braces.text, "{\n  \"mcpServers\": {\n    \"s\": {\n      \"command\": \"x\"\n    }\n  }\n}\n")
    }

    func testReplaceOnlyTouchesTheValue() throws {
        let original = "{\n  \"mcpServers\": {\n    \"a\": {\"command\": \"one\"},\n    \"b\": {\"command\": \"two\"}\n  },\n  \"z\": true\n}"
        var editor = JSONCEditor(text: original)
        try editor.set(.object([("command", .string("three"))]), forKey: "a", in: ["mcpServers"])
        XCTAssertEqual(editor.text, "{\n  \"mcpServers\": {\n    \"a\": {\n      \"command\": \"three\"\n    },\n    \"b\": {\"command\": \"two\"}\n  },\n  \"z\": true\n}")
    }

    func testCommentsAndTrailingCommasSurvive() throws {
        let original = """
        {
          // editor settings
          "editor.fontSize": 13,
          /* block */
          "mcp": {
            "servers": {
              "one": { "type": "stdio", "command": "a" },
            },
          },
        }
        """
        var editor = JSONCEditor(text: original)
        let servers = try editor.object(at: ["mcp", "servers"])
        XCTAssertEqual(servers?.keys.sorted(), ["one"])
        try editor.set(.object([("type", .string("stdio")), ("command", .string("b"))]), forKey: "two", in: ["mcp", "servers"])
        XCTAssertTrue(editor.text.contains("// editor settings"))
        XCTAssertTrue(editor.text.contains("/* block */"))
        XCTAssertEqual(try editor.object(at: ["mcp", "servers"])?.keys.sorted(), ["one", "two"])
        try editor.remove(key: "two", in: ["mcp", "servers"])
        XCTAssertEqual(editor.text, original)
    }

    func testRemoveFirstMiddleLastAndOnly() throws {
        let base = "{\n  \"s\": {\n    \"a\": 1,\n    \"b\": 2,\n    \"c\": 3\n  }\n}\n"
        var first = JSONCEditor(text: base)
        XCTAssertTrue(try first.remove(key: "a", in: ["s"]))
        XCTAssertEqual(first.text, "{\n  \"s\": {\n    \"b\": 2,\n    \"c\": 3\n  }\n}\n")
        var middle = JSONCEditor(text: base)
        try middle.remove(key: "b", in: ["s"])
        XCTAssertEqual(middle.text, "{\n  \"s\": {\n    \"a\": 1,\n    \"c\": 3\n  }\n}\n")
        var last = JSONCEditor(text: base)
        try last.remove(key: "c", in: ["s"])
        XCTAssertEqual(last.text, "{\n  \"s\": {\n    \"a\": 1,\n    \"b\": 2\n  }\n}\n")
        var only = JSONCEditor(text: "{\"s\": {\"a\": 1}}")
        try only.remove(key: "a", in: ["s"])
        XCTAssertEqual(only.text, "{\"s\": {}}")
        var missing = JSONCEditor(text: base)
        XCTAssertFalse(try missing.remove(key: "zz", in: ["s"]))
        XCTAssertEqual(missing.text, base)
    }

    func testAddThenRemoveRoundTrips() throws {
        let original = "{\n\t\"mcpServers\": {\n\t\t\"x\": {\"command\": \"y\"}\n\t},\n\t\"other\": [1, 2]\n}\n"
        var editor = JSONCEditor(text: original)
        try editor.set(.object([("url", .string("u"))]), forKey: "näme \"q\"", in: ["mcpServers"])
        XCTAssertTrue(editor.text.contains("\t\t\"näme \\\"q\\\"\": {\n\t\t\t\"url\": \"u\"\n\t\t}"))
        try editor.remove(key: "näme \"q\"", in: ["mcpServers"])
        XCTAssertEqual(editor.text, original)
    }

    func testBadJSONIsReported() {
        var editor = JSONCEditor(text: "{\n  \"a\": 1,\n  \"b\" 2\n}")
        XCTAssertThrowsError(try editor.set(.null, forKey: "c", in: [])) { error in
            XCTAssertEqual(error as? JSONCError, .syntax("Expected :", line: 3))
        }
        var notObject = JSONCEditor(text: "{\"mcpServers\": []}")
        XCTAssertThrowsError(try notObject.set(.null, forKey: "c", in: ["mcpServers"]))
    }

    func testKeyWithLocalProjectPath() throws {
        var editor = JSONCEditor(text: "{\"projects\": {\"/Users/me/app\": {\"history\": []}}}")
        try editor.set(.object([("command", .string("x"))]), forKey: "s", in: ["projects", "/Users/me/app", "mcpServers"])
        let servers = try editor.object(at: ["projects", "/Users/me/app", "mcpServers"])
        XCTAssertNotNil(servers?["s"])
        XCTAssertNotNil(try editor.object(at: ["projects", "/Users/me/app"])?["history"])
    }

    // MARK: TOML editor

    let codexConfig = """
    model = "gpt-5"

    [plugins."github@openai-curated"]
    enabled = true

    [mcp_servers.graft]
    command = "graft"
    args = ["mcp"]

    [mcp_servers.docs]
    command = "npx"
    args = [
      "-y",
      "@example/docs-mcp",
    ]
    startup_timeout_sec = 20

    [mcp_servers.docs.env]
    LOG_LEVEL = "info"

    # keep me
    [mcp_servers."web tools"]
    url = "https://mcp.example.com/mcp"
    http_headers = { "X-Region" = "us-east-1" }
    enabled = false

    [profiles.fast]
    model = "gpt-5-mini"

    """

    func testReadsCodexServers() {
        let servers = TOMLEditor(text: codexConfig).mcpServers()
        XCTAssertEqual(servers.map(\.name), ["graft", "docs", "web tools"])
        let docs = AgentEntryFormat.parse(name: "docs", toml: servers[1].values)
        XCTAssertEqual(docs?.args, ["-y", "@example/docs-mcp"])
        XCTAssertEqual(docs?.env, ["LOG_LEVEL": "info"])
        let web = AgentEntryFormat.parse(name: "web tools", toml: servers[2].values)
        XCTAssertEqual(web?.transport, .http)
        XCTAssertEqual(web?.headers, ["X-Region": "us-east-1"])
        XCTAssertEqual(servers[2].values["enabled"], .bool(false))
    }

    func testAppendsNewServerAndRemovesItAgain() {
        var editor = TOMLEditor(text: codexConfig)
        editor.setServer("deck-time", values: [("command", .string("/usr/local/bin/container")), ("args", .array([.string("run"), .string("-i")]))])
        XCTAssertTrue(editor.text.hasPrefix(codexConfig))
        XCTAssertTrue(editor.text.hasSuffix("\n\n[mcp_servers.deck-time]\ncommand = \"/usr/local/bin/container\"\nargs = [\"run\", \"-i\"]\n"))
        XCTAssertTrue(editor.removeServer("deck-time"))
        XCTAssertEqual(editor.text, codexConfig)
    }

    func testReplacesServerInPlaceWithSubTables() {
        var editor = TOMLEditor(text: codexConfig)
        editor.setServer("docs", values: [("url", .string("http://127.0.0.1:9/mcp"))])
        let text = editor.text
        XCTAssertFalse(text.contains("@example/docs-mcp"))
        XCTAssertFalse(text.contains("LOG_LEVEL"))
        XCTAssertTrue(text.contains("[mcp_servers.docs]\nurl = \"http://127.0.0.1:9/mcp\"\n\n# keep me\n[mcp_servers.\"web tools\"]"))
        XCTAssertTrue(text.contains("[profiles.fast]\nmodel = \"gpt-5-mini\""))
        XCTAssertTrue(text.contains("[mcp_servers.graft]\ncommand = \"graft\"\nargs = [\"mcp\"]\n"))
        XCTAssertEqual(TOMLEditor(text: text).mcpServers().map(\.name), ["graft", "docs", "web tools"])
    }

    func testRemoveQuotedServerKeepsComment() {
        var editor = TOMLEditor(text: codexConfig)
        XCTAssertTrue(editor.removeServer("web tools"))
        XCTAssertFalse(editor.text.contains("mcp.example.com"))
        XCTAssertTrue(editor.text.contains("# keep me"))
        XCTAssertTrue(editor.text.contains("[profiles.fast]"))
        XCTAssertFalse(editor.removeServer("nope"))
    }

    func testHeaderInsideMultilineStringIsIgnored() {
        let text = "[mcp_servers.a]\ncommand = \"\"\"\n[mcp_servers.fake]\n\"\"\"\n"
        XCTAssertEqual(TOMLEditor(text: text).mcpServers().map(\.name), ["a"])
        XCTAssertEqual(TOMLEditor(text: text).mcpServers().first?.values["command"], .string("[mcp_servers.fake]\n"))
    }

    func testTOMLQuotingAndInlineTables() {
        XCTAssertEqual(TOMLEditor.key("plain-name_1"), "plain-name_1")
        XCTAssertEqual(TOMLEditor.key("has space"), "\"has space\"")
        XCTAssertEqual(TOMLEditor.render(.table(["B": .string("x\"y"), "A": .integer(1)])), "{ A = 1, B = \"x\\\"y\" }")
        var editor = TOMLEditor(text: "")
        editor.setServer("n", values: AgentEntryFormat.toml(.stdio("n", command: "c", args: ["a b"], env: ["K": "v"])))
        XCTAssertEqual(editor.text, "[mcp_servers.n]\ncommand = \"c\"\nargs = [\"a b\"]\nenv = { K = \"v\" }\n")
        let read = AgentEntryFormat.parse(name: "n", toml: TOMLEditor(text: editor.text).mcpServers()[0].values)
        XCTAssertEqual(read, .stdio("n", command: "c", args: ["a b"], env: ["K": "v"]))
    }

    // MARK: Entry formats

    func testEntryShapesPerAgent() {
        let stdio = MCPServerEntry.stdio("t", command: "/usr/local/bin/container", args: ["run"], env: ["A": "1"])
        XCTAssertEqual(AgentEntryFormat.json(stdio, for: .claudeCode).render(),
                       "{\n  \"type\": \"stdio\",\n  \"command\": \"/usr/local/bin/container\",\n  \"args\": [\"run\"],\n  \"env\": {\n    \"A\": \"1\"\n  }\n}")
        XCTAssertEqual(AgentEntryFormat.json(stdio, for: .claudeDesktop),
                       .object([("command", .string("/usr/local/bin/container")), ("args", .array([.string("run")])), ("env", .object([("A", .string("1"))]))]))
        XCTAssertEqual(AgentEntryFormat.json(stdio, for: .gemini),
                       .object([("command", .string("/usr/local/bin/container")), ("args", .array([.string("run")])), ("env", .object([("A", .string("1"))]))]))

        let http = MCPServerEntry.remote("h", transport: .http, url: "http://127.0.0.1:1/mcp")
        XCTAssertEqual(AgentEntryFormat.json(http, for: .claudeCode), .object([("type", .string("http")), ("url", .string("http://127.0.0.1:1/mcp"))]))
        XCTAssertEqual(AgentEntryFormat.json(http, for: .vscode), .object([("type", .string("http")), ("url", .string("http://127.0.0.1:1/mcp"))]))
        XCTAssertEqual(AgentEntryFormat.json(http, for: .cursor), .object([("url", .string("http://127.0.0.1:1/mcp"))]))
        XCTAssertEqual(AgentEntryFormat.json(http, for: .gemini), .object([("httpUrl", .string("http://127.0.0.1:1/mcp"))]))
        XCTAssertEqual(AgentEntryFormat.toml(http).map(\.0), ["url"])

        let sse = MCPServerEntry.remote("s", transport: .sse, url: "http://127.0.0.1:2/sse")
        XCTAssertEqual(AgentEntryFormat.json(sse, for: .gemini), .object([("url", .string("http://127.0.0.1:2/sse"))]))
        XCTAssertEqual(AgentEntryFormat.json(sse, for: .claudeCode), .object([("type", .string("sse")), ("url", .string("http://127.0.0.1:2/sse"))]))
        // Claude Desktop and Codex cannot reach SSE directly: bridge.
        XCTAssertTrue(AgentEntryFormat.needsBridge(sse, for: .claudeDesktop))
        XCTAssertTrue(AgentEntryFormat.needsBridge(sse, for: .codex))
        XCTAssertFalse(AgentEntryFormat.needsBridge(http, for: .codex))
        XCTAssertEqual(AgentEntryFormat.adapted(sse, for: .claudeDesktop),
                       .stdio("s", command: "npx", args: ["-y", "mcp-remote", "http://127.0.0.1:2/sse", "--transport", "sse-only"]))
    }

    func testParsesEachAgentShape() {
        let gemini = AgentEntryFormat.parse(name: "g", ["httpUrl": "http://x/mcp", "headers": ["Authorization": "Bearer t"]], agent: .gemini)
        XCTAssertEqual(gemini?.transport, .http)
        XCTAssertEqual(gemini?.headers.keys.sorted(), ["Authorization"])
        XCTAssertEqual(AgentEntryFormat.parse(name: "g", ["url": "http://x/sse"], agent: .gemini)?.transport, .sse)
        XCTAssertEqual(AgentEntryFormat.parse(name: "c", ["url": "https://x/mcp"], agent: .cursor)?.transport, .http)
        XCTAssertEqual(AgentEntryFormat.parse(name: "v", ["type": "sse", "url": "http://x"], agent: .vscode)?.transport, .sse)
        XCTAssertEqual(AgentEntryFormat.parse(name: "v", ["type": "streamable-http", "url": "http://x"], agent: .claudeCode)?.transport, .http)
        XCTAssertNil(AgentEntryFormat.parse(name: "bad", ["foo": 1], agent: .claudeCode))
    }

    func testMasksSecretsInTargets() {
        let entry = MCPServerEntry.stdio("x", command: "srv", args: ["--api-key", "abc", "--token=xyz", "sk-1234567890abcdef", "KEY=1", "--port", "80"])
        XCTAssertEqual(entry.target, "srv --api-key •••• --token=•••• •••• •••• --port 80")
    }

    // MARK: Diff

    func testLineDiffShowsOnlyChangesWithContext() {
        let old = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"
        var lines = (1...20).map { "line \($0)" }
        lines.insert("new line", at: 10)
        let diff = LineDiff.diff(old, lines.joined(separator: "\n") + "\n", context: 2)
        XCTAssertEqual(diff.map(\.kind), [.gap, .same, .same, .added, .same, .same, .gap])
        XCTAssertEqual(diff[3].text, "new line")
        XCTAssertEqual(diff[3].number, 11)
        XCTAssertTrue(LineDiff.diff("a\n", "a\n").isEmpty)
        XCTAssertEqual(LineDiff.diff("", "x\n").map(\.kind), [.added])
    }
}
