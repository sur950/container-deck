import Foundation
import Darwin

public extension ComponentChecker {
    /// What the planner needs from this Mac, read with read only commands and files.
    func planContext(for info: ComponentInfo, restartOllama: Bool = false, mcpServerRunning: Bool = false) async -> ComponentPlanContext {
        var context = ComponentPlanContext(restartOllama: restartOllama, mcpServerRunning: mcpServerRunning)
        context.containerPath = toolsDirectory.map { $0 + "/container" } ?? containerPath
        context.brewPath = find("brew", in: AIConfig.homebrewPaths)
        context.isAdmin = await isAdmin()

        switch info.kind {
        case .container:
            if let target = info.target, let releases = await fetcher.releases(.githubReleases(AppConfig.appleContainerRepository)) {
                context.package = releases.packages[target] ?? releases.packages.first { ToolVersion($0.key) == ToolVersion(target) }?.value
            }
        case .lmStudio:
            context.lmsPath = find("lms", in: AIConfig.lmStudioCLIPaths)
            if let lms = context.lmsPath, let help = await output(lms, ["daemon", "--help"]) {
                context.lmsHasDaemonUpdate = ComponentParsers.lmsHasDaemonUpdate(help)
            }
            let runtime = LMStudioRuntime(runner: system.runner, toolsDirectory: toolsDirectory ?? LMStudioRuntime.debugToolsDirectory)
            let command = runtime.installCoreCommand()
            context.lmStudioInstallCommand = (command.executable, command.arguments)
        case .mlx:
            let runtime = MLXRuntime(paths: aiPaths, runner: system.runner, isExecutable: system.isExecutable)
            context.uvPath = system.isExecutable(aiPaths.ownUV.path) ? aiPaths.ownUV.path : find("uv", in: AIConfig.uvSearchPaths)
            context.mlxEnvironment = runtime.environmentArguments()
            if let record = MLXServerRecord.load(paths: aiPaths) {
                context.mlxServerRunning = kill(record.pid, 0) == 0
            }
        case .agent:
            context.toolUVPath = find("uv", in: AIConfig.uvSearchPaths)
            context.pipxPath = find("pipx", in: ["/opt/homebrew/bin/pipx", "/usr/local/bin/pipx", "~/.local/bin/pipx"])
        default:
            break
        }
        return context
    }

    /// The person is in the admin group, so they can approve the password prompt.
    /// Stand in tools: a file named `not-admin` in the folder says no.
    func isAdmin() async -> Bool {
        if let toolsDirectory { return !system.fileExists(toolsDirectory + "/not-admin") }
        guard let text = await output("/usr/bin/id", ["-Gn"]) else { return true }
        return ComponentParsers.isAdmin(groups: text)
    }
}

/// Debug builds: fake MCP servers and local images next to the stand in tools, so the
/// Components list shows every state without touching the real setup.
public enum ComponentStandIn {
    /// `<dir>/mcp-servers.json`, the same format as the app's own list.
    public static func mcpServers(_ directory: String) -> [MCPInstalledServer] {
        MCPServerRegistry(file: URL(fileURLWithPath: directory + "/mcp-servers.json")).load()
    }

    /// `<dir>/images.json`: `[{"reference": "...", "digest": "sha256:..."}]`.
    public static func images(_ directory: String) -> [ImageSummary] {
        struct Item: Decodable { let reference: String; let digest: String }
        guard let data = FileManager.default.contents(atPath: directory + "/images.json"),
              let items = try? JSONDecoder().decode([Item].self, from: data) else { return [] }
        return items.map { ImageSummary(reference: $0.reference, digest: $0.digest) }
    }

    /// `<dir>/latest.json`, stand in answers for every newest version source.
    public static func latestFile(_ directory: String) -> URL {
        URL(fileURLWithPath: directory + "/latest.json")
    }
}
