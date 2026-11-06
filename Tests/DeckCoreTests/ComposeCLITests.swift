import XCTest
@testable import DeckCore

// `container compose`: argument parsing, file discovery, output and the
// plugin installer. The live part runs the built plugin binary itself.

final class ComposeCLITests: XCTestCase {

    private func parse(_ line: String, env: [String: String] = [:]) throws -> ComposeCLIOptions {
        try ComposeCLIParser.parse(line.split(separator: " ").map(String.init), environment: env)
    }

    // MARK: Parsing

    func testUpFlags() throws {
        let o = try parse("up -d --force-recreate --build --pull always --keep-orphans --dry-run web worker")
        XCTAssertEqual(o.command, .up)
        XCTAssertTrue(o.detach)
        XCTAssertTrue(o.forceRecreate)
        XCTAssertTrue(o.build)
        XCTAssertEqual(o.pull, .always)
        XCTAssertFalse(o.removeOrphans)
        XCTAssertTrue(o.dryRun)
        XCTAssertEqual(o.services, ["web", "worker"])

        let defaults = try parse("up")
        XCTAssertTrue(defaults.removeOrphans)
        XCTAssertNil(defaults.pull)
        XCTAssertFalse(defaults.detach)
        XCTAssertTrue(try parse("up --keep-orphans --remove-orphans").removeOrphans)
        XCTAssertEqual(try parse("up --pull=never").pull, .never)
        XCTAssertEqual(try parse("up --pull missing").pull, .missing)
    }

    func testGlobalOptionsBeforeAndAfterTheCommand() throws {
        let o = try parse("-f a.yaml --file=b.yaml -p Shop --env-file prod.env --profile debug --profile=tools up -d")
        XCTAssertEqual(o.files, ["a.yaml", "b.yaml"])
        XCTAssertEqual(o.projectName, "Shop")
        XCTAssertEqual(o.envFiles, ["prod.env"])
        XCTAssertEqual(o.profiles, ["debug", "tools"])
        XCTAssertEqual(o.command, .up)

        let after = try parse("down -v --keep-networks -f x.yaml --project-name demo")
        XCTAssertEqual(after.command, .down)
        XCTAssertTrue(after.removeVolumes)
        XCTAssertTrue(after.keepNetworks)
        XCTAssertEqual(after.files, ["x.yaml"])
        XCTAssertEqual(after.projectName, "demo")
        XCTAssertEqual(try parse("--project-directory /work/shop ps").projectDirectory, "/work/shop")
    }

    func testDashVMeansVersionBeforeACommandAndVolumesAfterDown() throws {
        XCTAssertEqual(try parse("-v").command, .version)
        XCTAssertEqual(try parse("--version").command, .version)
        XCTAssertEqual(try parse("version").command, .version)
        XCTAssertTrue(try parse("down -v").removeVolumes)
        XCTAssertThrowsError(try parse("up -v"))
    }

    func testLogsPsAndConfigFlags() throws {
        let logs = try parse("logs -f --tail 20 web")
        XCTAssertTrue(logs.follow)
        XCTAssertEqual(logs.tail, 20)
        XCTAssertEqual(logs.services, ["web"])
        XCTAssertNil(try parse("logs -n all").tail)
        XCTAssertEqual(try parse("logs --tail=5").tail, 5)
        XCTAssertThrowsError(try parse("logs --tail lots"))
        XCTAssertTrue(try parse("ps -q").quiet)
        XCTAssertTrue(try parse("ps --services").listServices)
        XCTAssertTrue(try parse("config --services").listServices)
        XCTAssertTrue(try parse("config -q").quiet)
        for command in ["start", "stop", "restart", "pull"] {
            let o = try parse("\(command) web db")
            XCTAssertEqual(o.command.rawValue, command)
            XCTAssertEqual(o.services, ["web", "db"])
        }
    }

    func testExecSplitsTheCommand() throws {
        let o = try parse("exec -T -e A=1 --env B=2 -u root -w /app web sh -c ls -la")
        XCTAssertEqual(o.command, .exec)
        XCTAssertEqual(o.execService, "web")
        XCTAssertEqual(o.execCommand, ["sh", "-c", "ls", "-la"])
        XCTAssertTrue(o.noTTY)
        XCTAssertEqual(o.execEnv, ["A=1", "B=2"])
        XCTAssertEqual(o.execUser, "root")
        XCTAssertEqual(o.execWorkdir, "/app")
        // Flags after the service belong to the command.
        XCTAssertEqual(try parse("exec web ls -f").execCommand, ["ls", "-f"])
        XCTAssertEqual(try parse("exec -- web --help").execCommand, ["--help"])
        XCTAssertThrowsError(try parse("exec web"))
        XCTAssertThrowsError(try parse("exec"))
    }

    func testHelpForms() throws {
        XCTAssertEqual(try parse("").command, .help)
        XCTAssertEqual(try parse("--help").command, .help)
        let upHelp = try parse("up --help")
        XCTAssertEqual(upHelp.command, .help)
        XCTAssertEqual(upHelp.helpFor, .up)
        XCTAssertEqual(try parse("help down").helpFor, .down)
        XCTAssertTrue(ComposeCLI.help(for: nil).contains("Commands:"))
        XCTAssertTrue(ComposeCLI.help(for: .up).contains("--keep-orphans"))
        XCTAssertTrue(ComposeCLI.help(for: .down).contains("--keep-networks"))
        for command in ComposeCLIOptions.Command.allCases {
            let text = ComposeCLI.help(for: command)
            XCTAssertFalse(text.contains("—"), "long dash in help for \(command)")
            XCTAssertFalse(text.contains(";"), "semicolon in help for \(command)")
        }
    }

    func testUsageErrors() {
        XCTAssertThrowsError(try parse("launch"))
        XCTAssertThrowsError(try parse("--nope up"))
        XCTAssertThrowsError(try parse("up --pull build"))
        XCTAssertThrowsError(try parse("up --pull"))
        XCTAssertThrowsError(try parse("ps --follow"))
    }

    func testProfilesFromEnvironment() throws {
        XCTAssertEqual(try parse("up", env: ["COMPOSE_PROFILES": "debug, tools"]).profiles, ["debug", "tools"])
        XCTAssertEqual(try parse("--profile x up", env: ["COMPOSE_PROFILES": "debug"]).profiles, ["x"])
    }

    // MARK: File discovery

    func testDiscoveryWalksUpParentFolders() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let deep = root.appendingPathComponent("a/b/c")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try "services: {}\n".write(to: root.appendingPathComponent("a/compose.yml"), atomically: true, encoding: .utf8)
        let files = try ComposeCLI.composeFiles(ComposeCLIOptions(), currentDirectory: deep, environment: [:])
        XCTAssertEqual(files.map(\.lastPathComponent), ["compose.yml"])
        XCTAssertEqual(files.first?.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path,
                       root.appendingPathComponent("a").standardizedFileURL.resolvingSymlinksInPath().path)
    }

    func testDiscoveryPrefersTheNearestFolderAndCompose_yaml() {
        let existing: Set<String> = ["/w/compose.yaml", "/w/app/docker-compose.yml", "/w/app/compose.yaml"]
        let files = try? ComposeCLI.composeFiles(ComposeCLIOptions(), currentDirectory: URL(fileURLWithPath: "/w/app/src"),
                                                 environment: [:], fileExists: { existing.contains($0) })
        XCTAssertEqual(files?.map(\.path), ["/w/app/compose.yaml"])
    }

    func testDashFAndComposeFileAndProjectDirectory() throws {
        let existing: Set<String> = ["/w/app/one.yaml", "/w/other/two.yaml", "/srv/compose.yaml"]
        let exists: @Sendable (String) -> Bool = { existing.contains($0) }
        let cwd = URL(fileURLWithPath: "/w/app")
        var options = ComposeCLIOptions()
        options.files = ["one.yaml", "../other/two.yaml"]
        XCTAssertEqual(try ComposeCLI.composeFiles(options, currentDirectory: cwd, environment: [:], fileExists: exists).map(\.path),
                       ["/w/app/one.yaml", "/w/other/two.yaml"])
        options.files = ["missing.yaml"]
        XCTAssertThrowsError(try ComposeCLI.composeFiles(options, currentDirectory: cwd, environment: [:], fileExists: exists))

        let fromEnv = try ComposeCLI.composeFiles(ComposeCLIOptions(), currentDirectory: cwd,
                                                  environment: ["COMPOSE_FILE": "one.yaml:/w/other/two.yaml"], fileExists: exists)
        XCTAssertEqual(fromEnv.map(\.path), ["/w/app/one.yaml", "/w/other/two.yaml"])

        var dirOptions = ComposeCLIOptions()
        dirOptions.projectDirectory = "/srv"
        XCTAssertEqual(try ComposeCLI.composeFiles(dirOptions, currentDirectory: cwd, environment: [:], fileExists: exists).map(\.path),
                       ["/srv/compose.yaml"])
        XCTAssertThrowsError(try ComposeCLI.composeFiles(ComposeCLIOptions(), currentDirectory: URL(fileURLWithPath: "/nowhere"),
                                                         environment: [:], fileExists: exists)) { error in
            XCTAssertEqual(error as? ComposeError, .noFile("/nowhere"))
        }
    }

    // MARK: Running commands against a fake CLI

    func testVersionHelpAndUsageExitCodes() async {
        let output = Captured()
        let cli = ComposeCLI(environment: [:], out: output.out, err: output.err, cliPath: "/fake")
        let version = await cli.run(["version"])
        XCTAssertEqual(version, 0)
        XCTAssertTrue(output.stdout.contains("container compose version \(ComposePlugin.version)"))
        XCTAssertTrue(output.stdout.contains("(\(AppConfig.appName))"))
        let help = await cli.run(["--help"])
        XCTAssertEqual(help, 0)
        let bad = await cli.run(["launch"])
        XCTAssertEqual(bad, 2)
        XCTAssertTrue(output.stderr.contains("error: Unknown command launch"))
    }

    func testConfigPrintsTheResolvedFile() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        name: ${NAME:-demo}
        services:
          web:
            image: nginx:${TAG}
            dns: 1.1.1.1
            volumes: [/data]
        """.write(to: dir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)
        try "TAG=1.27\n".write(to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        let output = Captured()
        let cli = ComposeCLI(environment: [:], currentDirectory: dir, out: output.out, err: output.err, cliPath: "/fake")
        let code = await cli.run(["config"])
        XCTAssertEqual(code, 0, output.stderr)
        XCTAssertTrue(output.stdout.contains("name: demo"), output.stdout)
        XCTAssertTrue(output.stdout.contains("\"nginx:1.27\""), output.stdout)
        XCTAssertTrue(output.stdout.contains("container_name: demo-web"), output.stdout)
        XCTAssertTrue(output.stdout.contains("x-volume-name: demo_web_anon_"), output.stdout)

        let services = Captured()
        let named = ComposeCLI(environment: [:], currentDirectory: dir, out: services.out, err: services.err, cliPath: "/fake")
        let servicesCode = await named.run(["-p", "Other", "config", "--services"])
        XCTAssertEqual(servicesCode, 0)
        XCTAssertEqual(services.stdout, "web")
    }

    func testConfigQuietFailsOnBlockingProblems() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "services:\n  web: {}\n".write(to: dir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)
        let output = Captured()
        let code = await ComposeCLI(environment: [:], currentDirectory: dir, out: output.out, err: output.err, cliPath: "/fake").run(["config", "-q"])
        XCTAssertEqual(code, 1)
        XCTAssertTrue(output.stdout.isEmpty)
        XCTAssertTrue(output.stderr.contains("needs an image or a build"), output.stderr)
    }

    func testUpDryRunPsAndExecThroughTheFakeCLI() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        name: clitest
        services:
          web:
            image: alpine
            post_start:
              - command: echo hi
        """.write(to: dir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)
        let fake = FakeContainerCLI()
        fake.images = ["docker.io/library/alpine:latest"]
        let output = Captured()
        let execs = ExecCapture()
        let cli = ComposeCLI(environment: [:], currentDirectory: dir, out: output.out, err: output.err, cliPath: "/fake/container",
                             execReplace: { path, args in execs.record(path, args); return 0 },
                             stdinIsTerminal: false, runner: fake, streamer: fake)

        let dry = await cli.run(["up", "--dry-run"])
        XCTAssertEqual(dry, 0, output.stderr)
        XCTAssertTrue(output.stdout.contains("=> web: Would create and start clitest-web"), output.stdout)
        XCTAssertTrue(fake.containerNames.isEmpty)

        let up = await cli.run(["up", "-d"])
        XCTAssertEqual(up, 0, output.stderr)
        XCTAssertEqual(fake.containerNames, ["clitest-web"])
        XCTAssertTrue(output.stdout.contains("   web | ran echo hi"), output.stdout)

        output.clear()
        let ps = await cli.run(["ps"])
        XCTAssertEqual(ps, 0)
        let lines = output.stdout.split(separator: "\n")
        XCTAssertTrue(lines.first?.hasPrefix("NAME") == true, output.stdout)
        XCTAssertTrue(lines.contains { $0.contains("clitest-web") && $0.contains("running") && $0.contains("192.168.64.9") }, output.stdout)

        let exec = await cli.run(["exec", "-e", "A=1", "web", "ls", "/"])
        XCTAssertEqual(exec, 0, output.stderr)
        XCTAssertEqual(execs.path, "/fake/container")
        XCTAssertEqual(execs.arguments, ["exec", "--interactive", "--env", "A=1", "clitest-web", "ls", "/"])

        let missing = await cli.run(["exec", "nope", "ls"])
        XCTAssertEqual(missing, 1)

        let down = await cli.run(["down"])
        XCTAssertEqual(down, 0, output.stderr)
        XCTAssertTrue(fake.containerNames.isEmpty)
    }

    func testDryRunChangesNothingForEveryCommand() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        name: drytest
        services:
          web:
            image: alpine
          db:
            image: postgres
        """.write(to: dir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)
        let fake = FakeContainerCLI()
        fake.addContainer("drytest-web", labels: [ComposeLabel.project: "drytest", ComposeLabel.service: "web"])
        fake.addContainer("drytest-db", image: "docker.io/library/postgres:latest",
                          labels: [ComposeLabel.project: "drytest", ComposeLabel.service: "db"], running: false)
        let output = Captured()
        let execs = ExecCapture()
        let cli = ComposeCLI(environment: [:], currentDirectory: dir, out: output.out, err: output.err, cliPath: "/fake/container",
                             execReplace: { path, args in execs.record(path, args); return 0 },
                             stdinIsTerminal: false, runner: fake, streamer: fake)
        let changing: Set<String> = ["start", "stop", "restart", "kill", "delete", "exec", "run"]

        for args in [["stop", "--dry-run"], ["start", "--dry-run"], ["--dry-run", "restart", "web"], ["pull", "--dry-run"], ["exec", "--dry-run", "web", "ls"]] {
            output.clear()
            let code = await cli.run(args)
            XCTAssertEqual(code, 0, "\(args): \(output.stderr)")
            XCTAssertTrue(output.stdout.hasPrefix("Dry run for drytest."), "\(args): \(output.stdout)")
        }
        XCTAssertFalse(fake.calls.contains { changing.contains($0.first ?? "") || $0.starts(with: ["image", "pull"]) }, "\(fake.calls)")
        XCTAssertNil(execs.path)

        output.clear()
        _ = await cli.run(["stop", "--dry-run"])
        XCTAssertEqual(output.stdout, "Dry run for drytest. Nothing is changed.\nWould stop drytest-web")
        output.clear()
        _ = await cli.run(["pull", "--dry-run"])
        XCTAssertTrue(output.stdout.contains("Would pull alpine") && output.stdout.contains("Would pull postgres"), output.stdout)
    }

    func testUpRefusesBlockingProblems() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        services:
          web:
            image: alpine
            post_start:
              - command: id
                privileged: true
        """.write(to: dir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)
        let fake = FakeContainerCLI()
        let output = Captured()
        let code = await ComposeCLI(environment: [:], currentDirectory: dir, out: output.out, err: output.err,
                                    cliPath: "/fake", runner: fake, streamer: fake).run(["up", "-d"])
        XCTAssertEqual(code, 1)
        XCTAssertTrue(output.stderr.contains("error: compose.yaml:6: services.web.post_start.privileged"), output.stderr)
        XCTAssertFalse(fake.calls.contains { $0.first == "run" })
    }

    // MARK: Formatting

    func testEventFormatting() {
        XCTAssertEqual(ComposeCLI.format(ComposeEvent(.step, "Creating network x")).0, "=> Creating network x")
        XCTAssertEqual(ComposeCLI.format(ComposeEvent(.step, "Starting a", service: "web")).0, "=> web: Starting a")
        XCTAssertEqual(ComposeCLI.format(ComposeEvent(.output, "line", service: "db")).0, "   db | line")
        let warning = ComposeCLI.format(ComposeEvent(.warning, "careful"))
        XCTAssertEqual(warning.0, "warning: careful")
        XCTAssertTrue(warning.1)
        XCTAssertTrue(ComposeCLI.format(ComposeEvent(.failure, "bad")).1)
        XCTAssertFalse(ComposeCLI.format(ComposeEvent(.success, "ok")).1)
        XCTAssertEqual(ComposeCLI.logLine(ComposeLogLine(service: "db", text: "ready"), width: 5), "db    | ready")
        XCTAssertEqual(ComposeCLI.problemLine(ComposeProblem(kind: .notBuilt, key: "services.web.tty", line: 7, message: "tty is not built yet.")),
                       "not built yet: line 7: services.web.tty: tty is not built yet.")
    }

    func testPsTable() {
        let web = ComposeServiceStatus(service: "web", container: ContainerSummary(
            id: "shop-web", name: "shop-web", image: "nginx:alpine", state: .running, ipAddress: "192.168.64.3/24",
            ports: [PortMapping(hostPort: 8080, containerPort: 80)]))
        let db = ComposeServiceStatus(service: "db", container: ContainerSummary(id: "shop-database", name: "shop-database", image: "postgres", state: .stopped))
        let lines = ComposeCLI.psTable([web, db]).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], "NAME            IMAGE          SERVICE   STATUS    ADDRESS        PORTS")
        XCTAssertEqual(lines[1], "shop-web        nginx:alpine   web       running   192.168.64.3   8080->80/tcp")
        XCTAssertEqual(lines[2], "shop-database   postgres       db        stopped")
    }

    func testExecArguments() {
        var o = ComposeCLIOptions()
        o.execCommand = ["sh"]
        XCTAssertEqual(ComposeCLI.execArguments(o, container: "c", stdinIsTerminal: true), ["exec", "--interactive", "--tty", "c", "sh"])
        XCTAssertEqual(ComposeCLI.execArguments(o, container: "c", stdinIsTerminal: false), ["exec", "--interactive", "c", "sh"])
        o.noTTY = true
        o.execUser = "root"
        o.execWorkdir = "/srv"
        XCTAssertEqual(ComposeCLI.execArguments(o, container: "c", stdinIsTerminal: true),
                       ["exec", "--interactive", "--user", "root", "--workdir", "/srv", "c", "sh"])
        o.execDetach = true
        XCTAssertEqual(ComposeCLI.execArguments(o, container: "c", stdinIsTerminal: true).prefix(2), ["exec", "--detach"])
    }

    // MARK: Plugin installer

    func testPluginLayoutAndConfig() {
        XCTAssertEqual(ComposePlugin.installDirectory, "/usr/local/libexec/container-plugins/compose")
        XCTAssertEqual(ComposePlugin.installedBinary, "/usr/local/libexec/container-plugins/compose/bin/compose")
        let toml = ComposePlugin.configTOML
        XCTAssertTrue(toml.contains("abstract = "))
        XCTAssertTrue(toml.contains("author = \"\(AppConfig.author)\""))
        XCTAssertFalse(toml.contains("servicesConfig"), "a services table would make it a daemon plugin")
    }

    func testPluginStatus() {
        let ours = Data("build-1".utf8)
        func installer(files: [String: Data], bundled: String? = "/app/container-compose") -> ComposePluginInstaller {
            ComposePluginInstaller(bundledBinary: bundled, installDirectory: "/p/compose",
                                   fileExists: { files[$0] != nil }, readFile: { files[$0] })
        }
        let bundle = ["/app/container-compose": ours]
        XCTAssertEqual(installer(files: bundle).status(previouslyInstalled: false), .notInstalled)
        XCTAssertEqual(installer(files: bundle).status(previouslyInstalled: true), .removedByUpgrade)
        XCTAssertEqual(installer(files: [:], bundled: nil).status(previouslyInstalled: false), .notBundled)
        var installed = bundle
        installed["/p/compose/bin/compose"] = ours
        installed["/p/compose/config.toml"] = Data("x".utf8)
        XCTAssertEqual(installer(files: installed).status(previouslyInstalled: false), .installed)
        installed["/p/compose/bin/compose"] = Data("build-0".utf8)
        XCTAssertEqual(installer(files: installed).status(previouslyInstalled: true), .outdated)
        // Binary without its config is not a plugin to Apple's loader.
        XCTAssertEqual(installer(files: bundle.merging(["/p/compose/bin/compose": ours]) { a, _ in a }).status(previouslyInstalled: true), .removedByUpgrade)
    }

    func testPluginInstallCommandsUseOnePrompt() async throws {
        let mock = MockRunner()
        mock.responses = [:]
        let installer = ComposePluginInstaller(bundledBinary: "/app/Contents/MacOS/container-compose", installDirectory: "/p/compose",
                                               fileExists: { _ in false }, readFile: { _ in nil })
        XCTAssertEqual(installer.installCommands(binary: "/b", configFile: "/c.toml"), [
            ["/bin/mkdir", "-p", "/p/compose/bin"],
            ["/usr/bin/install", "-m", "0755", "/b", "/p/compose/bin/compose"],
            ["/usr/bin/install", "-m", "0644", "/c.toml", "/p/compose/config.toml"]
        ])
        XCTAssertEqual(installer.removeCommands(), [["/bin/rm", "-rf", "/p/compose"]])
        // The mock answers "not mocked" (exit 1), so install throws, but it must have asked once through osascript.
        do {
            try await installer.install(runner: mock)
            XCTFail("expected the mocked prompt to fail")
        } catch {}
        XCTAssertEqual(mock.calls.count, 1)
        XCTAssertEqual(mock.calls.first?.first, "/usr/bin/osascript")
        XCTAssertTrue(mock.calls.first?.last?.contains("with administrator privileges") == true)
        XCTAssertTrue(mock.calls.first?.last?.contains("/p/compose/bin/compose") == true)
    }

    // MARK: Helpers

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("deck-compose-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

final class Captured: @unchecked Sendable {
    private let lock = NSLock()
    private var outLines: [String] = []
    private var errLines: [String] = []
    var out: @Sendable (String) -> Void { { [self] line in lock.lock(); outLines.append(line); lock.unlock() } }
    var err: @Sendable (String) -> Void { { [self] line in lock.lock(); errLines.append(line); lock.unlock() } }
    var stdout: String { lock.lock(); defer { lock.unlock() }; return outLines.joined(separator: "\n") }
    var stderr: String { lock.lock(); defer { lock.unlock() }; return errLines.joined(separator: "\n") }
    func clear() { lock.lock(); outLines = []; errLines = []; lock.unlock() }
}

final class ExecCapture: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var path: String?
    private(set) var arguments: [String] = []
    func record(_ path: String, _ arguments: [String]) {
        lock.lock(); self.path = path; self.arguments = arguments; lock.unlock()
    }
}

// MARK: - Live

/// Runs the built `container-compose` binary against the real CLI from a temp
/// folder, without installing it. DECK_INTEGRATION=1 or DECK_LIVE_COMPOSE=1.
/// Uses project deck-compose-plugin and removes everything at the end.
final class ComposePluginLiveTests: XCTestCase {

    private var enabled: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["DECK_INTEGRATION"] == "1" || env["DECK_LIVE_COMPOSE"] == "1"
    }

    /// `.build/<config>/container-compose`, next to the test bundle.
    private func pluginBinary() -> String? {
        var dir = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        for _ in 0..<3 {
            let candidate = dir.appendingPathComponent(ComposePlugin.executableName).path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    private func run(_ binary: String, _ args: [String], in dir: URL) throws -> (code: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        process.currentDirectoryURL = dir
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
    }

    func testPluginBinaryUpExecDownFromATempFolder() throws {
        try XCTSkipUnless(enabled, "Set DECK_INTEGRATION=1 or DECK_LIVE_COMPOSE=1 to run against the real CLI.")
        guard let binary = pluginBinary() else {
            throw XCTSkip("Build the plugin first: swift build --product container-compose")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("deck-compose-plugin-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("src/deeper")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        name: deck-compose-plugin
        services:
          app:
            image: alpine:3.22
            command: ["sleep", "300"]
            stop_grace_period: 2s
            volumes:
              - /data
            post_start:
              - command: ["sh", "-c", "echo hooked > /data/hook.txt"]
        """.write(to: root.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        addTeardownBlock { [self] in
            _ = try? self.run(binary, ["down", "-v"], in: root)
        }

        // Found by walking up from src/deeper.
        let config = try run(binary, ["config", "--services"], in: nested)
        XCTAssertEqual(config.code, 0, config.err)
        XCTAssertEqual(config.out.trimmingCharacters(in: .whitespacesAndNewlines), "app")

        let up = try run(binary, ["up", "-d"], in: nested)
        XCTAssertEqual(up.code, 0, "\(up.out)\n\(up.err)")
        XCTAssertTrue(up.out.contains("post_start"), up.out)

        let ps = try run(binary, ["ps"], in: nested)
        XCTAssertEqual(ps.code, 0, ps.err)
        XCTAssertTrue(ps.out.contains("deck-compose-plugin-app") && ps.out.contains("running"), ps.out)

        let exec = try run(binary, ["exec", "-T", "app", "cat", "/data/hook.txt"], in: nested)
        XCTAssertEqual(exec.code, 0, exec.err)
        XCTAssertEqual(exec.out.trimmingCharacters(in: .whitespacesAndNewlines), "hooked")

        let again = try run(binary, ["up", "-d"], in: nested)
        XCTAssertEqual(again.code, 0, again.err)
        XCTAssertTrue(again.out.contains("Up to date"), again.out)

        let down = try run(binary, ["down", "-v"], in: nested)
        XCTAssertEqual(down.code, 0, down.err)
        let left = try run(binary, ["ps", "-q"], in: nested)
        XCTAssertEqual(left.out.trimmingCharacters(in: .whitespacesAndNewlines), "")
        let volumes = try run("/usr/local/bin/container", ["volume", "list", "--quiet"], in: root)
        XCTAssertFalse(volumes.out.contains("deck-compose-plugin_app_anon_"), volumes.out)
    }
}
