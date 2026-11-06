import XCTest
@testable import DeckCore

/// A real agent sandbox on this Mac. Run with:
/// `DECK_LIVE_AGENT_SANDBOX=1 swift test --filter AgentSandboxLiveTests`
/// Needs the container service and internet (node:22-slim and the npm registry).
/// Creates deck-agents-test-1 (container, network, cache volume, chat volume) and removes them all.
/// The agent CLI is installed but never run: a stand in command takes its place.
final class AgentSandboxLiveTests: XCTestCase {
    private let cli = "/usr/local/bin/container"
    private let boxName = "deck-agents-test-1"
    private let volume = "deck-agents-test-cache"

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DECK_LIVE_AGENT_SANDBOX"] == "1", "set DECK_LIVE_AGENT_SANDBOX=1")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: cli), "container CLI missing")
    }

    override func tearDown() async throws {
        let client = ContainerClient(cliPath: cli)
        _ = try? await client.run(["delete", "--force", boxName])
        _ = try? await client.run(["network", "delete", boxName + SandboxConfig.networkSuffix])
        _ = try? await client.run(["volume", "delete", volume])
        _ = try? await client.run(["volume", "delete", ChatVolumeSync.sandboxVolume(boxName)])
    }

    /// Runs the profile's exec line without a TTY, with a stand in command after `deck-agent`.
    private func run(_ client: ContainerClient, _ box: Sandbox, _ standIn: String, secrets: [String] = []) async throws -> String {
        var args = AgentSandboxRecipe.execArguments(container: box.container.id, tool: .claude, parts: AgentCommandParts(), secretKeys: secrets)
        args.removeAll { $0 == "--tty" }
        // Replace the agent (`claude`) with the stand in.
        args.removeLast()
        args += ["/bin/sh", "-c", standIn]
        let result = try await client.runner.run(cli, args, stdin: nil)
        return result.stdout + result.stderr
    }

    func testAgentSandboxInstallsThroughAllowListAndTakesKeyFromEnvironment() async throws {
        let client = ContainerClient(cliPath: cli)
        let folder = NSTemporaryDirectory() + "deck-agents-test-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try "hello\n".write(toFile: folder + "/README.md", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: folder) }

        let profile = AgentProfile(name: "live", tool: .claude, model: .account, workspace: folder, place: .sandbox)
        var spec = try AgentSandboxRecipe.spec(for: profile)
        spec.name = boxName
        spec.cpus = 2
        spec.extraMounts = [MountSpec(kind: .volume, source: volume, destination: AgentSandboxRecipe.cachePath)]
        XCTAssertEqual(AgentSandboxRecipe.action(existing: nil, spec: spec), .create)

        try await client.ensureAgentCacheVolume(volume)
        try await client.createSandbox(spec, apiKey: nil)
        let listed = try await client.listSandboxes().first { $0.name == boxName }
        let box = try XCTUnwrap(listed)
        XCTAssertTrue(box.isRunning)
        XCTAssertEqual(box.agentTool, "claude")
        XCTAssertEqual(AgentSandboxRecipe.action(existing: box, spec: spec), .reuse)

        // The app runs the allow list proxy. Here the test does.
        let plan = try XCTUnwrap(box.gatewayPlan)
        XCTAssertNotNil(plan.proxyPort)
        let gateway = plan.makeGateway { _ in }
        var started = false
        for _ in 0..<20 where !started {
            do { try await gateway.start(); started = true } catch { try await Task.sleep(nanoseconds: 500_000_000) }
        }
        XCTAssertTrue(started, "gateway did not bind")
        defer { gateway.stop() }

        // First run installs the CLI into the cache volume through the proxy. The key arrives by name only.
        setenv("DECK_TEST_SECRET", "s3cret-value", 1)
        defer { unsetenv("DECK_TEST_SECRET") }
        let first = try await run(client, box, "echo PWD=$(pwd); echo S=$DECK_TEST_SECRET; command -v claude; ls /workspace",
                                  secrets: ["DECK_TEST_SECRET"])
        XCTAssertTrue(first.contains("Installing Claude Code"), first)
        XCTAssertTrue(first.contains("PWD=/workspace"), first)
        XCTAssertTrue(first.contains("S=s3cret-value"), first)
        XCTAssertTrue(first.contains("/deck/tools/bin/claude"), first)
        XCTAssertTrue(first.contains("README.md"), first)

        // Second run finds it cached.
        let second = try await run(client, box, "command -v claude")
        XCTAssertFalse(second.contains("Installing"), second)
        XCTAssertTrue(second.contains("/deck/tools/bin/claude"), second)

        // The allow list blocks other hosts. The key is not in the container's config.
        let blocked = try await run(client, box, "npm ping --registry https://example.com/ >/dev/null 2>&1 && echo REACHED || echo BLOCKED")
        XCTAssertTrue(blocked.contains("BLOCKED"), blocked)
        let detail = try await client.inspectContainer(box.container.id)
        XCTAssertFalse(String(describing: detail).contains("s3cret-value"))
    }
}
