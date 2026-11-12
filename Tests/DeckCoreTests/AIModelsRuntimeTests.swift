import XCTest
@testable import DeckCore

private final class LineStreamer: CommandStreaming, @unchecked Sendable {
    private(set) var calls: [[String]] = []
    func stream(_ executable: String, _ arguments: [String]) -> AsyncThrowingStream<String, Error> {
        calls.append([executable] + arguments)
        return AsyncThrowingStream { $0.finish() }
    }
}

final class AIModelsRuntimeTests: XCTestCase {
    private var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("deck-ai-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    // MARK: Chat stream

    func testParseOllamaStream() {
        let events = AIFixtures.ollamaSSE.split(separator: "\n").flatMap { ChatStreamParser.parse(line: String($0)) }
        let reasoning = events.compactMap { if case .reasoning(let text) = $0 { return text } else { return nil } }.joined()
        let content = events.compactMap { if case .content(let text) = $0 { return text } else { return nil } }.joined()
        XCTAssertEqual(reasoning, "Okay,")
        XCTAssertFalse(content.isEmpty)
        XCTAssertTrue(events.contains(.finished("stop")))
        XCTAssertTrue(events.contains(.usage(promptTokens: 20, completionTokens: 182)))
        XCTAssertEqual(events.last, .done)
    }

    func testParseMLXStreamSkipsKeepalives() {
        XCTAssertEqual(ChatStreamParser.parse(line: ": keepalive 10/11"), [])
        XCTAssertEqual(ChatStreamParser.parse(line: ""), [])
        let events = AIFixtures.mlxSSE.split(separator: "\n").flatMap { ChatStreamParser.parse(line: String($0)) }
        XCTAssertTrue(events.contains(.content("We")))
        XCTAssertTrue(events.contains(.finished("length")))
        XCTAssertTrue(events.contains(.usage(promptTokens: 11, completionTokens: 20)))
        XCTAssertEqual(events.last, .done)
    }

    func testParseStreamError() {
        XCTAssertEqual(ChatStreamParser.parse(line: #"data: {"error":{"message":"model not found"}}"#), [.failed("model not found")])
        XCTAssertEqual(ChatStreamParser.parse(line: "data: not json"), [])
    }

    func testNoLengthCapUnlessTheServerNeedsOne() {
        // A fixed cap counts thinking too: qwen3 used all 1024 tokens thinking and never answered.
        let body = ChatStreamParser.requestBody(model: "qwen3:4b", messages: [ChatMessage(role: .user, content: "Hi")],
                                                maxTokens: ModelServerKind.ollama.chatMaxTokens, temperature: nil)
        XCTAssertNil(body["max_tokens"], "Ollama answers until the model is done, like ollama run")
        XCTAssertNil(ModelServerKind.lmStudio.chatMaxTokens)
        XCTAssertNil(ModelServerKind.llamaCpp.chatMaxTokens)
        XCTAssertEqual(ModelServerKind.mlxLM.chatMaxTokens, 16_384, "mlx_lm.server stops at 512 without one")
    }

    func testLengthStop() {
        XCTAssertTrue(ChatStreamEvent.finished("length").isLengthStop)
        XCTAssertTrue(ChatStreamEvent.finished("max_tokens").isLengthStop)
        XCTAssertFalse(ChatStreamEvent.finished("stop").isLengthStop)
        XCTAssertFalse(ChatStreamEvent.content("length").isLengthStop)
    }

    func testRequestBody() {
        let body = ChatStreamParser.requestBody(model: "qwen3:0.6b", messages: [ChatMessage(role: .user, content: "Hi")], maxTokens: 64, temperature: nil)
        XCTAssertEqual(body["model"] as? String, "qwen3:0.6b")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual((body["stream_options"] as? [String: Bool])?["include_usage"], true)
        XCTAssertEqual(body["max_tokens"] as? Int, 64)
        XCTAssertNil(body["temperature"])
        XCTAssertEqual((body["messages"] as? [[String: String]])?.first?["role"], "user")
    }

    func testChatStatsSpeed() {
        let start = Date(timeIntervalSince1970: 1000)
        var stats = ChatStats(started: start)
        XCTAssertNil(stats.tokensPerSecond(now: start))
        stats.record(.content("a"), at: start.addingTimeInterval(0.5))
        for i in 1...10 {
            stats.record(.content("b"), at: start.addingTimeInterval(0.5 + Double(i) * 0.1))
        }
        stats.record(.done, at: start.addingTimeInterval(1.5))
        XCTAssertEqual(stats.timeToFirstToken ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(stats.tokens, 11)
        XCTAssertEqual(stats.tokensPerSecond() ?? 0, 10, accuracy: 0.001)
        stats.record(.usage(promptTokens: 5, completionTokens: 21))
        XCTAssertEqual(stats.tokens, 21, "the server's count wins")
        XCTAssertEqual(stats.tokensPerSecond() ?? 0, 20, accuracy: 0.001)
    }

    // MARK: Ollama

    func testParsePullProgress() {
        let lines = AIFixtures.ollamaPull.split(separator: "\n").compactMap { OllamaPullProgress.parse(String($0)) }
        XCTAssertEqual(lines.first?.stepText, "Reading manifest")
        XCTAssertEqual(lines[1].total, 522_640_096)
        XCTAssertEqual(lines[1].fraction, 1)
        XCTAssertTrue(lines[1].stepText.hasPrefix("Downloading 7f4030143c1c"))
        XCTAssertTrue(lines.last?.isSuccess == true)
        let error = OllamaPullProgress.parse(#"{"error":"pull model manifest: file does not exist"}"#)
        XCTAssertEqual(error?.error, "pull model manifest: file does not exist")
        XCTAssertNil(OllamaPullProgress.parse(""))
    }

    func testOllamaLoadAndUnloadBodies() {
        XCTAssertEqual(OllamaClient.loadBody("qwen3:0.6b")["keep_alive"] as? Int, -1)
        XCTAssertEqual(OllamaClient.unloadBody("qwen3:0.6b")["keep_alive"] as? Int, 0)
    }

    func testOllamaStartPrefersCommandLineTool() {
        let both = OllamaControl(fileExists: { $0 == "/opt/homebrew/bin/ollama" || $0 == "/Applications/Ollama.app" })
        let command = both.startCommand(logFile: "/tmp/o.log")
        XCTAssertEqual(command?.0, "/bin/sh")
        XCTAssertEqual(command?.1.last, "nohup '/opt/homebrew/bin/ollama' serve >> '/tmp/o.log' 2>&1 &")

        let appOnly = OllamaControl(fileExists: { $0.hasPrefix("/Applications/Ollama.app") })
        XCTAssertEqual(appOnly.startCommand(logFile: "/tmp/o.log")?.1, ["-g", "-j", "-a", "/Applications/Ollama.app"])

        XCTAssertNil(OllamaControl(fileExists: { _ in false }).startCommand(logFile: "/tmp/o.log"))
        XCTAssertFalse(OllamaControl(fileExists: { _ in false }).isInstalled)
    }

    // MARK: MLX runtime

    func testRuntimeInstallStaysInOurFolder() {
        let paths = AIPaths(base: URL(fileURLWithPath: "/Users/me/Library/Application Support/x/AI"))
        let runtime = MLXRuntime(paths: paths, runner: MockRunner(), streamer: LineStreamer(), isExecutable: { _ in false })
        let args = runtime.installArguments(uv: "/opt/homebrew/bin/uv")
        XCTAssertTrue(args.contains("UV_TOOL_DIR=/Users/me/Library/Application Support/x/AI/uv-tools"))
        XCTAssertTrue(args.contains("UV_TOOL_BIN_DIR=/Users/me/Library/Application Support/x/AI/bin"))
        XCTAssertTrue(args.contains("UV_PYTHON_INSTALL_DIR=/Users/me/Library/Application Support/x/AI/python"))
        XCTAssertTrue(args.contains("UV_PYTHON_PREFERENCE=only-managed"))
        XCTAssertTrue(args.contains("UV_HTTP_TIMEOUT=300"))
        XCTAssertTrue(args.contains("UV_HTTP_RETRIES=5"))
        XCTAssertEqual(Array(args.suffix(6)), ["/opt/homebrew/bin/uv", "tool", "install", "--python", "3.12", "mlx-lm"])
        XCTAssertEqual(Array(runtime.installArguments(uv: "uv", upgrade: true).suffix(2)), ["--upgrade", "mlx-lm"])
        XCTAssertFalse(args.contains("sudo"))
    }

    func testRuntimeStatusWithOwnInstall() async {
        let paths = AIPaths(base: URL(fileURLWithPath: "/AI"))
        let runner = MockRunner()
        runner.responses["--version"] = CommandResult(exitCode: 0, stdout: "uv 0.9.28 (Homebrew 2026-01-29)\n")
        let env = MLXRuntime(paths: paths, runner: runner, streamer: LineStreamer(), isExecutable: { _ in false }).environmentArguments()
        runner.responses[(env + ["/opt/homebrew/bin/uv", "tool", "list"]).joined(separator: " ")] =
            CommandResult(exitCode: 0, stdout: "mlx-lm v0.32.2\n- mlx_lm\n- mlx_lm.server\n")
        let runtime = MLXRuntime(paths: paths, runner: runner, streamer: LineStreamer(),
                                 isExecutable: { $0 == "/opt/homebrew/bin/uv" || $0 == "/AI/bin/mlx_lm.server" })
        let status = await runtime.status()
        XCTAssertEqual(status.uvPath, "/opt/homebrew/bin/uv")
        XCTAssertEqual(status.uvVersion, "0.9.28")
        XCTAssertEqual(status.serverPath, "/AI/bin/mlx_lm.server")
        XCTAssertEqual(status.mlxVersion, "0.32.2")
        XCTAssertTrue(status.isOwnInstall)
        XCTAssertTrue(status.isReady)
    }

    func testRuntimeStatusWithNothingInstalled() async {
        let runtime = MLXRuntime(paths: AIPaths(base: URL(fileURLWithPath: "/AI")), runner: MockRunner(), streamer: LineStreamer(), isExecutable: { _ in false })
        let status = await runtime.status()
        XCTAssertNil(status.uvPath)
        XCTAssertNil(status.serverPath)
        XCTAssertFalse(status.isReady)
    }

    func testOwnUVIsPreferred() {
        let paths = AIPaths(base: URL(fileURLWithPath: "/AI"))
        let runtime = MLXRuntime(paths: paths, runner: MockRunner(), streamer: LineStreamer(), isExecutable: { $0 == "/AI/bin/uv" || $0 == "/opt/homebrew/bin/uv" })
        XCTAssertEqual(runtime.findUV(), "/AI/bin/uv")
    }

    func testParseToolList() {
        XCTAssertEqual(MLXRuntime.parseToolList("mlx-lm v0.32.2\n- mlx_lm\nnano-pdf v0.2.1\n- nano-pdf\n"), ["mlx-lm": "0.32.2", "nano-pdf": "0.2.1"])
        XCTAssertEqual(MLXRuntime.parseToolList("No tools installed"), [:])
        XCTAssertNil(MLXRuntime.parseUVVersion("garbage"))
    }

    // MARK: MLX server

    func testServerArgumentsAndBind() {
        let mac = MLXServerConfig(model: "/m/SmolLM", bind: .mac, port: 8585)
        XCTAssertEqual(MLXServerPlan.arguments(mac), ["--model", "/m/SmolLM", "--host", "127.0.0.1", "--port", "8585"])
        XCTAssertEqual(mac.baseURL.absoluteString, "http://127.0.0.1:8585/v1")
        let containers = MLXServerConfig(model: "mlx-community/x", bind: .containers(gateway: "192.168.64.1"), port: 9000)
        XCTAssertEqual(MLXServerPlan.arguments(containers)[3], "192.168.64.1")
        XCTAssertEqual(containers.baseURL.absoluteString, "http://192.168.64.1:9000/v1")
        XCTAssertNotEqual(containers.bind.host, "0.0.0.0", "never all addresses")
    }

    func testServerEnvironment() {
        let local = MLXServerPlan.environment(base: ["PATH": "/usr/bin"], model: "/models/x")
        XCTAssertEqual(local["HF_HUB_OFFLINE"], "1")
        XCTAssertEqual(local["PATH"], "/usr/bin")
        XCTAssertNotNil(local["HF_HUB_CACHE"])
        XCTAssertNil(MLXServerPlan.environment(base: [:], model: "mlx-community/x")["HF_HUB_OFFLINE"])
        XCTAssertTrue(MLXServerPlan.isServerCommand("python /x/bin/mlx_lm.server --model y"))
        XCTAssertFalse(MLXServerPlan.isServerCommand("python other.py"))
    }

    func testServerRecordRoundTripAndAdoptRejectsDeadProcess() throws {
        let paths = AIPaths(base: temp)
        let record = MLXServerRecord(pid: 999_999, config: MLXServerConfig(model: "/m", bind: .containers(gateway: "192.168.64.1"), port: 8585))
        record.save(paths: paths)
        XCTAssertEqual(MLXServerRecord.load(paths: paths)?.config, record.config)
        let controller = MLXServerController(paths: paths)
        XCTAssertFalse(controller.adopt(commandOf: { _ in "mlx_lm.server" }))
        XCTAssertNil(MLXServerRecord.load(paths: paths), "a stale record is removed")
    }

    func testServerStartsStopsAndReportsCrash() async throws {
        // A stand in for mlx_lm.server: a shell script that prints and waits.
        let paths = AIPaths(base: temp)
        let script = temp.appendingPathComponent("fake-server.sh")
        try "#!/bin/sh\necho \"Starting httpd at $4 on port $6...\"\nexec sleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let controller = MLXServerController(paths: paths)
        let exits = ExitBox()
        controller.onExit = { code, crashed in exits.add(code, crashed) }
        try controller.start(MLXServerConfig(model: "/m", port: 8599), serverPath: script.path)
        guard case .starting(let pid) = controller.state else { return XCTFail("not starting") }
        XCTAssertNotNil(MLXServerRecord.load(paths: paths))
        XCTAssertThrowsError(try controller.start(MLXServerConfig(model: "/m"), serverPath: script.path))

        // Wait for the condition, not a fixed time: under a full parallel test run the
        // shell can take longer than a few hundred milliseconds to print.
        let expected = ["Starting httpd at 127.0.0.1 on port 8599..."]
        try await waitUntil { LogTail(url: paths.serverLog).read() == expected }
        XCTAssertEqual(LogTail(url: paths.serverLog).read(), expected)

        await controller.stop(grace: 2)
        try await waitUntil { controller.state == .stopped }
        XCTAssertEqual(controller.state, .stopped)
        XCTAssertFalse(MLXServerController.isAlive(pid))
        XCTAssertEqual(exits.values.map(\.1), [false], "a requested stop is not a crash")
        XCTAssertNil(MLXServerRecord.load(paths: paths))

        // Now kill it from outside: that is a crash.
        try controller.start(MLXServerConfig(model: "/m", port: 8599), serverPath: script.path)
        let second = try XCTUnwrap(controller.state.pid)
        kill(second, SIGKILL)
        try await waitUntil { controller.state == .crashed(code: -9) }
        XCTAssertEqual(controller.state, .crashed(code: -9))
        XCTAssertEqual(exits.values.last?.1, true)
    }

    func testLogTailReadsOnlyNewLines() throws {
        let file = temp.appendingPathComponent("log.txt")
        try "one\ntwo\npart".write(to: file, atomically: true, encoding: .utf8)
        let tail = LogTail(url: file)
        XCTAssertEqual(tail.read(), ["one", "two"])
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("ial\nthree\n".utf8))
        try handle.close()
        XCTAssertEqual(tail.read(), ["partial", "three"])
        XCTAssertEqual(tail.read(), [])
        try "new\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(tail.read(), ["new"], "a shorter file starts over")
    }
}

private final class ExitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(Int32?, Bool)] = []
    var values: [(Int32?, Bool)] { lock.lock(); defer { lock.unlock() }; return items }
    func add(_ code: Int32?, _ crashed: Bool) { lock.lock(); items.append((code, crashed)); lock.unlock() }

}

/// Polls `condition` every 50 ms until it is true or `timeout` passes. Never fails by itself,
/// the assertion after it reports the real problem. Use instead of fixed sleeps in timing tests.
private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition(), clock.now < deadline {
        try await Task.sleep(for: .milliseconds(50))
    }
}
