import XCTest
@testable import DeckCore

private final class NoServerHTTP: AIHTTPFetching, @unchecked Sendable {
    var status = 0
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        guard status != 0 else { throw URLError(.cannotConnectToHost) }
        return (Data("{\"data\":[]}".utf8), status)
    }
}

private final class RecordingStreamer: CommandStreaming, @unchecked Sendable {
    var calls: [[String]] = []
    func stream(_ executable: String, _ arguments: [String]) -> AsyncThrowingStream<String, Error> {
        calls.append([executable] + arguments)
        return AsyncThrowingStream { continuation in
            continuation.yield("==> Installing Cask lm-studio")
            continuation.finish()
        }
    }
}

final class LMStudioRuntimeTests: XCTestCase {
    static let listJSON = """
    [{"type":"llm","modelKey":"qwen/qwen3-4b","format":"gguf","displayName":"Qwen3 4B","path":"qwen/qwen3-4b","sizeBytes":2497281632,"paramsString":"4B","architecture":"qwen3"},
     {"type":"embedding","modelKey":"text-embedding-nomic-embed-text-v1.5","format":"gguf","displayName":"Nomic Embed Text v1.5","sizeBytes":84106624}]
    """

    func testParseModels() {
        let models = LMStudioRuntime.parseModels(Self.listJSON)
        XCTAssertEqual(models.map(\.id), ["qwen/qwen3-4b", "text-embedding-nomic-embed-text-v1.5"])
        XCTAssertEqual(models[0].displayName, "Qwen3 4B")
        XCTAssertEqual(models[0].sizeBytes, 2_497_281_632)
        XCTAssertEqual(models[0].parameters, "4B")
        XCTAssertEqual(models[0].format, "gguf")
        XCTAssertTrue(models[1].isEmbedding)
        XCTAssertEqual(LMStudioRuntime.parseModels("Waking up LM Studio service...\n" + Self.listJSON).count, 2, "notice line before the JSON")
        XCTAssertEqual(LMStudioRuntime.parseModels("not json").count, 0)
    }

    func testParseLoadedAndServerStatus() {
        XCTAssertEqual(LMStudioRuntime.parseLoaded(#"[{"identifier":"qwen3-a","modelKey":"qwen/qwen3-4b"}]"#), ["qwen3-a", "qwen/qwen3-4b"])
        XCTAssertEqual(LMStudioRuntime.parseLoaded("[]"), [])
        XCTAssertEqual(LMStudioRuntime.parseServerStatus(#"{"running":true,"port":4321}"#)?.running, true)
        XCTAssertEqual(LMStudioRuntime.parseServerStatus(#"{"running":true,"port":4321}"#)?.port, 4321)
        XCTAssertEqual(LMStudioRuntime.parseServerStatus(#"{"running":false}"#)?.running, false)
        XCTAssertEqual(LMStudioRuntime.parseServerStatus("The server is running on port 1234.")?.port, 1234)
        XCTAssertEqual(LMStudioRuntime.parseServerStatus("The server is not running.")?.running, false)
        XCTAssertNil(LMStudioRuntime.parseServerStatus("hello"))
    }

    func testArguments() {
        XCTAssertEqual(LMStudioRuntime.startArguments(), ["server", "start"])
        XCTAssertEqual(LMStudioRuntime.startArguments(port: 4321), ["server", "start", "--port", "4321"])
        XCTAssertEqual(LMStudioRuntime.stopArguments, ["server", "stop"])
        XCTAssertEqual(LMStudioRuntime.loadArguments("qwen/qwen3-4b"), ["load", "qwen/qwen3-4b", "--yes"])
        XCTAssertEqual(LMStudioRuntime.unloadArguments("qwen/qwen3-4b"), ["unload", "qwen/qwen3-4b"])
        XCTAssertEqual(LMStudioRuntime.unloadArguments(nil), ["unload", "--all"])
        XCTAssertEqual(LMStudioRuntime.brewInstallCommandLine, "brew install --cask lm-studio")
    }

    func testFindsOnlyInToolsDirectory() {
        let runtime = LMStudioRuntime(toolsDirectory: "/stand-in", fileExists: { $0 == "/stand-in/lms" })
        XCTAssertEqual(runtime.findCLI(), "/stand-in/lms")
        XCTAssertNil(runtime.findBrew())
        XCTAssertNil(runtime.findApp())
        let normal = LMStudioRuntime(toolsDirectory: nil, fileExists: { $0 == "/Applications/LM Studio.app" || $0 == "/opt/homebrew/bin/brew" })
        XCTAssertEqual(normal.findApp(), "/Applications/LM Studio.app")
        XCTAssertEqual(normal.findBrew(), "/opt/homebrew/bin/brew")
        XCTAssertNil(normal.findCLI())
    }

    func testStatusModelsAndCommandsWithMock() async throws {
        let runner = MockRunner()
        runner.responses["server status --json"] = CommandResult(exitCode: 0, stdout: #"{"running":true,"port":1234}"#)
        runner.responses["ls --json"] = CommandResult(exitCode: 0, stdout: Self.listJSON)
        runner.responses["ps --json"] = CommandResult(exitCode: 0, stdout: #"[{"identifier":"qwen/qwen3-4b","modelKey":"qwen/qwen3-4b"}]"#)
        runner.responses["load qwen/qwen3-4b --yes"] = CommandResult(exitCode: 0, stdout: "loaded")
        runner.responses["unload --all"] = CommandResult(exitCode: 0, stdout: "")
        runner.responses["server start"] = CommandResult(exitCode: 0, stdout: "ok")
        let runtime = LMStudioRuntime(runner: runner, http: NoServerHTTP(), toolsDirectory: "/t", fileExists: { $0 == "/t/lms" })
        let status = await runtime.status()
        XCTAssertTrue(status.isInstalled)
        XCTAssertTrue(status.serverRunning)
        XCTAssertNil(status.brewPath, "no Homebrew, so no install button")
        let models = try await runtime.models()
        XCTAssertEqual(models.filter(\.isLoaded).map(\.id), ["qwen/qwen3-4b"])
        try await runtime.load("qwen/qwen3-4b")
        try await runtime.unload(nil)
        try await runtime.startServer()
        XCTAssertTrue(runner.calls.allSatisfy { $0.first == "/t/lms" })
        runner.responses["server stop"] = CommandResult(exitCode: 1, stdout: "", stderr: "no server")
        do {
            try await runtime.stopServer()
            XCTFail("a failed command throws")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("no server"))
        }
    }

    func testNotInstalledAndServerByHTTP() async throws {
        let http = NoServerHTTP()
        let runtime = LMStudioRuntime(runner: MockRunner(), http: http, toolsDirectory: "/empty", fileExists: { _ in false })
        var status = await runtime.status()
        XCTAssertFalse(status.isInstalled)
        XCTAssertFalse(status.serverRunning)
        http.status = 200
        status = await runtime.status()
        XCTAssertTrue(status.serverRunning, "a server answering on 1234 counts even without lms")
        do {
            _ = try await runtime.models()
            XCTFail("no lms")
        } catch {}
    }

    func testHomebrewInstallStreams() async throws {
        let streamer = RecordingStreamer()
        let runtime = LMStudioRuntime(runner: MockRunner(), streamer: streamer, toolsDirectory: "/t", fileExists: { $0 == "/t/brew" })
        var lines: [String] = []
        for try await line in try runtime.installWithHomebrew() { lines.append(line) }
        XCTAssertEqual(streamer.calls, [["/t/brew", "install", "--cask", "lm-studio"]])
        XCTAssertEqual(lines, ["==> Installing Cask lm-studio"])
        let none = LMStudioRuntime(runner: MockRunner(), streamer: streamer, toolsDirectory: "/t", fileExists: { _ in false })
        XCTAssertThrowsError(try none.installWithHomebrew())
    }

    /// Runs a real stand in `lms` script, the way debug runs do with DECK_LMSTUDIO_TOOLS_DIR.
    func testStandInScript() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lms-stand-in-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = """
        #!/bin/sh
        STATE="$(dirname "$0")/state"; mkdir -p "$STATE"; touch "$STATE/loaded"
        case "$1" in
          server) case "$2" in
            start) touch "$STATE/running" ;;
            stop) rm -f "$STATE/running" ;;
            status) if [ -f "$STATE/running" ]; then echo '{"running":true,"port":1234}'; else echo '{"running":false}'; fi ;;
          esac ;;
          ls) echo '[{"type":"llm","modelKey":"qwen/qwen3-4b","displayName":"Qwen3 4B","sizeBytes":100}]' ;;
          ps) if [ -s "$STATE/loaded" ]; then echo "[{\\"modelKey\\":\\"$(cat "$STATE/loaded")\\"}]"; else echo '[]'; fi ;;
          load) echo "$2" > "$STATE/loaded" ;;
          unload) : > "$STATE/loaded" ;;
          *) exit 1 ;;
        esac
        """
        let lms = dir.appendingPathComponent("lms")
        try script.write(to: lms, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lms.path)
        let runtime = LMStudioRuntime(http: NoServerHTTP(), toolsDirectory: dir.path)
        var status = await runtime.status()
        XCTAssertEqual(status.cliPath, lms.path)
        XCTAssertFalse(status.serverRunning)
        try await runtime.startServer()
        status = await runtime.status()
        XCTAssertTrue(status.serverRunning)
        try await runtime.load("qwen/qwen3-4b")
        var models = try await runtime.models()
        XCTAssertEqual(models.first?.isLoaded, true)
        try await runtime.unload(nil)
        models = try await runtime.models()
        XCTAssertEqual(models.first?.isLoaded, false)
        try await runtime.stopServer()
        status = await runtime.status()
        XCTAssertFalse(status.serverRunning)
    }
}
