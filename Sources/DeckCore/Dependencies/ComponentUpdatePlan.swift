import Foundation

/// The steps that update one component, with the same install method it came from.
/// Pure data, built by `ComponentUpdatePlanner` and run by `ComponentUpdater`.
public struct ComponentUpdatePlan: Sendable, Equatable {
    public enum Step: Sendable, Equatable {
        /// Apple's signed package for the target version.
        case downloadPackage(PackageRef)
        /// SHA-256 from GitHub, then `pkgutil --check-signature` (signed by Apple).
        case verifyPackage
        case stopContainerService
        /// `installer -pkg <package> -target /` behind the macOS password prompt.
        case installPackage
        case startContainerService
        /// Stops the MLX server Container Deck started.
        case stopMLXServer
        case stopOllama
        case startOllama
        /// A command with its output streamed (brew, uv, lms, LM Studio's installer).
        case run(executable: String, arguments: [String])
        /// Container Deck's own checked cloudflared download, again.
        case downloadCloudflared
        /// Cloudflare's release for one tag into Container Deck's own folder (a downgrade).
        case downloadCloudflaredVersion(String)
        /// Container Deck's own uv download, again.
        case downloadUV
        case pullImage(String)
        /// Starts the MCP server again so it runs the new image.
        case recreateMCPServer(String)
        /// Reads the version again.
        case recheck
        /// Notes which containers run now, so they start again after a downgrade.
        case recordRunningContainers
        /// Apple's uninstall script with `-k` (keeps images, volumes and settings). In a real run it
        /// shares the password prompt with the next `installPackage`.
        case uninstallKeepingData(script: String)
        /// The read only health checks of the tool, recorded as its last good version when they pass.
        case healthCheck
        /// Copies Apple container's data folder and ~/.config/container into this folder while the
        /// service is stopped (an APFS clone with `cp -c`, so it takes almost no space or time).
        case backupContainerData(folder: String)
        /// Starts the containers that ran before (`recordRunningContainers`).
        case restartContainers

        public var label: String {
            switch self {
            case .downloadPackage(let package): return "Download \(package.name)"
            case .verifyPackage: return "Check the download and Apple's signature"
            case .stopContainerService: return "Stop the container service"
            case .installPackage: return "Install (macOS asks for your password)"
            case .startContainerService: return "Start the container service"
            case .stopMLXServer: return "Stop the MLX server"
            case .stopOllama: return "Stop Ollama"
            case .startOllama: return "Start Ollama"
            case .run(let executable, let arguments): return "Run " + ComponentUpdatePlanner.shortCommand(executable, arguments)
            case .downloadCloudflared: return "Download cloudflared and check it"
            case .downloadCloudflaredVersion(let version): return "Download cloudflared \(version) and check it"
            case .downloadUV: return "Download uv"
            case .pullImage(let image): return "Pull \(image)"
            case .recreateMCPServer(let name): return "Start \(name) again"
            case .recheck: return "Check the new version"
            case .recordRunningContainers: return "Note the running containers"
            case .uninstallKeepingData: return "Remove the newer version, keep your data"
            case .healthCheck: return "Check the features \(AppConfig.appName) uses"
            case .backupContainerData: return "Back up the container data"
            case .restartContainers: return "Start the containers that were running"
            }
        }

        /// Steps that can stop halfway without leaving a broken install.
        public var isCancellable: Bool {
            switch self {
            case .downloadPackage, .verifyPackage, .pullImage, .downloadCloudflared, .downloadUV, .recheck,
                 .recordRunningContainers, .healthCheck: return true
            default: return false
            }
        }
    }

    public var componentID: String
    public var title: String
    public var target: String?
    public var steps: [Step]
    /// What the confirmation says before anything runs.
    public var confirmation: String
    /// Needs the macOS password prompt.
    public var needsAdmin: Bool
    /// True when this Mac cannot run it from the app (no admin rights). Show `terminalCommand` instead.
    public var manualOnly: Bool
    /// The same update as one line people can run in Terminal.
    public var terminalCommand: String
    /// A switch the app cannot run: the exact steps to do it by hand. Empty for plans with steps.
    public var manualSteps: [String] = []
    /// Shown above the manual steps, like why the app can't do it.
    public var manualReason: String?

    /// No button: show `manualSteps`.
    public var isManual: Bool { steps.isEmpty && !manualSteps.isEmpty }
}

/// Inputs for planning that come from this Mac.
public struct ComponentPlanContext: Sendable {
    public var containerPath: String?
    public var brewPath: String?
    public var lmsPath: String?
    /// `lms daemon --help` lists `update`.
    public var lmsHasDaemonUpdate: Bool
    /// LM Studio's installer as LMStudioRuntime runs it (a stand in script in debug runs).
    public var lmStudioInstallCommand: (executable: String, arguments: [String])?
    public var uvPath: String?
    /// The person's own uv and pipx, for agent tools installed with them.
    public var toolUVPath: String?
    public var pipxPath: String?
    /// `KEY=value` pairs that keep uv inside the app's folder (MLXRuntime).
    public var mlxEnvironment: [String]
    /// Installer for the target version (Apple container).
    public var package: PackageRef?
    public var isAdmin: Bool
    /// The person agreed to restart Ollama after the update.
    public var restartOllama: Bool
    public var mlxServerRunning: Bool
    /// The MCP server's long running container is up now.
    public var mcpServerRunning: Bool
    /// Apple's uninstall script from the installed package (`/usr/local/bin/uninstall-container.sh`), when it is there.
    public var uninstallScript: String?
    /// A Homebrew versioned formula that installs the switch target, like "helm@3".
    public var versionedFormula: String?
    /// Homebrew's newest release of the formula is in the tested line (a switch up can use `brew upgrade`).
    public var brewNewestMatchesTested = false
    /// The tool's own command, for tools that can install one version themselves (`claude install <version>`).
    public var toolPath: String?
    /// Where an Apple container downgrade backs up the data first. nil: no backup step.
    public var containerBackupFolder: String?

    public init(containerPath: String? = nil, brewPath: String? = nil, lmsPath: String? = nil, lmsHasDaemonUpdate: Bool = false,
                lmStudioInstallCommand: (executable: String, arguments: [String])? = nil, uvPath: String? = nil, mlxEnvironment: [String] = [], package: PackageRef? = nil, isAdmin: Bool = true,
                restartOllama: Bool = false, mlxServerRunning: Bool = false, mcpServerRunning: Bool = false) {
        self.containerPath = containerPath
        self.brewPath = brewPath
        self.lmsPath = lmsPath
        self.lmsHasDaemonUpdate = lmsHasDaemonUpdate
        self.lmStudioInstallCommand = lmStudioInstallCommand
        self.uvPath = uvPath
        self.toolUVPath = nil
        self.pipxPath = nil
        self.mlxEnvironment = mlxEnvironment
        self.package = package
        self.isAdmin = isAdmin
        self.restartOllama = restartOllama
        self.mlxServerRunning = mlxServerRunning
        self.mcpServerRunning = mcpServerRunning
    }
}

public enum ComponentPlanError: LocalizedError, Equatable {
    case notUpdatable(String)
    case missingTool(String)

    public var errorDescription: String? {
        switch self {
        case .notUpdatable(let name): return "\(name) cannot be updated from \(AppConfig.appName)."
        case .missingTool(let tool): return "\(tool) was not found."
        }
    }
}

public enum ComponentUpdatePlanner {
    /// The plan for a row with a safe update. Throws when the row has none or a tool is missing.
    /// Every update ends with the health checks, so a release that breaks a feature shows up
    /// right away and the last good version is kept.
    public static func plan(for info: ComponentInfo, context: ComponentPlanContext) throws -> ComponentUpdatePlan {
        var plan = try basePlan(for: info, context: context)
        if ComponentHealthProbe.hasChecks(info.kind), plan.steps.last == .recheck {
            plan.steps.append(.healthCheck)
        }
        return plan
    }

    static func basePlan(for info: ComponentInfo, context: ComponentPlanContext) throws -> ComponentUpdatePlan {
        guard info.status == .updateAvailable, let method = info.method, !info.updatesItself else {
            throw ComponentPlanError.notUpdatable(info.name)
        }
        let target = info.target
        let toText = target.map { " to \($0)" } ?? ""
        let title = "Update \(info.name)\(toText)"

        switch (info.kind, method) {
        case (.container, .applePackage):
            guard let package = context.package else { throw ComponentPlanError.missingTool("The installer package") }
            let cli = context.containerPath ?? "/usr/local/bin/container"
            let file = "/tmp/" + package.name
            let command = [
                "curl -fL -o \(quote(file)) \(quote(package.url.absoluteString))",
                "pkgutil --check-signature \(quote(file))",
                "\(quote(cli)) system stop",
                "sudo installer -pkg \(quote(file)) -target /",
                "\(quote(cli)) system start"
            ].joined(separator: " && ")
            return ComponentUpdatePlan(
                componentID: info.id, title: title, target: target,
                steps: [.downloadPackage(package), .verifyPackage, .stopContainerService, .installPackage, .startContainerService, .recheck],
                confirmation: "The container service stops while Apple's installer runs, then starts again. Running containers stop. macOS asks for your password. Images, volumes and settings are kept.",
                needsAdmin: true, manualOnly: !context.isAdmin, terminalCommand: command)

        case (_, .homebrewFormula(let name)), (_, .homebrewCask(let name)):
            guard let brew = context.brewPath else { throw ComponentPlanError.missingTool("Homebrew") }
            var arguments = ["upgrade"]
            if case .homebrewCask = method { arguments.append("--cask") }
            arguments.append(name)
            var steps: [ComponentUpdatePlan.Step] = [.run(executable: brew, arguments: arguments)]
            var confirmation = "Homebrew updates \(name). This can take a few minutes."
            if info.kind == .ollama {
                if context.restartOllama {
                    steps += [.stopOllama, .startOllama]
                    confirmation += " Ollama stops and starts again so the new version runs. Loaded models unload."
                } else {
                    confirmation += " Ollama keeps running the old version until it restarts."
                }
            }
            steps.append(.recheck)
            return ComponentUpdatePlan(componentID: info.id, title: title, target: target, steps: steps, confirmation: confirmation,
                                       needsAdmin: false, manualOnly: false, terminalCommand: displayCommand("brew", arguments))

        case (.mlx, .appRuntime):
            guard let uv = context.uvPath else { throw ComponentPlanError.missingTool("uv") }
            let package = target.map { "\(AIConfig.mlxPackage)==\($0)" } ?? AIConfig.mlxPackage
            let arguments = context.mlxEnvironment + [uv, "tool", "install", "--python", AIConfig.mlxPythonVersion, "--upgrade", package]
            var steps: [ComponentUpdatePlan.Step] = []
            var confirmation = "mlx-lm is updated in \(AppConfig.appName)'s own folder. Downloaded models are kept."
            if context.mlxServerRunning {
                steps.append(.stopMLXServer)
                confirmation += " The MLX server stops first. Start it again when the update is done."
            }
            steps += [.run(executable: "/usr/bin/env", arguments: arguments), .recheck]
            return ComponentUpdatePlan(componentID: info.id, title: title, target: target, steps: steps, confirmation: confirmation,
                                       needsAdmin: false, manualOnly: false,
                                       terminalCommand: displayCommand("/usr/bin/env", arguments))

        case (.lmStudio, .lmStudioScript):
            if context.lmsHasDaemonUpdate, let lms = context.lmsPath {
                return ComponentUpdatePlan(
                    componentID: info.id, title: title, target: target,
                    steps: [.run(executable: lms, arguments: ["daemon", "update"]), .recheck],
                    confirmation: "LM Studio updates its own service with lms daemon update. The LM Studio server may restart and loaded models unload.",
                    needsAdmin: false, manualOnly: false, terminalCommand: displayCommand("lms", ["daemon", "update"]))
            }
            let script = context.lmStudioInstallCommand ?? ("/bin/bash", ["-c", "set -o pipefail; " + LMStudioRuntime.installCoreCommandLine])
            return ComponentUpdatePlan(
                componentID: info.id, title: title, target: target,
                steps: [.run(executable: script.executable, arguments: script.arguments), .recheck],
                confirmation: "LM Studio's own installer runs again and replaces LM Studio core. The LM Studio server may restart and loaded models unload.",
                needsAdmin: false, manualOnly: false, terminalCommand: LMStudioRuntime.installCoreCommandLine)

        case (.uv, .appDownload):
            return ComponentUpdatePlan(componentID: info.id, title: title, target: target, steps: [.downloadUV, .recheck],
                                       confirmation: "\(AppConfig.appName) downloads the newest uv into its own folder.",
                                       needsAdmin: false, manualOnly: false,
                                       terminalCommand: "curl -fL \(AIConfig.uvDownloadURL.absoluteString) | tar -xz")

        case (.cloudflared, .appDownload):
            return ComponentUpdatePlan(componentID: info.id, title: title, target: target, steps: [.downloadCloudflared, .recheck],
                                       confirmation: "\(AppConfig.appName) downloads Cloudflare's release, checks its checksum and signature, and replaces its own copy. Running shares keep the old copy until they restart.",
                                       needsAdmin: false, manualOnly: false,
                                       terminalCommand: "brew install cloudflared")

        case (.agent, .npmGlobal(let package, let prefix)):
            // npm is a Node script: give it the Node next to it, apps do not get the shell PATH.
            let npm = prefix + "/bin/npm"
            let spec = target.map { "\(package)@\($0)" } ?? package
            let arguments = ["PATH=\(prefix)/bin:/usr/bin:/bin", npm, "install", "-g", spec]
            return ComponentUpdatePlan(componentID: info.id, title: title, target: target,
                                       steps: [.run(executable: "/usr/bin/env", arguments: arguments), .recheck],
                                       confirmation: "npm installs \(spec). Sessions that are open keep the old version until they restart.",
                                       needsAdmin: false, manualOnly: false, terminalCommand: "npm install -g \(spec)")

        case (.agent, .uvTool(let package)):
            guard let uv = context.toolUVPath else { throw ComponentPlanError.missingTool("uv") }
            return ComponentUpdatePlan(componentID: info.id, title: title, target: target,
                                       steps: [.run(executable: uv, arguments: ["tool", "upgrade", package]), .recheck],
                                       confirmation: "uv updates \(package). Sessions that are open keep the old version until they restart.",
                                       needsAdmin: false, manualOnly: false, terminalCommand: "uv tool upgrade \(package)")

        case (.agent, .pipx(let package)):
            guard let pipx = context.pipxPath else { throw ComponentPlanError.missingTool("pipx") }
            return ComponentUpdatePlan(componentID: info.id, title: title, target: target,
                                       steps: [.run(executable: pipx, arguments: ["upgrade", package]), .recheck],
                                       confirmation: "pipx updates \(package). Sessions that are open keep the old version until they restart.",
                                       needsAdmin: false, manualOnly: false, terminalCommand: "pipx upgrade \(package)")

        case (.agent, .selfUpdater(let binary)):
            return ComponentUpdatePlan(componentID: info.id, title: title, target: target,
                                       steps: [.run(executable: binary, arguments: ["update"]), .recheck],
                                       confirmation: "\(info.name) updates itself with its own update command.",
                                       needsAdmin: false, manualOnly: false,
                                       terminalCommand: displayCommand(binary, ["update"]))

        case (.mcp, .containerImage(let image)):
            var steps: [ComponentUpdatePlan.Step] = [.pullImage(image)]
            var confirmation = "The newer image is pulled."
            if context.mcpServerRunning {
                steps.append(.recreateMCPServer(info.name))
                confirmation += " The server's container starts again on the new image. Agents connected to it reconnect."
            } else {
                confirmation += " The server uses it the next time it starts."
            }
            steps.append(.recheck)
            return ComponentUpdatePlan(componentID: info.id, title: "Update \(info.name)", target: target, steps: steps,
                                       confirmation: confirmation, needsAdmin: false, manualOnly: false,
                                       terminalCommand: "container image pull \(image)")

        default:
            throw ComponentPlanError.notUpdatable(info.name)
        }
    }

    static func quote(_ text: String) -> String {
        if text.range(of: #"^[A-Za-z0-9_./:=@%+,-]+$"#, options: .regularExpression) != nil { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A short command for step labels: `/usr/bin/env KEY=value uv tool ...` reads as `uv tool ...`.
    public static func shortCommand(_ executable: String, _ arguments: [String]) -> String {
        guard (executable as NSString).lastPathComponent == "env" else { return displayCommand(executable, arguments) }
        let rest = arguments.drop { $0.contains("=") && !$0.hasPrefix("-") && !$0.hasPrefix("/") && $0.first?.isUppercase == true }
        guard let tool = rest.first else { return displayCommand(executable, arguments) }
        return displayCommand(tool, Array(rest.dropFirst()))
    }

    /// A command line for display, with the tool's short name and quoted arguments.
    public static func displayCommand(_ executable: String, _ arguments: [String]) -> String {
        ([(executable as NSString).lastPathComponent] + arguments.map(quote)).joined(separator: " ")
    }
}
