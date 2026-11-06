import Foundation

// `container compose`: the terminal front end for the compose engine the app uses.
// The executable target (Sources/ContainerCompose) is a thin wrapper around
// `ComposeCLI.run`. Everything here is testable without a terminal.

/// Version of the `container compose` plugin. Bump with changes to its commands.
public enum ComposePlugin {
    public static let version = "1.0.0"
    /// Name of the plugin folder and binary, so the command is `container compose`.
    public static let name = "compose"
    /// Name of the binary SwiftPM builds and the app bundles.
    public static let executableName = "container-compose"
    /// Where Apple's CLI looks for user plugins (`<install root>/libexec/container-plugins`).
    public static let pluginsDirectory = "/usr/local/libexec/container-plugins"
    public static var installDirectory: String { "\(pluginsDirectory)/\(name)" }
    public static var installedBinary: String { "\(installDirectory)/bin/\(name)" }
    public static var installedConfig: String { "\(installDirectory)/config.toml" }

    /// `config.toml` Apple's plugin loader reads. No services table means a CLI plugin.
    public static var configTOML: String {
        """
        abstract = "Run compose files with Apple's container tool (\(AppConfig.appName))"
        author = "\(AppConfig.author)"
        version = "\(version)"

        """
    }
}

/// Parsed command line of `container compose`.
public struct ComposeCLIOptions: Equatable, Sendable {
    public enum Command: String, CaseIterable, Sendable {
        case up, down, ps, logs, start, stop, restart, pull, exec, config, version, help
    }

    public var command: Command = .help
    /// Command the help is for (`compose up --help`, `compose help up`).
    public var helpFor: Command?

    // Global
    public var files: [String] = []
    public var projectName: String?
    public var projectDirectory: String?
    public var envFiles: [String] = []
    public var profiles: [String] = []

    /// Service names after the command.
    public var services: [String] = []

    // up
    public var detach = false
    public var forceRecreate = false
    public var build = false
    public var pull: ComposePullPolicy?
    public var removeOrphans = true
    public var dryRun = false

    // down
    public var removeVolumes = false
    public var keepNetworks = false

    // logs
    public var follow = false
    public var tail: Int?

    // ps and config
    public var quiet = false
    public var listServices = false

    // exec
    public var execService: String?
    public var execCommand: [String] = []
    public var execEnv: [String] = []
    public var execUser: String?
    public var execWorkdir: String?
    public var noTTY = false
    public var execDetach = false

    public init() {}
}

public struct ComposeCLIUsageError: LocalizedError, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum ComposeCLIParser {

    public static func parse(_ arguments: [String], environment: [String: String] = [:]) throws -> ComposeCLIOptions {
        var o = ComposeCLIOptions()
        var commandSet = false
        var wantsHelp = false
        var i = 0

        while i < arguments.count {
            let raw = arguments[i]
            i += 1

            // Everything after the exec service is the command to run.
            if commandSet && o.command == .exec && o.execService != nil {
                o.execCommand = Array(arguments[(i - 1)...])
                break
            }

            var name = raw
            var inline: String?
            if raw.hasPrefix("--"), let eq = raw.firstIndex(of: "=") {
                name = String(raw[..<eq])
                inline = String(raw[raw.index(after: eq)...])
            }
            func value() throws -> String {
                if let inline { return inline }
                guard i < arguments.count else { throw ComposeCLIUsageError("\(name) needs a value.") }
                let next = arguments[i]
                i += 1
                return next
            }

            if name == "--" {
                let rest = Array(arguments[i...])
                if o.command == .exec {
                    if o.execService == nil, let first = rest.first {
                        o.execService = first
                        o.execCommand = Array(rest.dropFirst())
                    } else {
                        o.execCommand = rest
                    }
                } else {
                    o.services += rest
                }
                break
            }

            // Positional: the command, then services (or the exec service).
            if !name.hasPrefix("-") || name == "-" {
                if !commandSet {
                    guard let command = ComposeCLIOptions.Command(rawValue: name) else {
                        throw ComposeCLIUsageError("Unknown command \(name). Run container compose --help to see the commands.")
                    }
                    o.command = command
                    commandSet = true
                } else if o.command == .help {
                    o.helpFor = ComposeCLIOptions.Command(rawValue: name)
                    if o.helpFor == nil { throw ComposeCLIUsageError("Unknown command \(name).") }
                } else if o.command == .exec {
                    o.execService = name
                } else {
                    o.services.append(name)
                }
                continue
            }

            // After `logs`, -f means follow (like docker compose), not --file.
            if commandSet && o.command == .logs && name == "-f" {
                o.follow = true
                continue
            }

            // Global options work before and after the command.
            switch name {
            case "-f", "--file":
                o.files.append(try value())
                continue
            case "-p", "--project-name":
                o.projectName = try value()
                continue
            case "--project-directory":
                o.projectDirectory = try value()
                continue
            case "--env-file":
                o.envFiles.append(try value())
                continue
            case "--profile":
                o.profiles.append(try value())
                continue
            case "-h", "--help":
                wantsHelp = true
                continue
            case "--dry-run":
                o.dryRun = true
                continue
            default:
                break
            }

            if !commandSet {
                if name == "-v" || name == "--version" {
                    o.command = .version
                    commandSet = true
                    continue
                }
                throw ComposeCLIUsageError("Unknown option \(name).")
            }

            switch (o.command, name) {
            case (.up, "-d"), (.up, "--detach"):
                o.detach = true
            case (.up, "--force-recreate"):
                o.forceRecreate = true
            case (.up, "--build"):
                o.build = true
            case (.up, "--pull"):
                let text = try value()
                guard let policy = ComposePullPolicy(composeValue: text), policy != .build else {
                    throw ComposeCLIUsageError("--pull takes missing, always or never.")
                }
                o.pull = policy
            case (.up, "--remove-orphans"):
                o.removeOrphans = true
            case (.up, "--keep-orphans"):
                o.removeOrphans = false
            case (.down, "-v"), (.down, "--volumes"):
                o.removeVolumes = true
            case (.down, "--keep-networks"):
                o.keepNetworks = true
            case (.down, "--remove-orphans"):
                // Down removes every container of the project already.
                break
            case (.logs, "-f"), (.logs, "--follow"):
                o.follow = true
            case (.logs, "-n"), (.logs, "--tail"):
                let text = try value()
                if text == "all" {
                    o.tail = nil
                } else if let count = Int(text), count >= 0 {
                    o.tail = count
                } else {
                    throw ComposeCLIUsageError("--tail takes a number or all.")
                }
            case (.logs, "--no-color"), (.ps, "-a"), (.ps, "--all"), (.exec, "-i"), (.exec, "--interactive"), (.exec, "-t"), (.exec, "--tty"):
                break
            case (.ps, "-q"), (.ps, "--quiet"), (.config, "-q"), (.config, "--quiet"):
                o.quiet = true
            case (.ps, "--services"), (.config, "--services"):
                o.listServices = true
            case (.exec, "-T"), (.exec, "--no-TTY"), (.exec, "--no-tty"):
                o.noTTY = true
            case (.exec, "-d"), (.exec, "--detach"):
                o.execDetach = true
            case (.exec, "-e"), (.exec, "--env"):
                o.execEnv.append(try value())
            case (.exec, "-u"), (.exec, "--user"):
                o.execUser = try value()
            case (.exec, "-w"), (.exec, "--workdir"):
                o.execWorkdir = try value()
            default:
                throw ComposeCLIUsageError("Unknown option \(name) for \(o.command.rawValue).")
            }
        }

        if wantsHelp {
            o.helpFor = commandSet && o.command != .help ? o.command : o.helpFor
            o.command = .help
        }
        if !commandSet && !wantsHelp {
            o.command = .help
        }
        if o.profiles.isEmpty, let fromEnv = environment["COMPOSE_PROFILES"], !fromEnv.isEmpty {
            o.profiles = fromEnv.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        if o.command == .exec {
            guard o.execService != nil else { throw ComposeCLIUsageError("exec needs a service and a command.") }
            guard !o.execCommand.isEmpty else { throw ComposeCLIUsageError("exec needs a command to run.") }
        }
        return o
    }
}

/// Runs one `container compose` command. Output goes through `out` and `err`.
public struct ComposeCLI: Sendable {
    public var environment: [String: String]
    public var currentDirectory: URL
    public var out: @Sendable (String) -> Void
    public var err: @Sendable (String) -> Void
    /// Path of Apple's `container` binary. nil finds it like the app does.
    public var cliPath: String?
    /// Replaces this process with `container exec`. Returns only on failure.
    public var execReplace: @Sendable (String, [String]) -> Int32
    /// True when stdin is a terminal (exec gets `-it`).
    public var stdinIsTerminal: Bool
    /// Swapped in tests.
    public var runner: (any CommandRunning)?
    public var streamer: (any CommandStreaming)?

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        out: @escaping @Sendable (String) -> Void = { ComposeCLI.write($0, to: .standardOutput) },
        err: @escaping @Sendable (String) -> Void = { ComposeCLI.write($0, to: .standardError) },
        cliPath: String? = nil,
        execReplace: @escaping @Sendable (String, [String]) -> Int32 = ComposeCLI.execv,
        stdinIsTerminal: Bool = isatty(STDIN_FILENO) == 1,
        runner: (any CommandRunning)? = nil,
        streamer: (any CommandStreaming)? = nil
    ) {
        self.environment = environment
        self.currentDirectory = currentDirectory
        self.out = out
        self.err = err
        self.cliPath = cliPath
        self.execReplace = execReplace
        self.stdinIsTerminal = stdinIsTerminal
        self.runner = runner
        self.streamer = streamer
    }

    /// Writes a line, unbuffered, so piped output shows up right away.
    public static func write(_ line: String, to handle: FileHandle) {
        handle.write(Data((line + "\n").utf8))
    }

    public static let execv: @Sendable (String, [String]) -> Int32 = { path, arguments in
        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        Darwin.execv(path, argv)
        return 127
    }

    // MARK: Run

    /// Runs the command line and returns the exit code: 0 ok, 1 failed, 2 bad usage.
    public func run(_ arguments: [String]) async -> Int32 {
        let options: ComposeCLIOptions
        do {
            options = try ComposeCLIParser.parse(arguments, environment: environment)
        } catch {
            err("error: \(error.localizedDescription)")
            return 2
        }
        switch options.command {
        case .help:
            out(Self.help(for: options.helpFor))
            return 0
        case .version:
            out("container compose version \(ComposePlugin.version) (\(AppConfig.appName))")
            return 0
        default:
            break
        }
        do {
            return try await execute(options)
        } catch is CancellationError {
            err("Stopped.")
            return 130
        } catch {
            err("error: \(error.localizedDescription)")
            return 1
        }
    }

    /// Compose files to use: `-f` values, else COMPOSE_FILE, else the first folder
    /// from the project directory up to `/` that has a compose file.
    public static func composeFiles(
        _ options: ComposeCLIOptions, currentDirectory: URL, environment: [String: String],
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) throws -> [URL] {
        func absolute(_ path: String, base: URL) -> URL {
            let expanded = path.hasPrefix("~") ? NSString(string: path).expandingTildeInPath : path
            if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL }
            return base.appendingPathComponent(expanded).standardizedFileURL
        }
        let base = options.projectDirectory.map { absolute($0, base: currentDirectory) } ?? currentDirectory
        if !options.files.isEmpty {
            let files = options.files.map { absolute($0, base: currentDirectory) }
            for file in files where !fileExists(file.path) {
                throw ComposeError.failed("The compose file \(file.path) does not exist.")
            }
            return files
        }
        let found = ComposeFileLocator(fileExists: fileExists).locate(from: base, environment: environment)
        guard !found.isEmpty else { throw ComposeError.noFile(base.path) }
        return found
    }

    /// Loads the project the options point at.
    public func loadProject(_ options: ComposeCLIOptions) throws -> ComposeProject {
        let files = try Self.composeFiles(options, currentDirectory: currentDirectory, environment: environment)
        let envFiles = options.envFiles.isEmpty ? nil : options.envFiles.map { path -> URL in
            path.hasPrefix("/") ? URL(fileURLWithPath: path) : currentDirectory.appendingPathComponent(path).standardizedFileURL
        }
        // Exactly the files found: with -f or COMPOSE_FILE only those, otherwise the
        // compose file and its override file. Paths resolve against the project directory.
        let projectDirectory = options.projectDirectory.map { path -> URL in
            path.hasPrefix("/") ? URL(fileURLWithPath: path).standardizedFileURL : currentDirectory.appendingPathComponent(path).standardizedFileURL
        }
        var project = try ComposeParser.load(files: files, projectDirectory: projectDirectory, processEnvironment: environment, envFiles: envFiles)
        if let name = options.projectName, !name.isEmpty {
            project.name = ComposeParser.normalizeProjectName(name)
        }
        return project
    }

    private func makeClient() throws -> ContainerClient {
        let path = cliPath
            ?? environment["CONTAINER_CLI"].flatMap { $0.isEmpty ? nil : $0 }
            ?? ContainerCLILocator(files: .live, pathEnv: environment["PATH"] ?? "").locate(customPath: nil)
        guard let path else {
            throw ComposeError.failed("Apple's container tool was not found. Install it from https://github.com/\(AppConfig.appleContainerRepository).")
        }
        return ContainerClient(cliPath: path, runner: runner ?? ProcessRunner(), streamer: streamer ?? ProcessRunner())
    }

    private func execute(_ options: ComposeCLIOptions) async throws -> Int32 {
        let project = try loadProject(options)

        if options.command == .config {
            return config(project, options: options)
        }

        // Things in the file that will not work here. Up refuses blocking ones.
        if [.up, .pull].contains(options.command) {
            for problem in project.problems {
                err(Self.problemLine(problem, relativeTo: currentDirectory))
            }
        }

        let client = try makeClient()
        let composeRunner = ComposeRunner(client: client)
        let settings = ComposePlanSettings(activeProfiles: Set(options.profiles))
        let fullPlan = try? ComposePlanner.plan(project, settings: settings)
        let services = options.services.isEmpty ? nil : options.services
        if let services {
            let unknown = services.filter { project.service($0) == nil }
            if !unknown.isEmpty { throw ComposeError.failed("No such service: \(unknown.joined(separator: ", ")).") }
        }
        let events: ComposeEventHandler = { event in
            let (line, isError) = Self.format(event)
            if isError { err(line) } else { out(line) }
        }

        // --dry-run is a global option. Commands that change something only say what they would do.
        if options.dryRun, [.start, .stop, .restart, .pull, .exec].contains(options.command) {
            return try await dryRun(options, project: project, runner: composeRunner, plan: fullPlan, settings: settings, services: services)
        }

        switch options.command {
        case .up:
            var upSettings = settings
            upSettings.services = services.map(Set.init)
            let plan = try ComposePlanner.plan(project, settings: upSettings)
            let upOptions = ComposeRunner.UpOptions(
                forceRecreate: options.forceRecreate, alwaysBuild: options.build,
                dryRun: options.dryRun, removeOrphans: options.removeOrphans, pull: options.pull
            )
            try await composeRunner.up(plan, options: upOptions, events: events)
            if options.detach || options.dryRun { return 0 }
            return await attach(composeRunner, plan: plan, services: services, events: events)
        case .down:
            if options.dryRun {
                let found = try await composeRunner.projectContainers(project.name)
                out("Dry run for \(project.name). Nothing is changed.")
                for container in found { out("Would remove \(container.name)") }
                return 0
            }
            try await composeRunner.down(project: project.name, removeVolumes: options.removeVolumes, keepNetworks: options.keepNetworks, plan: fullPlan, events: events)
        case .ps:
            let statuses = try await composeRunner.ps(project: project.name, plan: fullPlan)
                .filter { services == nil || services?.contains($0.service) == true }
            if options.quiet {
                statuses.forEach { out($0.container.id) }
            } else if options.listServices {
                statuses.forEach { out($0.service) }
            } else {
                out(Self.psTable(statuses))
            }
        case .logs:
            let stream = composeRunner.logs(project: project.name, services: services, follow: options.follow, tail: options.tail)
            let width = (services ?? project.services.map(\.name)).map(\.count).max() ?? 0
            for try await line in stream {
                out(Self.logLine(line, width: width))
            }
        case .start:
            try await composeRunner.start(project: project.name, services: services, plan: fullPlan, events: events)
        case .stop:
            try await composeRunner.stop(project: project.name, services: services, plan: fullPlan, events: events)
        case .restart:
            try await composeRunner.restart(project: project.name, services: services, plan: fullPlan, events: events)
        case .pull:
            var pullSettings = settings
            pullSettings.services = services.map(Set.init)
            try await composeRunner.pull(try ComposePlanner.plan(project, settings: pullSettings), events: events)
        case .exec:
            guard let service = options.execService else { return 2 }
            let containers = try await composeRunner.projectContainers(project.name)
            guard let container = containers.first(where: { ComposeLabel.serviceName($0.labels) == service }) else {
                throw ComposeError.failed("Service \(service) has no container. Run container compose up first.")
            }
            guard container.isRunning else {
                throw ComposeError.failed("Service \(service) is not running.")
            }
            let args = Self.execArguments(options, container: container.id, stdinIsTerminal: stdinIsTerminal)
            return execReplace(client.cliPath, args)
        case .config, .help, .version:
            break
        }
        return 0
    }

    /// `start`, `stop`, `restart`, `pull` and `exec` with `--dry-run`: print what would happen.
    private func dryRun(_ options: ComposeCLIOptions, project: ComposeProject, runner: ComposeRunner, plan: ComposePlan?,
                        settings: ComposePlanSettings, services: [String]?) async throws -> Int32 {
        out("Dry run for \(project.name). Nothing is changed.")
        if options.command == .pull {
            var pullSettings = settings
            pullSettings.services = services.map(Set.init)
            var done: Set<String> = []
            for service in try ComposePlanner.plan(project, settings: pullSettings).services
            where service.build == nil && !done.contains(service.options.image) {
                done.insert(service.options.image)
                out("Would pull \(service.options.image)")
            }
            return 0
        }
        let containers = try await runner.projectContainers(project.name).filter { container in
            services == nil || services?.contains(ComposeLabel.serviceName(container.labels) ?? "") == true
        }
        switch options.command {
        case .start:
            for container in containers where !container.isRunning { out("Would start \(container.name)") }
        case .stop:
            for container in containers where container.isRunning { out("Would stop \(container.name)") }
        case .restart:
            for container in containers { out("Would restart \(container.name)") }
        case .exec:
            guard let service = options.execService,
                  let container = containers.first(where: { ComposeLabel.serviceName($0.labels) == service }) else {
                throw ComposeError.failed("Service \(options.execService ?? "") has no container. Run container compose up first.")
            }
            out("Would run \(options.execCommand.joined(separator: " ")) in \(container.name)")
        default:
            break
        }
        return 0
    }

    /// Follows the logs after `up` without -d. Ctrl+C stops the services.
    private func attach(_ runner: ComposeRunner, plan: ComposePlan, services: [String]?, events: @escaping ComposeEventHandler) async -> Int32 {
        out("Attaching to \(plan.services.map(\.containerName).joined(separator: ", ")). Press Ctrl+C to stop.")
        let width = plan.services.map(\.name).map(\.count).max() ?? 0
        let out = self.out
        let interrupted = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                do {
                    for try await line in runner.logs(project: plan.projectName, services: services, follow: true, tail: 50) {
                        out(Self.logLine(line, width: width))
                    }
                } catch {}
                return false
            }
            group.addTask {
                await Self.waitForInterrupt()
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        guard interrupted else { return 0 }
        out("Stopping...")
        do {
            try await runner.stop(project: plan.projectName, services: services, plan: plan, events: events)
        } catch {
            err("error: \(error.localizedDescription)")
            return 1
        }
        return 130
    }

    /// Waits for Ctrl+C. Returns false when the task is cancelled first.
    private static func waitForInterrupt() async -> Bool {
        signal(SIGINT, SIG_IGN)
        let stream = AsyncStream<Void> { continuation in
            let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
            source.setEventHandler { continuation.yield() }
            source.resume()
            continuation.onTermination = { _ in source.cancel() }
        }
        for await _ in stream { return true }
        return false
    }

    private func config(_ project: ComposeProject, options: ComposeCLIOptions) -> Int32 {
        for problem in project.problems { err(Self.problemLine(problem, relativeTo: currentDirectory)) }
        if options.listServices {
            project.services.forEach { out($0.name) }
        } else if !options.quiet {
            out(Self.trimmed(ComposeConfigWriter.yaml(project)))
        }
        return project.hasBlockingProblems ? 1 : 0
    }

    private static func trimmed(_ text: String) -> String {
        text.hasSuffix("\n") ? String(text.dropLast()) : text
    }

    // MARK: Formatting

    /// One event as a terminal line. The Bool is true for stderr.
    public static func format(_ event: ComposeEvent) -> (String, Bool) {
        let prefix = event.service.map { "\($0): " } ?? ""
        switch event.kind {
        case .step: return ("=> \(prefix)\(event.message)", false)
        case .info: return ("   \(prefix)\(event.message)", false)
        case .output: return ("   \(event.service.map { "\($0) | " } ?? "| ")\(event.message)", false)
        case .success: return ("✔ \(prefix)\(event.message)", false)
        case .warning: return ("warning: \(prefix)\(event.message)", true)
        case .failure: return ("error: \(prefix)\(event.message)", true)
        }
    }

    /// "error: compose.override.yaml:12: services.web.ports: ...". The file is shown
    /// relative to `directory` when it is inside it. Without a file: "line 12: ...".
    public static func problemLine(_ problem: ComposeProblem, relativeTo directory: URL? = nil) -> String {
        let label: String
        switch problem.kind {
        case .invalid: label = "error"
        case .notPossible: label = "not possible"
        case .notBuilt: label = "not built yet"
        }
        let place: String
        if let location = problem.location(relativeTo: directory) {
            place = "\(location): "
        } else {
            place = problem.line > 0 ? "line \(problem.line): " : ""
        }
        return "\(label): \(place)\(problem.key): \(problem.message)"
    }

    public static func logLine(_ line: ComposeLogLine, width: Int) -> String {
        line.service.padding(toLength: max(width, line.service.count), withPad: " ", startingAt: 0) + " | " + line.text
    }

    /// `docker compose ps` style table.
    public static func psTable(_ statuses: [ComposeServiceStatus]) -> String {
        let header = ["NAME", "IMAGE", "SERVICE", "STATUS", "ADDRESS", "PORTS"]
        let rows = statuses.map { status -> [String] in
            let ports = status.container.ports.map { port -> String in
                let host = port.hostAddress.map { "\($0):" } ?? ""
                return "\(host)\(port.hostPort)->\(port.containerPort)/\(port.proto)"
            }.joined(separator: ", ")
            return [status.container.name, status.container.image, status.service, status.container.state.rawValue, status.ipAddress ?? "", ports]
        }
        var widths = header.map(\.count)
        for row in rows {
            for (index, cell) in row.enumerated() { widths[index] = max(widths[index], cell.count) }
        }
        func render(_ cells: [String]) -> String {
            cells.enumerated().map { index, cell in
                index == cells.count - 1 ? cell : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }.joined(separator: "   ").trimmingCharacters(in: .whitespaces)
        }
        return ([render(header)] + rows.map(render)).joined(separator: "\n")
    }

    /// `container exec` arguments for `compose exec`.
    public static func execArguments(_ options: ComposeCLIOptions, container: String, stdinIsTerminal: Bool) -> [String] {
        var args = ["exec"]
        if options.execDetach {
            args.append("--detach")
        } else {
            args.append("--interactive")
            if stdinIsTerminal && !options.noTTY { args.append("--tty") }
        }
        for env in options.execEnv { args += ["--env", env] }
        if let user = options.execUser { args += ["--user", user] }
        if let dir = options.execWorkdir { args += ["--workdir", dir] }
        args.append(container)
        args += options.execCommand
        return args
    }

    // MARK: Help

    public static func help(for command: ComposeCLIOptions.Command?) -> String {
        switch command {
        case .up:
            return """
            Usage: container compose up [OPTIONS] [SERVICE...]

            Create and start the services. Only what changed is recreated.

            Options:
              -d, --detach              Start in the background. Without it, logs follow until Ctrl+C.
                  --force-recreate      Recreate every service, even when nothing changed.
                  --build               Build images before starting.
                  --pull POLICY         missing (default), always or never.
                  --remove-orphans      Remove containers whose service left the file (default).
                  --keep-orphans        Keep them.
                  --dry-run             Show what would happen. Nothing is changed.
            """
        case .down:
            return """
            Usage: container compose down [OPTIONS]

            Stop and remove the project containers and networks.

            Options:
              -v, --volumes             Also remove the project volumes, anonymous ones included.
                  --keep-networks       Keep the project networks.
                  --dry-run             Show what would be removed.
            """
        case .ps:
            return """
            Usage: container compose ps [OPTIONS] [SERVICE...]

            List the project containers.

            Options:
              -q, --quiet               Only show container IDs.
                  --services            Only show service names.
            """
        case .logs:
            return """
            Usage: container compose logs [OPTIONS] [SERVICE...]

            Show service logs.

            Options:
              -f, --follow              Keep following new lines.
              -n, --tail N              Only the last N lines of each service. Default: all.
            """
        case .exec:
            return """
            Usage: container compose exec [OPTIONS] SERVICE COMMAND [ARGS...]

            Run a command in a running service.

            Options:
              -T, --no-TTY              Do not open a terminal.
              -d, --detach              Run in the background.
              -e, --env KEY=VALUE       Set a variable. Repeatable.
              -u, --user USER           Run as this user.
              -w, --workdir DIR         Run in this folder.
            """
        case .config:
            return """
            Usage: container compose config [OPTIONS]

            Print the project with every compose file merged, variables filled in,
            paths made absolute and the names Up uses.

            Options:
              -q, --quiet               Only check the file. Exit code 1 when it has errors.
                  --services            Only print the service names.
            """
        case .start, .stop, .restart, .pull:
            let what: String
            switch command {
            case .start: what = "Start stopped services."
            case .stop: what = "Stop services. Uses stop_signal and stop_grace_period."
            case .restart: what = "Restart services."
            default: what = "Pull the images of the services."
            }
            return """
            Usage: container compose \(command?.rawValue ?? "") [SERVICE...]

            \(what)
            """
        default:
            return """
            Usage: container compose [OPTIONS] COMMAND

            Run compose files with Apple's container tool. Part of \(AppConfig.appName).

            Options:
              -f, --file FILE           Compose file. Repeatable, later files merge on top.
                                        Default: compose.yaml in this folder or a parent,
                                        with compose.override.yaml next to it.
              -p, --project-name NAME   Project name. Default: the name key, then the folder name.
                  --project-directory DIR
                                        Folder to look for the compose file in.
                  --env-file FILE       Read variables from this file instead of .env. Repeatable.
                  --profile NAME        Turn on a profile. Repeatable.
                  --dry-run             Show what would happen. Nothing is changed.
              -v, --version             Show the version.
              -h, --help                Show this help.

            Commands:
              up        Create and start the services
              down      Stop and remove containers and networks
              ps        List the project containers
              logs      Show service logs
              start     Start stopped services
              stop      Stop services
              restart   Restart services
              pull      Pull service images
              exec      Run a command in a running service
              config    Print the merged and resolved compose file
              version   Show the version

            Environment: COMPOSE_FILE (with COMPOSE_PATH_SEPARATOR), COMPOSE_PROJECT_NAME,
            COMPOSE_PROFILES, CONTAINER_CLI.
            Run container compose COMMAND --help for the options of a command.
            """
        }
    }
}
