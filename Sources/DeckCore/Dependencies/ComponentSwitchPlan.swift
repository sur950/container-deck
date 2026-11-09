import Foundation

/// Texts about switching versions that other work fills in, kept in one place.
public enum ComponentSwitchNotes {
    /// Shown before an Apple container downgrade. Kept in one place so it can change with new tests.
    ///
    /// Apple's README: "The container application data provides forward compatibility only,
    /// guaranteed within one major version." Tested on 9 Nov 2026 (1.6.1 to 1.7.1 and back):
    /// containers, images, volumes with data, networks and a 1.6.1 cluster all came back, the
    /// plugin state files 1.7 adds are ignored by 1.6.1, and a 6.18.56 kernel works on 1.6.1.
    /// Clusters 1.7 made with "Share this Mac's image store" need 1.7's host store socket.
    public static func containerData(from installed: String, to target: String) -> String {
        "Containers, images, volumes, networks and clusters came back in testing after going from 1.6 to 1.7 and back, but Apple only promises that data works with newer versions. Back up first."
    }

    /// Clusters that share this Mac's image store (1.7) don't work on an older release.
    public static func sharedStoreClusters(_ names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        let list = names.sorted().joined(separator: ", ")
        return "Delete these clusters first, they use this Mac's image store, which needs the newer version: \(list)."
    }

    /// Claude Code updates itself in the background, which would undo a downgrade.
    public static let claudeAutoUpdate = "Claude Code updates itself again later unless auto updates are off: add \"DISABLE_AUTOUPDATER\": \"1\" under \"env\" in ~/.claude/settings.json."
}

/// The steps that switch one component to its tested version, a downgrade or an upgrade, with the
/// same install method it came from. Where that method cannot install one exact version, the plan
/// has no steps and lists the exact steps to do it by hand.
///
/// What works, checked on 9 Nov 2026:
/// - Apple container: Apple's README says stop, `uninstall-container.sh -k` (keeps data), install
///   the older signed package, start. The package installer alone would not replace newer files.
/// - npm `install -g <pkg>@<ver>`, uv `tool install <pkg>==<ver> --force`, pipx `install --force <pkg>==<ver>`.
/// - Claude Code's native install: `claude install <version>`.
/// - mlx-lm in the app's own folder: `uv tool install --force mlx-lm==<ver>`.
/// - The app's own cloudflared: Cloudflare's release for that tag, checksum and signature checked.
/// - Homebrew: only a versioned formula (helm@3, kubernetes-cli@1.35) installs an older line, and
///   `brew upgrade` only goes to Homebrew's newest. Everything else is by hand.
/// - LM Studio core, ngrok, Tailscale, apps: no supported way to pick a version. Steps by hand.
public enum ComponentSwitchPlanner {
    /// True when the app can usually run the switch (a Switch button). False shows the manual
    /// steps instead. Homebrew is checked again when pressed.
    public static func runsInApp(_ row: ComponentInfo) -> Bool {
        switch (row.kind, row.method) {
        case (.container, .applePackage?), (.mlx, .appRuntime?), (.cloudflared, .appDownload?): return true
        case (.agent, .npmGlobal?), (.agent, .uvTool?), (.agent, .pipx?), (.agent, .selfUpdater?): return true
        case (_, .homebrewFormula(let name)?): return isUpgrade(row, to: row.switchTarget) || versionedFormulaNames.contains(name)
        default: return false
        }
    }

    /// The target is newer than the installed version.
    public static func isUpgrade(_ row: ComponentInfo, to target: String?) -> Bool {
        guard let target = target.flatMap(ToolVersion.init), let installed = row.installed.flatMap(ToolVersion.init) else { return false }
        return target > installed
    }

    /// Homebrew formulae that have versioned formulae in homebrew-core.
    public static let versionedFormulaNames: Set<String> = ["helm", "kubernetes-cli", "node"]

    /// Versioned formula names to look for, most exact first: "kubernetes-cli@1.35", "kubernetes-cli@1".
    public static func versionedFormulaCandidates(_ name: String, target: ToolVersion) -> [String] {
        ["\(name)@\(target.major).\(target.minor)", "\(name)@\(target.major)"]
    }

    public static func plan(for row: ComponentInfo, to targetText: String?, context: ComponentPlanContext) throws -> ComponentUpdatePlan {
        guard let method = row.method else { throw ComponentPlanError.notUpdatable(row.name) }
        guard let target = targetText else {
            return manual(row, target: nil, reason: "No release of the tested \(row.testedText ?? "version") was found.",
                          steps: genericSteps(row, target: nil))
        }
        let title = "Switch \(row.name) to \(target)"
        let upgrade = isUpgrade(row, to: target)
        let afterChecks: [ComponentUpdatePlan.Step] = [.recheck, .healthCheck]

        switch (row.kind, method) {
        case (.container, .applePackage):
            guard let package = context.package, upgrade || context.uninstallScript != nil else {
                return manual(row, target: target, reason: "The installer for \(target) or Apple's uninstall script was not found.",
                              steps: containerSteps(target: target, cli: context.containerPath, uninstall: !upgrade))
            }
            let cli = context.containerPath ?? "/usr/local/bin/container"
            let file = "/tmp/" + package.name
            if upgrade {
                return ComponentUpdatePlan(
                    componentID: row.id, title: title, target: target,
                    steps: [.downloadPackage(package), .verifyPackage, .recordRunningContainers, .stopContainerService, .installPackage,
                            .startContainerService, .recheck, .healthCheck, .restartContainers],
                    confirmation: "The container service stops and running containers stop while Apple's installer adds \(target). macOS asks for your password. Images, volumes and settings are kept, and containers that were running start again afterwards.",
                    needsAdmin: true, manualOnly: !context.isAdmin,
                    terminalCommand: ["curl -fL -o \(quote(file)) \(quote(package.url.absoluteString))", "pkgutil --check-signature \(quote(file))",
                                      "\(quote(cli)) system stop", "sudo installer -pkg \(quote(file)) -target /", "\(quote(cli)) system start"].joined(separator: " && "))
            }
            let script = context.uninstallScript ?? "/usr/local/bin/uninstall-container.sh"
            let command = [
                "curl -fL -o \(quote(file)) \(quote(package.url.absoluteString))",
                "pkgutil --check-signature \(quote(file))",
                "\(quote(cli)) system stop",
                "sudo \(quote(script)) -k",
                "sudo installer -pkg \(quote(file)) -target /",
                "\(quote(cli)) system start"
            ].joined(separator: " && ")
            let warning = ComponentSwitchNotes.containerData(from: row.installed ?? "the newer version", to: target)
            return ComponentUpdatePlan(
                componentID: row.id, title: title, target: target,
                steps: [.downloadPackage(package), .verifyPackage, .recordRunningContainers, .stopContainerService]
                    + (context.containerBackupFolder.map { [.backupContainerData(folder: $0)] } ?? [])
                    + [.uninstallKeepingData(script: script), .installPackage, .startContainerService, .recheck, .healthCheck, .restartContainers],
                confirmation: "The container service stops and running containers stop. Apple's uninstall script removes \(row.installed ?? "the newer version") and keeps your images, volumes and settings, then Apple's installer adds \(target). macOS asks for your password once. Containers that were running start again afterwards. \(warning)",
                needsAdmin: true, manualOnly: !context.isAdmin, terminalCommand: command)

        case (.container, _):
            return manual(row, target: target, reason: "This copy of Apple container did not come from Apple's installer.",
                          steps: containerSteps(target: target, cli: nil, uninstall: true).enumerated().map { $0.offset == 1 ? "brew uninstall container" : $0.element })

        case (_, .homebrewFormula(let name)):
            if upgrade, context.brewNewestMatchesTested, let brew = context.brewPath {
                return ComponentUpdatePlan(
                    componentID: row.id, title: title, target: target,
                    steps: [.run(executable: brew, arguments: ["upgrade", name])] + afterChecks,
                    confirmation: "Homebrew updates \(name) to its newest release, which is the tested \(row.testedText ?? target).",
                    needsAdmin: false, manualOnly: false, terminalCommand: "brew upgrade \(name)")
            }
            if !upgrade, let versioned = context.versionedFormula, let brew = context.brewPath {
                let steps: [ComponentUpdatePlan.Step] = [
                    .run(executable: brew, arguments: ["install", versioned]),
                    .run(executable: brew, arguments: ["unlink", name]),
                    .run(executable: brew, arguments: ["link", "--force", versioned])
                ] + afterChecks
                return ComponentUpdatePlan(
                    componentID: row.id, title: title, target: target, steps: steps,
                    confirmation: "Homebrew installs \(versioned) and links it in place of \(name). To go back later: brew unlink \(versioned) && brew link \(name).",
                    needsAdmin: false, manualOnly: false,
                    terminalCommand: "brew install \(versioned) && brew unlink \(name) && brew link --force \(versioned)")
            }
            return manual(row, target: target, reason: upgrade ? "Homebrew's newest \(name) is not the tested version." : "Homebrew only has the newest \(name).",
                          steps: homebrewSteps(row, formula: name, target: target))

        case (_, .homebrewCask(let name)):
            return manual(row, target: target, reason: "Homebrew only has the newest \(name).", steps: caskSteps(row, cask: name, target: target))

        case (.mlx, .appRuntime):
            guard let uv = context.uvPath else { throw ComponentPlanError.missingTool("uv") }
            let arguments = context.mlxEnvironment + [uv, "tool", "install", "--python", AIConfig.mlxPythonVersion, "--force", "\(AIConfig.mlxPackage)==\(target)"]
            var steps: [ComponentUpdatePlan.Step] = []
            var confirmation = "mlx-lm \(target) is installed in \(AppConfig.appName)'s own folder. Downloaded models are kept."
            if context.mlxServerRunning {
                steps.append(.stopMLXServer)
                confirmation += " The MLX server stops first. Start it again when the downgrade is done."
            }
            steps += [.run(executable: "/usr/bin/env", arguments: arguments)] + afterChecks
            return ComponentUpdatePlan(componentID: row.id, title: title, target: target, steps: steps, confirmation: confirmation,
                                       needsAdmin: false, manualOnly: false, terminalCommand: displayCommand("/usr/bin/env", arguments))

        case (.cloudflared, .appDownload):
            return ComponentUpdatePlan(componentID: row.id, title: title, target: target,
                                       steps: [.downloadCloudflaredVersion(target)] + afterChecks,
                                       confirmation: "\(AppConfig.appName) downloads Cloudflare's \(target) release, checks its checksum and signature, and replaces its own copy. Running shares keep the old copy until they restart.",
                                       needsAdmin: false, manualOnly: false,
                                       terminalCommand: "curl -fLO https://github.com/\(DomainsConfig.cloudflaredRepository)/releases/download/\(target)/\(DomainsConfig.cloudflaredAsset)")

        case (.agent, .npmGlobal(let package, let prefix)):
            let npm = prefix + "/bin/npm"
            let spec = "\(package)@\(target)"
            let arguments = ["PATH=\(prefix)/bin:/usr/bin:/bin", npm, "install", "-g", spec]
            return ComponentUpdatePlan(componentID: row.id, title: title, target: target,
                                       steps: [.run(executable: "/usr/bin/env", arguments: arguments)] + afterChecks,
                                       confirmation: agentConfirmation(row, "npm installs \(spec)."),
                                       needsAdmin: false, manualOnly: false, terminalCommand: "npm install -g \(spec)")

        case (.agent, .uvTool(let package)):
            guard let uv = context.toolUVPath else { throw ComponentPlanError.missingTool("uv") }
            let spec = "\(package)==\(target)"
            return ComponentUpdatePlan(componentID: row.id, title: title, target: target,
                                       steps: [.run(executable: uv, arguments: ["tool", "install", spec, "--force"])] + afterChecks,
                                       confirmation: agentConfirmation(row, "uv installs \(spec). Later updates stay on this version until you run uv tool install \(package)@latest."),
                                       needsAdmin: false, manualOnly: false, terminalCommand: "uv tool install \(spec) --force")

        case (.agent, .pipx(let package)):
            guard let pipx = context.pipxPath else { throw ComponentPlanError.missingTool("pipx") }
            let spec = "\(package)==\(target)"
            return ComponentUpdatePlan(componentID: row.id, title: title, target: target,
                                       steps: [.run(executable: pipx, arguments: ["install", "--force", spec])] + afterChecks,
                                       confirmation: agentConfirmation(row, "pipx installs \(spec)."),
                                       needsAdmin: false, manualOnly: false, terminalCommand: "pipx install --force \(spec)")

        case (.agent, .selfUpdater(let binary)):
            return ComponentUpdatePlan(componentID: row.id, title: title, target: target,
                                       steps: [.run(executable: binary, arguments: ["install", target])] + afterChecks,
                                       confirmation: agentConfirmation(row, "\(row.name) installs \(target) with its own installer."),
                                       needsAdmin: false, manualOnly: false, terminalCommand: displayCommand(binary, ["install", target]))

        case (.lmStudio, .lmStudioScript):
            return manual(row, target: target,
                          reason: "LM Studio's installer and lms only install the newest LM Studio core, so \(AppConfig.appName) can't install \(target).",
                          steps: ["Check for a fixed release: lms daemon update",
                                  "Or update \(AppConfig.appName) when a version that supports \(row.installed ?? "this version") is out."])

        default:
            return manual(row, target: target, reason: "\(AppConfig.appName) can't install one exact version of \(row.name) for this install.",
                          steps: genericSteps(row, target: target))
        }
    }

    // MARK: Manual steps

    static func manual(_ row: ComponentInfo, target: String?, reason: String, steps: [String]) -> ComponentUpdatePlan {
        ComponentUpdatePlan(componentID: row.id, title: target.map { "Switch \(row.name) to \($0)" } ?? "Switch \(row.name) to the tested version",
                            target: target, steps: [], confirmation: "", needsAdmin: false, manualOnly: true,
                            terminalCommand: steps.joined(separator: "\n"), manualSteps: steps, manualReason: reason)
    }

    static func containerSteps(target: String, cli: String?, uninstall: Bool) -> [String] {
        let cli = cli ?? "container"
        let pkg = "container-\(target)-installer-signed.pkg"
        return [
            "\(cli) system stop",
            uninstall ? "sudo /usr/local/bin/uninstall-container.sh -k" : nil,
            "curl -fL -o /tmp/\(pkg) https://github.com/\(AppConfig.appleContainerRepository)/releases/download/\(target)/\(pkg)",
            "pkgutil --check-signature /tmp/\(pkg)",
            "sudo installer -pkg /tmp/\(pkg) -target /",
            "\(cli) system start"
        ].compactMap { $0 }
    }

    static func homebrewSteps(_ row: ComponentInfo, formula: String, target: String) -> [String] {
        switch row.kind {
        case .ollama:
            return ["brew services stop ollama",
                    "brew uninstall ollama",
                    "curl -fsSL https://ollama.com/install.sh | OLLAMA_VERSION=\(target) sh",
                    "In Ollama's Settings, turn off Auto-download updates so it stays on \(target)."]
        case .kubectl:
            return ["curl -fLO https://dl.k8s.io/release/v\(target)/bin/darwin/arm64/kubectl",
                    "chmod +x kubectl",
                    "brew uninstall \(formula)",
                    "sudo mv kubectl /usr/local/bin/kubectl"]
        case .helm:
            return ["curl -fLO https://get.helm.sh/helm-v\(target)-darwin-arm64.tar.gz",
                    "tar -xzf helm-v\(target)-darwin-arm64.tar.gz",
                    "brew uninstall \(formula)",
                    "sudo mv darwin-arm64/helm /usr/local/bin/helm"]
        case .cloudflared:
            return ["curl -fLO https://github.com/\(DomainsConfig.cloudflaredRepository)/releases/download/\(target)/\(DomainsConfig.cloudflaredAsset)",
                    "tar -xzf \(DomainsConfig.cloudflaredAsset)",
                    "brew uninstall \(formula)",
                    "sudo mv cloudflared /usr/local/bin/cloudflared"]
        case .uv:
            return ["brew uninstall \(formula)",
                    "curl -LsSf https://astral.sh/uv/\(target)/install.sh | sh"]
        case .agent where formula == "block-goose-cli":
            return ["brew uninstall \(formula)",
                    "curl -fsSL https://github.com/aaif-goose/goose/releases/download/stable/download_cli.sh | GOOSE_VERSION=v\(target) CONFIGURE=false bash"]
        case .agent where formula == "gemini-cli":
            return ["brew uninstall \(formula)", "npm install -g @google/gemini-cli@\(target)"]
        default:
            return ["brew uninstall \(formula)"] + genericSteps(row, target: target)
        }
    }

    static func caskSteps(_ row: ComponentInfo, cask: String, target: String) -> [String] {
        switch cask {
        case "ollama-app", "ollama":
            return ["curl -fsSL https://ollama.com/install.sh | OLLAMA_VERSION=\(target) sh",
                    "In Ollama's Settings, turn off Auto-download updates so it stays on \(target)."]
        case "tailscale-app", "tailscale":
            return ["brew uninstall --cask \(cask)",
                    "curl -fLO https://pkgs.tailscale.com/stable/Tailscale-\(target)-macos.pkg",
                    "sudo installer -pkg Tailscale-\(target)-macos.pkg -target /"]
        case "claude-code", "claude-code@latest":
            return ["brew uninstall --cask \(cask)",
                    "curl -fsSL https://claude.ai/install.sh | bash -s \(target)",
                    ComponentSwitchNotes.claudeAutoUpdate]
        default:
            return ["brew uninstall --cask \(cask)"] + genericSteps(row, target: target)
        }
    }

    static func genericSteps(_ row: ComponentInfo, target: String?) -> [String] {
        if case .appBundle(let app) = row.method, row.kind == .ollama || app.hasSuffix("Ollama.app"), let target {
            return ["curl -fsSL https://ollama.com/install.sh | OLLAMA_VERSION=\(target) sh",
                    "In Ollama's Settings, turn off Auto-download updates so it stays on \(target)."]
        }
        if case .appBundle(let app) = row.method, app.hasSuffix("Tailscale.app"), let target {
            return ["curl -fLO https://pkgs.tailscale.com/stable/Tailscale-\(target)-macos.pkg",
                    "sudo installer -pkg Tailscale-\(target)-macos.pkg -target /"]
        }
        let page = row.downloadURL?.absoluteString ?? "the project's download page"
        let version = target ?? "a \(row.testedText ?? "tested") release"
        return ["Download \(row.name) \(version) from \(page)",
                "Install it in place of version \(row.installed ?? "on this Mac")."]
    }

    static func agentConfirmation(_ row: ComponentInfo, _ text: String) -> String {
        var result = text + " Sessions that are open keep the current version until they restart."
        if row.id == AgentTool.claude.componentID { result += " " + ComponentSwitchNotes.claudeAutoUpdate }
        return result
    }

    static func quote(_ text: String) -> String { ComponentUpdatePlanner.quote(text) }
    static func displayCommand(_ executable: String, _ arguments: [String]) -> String {
        ComponentUpdatePlanner.displayCommand(executable, arguments)
    }
}

public extension ComponentChecker {
    /// What a switch needs from this Mac, and the version it really installs (a Homebrew
    /// versioned formula installs its own newest version, like helm@3 3.22.1).
    func switchContext(for row: ComponentInfo, target: String?, restartOllama: Bool = false) async -> (context: ComponentPlanContext, target: String?) {
        var context = await planContext(for: row, restartOllama: restartOllama)
        var effective = target
        switch (row.kind, row.method) {
        case (.container, _):
            context.package = nil
            if let target, let releases = await fetcher.releases(.githubReleases(AppConfig.appleContainerRepository)) {
                context.package = releases.packages[target] ?? releases.packages.first { ToolVersion($0.key) == ToolVersion(target) }?.value
            }
            let script = toolsDirectory.map { $0 + "/uninstall-container.sh" } ?? "/usr/local/bin/uninstall-container.sh"
            context.uninstallScript = system.fileExists(script) ? script : nil
            context.containerBackupFolder = Self.containerBackupFolder(toolsDirectory: toolsDirectory)
        case (_, .homebrewFormula(let name)?):
            guard let target, let version = ToolVersion(target) else { break }
            let tested = self.tested(row.id)
            if ComponentSwitchPlanner.isUpgrade(row, to: target) {
                if let newest = await fetcher.releases(.homebrewFormula(name))?.newest {
                    context.brewNewestMatchesTested = tested?.matches(newest) ?? false
                    if context.brewNewestMatchesTested { effective = newest.description }
                }
                break
            }
            guard ComponentSwitchPlanner.versionedFormulaNames.contains(name) else { break }
            for candidate in ComponentSwitchPlanner.versionedFormulaCandidates(name, target: version) {
                guard let stable = await fetcher.releases(.homebrewFormula(candidate))?.newest,
                      stable.major == version.major, tested?.matches(stable) ?? true,
                      let installed = row.installed.flatMap(ToolVersion.init), stable < installed else { continue }
                context.versionedFormula = candidate
                effective = stable.description
                break
            }
        case (.agent, .selfUpdater(let binary)?):
            context.toolPath = binary
        default:
            break
        }
        return (context, effective)
    }
}

public extension ComponentChecker {
    /// Application Support/<data id>/Backups/container-<date and time> (stand in tools: next to them).
    static func containerBackupFolder(toolsDirectory: String?, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "container-" + formatter.string(from: now)
        if let toolsDirectory { return toolsDirectory + "/backups/" + name }
        return DomainsConfig.supportDirectory().appendingPathComponent("Backups/" + name).path
    }
}

extension CloudflaredInstaller {
    /// One release by tag (a downgrade), checked like `installDirect`: GitHub's SHA-256, then the
    /// code signature. Replaces the app's own copy.
    func installVersion(_ version: String, session: URLSession = .shared) async throws -> String {
        let api = URL(string: "https://api.github.com/repos/\(DomainsConfig.cloudflaredRepository)/releases/tags/\(version)")!
        var request = URLRequest(url: api)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (json, _) = try await session.data(for: request)
        let release = try Self.release(fromJSON: json)
        let (archive, response) = try await session.data(from: release.downloadURL)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw DeckError.network("Download failed with status \(http.statusCode).")
        }
        try Self.verify(archive, expected: release.sha256)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("deck-cloudflared-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let file = work.appendingPathComponent(DomainsConfig.cloudflaredAsset)
        try archive.write(to: file)
        try await runner.run("/usr/bin/tar", ["-xzf", file.path, "-C", work.path]).orThrow()
        let binary = work.appendingPathComponent("cloudflared")
        guard FileManager.default.fileExists(atPath: binary.path) else {
            throw DeckError.commandFailed("The cloudflared download did not contain the program.")
        }
        try await runner.run("/usr/bin/codesign", ["--verify", "--strict", binary.path]).orThrow()
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let target = destination.appendingPathComponent("cloudflared")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: binary, to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        return target.path
    }
}
