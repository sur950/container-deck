import Foundation

/// Where each agent tool's newest version is published, when it is not obvious from the install.
public extension AgentTool {
    /// npm package of the tool's official install.
    var npmPackage: String? {
        switch self {
        case .claude: return "@anthropic-ai/claude-code"
        case .codex: return "@openai/codex"
        case .gemini: return "@google/gemini-cli"
        case .amp: return "@sourcegraph/amp"
        case .qwen: return "@qwen-code/qwen-code"
        case .opencode: return "opencode-ai"
        default: return nil
        }
    }

    /// PyPI package (Aider).
    var pypiPackage: String? { self == .aider ? "aider-chat" : nil }

    /// Release notes or project page.
    var releasesPage: String? {
        switch self {
        case .claude: return "https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md"
        case .codex: return "https://github.com/openai/codex/releases"
        case .gemini: return "https://github.com/google-gemini/gemini-cli/releases"
        case .aider: return "https://aider.chat/HISTORY.html"
        case .goose: return "https://github.com/block/goose/releases"
        case .opencode: return "https://github.com/sst/opencode/releases"
        case .crush: return "https://github.com/charmbracelet/crush/releases"
        case .amp: return "https://ampcode.com/news"
        case .qwen: return "https://github.com/QwenLM/qwen-code/releases"
        case .cursorAgent: return "https://cursor.com/cli"
        default: return nil
        }
    }

    /// Key in `AppConfig.componentTested`.
    var componentID: String { "agent:\(rawValue)" }
}

extension ComponentChecker {
    /// Every agent command line tool the Agents screen finds (apps update themselves and are left out).
    static func detectAgents(toolsDirectory: String?) -> @Sendable () async -> [DetectedAgentTool] {
        {
            let detector: AgentToolDetector
            if let toolsDirectory {
                let resolver = AgentPathResolver(home: toolsDirectory + "/home", environment: [:], applicationFolders: [],
                                                 systemFolders: [], toolsFolder: toolsDirectory + "/agents")
                detector = AgentToolDetector(resolver: resolver, runner: ProcessRunner())
            } else {
                detector = AgentToolDetector()
            }
            return await detector.detect(withVersions: true)
        }
    }

    func agentRows(force: Bool) async -> [ComponentInfo] {
        // Only tools whose program is here. Leftover settings folders (an uninstalled opencode
        // keeps ~/.config/opencode) count as found on the Agents screen, not as something to update.
        let found = await agents().filter { !$0.tool.isApp && $0.installed && !($0.path ?? "").isEmpty }
        var rows: [ComponentInfo] = []
        for agent in found {
            rows.append(await agentRow(agent, force: force))
        }
        return rows
    }

    func agentRow(_ agent: DetectedAgentTool, force: Bool) async -> ComponentInfo {
        let tool = agent.tool
        let path = agent.path ?? ""
        let resolved = system.resolve(path)
        let method = ComponentParsers.agentInstallMethod(resolvedPath: resolved, home: system.home) ?? .other(path)
        let source: LatestSource?
        switch method {
        case .homebrewFormula(let name): source = .homebrewFormula(name)
        case .homebrewCask(let name): source = .homebrewCask(name)
        case .npmGlobal(let package, _): source = .npm(package)
        case .uvTool(let package), .pipx(let package): source = .pypi(package)
        default:
            if let npm = tool.npmPackage { source = .npm(npm) }
            else if let pypi = tool.pypiPackage { source = .pypi(pypi) }
            else if tool == .goose { source = .homebrewFormula("block-goose-cli") }
            else if tool == .crush { source = .githubLatest("charmbracelet/crush") }
            else { source = nil }
        }
        let manual: Bool
        switch method {
        case .homebrewFormula, .homebrewCask, .npmGlobal, .uvTool, .pipx, .selfUpdater: manual = false
        default: manual = true
        }
        return await finish(.agent, id: tool.componentID, name: tool.title, location: path, method: method,
                            installed: agent.version.flatMap(ToolVersion.init), found: true, source: source,
                            notes: { _ in tool.releasesPage ?? "" }, download: tool.releasesPage, updatesItself: manual, force: force)
    }
}
