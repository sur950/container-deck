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

    /// A stand in `lms` like LM Studio core: `server start` fails unless `daemon up` ran first.
    /// Every call is written to state/calls so tests can check the order.
    static let standInLMS = """
    #!/bin/sh
    STATE="$(dirname "$0")/state"; mkdir -p "$STATE"; touch "$STATE/loaded"
    echo "$*" >> "$STATE/calls"
    case "$1" in
      daemon) case "$2" in
        up) touch "$STATE/daemon"; echo '{"status":"running","pid":4242,"isDaemon":true}' ;;
        down) rm -f "$STATE/daemon" "$STATE/running" ;;
        status) if [ -f "$STATE/daemon" ]; then echo '{"status":"running","pid":4242,"isDaemon":true}'; else echo '{"status":"not-running"}'; fi ;;
        *) exit 1 ;;
      esac ;;
      server) case "$2" in
        start) if [ -f "$STATE/daemon" ]; then touch "$STATE/running"; else echo "LM Studio service is not running" >&2; exit 1; fi ;;
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

    private func makeToolsDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lms-stand-in-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeExecutable(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func calls(_ dir: URL) -> [String] {
        let text = (try? String(contentsOf: dir.appendingPathComponent("state/calls"), encoding: .utf8)) ?? ""
        return text.split(whereSeparator: \.isNewline).map(String.init)
    }

    /// Runs a real stand in `lms` script, the way debug runs do with DECK_LMSTUDIO_TOOLS_DIR.
    func testStandInScript() async throws {
        let dir = try makeToolsDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let lms = dir.appendingPathComponent("lms")
        try writeExecutable(Self.standInLMS, to: lms)
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

    func testDaemonComesUpBeforeServer() async throws {
        let dir = try makeToolsDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeExecutable(Self.standInLMS, to: dir.appendingPathComponent("lms"))
        let runtime = LMStudioRuntime(http: NoServerHTTP(), toolsDirectory: dir.path)

        let before = await runtime.daemonStatus()
        XCTAssertEqual(before, .notRunning)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("state/calls"))
        try await runtime.startServer()
        let started = calls(dir)
        XCTAssertEqual(started, ["daemon status --json", "daemon up", "server start"], "daemon up runs before server start")
        let after = await runtime.daemonStatus()
        XCTAssertEqual(after, .running)

        // Daemon already up: no second daemon up.
        try await runtime.stopServer()
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("state/calls"))
        try await runtime.startServer()
        XCTAssertEqual(calls(dir), ["daemon status --json", "server start"])

        try await runtime.daemonDown()
        let down = await runtime.daemonStatus()
        XCTAssertEqual(down, .notRunning)
        let status = await runtime.status()
        XCTAssertFalse(status.serverRunning, "daemon down stops the server too")
    }

    func testDaemonUpFailureIsReported() async throws {
        let dir = try makeToolsDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeExecutable("""
        #!/bin/sh
        case "$1 $2" in
          "daemon status") echo '{"status":"not-running"}' ;;
          "daemon up") echo "Could not start llmster" >&2; exit 3 ;;
          *) exit 1 ;;
        esac
        """, to: dir.appendingPathComponent("lms"))
        let runtime = LMStudioRuntime(http: NoServerHTTP(), toolsDirectory: dir.path)
        do {
            try await runtime.startServer()
            XCTFail("daemon up failed, so start fails")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Could not start llmster"), error.localizedDescription)
        }
    }

    func testParseDaemonStatus() {
        XCTAssertEqual(LMStudioRuntime.parseDaemonStatus(#"{ "status": "running", "pid": 12345, "isDaemon": true }"#), .running)
        XCTAssertEqual(LMStudioRuntime.parseDaemonStatus(#"{ "status": "not-running" }"#), .notRunning)
        XCTAssertEqual(LMStudioRuntime.parseDaemonStatus("notice\n" + #"{"status":"running","pid":26754,"isDaemon":true,"version":"0.4.4+1"}"#), .running)
        XCTAssertEqual(LMStudioRuntime.parseDaemonStatus("The daemon is not running."), .notRunning)
        XCTAssertEqual(LMStudioRuntime.parseDaemonStatus("error: unknown command 'daemon'"), .unknown)
        XCTAssertEqual(LMStudioRuntime.parseDaemonStatus(""), .unknown)
    }

    func testOlderLMSWithoutDaemonStillStartsServer() async throws {
        let runner = MockRunner()
        runner.responses["server start"] = CommandResult(exitCode: 0, stdout: "ok")
        let runtime = LMStudioRuntime(runner: runner, http: NoServerHTTP(), toolsDirectory: "/t", fileExists: { $0 == "/t/lms" })
        try await runtime.startServer()
        XCTAssertEqual(runner.calls, [["/t/lms", "daemon", "status", "--json"], ["/t/lms", "server", "start"]],
                       "no daemon up when the status is unclear")
    }

    func testInstallCoreCommand() async throws {
        XCTAssertEqual(LMStudioRuntime.installCoreCommandLine, "curl -fsSL https://lmstudio.ai/install.sh | bash")
        let streamer = RecordingStreamer()
        // No tools folder: the real installer command is built (the recording streamer never runs it).
        let real = LMStudioRuntime(runner: MockRunner(), streamer: streamer, toolsDirectory: nil, fileExists: { _ in false })
        XCTAssertEqual(real.installCoreCommand().executable, "/bin/bash")
        XCTAssertEqual(real.installCoreCommand().arguments, ["-c", "set -o pipefail; curl -fsSL https://lmstudio.ai/install.sh | bash"])
        for try await _ in try real.installCore() {}
        XCTAssertEqual(streamer.calls, [["/bin/bash", "-c", "set -o pipefail; curl -fsSL https://lmstudio.ai/install.sh | bash"]])
        // A tools folder runs its stand in install.sh, never the real script.
        let standIn = LMStudioRuntime(runner: MockRunner(), streamer: streamer, toolsDirectory: "/t", fileExists: { $0 == "/t/install.sh" })
        XCTAssertEqual(standIn.installCoreCommand().arguments, ["/t/install.sh"])
        let missing = LMStudioRuntime(runner: MockRunner(), streamer: streamer, toolsDirectory: "/t", fileExists: { _ in false })
        XCTAssertThrowsError(try missing.installCore())
    }

    /// The stand in installer puts a stand in lms in place, and the install then counts as LM Studio core.
    func testStandInInstallCoreThenHeadless() async throws {
        let dir = try makeToolsDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("lms.template")
        try Self.standInLMS.write(to: source, atomically: true, encoding: .utf8)
        try writeExecutable("""
        #!/bin/bash
        echo "Installing llmster..."
        cp "$(dirname "$0")/lms.template" "$(dirname "$0")/lms" && chmod +x "$(dirname "$0")/lms"
        echo "lms install location: $(dirname "$0")/lms"
        """, to: dir.appendingPathComponent("install.sh"))
        let runtime = LMStudioRuntime(http: NoServerHTTP(), toolsDirectory: dir.path)
        var status = await runtime.status()
        XCTAssertFalse(status.isInstalled)
        var lines: [String] = []
        for try await line in try runtime.installCore() { lines.append(line) }
        XCTAssertEqual(lines.first, "Installing llmster...")
        status = await runtime.status()
        XCTAssertTrue(status.isInstalled)
        XCTAssertTrue(status.isCoreOnly)
        XCTAssertEqual(status.installLabel, "LM Studio core")
    }

    func testHeadlessDetection() async {
        let core = LMStudioRuntime(runner: MockRunner(), http: NoServerHTTP(), toolsDirectory: "/t", fileExists: { $0 == "/t/lms" })
        let coreStatus = await core.status()
        XCTAssertTrue(coreStatus.isInstalled, "lms without the app counts as installed")
        XCTAssertTrue(coreStatus.isCoreOnly)
        XCTAssertEqual(coreStatus.installLabel, "LM Studio core")

        let app = LMStudioRuntime(runner: MockRunner(), http: NoServerHTTP(), toolsDirectory: "/t",
                                  fileExists: { $0 == "/t/lms" || $0 == "/t/LM Studio.app" })
        let appStatus = await app.status()
        XCTAssertFalse(appStatus.isCoreOnly)
        XCTAssertEqual(appStatus.installLabel, "LM Studio app")

        // The real search finds LM Studio core in ~/.lmstudio/bin, where its installer puts lms.
        let home = AIConfig.expand("~/.lmstudio/bin/lms")
        let normal = LMStudioRuntime(runner: MockRunner(), http: NoServerHTTP(), toolsDirectory: nil, fileExists: { $0 == home })
        XCTAssertEqual(normal.findCLI(), home)
        XCTAssertNil(normal.findApp())
        XCTAssertEqual(LMStudioStatus().installLabel, nil)
    }

    func testDiskImageFailureMapping() {
        // From the owner's v1.1.0 run of brew install --cask lm-studio on macOS 27.2.
        let brewOutput = """
        ==> Downloading https://installers.lmstudio.ai/darwin/arm64/0.3.30-2/LM-Studio-0.3.30-2-arm64.dmg
        Error: Failure while executing; `/usr/bin/hdiutil attach -plist -nobrowse -readonly -mountrandom /private/tmp/d20261106-1234-abc /Users/suresh/Library/Caches/Homebrew/downloads/abc--LM-Studio-0.3.30-2-arm64.dmg` exited with 1. Here's the output:
        hdiutil: attach failed - no mountable file systems
        """
        XCTAssertTrue(LMStudioRuntime.isDiskImageFailure(brewOutput))
        XCTAssertTrue(LMStudioRuntime.isDiskImageFailure("hdiutil: attach failed - no mountable file systems"))
        XCTAssertTrue(LMStudioRuntime.isDiskImageFailure("hdiutil: attach failed - image not recognized"))
        XCTAssertFalse(LMStudioRuntime.isDiskImageFailure("Error: Download failed on Cask 'lm-studio'"))
        XCTAssertFalse(LMStudioRuntime.isDiskImageFailure(""))
        XCTAssertEqual(LMStudioRuntime.diskImageFailureMessage, "This Mac can't open LM Studio's disk image. Use Install LM Studio core instead.")
    }
}
