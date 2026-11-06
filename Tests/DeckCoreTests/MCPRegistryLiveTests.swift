import XCTest
@testable import DeckCore

/// The live MCP Registry and Docker Hub, plus one throwaway stdio container. Run with:
/// `DECK_LIVE_MCP_REGISTRY=1 swift test --filter MCPRegistryLiveTests`
/// Needs internet and the container service. The container runs with `--rm` and is checked to be gone.
final class MCPRegistryLiveTests: XCTestCase {
    private let cli = "/usr/local/bin/container"

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DECK_LIVE_MCP_REGISTRY"] == "1", "set DECK_LIVE_MCP_REGISTRY=1")
    }

    func testLiveSearchAndPaging() async throws {
        let client = MCPRegistryClient(cache: MCPRegistryCache())
        let first = try await client.search("github", source: .registry)
        XCTAssertFalse(first.servers.isEmpty)
        let cursor = try XCTUnwrap(first.nextCursor)
        let second = try await client.search("github", source: .registry, cursor: cursor)
        XCTAssertFalse(second.servers.isEmpty)
        XCTAssertTrue(Set(first.servers.map(\.name)).isDisjoint(with: second.servers.map(\.name)))
        XCTAssertTrue(first.servers.contains { $0.isInstallable })

        let docker = try await client.search("git", source: .docker)
        XCTAssertTrue(docker.servers.contains { $0.name == "mcp/git" })
    }

    /// An npm package run the way the app runs it: `npx -y` in a Node container, over stdio.
    func testNpmPackageRunsInAContainer() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: cli), "container CLI missing")
        let package = MCPRegistryPackage(registryType: "npm", identifier: "@modelcontextprotocol/server-everything")
        let run = try XCTUnwrap(MCPRegistryInstall.run(package))
        let server = MCPInstalledServer(name: "deck-agents-test-mcp", image: run.image, transport: .stdio, command: run.command)
        let entry = MCPLaunch.entry(server, cliPath: cli)
        XCTAssertEqual(entry.command, cli)
        XCTAssertTrue(entry.args.contains("--rm"))
        let result = try await MCPHandshake.stdio(executable: cli, arguments: entry.args, timeout: 180)
        XCTAssertFalse(result.serverName.isEmpty)
        XCTAssertGreaterThan(result.toolCount ?? 0, 0)

        // Nothing is left behind.
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let left = try await ContainerClient(cliPath: cli).listContainers(all: true)
            .filter { $0.labels[AgentsConfig.serverLabel] == server.name }
        for container in left { _ = try? await ContainerClient(cliPath: cli).run(["delete", "--force", container.id]) }
        XCTAssertTrue(left.isEmpty, "left: \(left.map(\.name))")
    }
}
