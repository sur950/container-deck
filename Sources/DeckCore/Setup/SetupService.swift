import Foundation

/// Everything the checks read from the Mac. Tests pass a fake one.
public struct SetupEnvironment: Sendable {
    public var system: SystemInfo
    public var files: FileSystem
    public var pathEnv: String
    public var customCLIPath: String?
    /// Apple's container data folder.
    public var appRoot: String

    public init(system: SystemInfo, files: FileSystem, pathEnv: String, customCLIPath: String?, appRoot: String) {
        self.system = system
        self.files = files
        self.pathEnv = pathEnv
        self.customCLIPath = customCLIPath
        self.appRoot = appRoot
    }

    public static func live(customCLIPath: String?) -> SetupEnvironment {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return SetupEnvironment(
            system: .current(),
            files: .live,
            pathEnv: ProcessInfo.processInfo.environment["PATH"] ?? "",
            customCLIPath: customCLIPath,
            appRoot: ContainerAppRoot.current(defaultHome: home)
        )
    }
}

/// Apple's container data folder. `CONTAINER_APP_ROOT` moves it, as for Apple's own tools
/// (`ApplicationRoot.environmentName`), which is how a second release runs side by side.
public enum ContainerAppRoot {
    public static let environmentName = "CONTAINER_APP_ROOT"

    public static func current(defaultHome: String = FileManager.default.homeDirectoryForCurrentUser.path,
                               environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let custom = environment[environmentName]?.trimmingCharacters(in: .whitespaces), custom.hasPrefix("/") {
            return custom.hasSuffix("/") && custom.count > 1 ? String(custom.dropLast()) : custom
        }
        return defaultHome + "/Library/Application Support/com.apple.container"
    }
}

/// Checks whether the Mac is ready to run containers.
public struct SetupService: Sendable {
    /// Oldest `container` version we support.
    public static let minimumVersion = SemanticVersion(0, 5, 0)

    public static let rosettaPaths = [
        "/Library/Apple/usr/libexec/oah/libRosettaRuntime",
        "/Library/Apple/usr/share/rosetta/rosetta"
    ]

    /// Says whether the container services run, for the CLI found at the path.
    public typealias ServiceCheck = @Sendable (_ cliPath: String) async throws -> Bool

    let runner: any CommandRunning
    let env: SetupEnvironment
    let serviceCheck: ServiceCheck?

    /// `serviceCheck` replaces `container system status` (the app asks the daemon
    /// directly through its router). nil uses the CLI.
    public init(runner: any CommandRunning, environment: SetupEnvironment, serviceCheck: ServiceCheck? = nil) {
        self.runner = runner
        self.env = environment
        self.serviceCheck = serviceCheck
    }

    public func runChecks() async -> SetupReport {
        var checks: [SetupCheck] = [hardwareCheck()]

        let locator = ContainerCLILocator(files: env.files, pathEnv: env.pathEnv)
        guard let path = locator.locate(customPath: env.customCLIPath) else {
            checks.append(SetupCheck(
                id: .cliInstalled,
                state: .missing("Apple's container tool is not installed yet."),
                fix: .installPlatform
            ))
            for id in [CheckID.cliVersion, .service, .kernel] {
                checks.append(SetupCheck(id: id, state: .waiting("Waiting for the install step.")))
            }
            checks.append(rosettaCheck())
            checks.append(SetupCheck(id: .dns, state: .waiting("Waiting for the install step.")))
            checks.append(SetupCheck(id: .terminalCommand, state: .waiting("Waiting for the install step.")))
            return SetupReport(checks: checks, cliPath: nil, cliVersion: nil, serviceRunning: false)
        }

        checks.append(SetupCheck(id: .cliInstalled, state: .ok("Found at \(path)")))

        let cli = ContainerCLI(path: path, runner: runner)
        // The three calls do not depend on each other, so they run at the same time.
        // The DNS answer is only used when the service runs.
        async let versionResult = try? cli.version()
        let check = serviceCheck
        async let runningResult: Bool? = {
            if let check { return try? await check(path) }
            return try? await cli.isServiceRunning()
        }()
        async let domainsResult = try? cli.dnsDomains()
        let version = await versionResult
        checks.append(versionCheck(version))

        let running = (await runningResult) ?? false
        checks.append(running
            ? SetupCheck(id: .service, state: .ok("Running"))
            : SetupCheck(id: .service, state: .missing("The container service is not running."), fix: .startService))

        var kernel = kernelCheck(version: version)
        if case .warning = kernel.state, running {
            // Confirm with the tool's own config, which honours a kernel set in config.toml.
            kernel = kernelCheck(version: version, recommended: await recommendedKernelFromTool(cli))
        }
        checks.append(kernel)
        checks.append(rosettaCheck())

        if running {
            let domains = (await domainsResult) ?? []
            if let first = domains.first {
                checks.append(SetupCheck(id: .dns, state: .ok("Containers can use names like web.\(first)")))
            } else {
                checks.append(SetupCheck(
                    id: .dns,
                    state: .missing("Reach containers by name, like web.test."),
                    fix: .createDNSDomain
                ))
            }
        } else {
            checks.append(SetupCheck(id: .dns, state: .waiting("Start the service first.")))
        }

        checks.append(terminalCommandCheck())

        return SetupReport(checks: checks, cliPath: path, cliVersion: version, serviceRunning: running)
    }

    // MARK: - Single checks

    func hardwareCheck() -> SetupCheck {
        let sys = env.system
        guard sys.isAppleSilicon else {
            return SetupCheck(id: .hardware, state: .failed("\(AppConfig.appName) needs a Mac with Apple silicon."))
        }
        let os = "macOS \(sys.osMajor).\(sys.osMinor)"
        if sys.osMajor < 15 {
            return SetupCheck(id: .hardware, state: .failed("\(os) is too old. macOS 15 or later is needed."))
        }
        if sys.osMajor == 15 {
            return SetupCheck(id: .hardware, state: .warning("\(os) works with limits. macOS 26 is recommended."))
        }
        return SetupCheck(id: .hardware, state: .ok("Apple silicon, \(os)"))
    }

    func versionCheck(_ version: SemanticVersion?) -> SetupCheck {
        guard let version else {
            return SetupCheck(id: .cliVersion, state: .warning("Could not read the version. Some features may not work."))
        }
        if version < Self.minimumVersion {
            return SetupCheck(
                id: .cliVersion,
                state: .warning("Version \(version) is older than \(Self.minimumVersion). Some screens may not work. Updating is recommended."),
                fix: .installPlatform
            )
        }
        return SetupCheck(id: .cliVersion, state: .ok("Version \(version)"))
    }

    /// Installed, missing, or installed but older than the release recommends. An upgraded
    /// Mac keeps its old default kernel (for example 6.18.35 after moving to 1.7, which
    /// recommends 6.18.56) until `container system kernel set --recommended`.
    /// `recommended` is the kernel file the tool names, nil for the tested value of `version`.
    func kernelCheck(version: SemanticVersion? = nil, recommended: String? = nil) -> SetupCheck {
        let folder = env.appRoot + "/kernels"
        let names = env.files.contentsOfDirectory(folder)
        if let link = names.first(where: { $0.hasPrefix("default.kernel") }) {
            let installed = env.files.symlinkDestination(folder + "/" + link).map { ($0 as NSString).lastPathComponent }
            let wanted = recommended ?? (version.map { (KernelSource.builtIn(for: $0).binaryPath as NSString).lastPathComponent })
            if let installed, let wanted, Self.isKernelFile(installed), installed != wanted {
                return SetupCheck(
                    id: .kernel,
                    state: .warning("Installed \(Self.kernelName(installed)). This container release recommends \(Self.kernelName(wanted))."),
                    fix: .useRecommendedKernel
                )
            }
            return SetupCheck(id: .kernel, state: .ok("Installed"))
        }
        return SetupCheck(
            id: .kernel,
            state: .missing("No default Linux kernel yet. Containers need one to boot."),
            fix: .installKernel
        )
    }

    /// "vmlinux-6.18.56-208-debug" reads "kernel 6.18.56".
    static func kernelName(_ file: String) -> String {
        if let version = SemanticVersion.firstMatch(in: file) { return "kernel \(version)" }
        return file
    }

    /// Only compare files named like Apple's kernels, so a custom kernel someone set on purpose is left alone.
    static func isKernelFile(_ name: String) -> Bool {
        name.hasPrefix("vmlinux") && SemanticVersion.firstMatch(in: name) != nil
    }

    /// The kernel file `container system property list` names (`kernel.binaryPath`).
    func recommendedKernelFromTool(_ cli: ContainerCLI) async -> String? {
        guard let result = try? await cli.run(["system", "property", "list", "--format", "json"]), result.succeeded,
              let properties = try? ContainerOutputParser.systemProperties(result.stdout),
              let source = KernelSource.from(properties: properties) else { return nil }
        return (source.binaryPath as NSString).lastPathComponent
    }

    func rosettaCheck() -> SetupCheck {
        if Self.rosettaPaths.contains(where: env.files.fileExists) {
            return SetupCheck(id: .rosetta, state: .ok("Installed"))
        }
        return SetupCheck(
            id: .rosetta,
            state: .missing("Needed only for images built for Intel (amd64)."),
            fix: .installRosetta
        )
    }

    func terminalCommandCheck() -> SetupCheck {
        if ContainerCLILocator.defaultCandidates.contains(where: env.files.fileExists) {
            return SetupCheck(id: .terminalCommand, state: .ok("Ready to use in Terminal"))
        }
        return SetupCheck(
            id: .terminalCommand,
            state: .missing("Lets you type container in Terminal."),
            fix: .linkCommand
        )
    }
}
