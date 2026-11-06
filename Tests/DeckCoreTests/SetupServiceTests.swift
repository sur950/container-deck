import XCTest
@testable import DeckCore

/// Replays canned command output. Keyed by the arguments joined with spaces.
final class MockRunner: CommandRunning, @unchecked Sendable {
    var responses: [String: CommandResult] = [:]
    private let lock = NSLock()
    private var recorded: [[String]] = []
    /// Calls in the order they started. Safe when calls run at the same time.
    var calls: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func run(_ executable: String, _ arguments: [String], stdin: Data?) async throws -> CommandResult {
        record([executable] + arguments)
            ?? CommandResult(exitCode: 1, stdout: "", stderr: "not mocked")
    }

    private func record(_ call: [String]) -> CommandResult? {
        lock.lock(); defer { lock.unlock() }
        recorded.append(call)
        return responses[call.dropFirst().joined(separator: " ")]
    }
}

private func fakeFiles(executables: Set<String> = [], files: Set<String> = [], dirs: [String: [String]] = [:]) -> FileSystem {
    FileSystem(
        fileExists: { files.contains($0) || executables.contains($0) },
        isExecutable: { executables.contains($0) },
        contentsOfDirectory: { dirs[$0] ?? [] }
    )
}

private let appRoot = "/Users/test/Library/Application Support/com.apple.container"

private func environment(
    files: FileSystem,
    system: SystemInfo = SystemInfo(isAppleSilicon: true, osMajor: 26, osMinor: 0)
) -> SetupEnvironment {
    SetupEnvironment(system: system, files: files, pathEnv: "/usr/bin:/bin", customCLIPath: nil, appRoot: appRoot)
}

final class SetupServiceTests: XCTestCase {

    func testVersionParsing() {
        XCTAssertEqual(
            SemanticVersion.firstMatch(in: "container CLI version 0.5.0 (build: release, commit: 1a2b3c)"),
            SemanticVersion(0, 5, 0)
        )
        XCTAssertEqual(SemanticVersion.firstMatch(in: "1.1"), SemanticVersion(1, 1, 0))
        XCTAssertNil(SemanticVersion.firstMatch(in: "no version here"))
        XCTAssertTrue(SemanticVersion(0, 9, 9) < SemanticVersion(1, 0, 0))
    }

    func testLocatorPrefersCustomPath() {
        let files = fakeFiles(executables: ["/custom/container", "/usr/local/bin/container"])
        let locator = ContainerCLILocator(files: files, pathEnv: "")
        XCTAssertEqual(locator.locate(customPath: "/custom/container"), "/custom/container")
        XCTAssertEqual(locator.locate(customPath: nil), "/usr/local/bin/container")
    }

    func testLocatorSearchesPath() {
        let files = fakeFiles(executables: ["/somewhere/bin/container"])
        let locator = ContainerCLILocator(files: files, pathEnv: "/usr/bin:/somewhere/bin")
        XCTAssertEqual(locator.locate(customPath: nil), "/somewhere/bin/container")
    }

    func testNotInstalled() async {
        let service = SetupService(runner: MockRunner(), environment: environment(files: fakeFiles()))
        let report = await service.runChecks()

        XCTAssertFalse(report.isReady)
        XCTAssertNil(report.cliPath)
        XCTAssertEqual(report.check(.cliInstalled)?.fix, .installPlatform)
        XCTAssertEqual(report.firstIssue?.id, .cliInstalled)
        if case .waiting? = report.check(.service)?.state {} else {
            XCTFail("Service check should wait for the install step")
        }
    }

    func testServiceStopped() async {
        let runner = MockRunner()
        runner.responses["--version"] = CommandResult(exitCode: 0, stdout: "container CLI version 1.0.0")
        runner.responses["system status"] = CommandResult(exitCode: 1, stdout: "apiserver is not running")

        let files = fakeFiles(executables: ["/usr/local/bin/container"])
        let report = await SetupService(runner: runner, environment: environment(files: files)).runChecks()

        XCTAssertEqual(report.cliPath, "/usr/local/bin/container")
        XCTAssertEqual(report.cliVersion, SemanticVersion(1, 0, 0))
        XCTAssertFalse(report.serviceRunning)
        XCTAssertEqual(report.check(.service)?.fix, .startService)
        XCTAssertEqual(report.check(.kernel)?.fix, .installKernel)
        XCTAssertFalse(report.isReady)
    }

    func testAllReady() async {
        let runner = MockRunner()
        runner.responses["--version"] = CommandResult(exitCode: 0, stdout: "container CLI version 1.1.0")
        runner.responses["system status"] = CommandResult(exitCode: 0, stdout: "apiserver is running")
        runner.responses["system dns list"] = CommandResult(exitCode: 0, stdout: "DOMAIN\ntest\n")

        let files = fakeFiles(
            executables: ["/usr/local/bin/container"],
            files: ["/Library/Apple/usr/libexec/oah/libRosettaRuntime"],
            dirs: [appRoot + "/kernels": ["default.kernel-arm64", "vmlinux-6.12"]]
        )
        let report = await SetupService(runner: runner, environment: environment(files: files)).runChecks()

        XCTAssertTrue(report.isReady)
        XCTAssertNil(report.firstIssue)
        XCTAssertEqual(report.check(.dns)?.state, .ok("Containers can use names like web.test"))
        XCTAssertEqual(report.check(.rosetta)?.state, .ok("Installed"))
        XCTAssertEqual(report.check(.terminalCommand)?.state, .ok("Ready to use in Terminal"))
    }

    func testOldVersionNeedsUpgrade() async {
        let runner = MockRunner()
        runner.responses["--version"] = CommandResult(exitCode: 0, stdout: "container CLI version 0.3.0")
        runner.responses["system status"] = CommandResult(exitCode: 0, stdout: "apiserver is running")

        let files = fakeFiles(executables: ["/opt/homebrew/bin/container"])
        let report = await SetupService(runner: runner, environment: environment(files: files)).runChecks()

        XCTAssertEqual(report.check(.cliVersion)?.fix, .installPlatform)
        XCTAssertFalse(report.isReady)
    }

    func testNewerVersionIsOK() async {
        let runner = MockRunner()
        runner.responses["--version"] = CommandResult(exitCode: 0, stdout: "container CLI version 9.0.0")
        let files = fakeFiles(executables: ["/usr/local/bin/container"])
        let report = await SetupService(runner: runner, environment: environment(files: files)).runChecks()

        XCTAssertEqual(report.check(.cliVersion)?.state, .ok("Version 9.0.0"))
    }

    func testIntelMacFails() async {
        let env = environment(files: fakeFiles(), system: SystemInfo(isAppleSilicon: false, osMajor: 15, osMinor: 0))
        let report = await SetupService(runner: MockRunner(), environment: env).runChecks()
        if case .failed? = report.check(.hardware)?.state {} else {
            XCTFail("Intel Macs are not supported")
        }
    }

    func testShellQuoting() {
        XCTAssertEqual(PrivilegedRunner.shellQuote("/a b/c"), "'/a b/c'")
        XCTAssertEqual(PrivilegedRunner.shellQuote("it's"), "'it'\\''s'")
        XCTAssertEqual(PrivilegedRunner.appleScriptEscape("say \"hi\""), "say \\\"hi\\\"")
    }

    func testParseRelease() throws {
        let json = """
        {"tag_name":"1.1.0","assets":[
          {"name":"container-1.1.0-installer-unsigned.zip","browser_download_url":"https://example.com/a.zip"},
          {"name":"container-1.1.0-installer-signed.pkg","browser_download_url":"https://example.com/b.pkg"}
        ]}
        """
        let release = try PlatformInstaller.parseRelease(Data(json.utf8))
        XCTAssertEqual(release.version, "1.1.0")
        XCTAssertEqual(release.packageName, "container-1.1.0-installer-signed.pkg")
    }
}
