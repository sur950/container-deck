import XCTest
@testable import DeckCore

/// Real sandboxes on this Mac. Run with:
/// `DECK_LIVE_SANDBOX=1 swift test --filter SandboxLiveTests`
/// Needs the container service, the alpine image and internet (example.com).
/// Creates deck-v2-sbx-live-* containers, networks and a Keychain item, and removes them all.
final class SandboxLiveTests: XCTestCase {
    private let cli = "/usr/local/bin/container"
    private var cleanup: [Sandbox] = []
    private let keychain = SandboxKeychain(service: SandboxConfig.keychainService + ".test")

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DECK_LIVE_SANDBOX"] == "1", "set DECK_LIVE_SANDBOX=1")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: cli), "container CLI missing")
    }

    override func tearDown() async throws {
        let client = ContainerClient(cliPath: cli)
        for sandbox in cleanup {
            try? await client.removeSandbox(sandbox)
            try? keychain.delete(account: sandbox.name)
        }
        // Belt and braces: names we may have made even when a step failed.
        for name in ["deck-v2-sbx-live-iso", "deck-v2-sbx-live-allow"] {
            _ = try? await client.run(["delete", "--force", name])
            _ = try? await client.run(["network", "delete", name + SandboxConfig.networkSuffix])
            try? keychain.delete(account: name)
        }
    }

    private func sandbox(_ client: ContainerClient, _ name: String) async throws -> Sandbox {
        let found = try await client.listSandboxes().first { $0.name == name }
        return try XCTUnwrap(found, "sandbox \(name) not listed")
    }

    private func sh(_ client: ContainerClient, _ id: String, _ script: String) async throws -> String {
        let result = try await client.exec(id, ["/bin/sh", "-c", script])
        return result.stdout + result.stderr
    }

    func testIsolatedSandboxHasNoEgressAndKeepsKeyInMemory() async throws {
        let client = ContainerClient(cliPath: cli)
        let name = "deck-v2-sbx-live-iso"
        let spec = SandboxSpec(name: name, templateID: "alpine", image: "alpine:latest", cpus: 1, memoryMB: 512, egress: .isolated,
                               model: SandboxModel(kind: .ollama, url: URL(string: "http://127.0.0.1:11434")!, name: "test", hasKey: true))
        let key = "sk-deck-test-\(UUID().uuidString.prefix(8))"
        try keychain.save(key, account: name)
        XCTAssertEqual(try keychain.read(account: name), key)

        try await client.createSandbox(spec, apiKey: try keychain.read(account: name))
        let box = try await sandbox(client, name)
        cleanup.append(box)
        XCTAssertTrue(box.isRunning)
        XCTAssertEqual(box.egress, .isolated)
        let network = try await client.listNetworkSummaries().first { $0.name == name + "-net" }
        XCTAssertEqual(network?.isInternal, true)

        let out = try await sh(client, box.container.id, "wget -q -T 4 -O- http://example.com >/dev/null 2>&1 && echo REACHED || echo BLOCKED")
        XCTAssertTrue(out.contains("BLOCKED"), out)

        // Key is in the tmpfs file and in shells, never in the container's plain environment.
        let keyOut = try await sh(client, box.container.id, ". /run/deck/env.sh; echo \"K=$OPENAI_API_KEY\"; mount | grep /run/deck")
        XCTAssertTrue(keyOut.contains("K=\(key)"), keyOut)
        XCTAssertTrue(keyOut.contains("tmpfs"), keyOut)
        let detail = try await client.inspectContainer(box.container.id)
        XCTAssertFalse(String(describing: detail).contains(key), "key leaked into the container config")
        try keychain.delete(account: name)
        XCTAssertNil(try keychain.read(account: name))

        // Chat from inside the Isolated sandbox through the relay, when Ollama runs on this Mac.
        let hostModels = (try? await SandboxModelProbe.models(baseURL: URL(string: "http://127.0.0.1:11434")!, kind: .ollama, apiKey: nil)) ?? []
        if let model = hostModels.first(where: { $0.hasPrefix("tinyllama") }) ?? hostModels.first {
            let plan = try XCTUnwrap(box.gatewayPlan)
            XCTAssertNil(plan.proxyPort)
            let gateway = plan.makeGateway { _ in }
            try await gateway.start()
            defer { gateway.stop() }
            let seen = try await client.sandboxModels(box)
            XCTAssertTrue(seen.contains(model), "models seen from inside: \(seen)")
            let reply = try await client.sandboxChat(box, model: model, messages: [SandboxChatMessage(role: .user, content: "Say hello in one word.")])
            XCTAssertFalse(reply.isEmpty)
            print("Chat reply from \(model) through the relay: \(reply.prefix(80))")
        }
    }

    func testAllowListProxyAndKillSwitch() async throws {
        let client = ContainerClient(cliPath: cli)
        let name = "deck-v2-sbx-live-allow"
        let spec = SandboxSpec(name: name, templateID: "alpine", image: "alpine:latest", cpus: 1, memoryMB: 512,
                               egress: .allowList, allowList: ["example.com", "dl-cdn.alpinelinux.org"])
        try await client.createSandbox(spec, apiKey: nil)
        let box = try await sandbox(client, name)
        cleanup.append(box)
        let plan = try XCTUnwrap(box.gatewayPlan)
        XCTAssertEqual(plan.proxyPort, SandboxConfig.proxyPort)

        let events = LiveEvents()
        let gateway = plan.makeGateway { events.add($0) }
        try await gateway.start()
        defer { gateway.stop() }

        let plain = try await sh(client, box.container.id, "wget -q -T 15 -O- http://example.com | grep -o 'Example Domain' | head -1")
        XCTAssertTrue(plain.contains("Example Domain"), "http via proxy: \(plain) \(events.text)")
        // apk and curl use CONNECT through HTTPS_PROXY, like pip, npm and agent SDKs.
        let install = try await sh(client, box.container.id, "apk add --no-progress -q curl 2>&1; command -v curl")
        XCTAssertTrue(install.contains("/usr/bin/curl"), "apk through the proxy: \(install) \(events.text)")
        let tls = try await sh(client, box.container.id, "curl -sS -m 15 https://example.com | grep -o 'Example Domain' | head -1")
        XCTAssertTrue(tls.contains("Example Domain"), "https via CONNECT: \(tls)")
        let blocked = try await sh(client, box.container.id, "curl -sS -m 15 -o /dev/null -w '%{http_code}' https://www.apple.com 2>&1")
        XCTAssertTrue(blocked.contains("403"), "other host: \(blocked)")
        let bypass = try await sh(client, box.container.id, "curl --noproxy '*' -sS -m 5 -o /dev/null https://example.com 2>&1 && echo REACHED || echo BLOCKED")
        XCTAssertTrue(bypass.contains("BLOCKED"), "direct traffic must not leave the host only network: \(bypass)")
        XCTAssertTrue(events.all.contains { $0.kind == .blocked && $0.host == "www.apple.com" })

        // Kill switch: proxy closed first, then SIGKILL.
        gateway.stop()
        XCTAssertEqual(gateway.openConnections, 0)
        try await client.killSandbox(box)
        let after = try await sandbox(client, name)
        XCTAssertFalse(after.isRunning)
    }
}

private final class LiveEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [SandboxEgressEvent] = []
    func add(_ event: SandboxEgressEvent) { lock.lock(); events.append(event); lock.unlock() }
    var all: [SandboxEgressEvent] { lock.lock(); defer { lock.unlock() }; return events }
    var text: String { all.map { "\($0.kind.rawValue) \($0.host):\($0.port) \($0.detail)" }.joined(separator: "; ") }
}
