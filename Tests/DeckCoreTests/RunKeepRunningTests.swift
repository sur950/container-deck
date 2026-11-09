import XCTest
@testable import DeckCore

/// Images that start a bare shell (ubuntu, debian, alpine) stop at once with
/// no terminal. Checks the bare shell rule, the Run sheet "Keep it running"
/// options and the stopped container note.
final class RunKeepRunningTests: XCTestCase {
    private let ubuntu = ImageConfigInfo(cmd: ["/bin/bash"])
    private let alpine = ImageConfigInfo(cmd: ["/bin/sh"])
    private let nginx = ImageConfigInfo(entrypoint: ["/docker-entrypoint.sh"], cmd: ["nginx", "-g", "daemon off;"])
    private let shellEntrypoint = ImageConfigInfo(entrypoint: ["/bin/bash"])

    // MARK: Bare shell rule

    func testBareShells() {
        for words in [["bash"], ["sh"], ["zsh"], ["ash"], ["dash"], ["fish"],
                      ["/bin/bash"], ["/bin/sh"], ["/usr/bin/zsh"], ["/usr/bin/fish"], ["/usr/local/bin/fish"],
                      ["/bin/bash", "-l"], ["bash", "--login"], ["sh", "-i"], ["/bin/bash", "-il"]] {
            XCTAssertEqual(BareShell.shell(in: words), words[0], "\(words)")
        }
    }

    func testNotBareShells() {
        for words in [[], ["bash", "-c", "echo hi"], ["sh", "/start.sh"], ["/bin/bash", "run.sh"],
                      ["nginx", "-g", "daemon off;"], ["sleep", "infinity"], ["/opt/bin/bash"], ["bashful"],
                      ["/bin/bash", "-l", "-c", "x"], ["python3"], ["/docker-entrypoint.sh", "bash"], [""]] {
            XCTAssertNil(BareShell.shell(in: words), "\(words)")
        }
    }

    // MARK: Effective command

    func testEffectiveCommandFromImage() {
        XCTAssertEqual(BareShell.effectiveCommand(RunOptions(image: "ubuntu"), image: ubuntu), ["/bin/bash"])
        XCTAssertEqual(BareShell.effectiveCommand(RunOptions(image: "nginx"), image: nginx),
                       ["/docker-entrypoint.sh", "nginx", "-g", "daemon off;"])
        XCTAssertNil(BareShell.effectiveCommand(RunOptions(image: "x"), image: nil))
    }

    func testCommandReplacesImageCmdButKeepsEntrypoint() {
        let run = RunOptions(image: "nginx", command: ["sh"])
        XCTAssertEqual(BareShell.effectiveCommand(run, image: nginx), ["/docker-entrypoint.sh", "sh"])
        XCTAssertNil(BareShell.exitingShell(run, image: nginx), "the entrypoint script runs first")
        XCTAssertEqual(BareShell.exitingShell(RunOptions(image: "ubuntu", command: ["sh"]), image: ubuntu), "sh")
    }

    func testEntrypointReplacesBoth() {
        let run = RunOptions(image: "nginx", command: ["-l"], entrypoint: "/bin/bash")
        XCTAssertEqual(BareShell.effectiveCommand(run, image: nginx), ["/bin/bash", "-l"])
        XCTAssertEqual(BareShell.exitingShell(run, image: nginx), "/bin/bash")
    }

    func testExitingShell() {
        XCTAssertEqual(BareShell.exitingShell(RunOptions(image: "ubuntu"), image: ubuntu), "/bin/bash")
        XCTAssertEqual(BareShell.exitingShell(RunOptions(image: "alpine"), image: alpine), "/bin/sh")
        XCTAssertNil(BareShell.exitingShell(RunOptions(image: "nginx"), image: nginx))
        XCTAssertNil(BareShell.exitingShell(RunOptions(image: "ubuntu", command: ["bash", "-c", "sleep 9"]), image: ubuntu))
        XCTAssertNil(BareShell.exitingShell(RunOptions(image: "ubuntu", tty: true), image: ubuntu), "a terminal keeps it open")
    }

    // MARK: Keep it running

    func testKeepRunningSetsSleepWhenOnAndNoCommand() {
        let run = RunOptions(image: "ubuntu:latest").applyingKeepRunning(true, image: ubuntu)
        XCTAssertEqual(run.command, ["sleep", "infinity"])
        XCTAssertNil(run.entrypoint)
        XCTAssertEqual(run.labels[BareShell.shellLabel], "/bin/bash")
    }

    func testKeepRunningOffChangesNothing() {
        let base = RunOptions(image: "ubuntu:latest")
        XCTAssertEqual(base.applyingKeepRunning(false, image: ubuntu), base)
    }

    func testKeepRunningLeavesUserCommandAlone() {
        let withCommand = RunOptions(image: "ubuntu", command: ["bash"])
        XCTAssertEqual(withCommand.applyingKeepRunning(true, image: ubuntu), withCommand)
        let withEntrypoint = RunOptions(image: "ubuntu", entrypoint: "/bin/sh")
        XCTAssertEqual(withEntrypoint.applyingKeepRunning(true, image: ubuntu), withEntrypoint)
        XCTAssertNil(withCommand.keepRunningShell(image: ubuntu))
        XCTAssertNil(withEntrypoint.keepRunningShell(image: ubuntu))
    }

    func testKeepRunningNeedsKnownBareShellImage() {
        let base = RunOptions(image: "nginx")
        XCTAssertEqual(base.applyingKeepRunning(true, image: nginx), base)
        XCTAssertEqual(base.applyingKeepRunning(true, image: nil), base, "image not on this Mac")
        XCTAssertEqual(RunOptions(image: "ubuntu", tty: true).applyingKeepRunning(true, image: ubuntu).command, [])
    }

    func testKeepRunningReplacesShellEntrypoint() {
        // A command alone would become "/bin/bash sleep infinity".
        let run = RunOptions(image: "shelly").applyingKeepRunning(true, image: shellEntrypoint)
        XCTAssertEqual(run.entrypoint, "sleep")
        XCTAssertEqual(run.command, ["infinity"])
    }

    func testKeepRunningArguments() {
        let client = ContainerClient(cliPath: "/usr/local/bin/container", runner: MockRunner())
        let args = client.runArguments(RunOptions(image: "ubuntu:latest", name: "box").applyingKeepRunning(true, image: ubuntu))
        XCTAssertEqual(Array(args.suffix(3)), ["ubuntu:latest", "sleep", "infinity"])
        XCTAssertTrue(args.contains("deck.shell=/bin/bash"))
        XCTAssertFalse(args.contains("-t") || args.contains("--tty"))
    }

    func testKeptRunningClearsOldShellEntrypoint() {
        let run = RunOptions(image: "ubuntu", entrypoint: "/bin/bash").keptRunning(shell: "/bin/bash", image: ubuntu)
        XCTAssertNil(run.entrypoint)
        XCTAssertEqual(run.command, ["sleep", "infinity"])
    }

    // MARK: Stopped container note

    /// The owner's container from v1.1.1: `container run -d ubuntu:latest` on 1.6.1.
    private let stoppedUbuntu = """
    [{"configuration":{"id":"ubuntu","creationDate":"2026-11-09T07:21:31Z",
      "image":{"reference":"docker.io/library/ubuntu:latest"},
      "initProcess":{"arguments":[],"environment":["PATH=/usr/bin:/bin"],"executable":"/bin/bash",
        "terminal":false,"user":{"id":{"gid":0,"uid":0}},"workingDirectory":"/"},
      "labels":{},"mounts":[],"networks":[{"network":"default","options":{"hostname":"ubuntu"}}],
      "platform":{"architecture":"arm64","os":"linux"},"publishedPorts":[],"readOnly":false,
      "resources":{"cpus":4,"memoryInBytes":1073741824},"rosetta":false},
     "id":"ubuntu","status":{"networks":[],"startedDate":"2026-11-09T07:21:35Z","state":"stopped"}}]
    """

    private func detail(_ json: String) throws -> ContainerDetail {
        try XCTUnwrap(ContainerOutputParser.containerDetails(json).first)
    }

    func testStoppedBareShellShowsNote() throws {
        let ubuntu = try detail(stoppedUbuntu)
        XCTAssertFalse(ubuntu.terminal)
        XCTAssertEqual(BareShell.quickExitShell(ubuntu), "/bin/bash")
        let started = try XCTUnwrap(ubuntu.summary.startedAt)
        XCTAssertEqual(BareShell.quickExitShell(ubuntu, stoppedAt: started.addingTimeInterval(1)), "/bin/bash")
        XCTAssertNil(BareShell.quickExitShell(ubuntu, stoppedAt: started.addingTimeInterval(600)), "ran for a while")
    }

    func testNoNoteWithTerminalOrWhenRunning() throws {
        let withTTY = try detail(stoppedUbuntu.replacingOccurrences(of: "\"terminal\":false", with: "\"terminal\":true"))
        XCTAssertTrue(withTTY.terminal)
        XCTAssertNil(BareShell.quickExitShell(withTTY))
        let running = try detail(stoppedUbuntu.replacingOccurrences(of: "\"state\":\"stopped\"", with: "\"state\":\"running\""))
        XCTAssertNil(BareShell.quickExitShell(running))
    }

    func testNoNoteForNormalStoppedContainers() throws {
        let sleeper = try detail(stoppedUbuntu.replacingOccurrences(
            of: "\"arguments\":[],", with: "\"arguments\":[\"infinity\"],"
        ).replacingOccurrences(of: "\"/bin/bash\"", with: "\"sleep\""))
        XCTAssertNil(BareShell.quickExitShell(sleeper))
        let script = try detail(stoppedUbuntu.replacingOccurrences(
            of: "\"arguments\":[],", with: "\"arguments\":[\"-c\",\"echo hi\"],"))
        XCTAssertNil(BareShell.quickExitShell(script))
    }

    // MARK: Terminal shell

    func testTerminalShell() {
        let kept = ContainerSummary(id: "a", name: "a", image: "ubuntu", state: .running,
                                    labels: [BareShell.shellLabel: "/bin/bash"], command: ["sleep", "infinity"])
        XCTAssertEqual(BareShell.terminalShell(for: kept), "/bin/bash")
        let plain = ContainerSummary(id: "b", name: "b", image: "nginx", state: .running, command: ["nginx"])
        XCTAssertEqual(BareShell.terminalShell(for: plain), "/bin/sh")
        let tty = ContainerSummary(id: "c", name: "c", image: "ubuntu", state: .running, command: ["/bin/zsh"])
        XCTAssertEqual(BareShell.terminalShell(for: tty), "/bin/zsh")
        let odd = ContainerSummary(id: "d", name: "d", image: "x", state: .running,
                                   labels: [BareShell.shellLabel: "rm -rf /"], command: ["sleep", "infinity"])
        XCTAssertEqual(BareShell.terminalShell(for: odd), "/bin/sh", "only real shell paths are used")
        let client = ContainerClient(cliPath: "/usr/local/bin/container", runner: MockRunner())
        XCTAssertEqual(client.shellArguments("a", shell: BareShell.terminalShell(for: kept)), ["exec", "-it", "a", "/bin/bash"])
    }
}

/// One real run from ubuntu:latest through the DeckCore path. Run with:
/// `DECK_LIVE_SHELL=1 swift test --filter RunKeepRunningLiveTests`
/// Makes one deck-shell-test-* container and deletes it.
final class RunKeepRunningLiveTests: XCTestCase {
    private let cli = "/usr/local/bin/container"
    private let boxName = "deck-shell-test-\(UUID().uuidString.prefix(6).lowercased())"

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DECK_LIVE_SHELL"] == "1", "set DECK_LIVE_SHELL=1")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: cli), "container CLI missing")
    }

    override func tearDown() async throws {
        let client = ContainerClient(cliPath: cli)
        _ = try? await client.run(["delete", "--force", boxName])
        _ = try? await client.run(["delete", "--force", boxName + "-fix"])
    }

    func testUbuntuKeptRunning() async throws {
        let client = ContainerClient(cliPath: cli)
        let image = try await client.inspectImage("docker.io/library/ubuntu:latest")
        XCTAssertEqual(BareShell.exitingShell(RunOptions(image: "ubuntu:latest"), image: image.config), "/bin/bash")

        // The shared step the Run sheet (and so every run path) takes.
        let options = await client.prepareRun(RunOptions(image: "ubuntu:latest", name: boxName))
        XCTAssertEqual(options.command, ["sleep", "infinity"])
        _ = try await client.runContainer(options)
        try await Task.sleep(for: .seconds(6))

        let detail = try await client.inspectContainer(boxName)
        XCTAssertEqual(detail.summary.state, .running, "still running after 6 seconds")
        XCTAssertEqual(detail.summary.command, ["sleep", "infinity"])
        XCTAssertNil(BareShell.quickExitShell(detail))
        XCTAssertEqual(BareShell.terminalShell(for: detail.summary), "/bin/bash")

        // A shell opens with exec, the way Terminal does it (without -t here).
        let result = try await client.run(["exec", boxName, "/bin/bash", "-c", "echo shell-ok"])
        XCTAssertTrue(result.stdout.contains("shell-ok"), result.stdout + result.stderr)
    }

    /// The detail's one click Keep It Running on a container that already stopped.
    func testStoppedShellFixedInOneClick() async throws {
        let client = ContainerClient(cliPath: cli)
        let name = boxName + "-fix"
        _ = try await client.runContainer(RunOptions(image: "ubuntu:latest", name: name))
        try await Task.sleep(for: .seconds(3))
        let stopped = try await client.inspectContainer(name)
        let shell = try XCTUnwrap(BareShell.quickExitShell(stopped), "plain run stops at once")
        XCTAssertEqual(shell, "/bin/bash")

        let plan = try await client.keepRunningPlan(name, shell: shell)
        XCTAssertTrue(plan.old.options.command.isEmpty, "the restore keeps the old settings")
        let issues = await client.checkRecreate(plan)
        XCTAssertEqual(issues, [])
        let outcome = try await client.performRecreate(plan)
        XCTAssertEqual(outcome, .recreated(id: name))
        try await Task.sleep(for: .seconds(4))
        let fixed = try await client.inspectContainer(name)
        XCTAssertEqual(fixed.summary.state, .running)
        XCTAssertEqual(fixed.summary.command, ["sleep", "infinity"])
        XCTAssertEqual(fixed.summary.labels[BareShell.shellLabel], "/bin/bash")
    }
}

/// Fake `container` for the shared run step: `image inspect` answers for the
/// images "on this Mac", and a pull adds the image.
private final class ShellImageCLI: CommandRunning, CommandStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var local: [String: String]
    private let remote: [String: String]
    private(set) var pulls: [[String]] = []
    private(set) var inspects: [String] = []

    init(local: [String: String], remote: [String: String] = [:]) {
        self.local = local
        self.remote = remote
    }

    func run(_ executable: String, _ arguments: [String], stdin: Data?) async throws -> CommandResult {
        lock.lock(); defer { lock.unlock() }
        if arguments.count == 3, arguments[0] == "image", arguments[1] == "inspect" {
            inspects.append(arguments[2])
            if let json = local[arguments[2]] { return CommandResult(exitCode: 0, stdout: json) }
            return CommandResult(exitCode: 1, stdout: "", stderr: "Error: image not found: \(arguments[2])")
        }
        return CommandResult(exitCode: 1, stdout: "", stderr: "not mocked")
    }

    func stream(_ executable: String, _ arguments: [String]) -> AsyncThrowingStream<String, Error> {
        lock.lock()
        pulls.append(arguments)
        let reference = arguments.last ?? ""
        let found = remote[reference]
        if let found { local[reference] = found }
        lock.unlock()
        return AsyncThrowingStream { continuation in
            if found == nil {
                continuation.finish(throwing: DeckError.commandFailed("not found"))
            } else {
                continuation.yield("done")
                continuation.finish()
            }
        }
    }
}

/// The shared run step every app path uses (Run sheet, Images Run, palette
/// "run ubuntu", Explore pull and run, Builds Run, Edit and Recreate).
final class RunPrepareTests: XCTestCase {
    private let alpine = RecreateFixtures.alpineImage
    private let nginx = ContainerCLIFixtures.imageList

    private func client(_ cli: ShellImageCLI) -> ContainerClient {
        ContainerClient(cliPath: "/usr/local/bin/container", runner: cli, streamer: cli)
    }

    /// RunOptions the way each entry point builds them.
    private func entryPoints(_ reference: String) -> [String: RunOptions] {
        [
            "images": RunOptions(image: reference),                              // ImagesScreen Run
            "palette": RunOptions(image: reference),                             // CommandPalette run <image>
            "explore": RunOptions(image: reference, platform: nil),              // ExploreRepositorySheet
            "explore-intel": RunOptions(image: reference, platform: "linux/amd64"),
            "builds": RunOptions(image: reference, platform: "linux/arm64"),     // BuildsScreen and BuildSheet Run
            "recreate": RunOptions(image: reference, name: "box", cpus: 2)       // Edit and Recreate capture
        ]
    }

    func testEveryEntryPointKeepsBareShellRunning() async {
        let cli = ShellImageCLI(local: ["alpine:latest": alpine])
        for (path, options) in entryPoints("alpine:latest") {
            let prepared = await client(cli).prepareRun(options)
            XCTAssertEqual(prepared.command, ["sleep", "infinity"], path)
            XCTAssertNil(prepared.entrypoint, path)
            XCTAssertEqual(prepared.labels[BareShell.shellLabel], "/bin/sh", path)
            XCTAssertEqual(prepared.platform, options.platform, path)
        }
        XCTAssertTrue(cli.pulls.isEmpty, "local image, nothing pulled")
    }

    func testOtherImagesAreLeftAlone() async {
        let cli = ShellImageCLI(local: ["nginx:latest": nginx])
        for (path, options) in entryPoints("nginx:latest") {
            let prepared = await client(cli).prepareRun(options)
            XCTAssertEqual(prepared, options, path)
        }
    }

    func testSetCommandOrSwitchOffIsLeftAlone() async {
        let cli = ShellImageCLI(local: ["alpine:latest": alpine])
        let withCommand = RunOptions(image: "alpine:latest", command: ["sh", "-c", "echo hi"])
        let prepared = await client(cli).prepareRun(withCommand)
        XCTAssertEqual(prepared, withCommand)
        let withEntrypoint = RunOptions(image: "alpine:latest", entrypoint: "/bin/sh")
        let preparedEntry = await client(cli).prepareRun(withEntrypoint)
        XCTAssertEqual(preparedEntry, withEntrypoint)
        let off = await client(cli).prepareRun(RunOptions(image: "alpine:latest"), keepShellRunning: false)
        XCTAssertEqual(off, RunOptions(image: "alpine:latest"))
        let empty = await client(cli).prepareRun(RunOptions(image: ""))
        XCTAssertEqual(empty, RunOptions(image: ""))
        XCTAssertTrue(cli.inspects.isEmpty, "no image check when nothing can change")
    }

    func testImageNotOnThisMacIsPulledThenChecked() async {
        let cli = ShellImageCLI(local: [:], remote: ["alpine:latest": alpine])
        let prepared = await client(cli).prepareRun(RunOptions(image: "alpine:latest", platform: "linux/amd64"))
        XCTAssertEqual(prepared.command, ["sleep", "infinity"])
        XCTAssertEqual(cli.pulls.count, 1)
        XCTAssertTrue(cli.pulls.first?.contains("linux/amd64") ?? false, "pulls for the chosen platform")
    }

    func testFailedPullLeavesRunAsIs() async {
        let cli = ShellImageCLI(local: [:])
        let options = RunOptions(image: "nope:latest")
        let prepared = await client(cli).prepareRun(options)
        XCTAssertEqual(prepared, options, "container run reports the real error")
    }

    func testAlreadyPreparedIsStable() async {
        let cli = ShellImageCLI(local: ["alpine:latest": alpine])
        let once = await client(cli).prepareRun(RunOptions(image: "alpine:latest"))
        let twice = await client(cli).prepareRun(once)
        XCTAssertEqual(once, twice, "the Run sheet may have applied it already")
    }
}
