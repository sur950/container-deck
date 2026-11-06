import XCTest
@testable import DeckCore

final class SandboxPolicyTests: XCTestCase {
    func testExactAndWildcardRules() {
        let policy = EgressPolicy(entries: ["example.com", "*.github.com", "api.openai.com:443"])
        XCTAssertTrue(policy.allows(host: "example.com", port: 443))
        XCTAssertTrue(policy.allows(host: "EXAMPLE.com.", port: 80))
        XCTAssertFalse(policy.allows(host: "www.example.com", port: 443))
        XCTAssertTrue(policy.allows(host: "github.com", port: 443))
        XCTAssertTrue(policy.allows(host: "api.github.com", port: 443))
        XCTAssertFalse(policy.allows(host: "evilgithub.com", port: 443))
        XCTAssertTrue(policy.allows(host: "api.openai.com", port: 443))
        XCTAssertFalse(policy.allows(host: "api.openai.com", port: 80))
        XCTAssertFalse(policy.allows(host: "", port: 80))
        XCTAssertFalse(policy.allows(host: "1.1.1.1", port: 443))
    }

    func testAlwaysAllowed() {
        let policy = EgressPolicy(entries: [], alwaysAllowed: ["192.168.128.1:39434"])
        XCTAssertTrue(policy.allows(host: "192.168.128.1", port: 39434))
        XCTAssertFalse(policy.allows(host: "192.168.128.1", port: 22))
    }

    func testNormalize() {
        XCTAssertEqual(EgressPolicy.normalize("https://PyPI.org/simple/"), "pypi.org")
        XCTAssertEqual(EgressPolicy.normalize(" .npmjs.org "), "*.npmjs.org")
        XCTAssertEqual(EgressPolicy.normalize("*.npmjs.org"), "*.npmjs.org")
        XCTAssertEqual(EgressPolicy.normalize("example.com:8443"), "example.com:8443")
        XCTAssertEqual(EgressPolicy.normalize("[::1]:8080"), "::1:8080")
        XCTAssertNil(EgressPolicy.normalize("*.com"))
        XCTAssertNil(EgressPolicy.normalize("bad host!"))
        XCTAssertNil(EgressPolicy.normalize("example.com:99999"))
        XCTAssertNil(EgressPolicy.normalize(""))
    }

    func testParseList() {
        XCTAssertEqual(EgressPolicy.parseList("pypi.org, files.pythonhosted.org\npypi.org  *.github.com"),
                       ["pypi.org", "files.pythonhosted.org", "*.github.com"])
        XCTAssertEqual(EgressPolicy.invalidEntries("ok.com nope!"), ["nope!"])
    }
}

final class SandboxProxyRequestTests: XCTestCase {
    func testConnect() throws {
        let head = Data("CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\nUser-Agent: curl\r\n\r\nTLSDATA".utf8)
        guard case .request(let request) = ProxyRequest.parse(head) else { return XCTFail("not parsed") }
        XCTAssertEqual(request.kind, .tunnel)
        XCTAssertEqual(request.host, "example.com")
        XCTAssertEqual(request.port, 443)
        XCTAssertEqual(head.count - request.headLength, 7)
    }

    func testAbsoluteHTTPIsRewritten() throws {
        let head = Data("GET http://Example.com:8080/a/b?x=1 HTTP/1.1\r\nHost: example.com:8080\r\nProxy-Connection: keep-alive\r\nAccept: */*\r\n\r\n".utf8)
        guard case .request(let request) = ProxyRequest.parse(head) else { return XCTFail("not parsed") }
        XCTAssertEqual(request.kind, .http)
        XCTAssertEqual(request.host, "example.com")
        XCTAssertEqual(request.port, 8080)
        XCTAssertEqual(request.path, "/a/b?x=1")
        let origin = String(decoding: request.originHead(), as: UTF8.self)
        XCTAssertEqual(origin, "GET /a/b?x=1 HTTP/1.1\r\nHost: example.com:8080\r\nAccept: */*\r\nConnection: close\r\n\r\n")
    }

    func testMissingHostHeaderIsAdded() {
        guard case .request(let request) = ProxyRequest.parse(Data("GET http://example.com HTTP/1.0\r\n\r\n".utf8)) else {
            return XCTFail("not parsed")
        }
        XCTAssertEqual(request.path, "/")
        XCTAssertTrue(String(decoding: request.originHead(), as: UTF8.self).contains("Host: example.com\r\n"))
    }

    func testIncompleteAndInvalid() {
        if case .incomplete = ProxyRequest.parse(Data("CONNECT a.com:443 HTTP/1.1\r\n".utf8)) {} else { XCTFail("should wait") }
        if case .invalid(400, _) = ProxyRequest.parse(Data("GET /local HTTP/1.1\r\n\r\n".utf8)) {} else { XCTFail("origin form") }
        if case .invalid(400, _) = ProxyRequest.parse(Data("CONNECT a.com HTTP/1.1\r\n\r\n".utf8)) {} else { XCTFail("no port") }
        if case .invalid(400, _) = ProxyRequest.parse(Data("GET https://a.com/ HTTP/1.1\r\n\r\n".utf8)) {} else { XCTFail("https get") }
        let huge = Data(repeating: 65, count: 40_000)
        if case .invalid(431, _) = ProxyRequest.parse(huge) {} else { XCTFail("too large") }
    }
}

final class SandboxPlannerTests: XCTestCase {
    private let gateway = "192.168.128.1"

    func testModelRoutes() {
        let local = URL(string: "http://127.0.0.1:11434")!
        XCTAssertEqual(SandboxModelRoute.route(for: local, egress: .isolated), .relay(host: "127.0.0.1", port: 11434))
        XCTAssertEqual(SandboxModelRoute.route(for: URL(string: "http://localhost:1234/v1")!, egress: .open), .relay(host: "127.0.0.1", port: 1234))
        XCTAssertEqual(SandboxModelRoute.route(for: URL(string: "http://192.168.1.20:8080/v1")!, egress: .open), .relay(host: "192.168.1.20", port: 8080))
        let remote = URL(string: "https://api.openai.com/v1")!
        XCTAssertEqual(SandboxModelRoute.route(for: remote, egress: .open), .direct)
        XCTAssertEqual(SandboxModelRoute.route(for: remote, egress: .allowList), .proxy(host: "api.openai.com"))
        XCTAssertFalse(SandboxModelRoute.route(for: remote, egress: .isolated).isReachable)
        let relayed = SandboxModelRoute.relay(host: "127.0.0.1", port: 1234).containerURL(for: URL(string: "http://localhost:1234/v1")!, gateway: gateway)
        XCTAssertEqual(relayed.absoluteString, "http://192.168.128.1:39434/v1")
    }

    func testRunOptionsForAllowListWithKey() {
        let spec = SandboxSpec(
            name: "agent", templateID: "python", image: "python:3.12-slim", workspace: "/Users/me/code", workspaceReadOnly: false,
            cpus: 4, memoryMB: 4096, egress: .allowList, allowList: ["pypi.org"],
            model: SandboxModel(kind: .openAI, url: URL(string: "https://api.openai.com/v1")!, name: "gpt-5", hasKey: true)
        )
        let options = SandboxPlanner.runOptions(spec, gateway: gateway, subnet: "192.168.128.0/24", hasKey: true)
        XCTAssertEqual(options.network, "agent-net")
        XCTAssertEqual(options.cpus, 4)
        XCTAssertEqual(options.memory, "4096M")
        XCTAssertEqual(options.tmpfs, ["/run/deck"])
        XCTAssertEqual(options.workingDir, "/workspace")
        XCTAssertEqual(options.mounts.first?.source, "/Users/me/code")
        XCTAssertEqual(options.mounts.first?.readOnly, false)
        XCTAssertEqual(options.labels["deck.sandbox.allow"], "pypi.org,api.openai.com")
        XCTAssertEqual(options.labels["deck.sandbox.workspace-mode"], "rw")
        XCTAssertEqual(options.labels["deck.sandbox.key"], "1")
        let env = Dictionary(uniqueKeysWithValues: options.env.map { ($0.key, $0.value) })
        XCTAssertEqual(env["HTTPS_PROXY"], "http://192.168.128.1:39128")
        XCTAssertEqual(env["https_proxy"], "http://192.168.128.1:39128")
        XCTAssertEqual(env["OPENAI_BASE_URL"], "https://api.openai.com/v1")
        XCTAssertEqual(env["OPENAI_API_KEY_FILE"], "/run/deck/openai_api_key")
        XCTAssertNil(env["OPENAI_API_KEY"], "the key must never be a plain variable")
        XCTAssertTrue(env["NO_PROXY"]?.contains(gateway) ?? false)
    }

    func testRunArgumentsAndSandboxRoundTrip() {
        let spec = SandboxSpec(
            name: "deck-v2-sbx-a", image: "alpine:latest", egress: .isolated,
            model: SandboxModel(kind: .ollama, url: URL(string: "http://127.0.0.1:11434")!, name: "llama3.2")
        )
        let options = SandboxPlanner.runOptions(spec, gateway: gateway, subnet: nil, hasKey: false)
        let client = ContainerClient(cliPath: "/usr/local/bin/container", runner: MockRunner())
        let args = client.runArguments(options)
        XCTAssertTrue(args.contains("--tmpfs"))
        XCTAssertTrue(args.contains("--network"))
        XCTAssertEqual(args.suffix(3), ["alpine:latest", "-c", SandboxConfig.keepAliveArguments[1]])
        let env = Dictionary(uniqueKeysWithValues: options.env.map { ($0.key, $0.value) })
        XCTAssertEqual(env["OLLAMA_HOST"], "http://192.168.128.1:39434")
        XCTAssertEqual(env["OPENAI_BASE_URL"], "http://192.168.128.1:39434/v1")
        XCTAssertEqual(env["OPENAI_API_KEY"], "local")
        XCTAssertNil(env["HTTP_PROXY"])

        let summary = ContainerSummary(id: "deck-v2-sbx-a", name: "deck-v2-sbx-a", image: "alpine:latest", state: .running, labels: options.labels)
        guard let sandbox = Sandbox(container: summary) else { return XCTFail("not a sandbox") }
        XCTAssertEqual(sandbox.egress, .isolated)
        XCTAssertEqual(sandbox.gateway, gateway)
        XCTAssertEqual(sandbox.model?.kind, .ollama)
        XCTAssertEqual(sandbox.model?.name, "llama3.2")
        XCTAssertEqual(sandbox.containerModelURL?.absoluteString, "http://192.168.128.1:39434")
        let plan = sandbox.gatewayPlan
        XCTAssertNil(plan?.proxyPort)
        XCTAssertEqual(plan?.relay, SandboxGateway.Relay(port: 39434, targetHost: "127.0.0.1", targetPort: 11434))
        XCTAssertNil(Sandbox(container: ContainerSummary(id: "x", name: "x", image: "alpine", state: .running)))
    }

    func testOpenSandboxWithoutModelNeedsNoGateway() {
        let options = SandboxPlanner.runOptions(SandboxSpec(name: "o", image: "alpine", egress: .open), gateway: gateway, subnet: nil, hasKey: false)
        let sandbox = Sandbox(container: ContainerSummary(id: "o", name: "o", image: "alpine", state: .running, labels: options.labels))
        XCTAssertNil(sandbox?.gatewayPlan)
        XCTAssertEqual(sandbox?.egress, .open)
    }

    func testNames() {
        XCTAssertTrue(SandboxSpec.isValidName("deck-v2-sbx-1"))
        XCTAssertFalse(SandboxSpec.isValidName("Bad Name"))
        XCTAssertFalse(SandboxSpec.isValidName("-x"))
        XCTAssertFalse(SandboxSpec.isValidName(String(repeating: "a", count: 60)))
    }

    func testShellQuote() {
        XCTAssertEqual(SandboxPlanner.shellQuote(["a", "b c", "it's"]), "a 'b c' 'it'\\''s'")
    }

    func testCreateRunsNetworkThenContainerThenSecrets() async throws {
        let runner = MockRunner()
        let networks = """
        [{"configuration":{"creationDate":"2026-11-05T16:52:50Z","labels":{"deck.sandbox":"1","deck.sandbox.egress":"isolated"},"mode":"hostOnly","name":"s1-net","options":{},"plugin":"container-network-vmnet"},"id":"s1-net","status":{"ipv4Gateway":"192.168.130.1","ipv4Subnet":"192.168.130.0/24","ipv6Subnet":"fdc5:d08f:33b5:2e9d::/64"}}]
        """
        runner.responses["network list --format json"] = CommandResult(exitCode: 0, stdout: networks, stderr: "")
        let client = ContainerClient(cliPath: "/c", runner: runner)
        let spec = SandboxSpec(name: "s1", image: "alpine", egress: .isolated)
        let networkArgs = client.sandboxNetworkArguments(spec)
        XCTAssertEqual(networkArgs, ["network", "create", "--internal", "--label", "deck.sandbox=1", "--label", "deck.sandbox.egress=isolated", "s1-net"])
        runner.responses[networkArgs.joined(separator: " ")] = CommandResult(exitCode: 0, stdout: "s1-net", stderr: "")
        let options = SandboxPlanner.runOptions(spec, gateway: "192.168.130.1", subnet: "192.168.130.0/24", hasKey: false)
        runner.responses[client.runArguments(options).joined(separator: " ")] = CommandResult(exitCode: 0, stdout: "s1\n", stderr: "")
        runner.responses["exec --interactive --uid 0 s1 /bin/sh -c \(SandboxPlanner.envScriptWriter)"] = CommandResult(exitCode: 0, stdout: "", stderr: "")
        // First list has no network yet, so it gets created. The mock always answers with it,
        // which is fine: the planner only needs the gateway.
        _ = try await client.createSandbox(spec, apiKey: nil)
        let calls = runner.calls.map { Array($0.dropFirst()) }
        XCTAssertTrue(calls.contains(client.runArguments(options)))
        XCTAssertEqual(calls.last?.first, "exec")
    }
}

final class SandboxChatTests: XCTestCase {
    func testURLs() {
        XCTAssertEqual(SandboxChat.completionsURL(base: URL(string: "http://h:1/v1/")!, kind: .openAI), "http://h:1/v1/chat/completions")
        XCTAssertEqual(SandboxChat.completionsURL(base: URL(string: "http://h:11434")!, kind: .ollama), "http://h:11434/v1/chat/completions")
        XCTAssertEqual(SandboxChat.modelsURL(base: URL(string: "http://h:11434")!, kind: .ollama), "http://h:11434/v1/models")
    }

    func testParseReply() throws {
        let reply = #"{"id":"x","choices":[{"index":0,"message":{"role":"assistant","content":"Hello there"}}]}"#
        XCTAssertEqual(try SandboxChat.parseReply(reply), "Hello there")
        XCTAssertThrowsError(try SandboxChat.parseReply(#"{"error":{"message":"model not found"}}"#)) { error in
            XCTAssertTrue(error.localizedDescription.contains("model not found"))
        }
        XCTAssertThrowsError(try SandboxChat.parseReply("<html>"))
    }

    func testParseModels() {
        XCTAssertEqual(SandboxChat.parseModels(#"{"object":"list","data":[{"id":"a"},{"id":"b"}]}"#), ["a", "b"])
        XCTAssertEqual(SandboxChat.parseModels(#"{"models":[{"name":"llama3.2:latest"}]}"#), ["llama3.2:latest"])
        XCTAssertEqual(SandboxChat.parseModels("nope"), [])
    }

    func testRequestBody() throws {
        let data = try SandboxChat.requestBody(model: "m", messages: [SandboxChatMessage(role: .user, content: "hi")])
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["model"] as? String, "m")
        XCTAssertEqual(object?["stream"] as? Bool, false)
        let messages = object?["messages"] as? [[String: String]]
        XCTAssertEqual(messages?.first, ["role": "user", "content": "hi"])
    }
}
