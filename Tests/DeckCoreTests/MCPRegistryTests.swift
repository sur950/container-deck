import XCTest
@testable import DeckCore

final class MCPRegistryTests: XCTestCase {
    func page() throws -> MCPRegistryPage {
        try MCPRegistryClient.parseRegistry(Data(MCPRegistryFixtures.registryPage.utf8))
    }

    func server(_ name: String) throws -> MCPRegistryServer {
        try XCTUnwrap(try page().servers.first { $0.name == name }, name)
    }

    func testURLs() {
        let first = MCPRegistryClient.registryURL("  github ", cursor: nil).absoluteString
        XCTAssertEqual(first, "https://registry.modelcontextprotocol.io/v0.1/servers?limit=30&version=latest&search=github")
        // The registry needs 3 letters to search, so shorter text lists everything.
        XCTAssertFalse(MCPRegistryClient.registryURL("gi", cursor: nil).absoluteString.contains("search="))
        let next = MCPRegistryClient.registryURL("postgres", cursor: "io.github.x/y:1.0.0").absoluteString
        XCTAssertTrue(next.contains("cursor=io.github.x/y:1.0.0"), next)
        XCTAssertEqual(MCPRegistryClient.dockerURL("git", page: 2).absoluteString,
                       "https://hub.docker.com/v2/repositories/mcp/?page=2&page_size=30&ordering=pull_count&name=git")
        XCTAssertFalse(MCPRegistryClient.dockerURL("", page: 1).absoluteString.contains("name="))
    }

    func testParseRegistryPage() throws {
        let page = try page()
        XCTAssertEqual(page.servers.count, 5)
        XCTAssertEqual(page.nextCursor, "io.github.edelciomolina/postgres-mcp:1.7.0")
        XCTAssertNil(page.total)
        XCTAssertNotNil(page.servers.first?.updated)

        let card = try server("com.githubcard/mcp")
        XCTAssertEqual(card.displayTitle, "GitHubCard")
        XCTAssertEqual(card.publisher, "com.githubcard")
        XCTAssertEqual(card.version, "0.2.1")
        XCTAssertEqual(card.homepage, "https://githubcard.com")
        let npm = try XCTUnwrap(card.packages.first)
        XCTAssertEqual(npm.kind, .npm)
        XCTAssertEqual(npm.identifier, "@ghcardhq/ghcard")
        XCTAssertEqual(npm.packageArguments, ["mcp"])
        XCTAssertEqual(npm.environment.first?.name, "GHCARD_API_KEY")
        XCTAssertEqual(npm.environment.first?.isSecret, true)
        XCTAssertEqual(card.remotes.first?.transport, .http)
        XCTAssertEqual(card.remotes.first?.headers.first?.name, "Authorization")
        XCTAssertEqual(card.transports, [.stdio, .http])

        let waystation = try server("ai.waystation/postgres")
        XCTAssertEqual(waystation.displayTitle, "postgres")
        XCTAssertEqual(waystation.remotes.map(\.transport), [.http, .sse])
        XCTAssertEqual(waystation.homepage, "https://github.com/waystation-ai/mcp")
    }

    func testInstallOptionsPreferContainers() throws {
        let armory = try server("com.mcparmory/github")
        XCTAssertEqual(armory.installOptions.map(\.title), ["Container", "PyPI"])
        let ugt = try server("com.usegithubthing/ugt")
        XCTAssertFalse(ugt.packages[0].isSupported)
        XCTAssertFalse(ugt.isInstallable)
    }

    func testNpmRunsWithNpxInNodeImage() throws {
        let card = try server("com.githubcard/mcp")
        guard case .package(let npm)? = card.installOptions.first(where: { $0.title == "npm" }) else { return XCTFail("no npm") }
        let item = try XCTUnwrap(MCPRegistryInstall.catalogItem(card, option: .package(npm)))
        XCTAssertEqual(item.image, "node:22-slim")
        XCTAssertEqual(item.command, ["npx", "-y", "@ghcardhq/ghcard@0.2.1", "mcp"])
        XCTAssertEqual(item.transport, .stdio)
        XCTAssertNil(item.containerPort)
        XCTAssertEqual(item.fields.first?.key, "GHCARD_API_KEY")
        XCTAssertEqual(item.fields.first?.secret, true)
        XCTAssertEqual(item.defaultServerName, "githubcard")
        XCTAssertEqual(item.fields.first?.label, "Ghcard API key")
        XCTAssertEqual(MCPRegistryInstall.label("DATABASE_URL"), "Database URL")
        XCTAssertEqual(item.id, "registry:com.githubcard/mcp")
    }

    func testPypiRunsWithUvx() throws {
        let armory = try server("com.mcparmory/github")
        let pypi = try XCTUnwrap(armory.packages.first { $0.kind == .pypi })
        let item = try XCTUnwrap(MCPRegistryInstall.catalogItem(armory, option: .package(pypi)))
        XCTAssertEqual(item.image, MCPRegistryInstall.pythonImage)
        XCTAssertEqual(item.command, ["uvx", "mcparmory-github==1.0.6"])
        XCTAssertEqual(item.defaultServerName, "github")
    }

    func testOCIImageRunsDirectlyAndHTTPGetsAPort() throws {
        let armory = try server("com.mcparmory/github")
        let oci = try XCTUnwrap(armory.packages.first { $0.kind == .oci })
        XCTAssertEqual(MCPRegistryInstall.run(oci)?.image, "ghcr.io/mcparmory/github:1.0.6")

        let hardened = try server("io.github.Eszetael/postgres-mcp-hardened")
        let http = try XCTUnwrap(hardened.packages.first { $0.kind == .oci })
        XCTAssertEqual(http.transport, .http)
        let item = try XCTUnwrap(MCPRegistryInstall.catalogItem(hardened, option: .package(http)))
        XCTAssertEqual(item.image, "ghcr.io/eszetael/postgres-mcp-hardened:0.1.10")
        XCTAssertEqual(item.containerPort, 8080)
        XCTAssertEqual(item.path, "/mcp")
        XCTAssertEqual(item.fields.first { $0.key == "DATABASE_URL" }?.required, true)
        // The npm package's required runtime flag is kept.
        let npm = try XCTUnwrap(hardened.packages.first { $0.kind == .npm })
        XCTAssertEqual(MCPRegistryInstall.run(npm)?.command, ["npx", "-y", "--stdio", "postgres-mcp-hardened@0.1.10"])
    }

    func testRemoteConnectsByURL() throws {
        let waystation = try server("ai.waystation/postgres")
        let item = try XCTUnwrap(MCPRegistryInstall.catalogItem(waystation, option: .remote(waystation.remotes[1])))
        XCTAssertEqual(item.remoteURL, "https://waystation.ai/postgres/mcp/sse")
        XCTAssertEqual(item.transport, .sse)
        XCTAssertEqual(item.image, "")
        let server = MCPInstalledServer(name: "pg", kind: .remote, transport: .sse, remoteURL: item.remoteURL,
                                        headers: [EnvVar(key: "Authorization", value: "Bearer x")])
        let entry = MCPLaunch.entry(server, cliPath: "/usr/local/bin/container")
        XCTAssertEqual(entry.url, "https://waystation.ai/postgres/mcp/sse")
        XCTAssertEqual(entry.transport, .sse)
        XCTAssertEqual(entry.headers["Authorization"], "Bearer x")
        XCTAssertEqual(MCPLaunch.url(server), "https://waystation.ai/postgres/mcp/sse")
        XCTAssertFalse(server.isLongRunning)
    }

    func testInstalledServersWithoutNewFieldsStillDecode() throws {
        let old = #"[{"name":"time","kind":"container","image":"mcp/time","transport":"stdio","command":[],"env":[],"secretKeys":[],"mounts":[],"createdAt":"2026-11-01T00:00:00Z"}]"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let servers = try decoder.decode([MCPInstalledServer].self, from: Data(old.utf8))
        XCTAssertNil(servers[0].remoteURL)
        XCTAssertNil(servers[0].headers)
    }

    func testParseDockerCatalog() throws {
        let page = try MCPRegistryClient.parseDocker(Data(MCPRegistryFixtures.dockerPage.utf8), page: 1, pageSize: 2)
        XCTAssertEqual(page.servers.map(\.name), ["mcp/git", "mcp/github"])
        XCTAssertEqual(page.nextCursor, "2")
        XCTAssertEqual(page.total, 4)
        XCTAssertNotNil(page.servers[0].updated)
        let helper = #"{"count":1,"next":null,"results":[{"name":"signatures","namespace":"mcp"}]}"#
        XCTAssertTrue(try MCPRegistryClient.parseDocker(Data(helper.utf8), page: 1).servers.isEmpty)
        let git = page.servers[0]
        XCTAssertEqual(git.source, .docker)
        XCTAssertEqual(git.publisher, "Docker MCP catalog")
        XCTAssertEqual(git.homepage, "https://hub.docker.com/r/mcp/git")
        XCTAssertGreaterThan(git.pullCount ?? 0, 0)
        let item = try XCTUnwrap(MCPRegistryInstall.catalogItem(git, option: git.installOptions[0]))
        XCTAssertEqual(item.image, "mcp/git")
        XCTAssertEqual(item.transport, .stdio)
        XCTAssertEqual(item.defaultServerName, "git")
    }

    func testBadJSONThrows() {
        XCTAssertThrowsError(try MCPRegistryClient.parseRegistry(Data("<html>".utf8)))
        XCTAssertEqual(try MCPRegistryClient.parseRegistry(Data(#"{"servers":[],"metadata":{"nextCursor":"x"}}"#.utf8)).nextCursor, nil)
    }

    func testCacheAvoidsSecondRequest() async throws {
        let cache = MCPRegistryCache()
        await cache.store(Data(MCPRegistryFixtures.registryPage.utf8), for: MCPRegistryClient.registryURL("github", cursor: nil).absoluteString)
        // No network: the cached page answers.
        let client = MCPRegistryClient(session: URLSession(configuration: .ephemeral), cache: cache)
        let page = try await client.search("github", source: .registry)
        XCTAssertEqual(page.servers.count, 5)
    }
}
