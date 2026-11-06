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
            appRoot: home + "/Library/Application Support/com.apple.container"
        )
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

        checks.append(kernelCheck())
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
                state: .missing("Version \(version) is too old. Version \(Self.minimumVersion) or newer is needed."),
                fix: .installPlatform
            )
        }
        return SetupCheck(id: .cliVersion, state: .ok("Version \(version)"))
    }

    func kernelCheck() -> SetupCheck {
        let names = env.files.contentsOfDirectory(env.appRoot + "/kernels")
        if names.contains(where: { $0.hasPrefix("default.kernel") }) {
            return SetupCheck(id: .kernel, state: .ok("Installed"))
        }
        return SetupCheck(
            id: .kernel,
            state: .missing("No default Linux kernel yet. Containers need one to boot."),
            fix: .installKernel
        )
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
