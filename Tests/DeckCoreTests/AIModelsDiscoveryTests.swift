import XCTest
@testable import DeckCore

/// Answers HTTP requests from a table keyed by URL. Unknown URLs fail like a closed port.
private final class FakeHTTP: AIHTTPFetching, @unchecked Sendable {
    var responses: [String: (String, Int)] = [:]
    private let lock = NSLock()
    private var seen: [String] = []

    var requested: [String] {
        lock.lock(); defer { lock.unlock() }
        return seen
    }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let key = request.url?.absoluteString ?? ""
        record(key)
        guard let (body, status) = responses[key] else { throw URLError(.cannotConnectToHost) }
        return (Data(body.utf8), status)
    }

    private func record(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        seen.append(key)
    }
}

// Built from real `lsof -nP -iTCP -sTCP:LISTEN -Fpcn` lines on this Mac.
private let lsofOutput = """
p1982
cControlCenter
f9
n*:7000
f11
n*:5000
f12
n*:5000
p7939
cnode
f15
n127.0.0.1:18789
f17
n[::1]:18789
p16934
collama
f4
n127.0.0.1:11434
p17001
collama
f5
n127.0.0.1:52011
p26312
cpython3.12
f5
n192.168.64.1:8585
p27723
credis-server
f6
n127.0.0.1:6379
"""

private let psOutput = """
 1982 /System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter
 7939 node server.js
16934 /opt/homebrew/opt/ollama/bin/ollama serve
17001 /opt/homebrew/Cellar/ollama/0.16.2/bin/ollama runner --model /Users/me/.ollama/models/blobs/sha256-7f40 --port 52011
26312 /Users/me/Library/Application Support/io.github.sur950.containerdeck/AI/uv-tools/mlx-lm/bin/python /Users/me/Library/Application Support/io.github.sur950.containerdeck/AI/bin/mlx_lm.server --model /Users/me/Library/Application Support/io.github.sur950.containerdeck/AI/models/mlx-community/SmolLM-135M-Instruct-4bit --host 192.168.64.1 --port 8585
27723 redis-server 127.0.0.1:6379
"""

private func data(_ text: String) -> Data { Data(text.utf8) }

final class AIModelsDiscoveryTests: XCTestCase {

    // MARK: lsof and ps

    func testParseLsofReadsEverySocket() {
        let sockets = ModelDiscoveryParser.parseLsof(lsofOutput)
        XCTAssertEqual(sockets.count, 8)
        XCTAssertTrue(sockets.contains(ListeningSocket(pid: 16934, processName: "ollama", address: "127.0.0.1", port: 11434)))
        XCTAssertTrue(sockets.contains(ListeningSocket(pid: 7939, processName: "node", address: "::1", port: 18789)))
        XCTAssertTrue(sockets.contains(ListeningSocket(pid: 1982, processName: "ControlCenter", address: "*", port: 5000)))
        XCTAssertTrue(sockets.contains(ListeningSocket(pid: 26312, processName: "python3.12", address: "192.168.64.1", port: 8585)))
    }

    func testParsePSKeepsSpacesInCommands() {
        let commands = ModelDiscoveryParser.parsePS(psOutput)
        XCTAssertEqual(commands[16934], "/opt/homebrew/opt/ollama/bin/ollama serve")
        XCTAssertTrue(commands[26312]?.contains("Application Support") == true)
        XCTAssertEqual(commands.count, 6)
    }

    func testKindFromCommand() {
        XCTAssertEqual(ModelDiscoveryParser.kind(forCommand: "/opt/homebrew/bin/ollama serve"), .ollama)
        XCTAssertEqual(ModelDiscoveryParser.kind(forCommand: "/x/bin/python /x/bin/mlx_lm.server --model m"), .mlxLM)
        XCTAssertEqual(ModelDiscoveryParser.kind(forCommand: "python -m mlx_lm server --port 8080"), .mlxLM)
        XCTAssertEqual(ModelDiscoveryParser.kind(forCommand: "/Applications/LM Studio.app/Contents/MacOS/LM Studio"), .lmStudio)
        XCTAssertEqual(ModelDiscoveryParser.kind(forCommand: "./llama-server -m model.gguf"), .llamaCpp)
        XCTAssertEqual(ModelDiscoveryParser.kind(forCommand: "omlx serve"), .oMLX)
        XCTAssertNil(ModelDiscoveryParser.kind(forCommand: "node server.js"))
        XCTAssertNil(ModelDiscoveryParser.kind(forCommand: "redis-server 127.0.0.1:6379"))
    }

    func testProbeTargetsKeepWellKnownAndModelServerPorts() {
        let sockets = ModelDiscoveryParser.parseLsof(lsofOutput)
        let targets = ModelDiscoveryParser.probeTargets(sockets: sockets, commands: ModelDiscoveryParser.parsePS(psOutput))
        let ports = targets.map(\.port)
        XCTAssertTrue(ports.contains(11434))
        XCTAssertTrue(ports.contains(8585))
        XCTAssertTrue(ports.contains(1234), "well known ports are probed even when lsof did not see them")
        XCTAssertFalse(ports.contains(18789), "a node dev server is not a model server")
        XCTAssertFalse(ports.contains(6379))
        XCTAssertFalse(ports.contains(5000), "AirPlay on 5000 is not probed")
        XCTAssertFalse(ports.contains(52011), "Ollama runners are not endpoints")

        let mlx = targets.first { $0.port == 8585 }
        XCTAssertEqual(mlx?.processKind, .mlxLM)
        XCTAssertEqual(mlx?.bindAddress, "192.168.64.1")
        XCTAssertEqual(mlx?.probeHost, "192.168.64.1")
        XCTAssertEqual(targets.first { $0.port == 11434 }?.probeHost, "127.0.0.1")
    }

    func testWidestBindAddressWins() {
        let sockets = [
            ListeningSocket(pid: 5, processName: "ollama", address: "127.0.0.1", port: 11434),
            ListeningSocket(pid: 5, processName: "ollama", address: "*", port: 11434)
        ]
        let target = ModelDiscoveryParser.probeTargets(sockets: sockets, commands: [:]).first { $0.port == 11434 }
        XCTAssertEqual(target?.bindAddress, "*")
        XCTAssertEqual(target?.probeHost, "127.0.0.1")
    }

    // MARK: HTTP bodies

    func testParseOllamaBodies() throws {
        XCTAssertEqual(ModelDiscoveryParser.parseOllamaVersion(data(AIFixtures.ollamaVersion)), "0.16.2")
        let tags = try XCTUnwrap(ModelDiscoveryParser.parseOllamaTags(data(AIFixtures.ollamaTags)))
        XCTAssertEqual(tags.map(\.id), ["mistral:latest", "tinyllama:latest", "qwen3:0.6b"])
        XCTAssertEqual(tags[2].sizeBytes, 522_653_767)
        XCTAssertEqual(tags[2].parameterSize, "751.63M")
        XCTAssertEqual(tags[2].quantization, "Q4_K_M")
        XCTAssertEqual(ModelDiscoveryParser.parseOllamaLoaded(data(AIFixtures.ollamaPSEmpty)), [])
        XCTAssertEqual(ModelDiscoveryParser.parseOllamaLoaded(data(AIFixtures.ollamaPSLoaded)), ["qwen3:0.6b"])
    }

    func testParseOpenAIModels() throws {
        let ollama = try XCTUnwrap(ModelDiscoveryParser.parseOpenAIModels(data(AIFixtures.ollamaV1Models)))
        XCTAssertEqual(ollama.models.count, 3)
        XCTAssertEqual(Set(ollama.ownedBy), ["library"])

        let mlx = try XCTUnwrap(ModelDiscoveryParser.parseOpenAIModels(data(AIFixtures.mlxV1Models)))
        XCTAssertEqual(mlx.models.map(\.id), ["/private/tmp/ai rt/models/mlx-community/SmolLM-135M-Instruct-4bit"])
        XCTAssertEqual(mlx.models[0].displayName, "SmolLM-135M-Instruct-4bit")

        XCTAssertNil(ModelDiscoveryParser.parseOpenAIModels(data("<html>Not Found</html>")))
        XCTAssertNil(ModelDiscoveryParser.parseOpenAIModels(data(AIFixtures.ollamaVersion)))
        XCTAssertNil(ModelDiscoveryParser.parseOpenAIModels(Data()))
    }

    func testParseLMStudioModels() throws {
        let body = #"{"data":[{"id":"qwen2.5-7b-instruct","object":"model","type":"llm","publisher":"lmstudio-community","arch":"qwen2","compatibility_type":"mlx","quantization":"4bit","state":"loaded","max_context_length":32768},{"id":"text-embedding-nomic","object":"model","type":"embeddings","state":"not-loaded"}],"object":"list"}"#
        let models = try XCTUnwrap(ModelDiscoveryParser.parseLMStudioModels(data(body)))
        XCTAssertEqual(models.map(\.id), ["qwen2.5-7b-instruct", "text-embedding-nomic"])
        XCTAssertTrue(models[0].isLoaded)
        XCTAssertEqual(models[0].quantization, "4bit")
        XCTAssertFalse(models[1].isLoaded)
        // A plain OpenAI list is not LM Studio's rich shape.
        XCTAssertNil(ModelDiscoveryParser.parseLMStudioModels(data(AIFixtures.ollamaV1Models)))
    }

    func testClassify() {
        XCTAssertEqual(ModelDiscoveryParser.classify(processKind: nil, ownedBy: ["library"], isOllama: true), .ollama)
        XCTAssertEqual(ModelDiscoveryParser.classify(processKind: .mlxLM, ownedBy: [], isOllama: false), .mlxLM)
        XCTAssertEqual(ModelDiscoveryParser.classify(processKind: nil, ownedBy: ["llamacpp"], isOllama: false), .llamaCpp)
        XCTAssertEqual(ModelDiscoveryParser.classify(processKind: nil, ownedBy: ["vllm"], isOllama: false), .vLLM)
        XCTAssertEqual(ModelDiscoveryParser.classify(processKind: nil, ownedBy: ["organization_owner"], isOllama: false), .lmStudio)
        XCTAssertEqual(ModelDiscoveryParser.classify(processKind: nil, ownedBy: [], isOllama: false), .openAICompatible)
    }

    func testServedModelIsMarkedLoaded() {
        let command = "/x/AI/uv-tools/mlx-lm/bin/python /x/AI/bin/mlx_lm.server --model /tmp/ai rt/models/mlx-community/SmolLM-135M-Instruct-4bit --host 127.0.0.1 --port 8585"
        XCTAssertEqual(ModelDiscoveryParser.modelArgument(command), "/tmp/ai rt/models/mlx-community/SmolLM-135M-Instruct-4bit")
        let listed = ModelDiscoveryParser.parseOpenAIModels(data(AIFixtures.mlxV1Models))?.models ?? []
        let marked = ModelDiscoveryParser.markServedModel(listed, command: command)
        XCTAssertEqual(marked.count, 1)
        XCTAssertTrue(marked[0].isLoaded, "/private/tmp and /tmp paths match by their last parts")

        let other = ModelDiscoveryParser.markServedModel([ModelEndpointModel(id: "mlx-community/Other")], command: command)
        XCTAssertEqual(other.first?.id, "/tmp/ai rt/models/mlx-community/SmolLM-135M-Instruct-4bit")
        XCTAssertEqual(other.first?.isLoaded, true)
        XCTAssertEqual(other.count, 2)
    }

    // MARK: Full discovery with fakes

    func testDiscoverFindsOllamaAndManagedMLXServer() async {
        let runner = MockRunner()
        runner.responses["-nP -iTCP -sTCP:LISTEN -Fpcn"] = CommandResult(exitCode: 0, stdout: lsofOutput)
        runner.responses["-o pid=,command= -p 1982,7939,16934,17001,26312,27723"] = CommandResult(exitCode: 0, stdout: psOutput)

        let http = FakeHTTP()
        http.responses["http://127.0.0.1:11434/v1/models"] = (AIFixtures.ollamaV1Models, 200)
        http.responses["http://127.0.0.1:11434/api/version"] = (AIFixtures.ollamaVersion, 200)
        http.responses["http://127.0.0.1:11434/api/tags"] = (AIFixtures.ollamaTags, 200)
        http.responses["http://127.0.0.1:11434/api/ps"] = (AIFixtures.ollamaPSLoaded, 200)
        http.responses["http://192.168.64.1:8585/v1/models"] = (AIFixtures.mlxV1Models, 200)
        http.responses["http://192.168.64.1:8585/api/version"] = ("", 404)
        // A web app on 8080 that is not a model server.
        http.responses["http://127.0.0.1:8080/v1/models"] = ("<html>404</html>", 404)
        http.responses["http://127.0.0.1:8080/api/version"] = ("<html>404</html>", 404)

        let discovery = ModelDiscovery(runner: runner, http: http, fileExists: { _ in false }, managedPIDs: { [26312] }, timeout: 0.2)
        let endpoints = await discovery.discover()

        XCTAssertEqual(endpoints.map(\.id), ["192.168.64.1:8585", "127.0.0.1:11434"], "managed server first, then by kind")

        let mlx = endpoints[0]
        XCTAssertEqual(mlx.kind, .mlxLM)
        XCTAssertTrue(mlx.isManaged)
        XCTAssertEqual(mlx.status, .running)
        XCTAssertEqual(mlx.baseURL.absoluteString, "http://192.168.64.1:8585/v1")
        XCTAssertTrue(mlx.reachableFromContainers)
        XCTAssertEqual(mlx.containerBaseURL(gateway: "192.168.64.1")?.absoluteString, "http://192.168.64.1:8585/v1")
        XCTAssertEqual(mlx.models.first?.isLoaded, true)

        let ollama = endpoints[1]
        XCTAssertEqual(ollama.kind, .ollama)
        XCTAssertEqual(ollama.version, "0.16.2")
        XCTAssertEqual(ollama.models.count, 3)
        XCTAssertEqual(ollama.models.filter(\.isLoaded).map(\.id), ["qwen3:0.6b"])
        XCTAssertEqual(ollama.baseURL.absoluteString, "http://127.0.0.1:11434/v1")
        XCTAssertEqual(ollama.nativeURL?.absoluteString, "http://127.0.0.1:11434")
        XCTAssertFalse(ollama.reachableFromContainers)
        XCTAssertNil(ollama.containerBaseURL(gateway: "192.168.64.1"))
        XCTAssertEqual(ollama.containerEnvironment(gateway: "192.168.64.1"), [:])
        XCTAssertEqual(ollama.hostEnvironment["OLLAMA_HOST"], "http://127.0.0.1:11434")

        XCTAssertFalse(http.requested.contains { $0.contains(":52011") }, "Ollama runner ports are never probed")
        XCTAssertFalse(http.requested.contains { $0.contains(":18789") })
    }

    func testDiscoverReportsInstalledServersThatAreNotRunning() async {
        let runner = MockRunner()
        runner.responses["-nP -iTCP -sTCP:LISTEN -Fpcn"] = CommandResult(exitCode: 0, stdout: "")
        let discovery = ModelDiscovery(runner: runner, http: FakeHTTP(),
                                       fileExists: { $0 == "/opt/homebrew/bin/ollama" || $0 == "/Applications/LM Studio.app" },
                                       managedPIDs: { [] }, timeout: 0.2)
        let endpoints = await discovery.discover()
        XCTAssertEqual(endpoints.map(\.kind), [.ollama, .lmStudio])
        XCTAssertTrue(endpoints.allSatisfy { $0.status == .installed })
        XCTAssertEqual(endpoints[0].baseURL.absoluteString, "http://127.0.0.1:11434/v1")
        XCTAssertEqual(endpoints[1].baseURL.absoluteString, "http://127.0.0.1:1234/v1")
    }

    func testSilentMLXServerIsReportedAsNotResponding() async {
        let runner = MockRunner()
        runner.responses["-nP -iTCP -sTCP:LISTEN -Fpcn"] = CommandResult(exitCode: 0, stdout: "p900\ncPython\nf5\nn127.0.0.1:9123\n")
        runner.responses["-o pid=,command= -p 900"] = CommandResult(exitCode: 0, stdout: "900 python -m mlx_lm.server --model x --port 9123\n")
        let discovery = ModelDiscovery(runner: runner, http: FakeHTTP(), fileExists: { _ in false }, managedPIDs: { [] }, timeout: 0.2)
        let endpoints = await discovery.discover()
        XCTAssertEqual(endpoints.count, 1)
        XCTAssertEqual(endpoints.first?.status, .notResponding)
        XCTAssertEqual(endpoints.first?.kind, .mlxLM)
    }

    // MARK: Public API shape

    func testContainerEnvironmentForAllAddressesServer() {
        let endpoint = ModelEndpoint(id: "127.0.0.1:11434", kind: .ollama, host: "127.0.0.1", port: 11434,
                                     baseURL: URL(string: "http://127.0.0.1:11434/v1")!, status: .running, bindAddress: "*")
        XCTAssertTrue(endpoint.reachableFromContainers)
        let env = endpoint.containerEnvironment(gateway: "192.168.64.1")
        XCTAssertEqual(env["OPENAI_BASE_URL"], "http://192.168.64.1:11434/v1")
        XCTAssertEqual(env["OPENAI_API_BASE"], "http://192.168.64.1:11434/v1")
        XCTAssertEqual(env["OPENAI_API_KEY"], "ollama")
        XCTAssertEqual(env["OLLAMA_HOST"], "http://192.168.64.1:11434")
    }

    func testEndpointIsCodableForOtherAreas() throws {
        let endpoint = ModelEndpoint(id: "127.0.0.1:1234", kind: .lmStudio, host: "127.0.0.1", port: 1234,
                                     baseURL: URL(string: "http://127.0.0.1:1234/v1")!, status: .running,
                                     models: [ModelEndpointModel(id: "qwen", isLoaded: true)], bindAddress: "127.0.0.1")
        let copy = try JSONDecoder().decode(ModelEndpoint.self, from: JSONEncoder().encode(endpoint))
        XCTAssertEqual(copy, endpoint)
        XCTAssertEqual(copy.name, "LM Studio")
    }
}
