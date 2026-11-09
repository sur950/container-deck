import Foundation

/// A system tool Container Deck uses or installs (Settings, Components).
public enum ComponentKind: String, Sendable, Codable, CaseIterable {
    case container
    case ollama
    case mlx
    case lmStudio = "lmstudio"
    case mcp
    case uv
    case cloudflared
    case ngrok
    case tailscale
    case kubectl
    case helm
    /// An AI agent command line tool (Claude Code, Codex, Gemini CLI, Aider and others). One row each.
    case agent

    public var title: String {
        switch self {
        case .container: return "Apple container"
        case .ollama: return "Ollama"
        case .mlx: return "MLX (mlx-lm)"
        case .lmStudio: return "LM Studio"
        case .mcp: return "MCP server"
        case .uv: return "uv"
        case .cloudflared: return "Cloudflare Tunnel"
        case .ngrok: return "ngrok"
        case .tailscale: return "Tailscale"
        case .kubectl: return "kubectl"
        case .helm: return "Helm"
        case .agent: return "AI agent"
        }
    }

    /// What the app uses it for, one short line.
    public var role: String {
        switch self {
        case .container: return "Runs your containers"
        case .ollama: return "Local models"
        case .mlx: return "Local models on Apple silicon"
        case .lmStudio: return "Local models"
        case .mcp: return "Tools for AI agents"
        case .uv: return "Installs the MLX runtime"
        case .cloudflared: return "Share to the internet"
        case .ngrok: return "Share to the internet"
        case .tailscale: return "Share with Tailscale Funnel"
        case .kubectl: return "Kubernetes port forwards"
        case .helm: return "Kubernetes charts"
        case .agent: return "Coding agent"
        }
    }

    /// Group in the list.
    public var group: ComponentGroup {
        switch self {
        case .container: return .platform
        case .ollama, .mlx, .lmStudio, .uv: return .models
        case .mcp: return .mcp
        case .agent: return .agents
        case .cloudflared, .ngrok, .tailscale, .kubectl, .helm: return .tools
        }
    }
}

public enum ComponentGroup: String, Sendable, CaseIterable {
    case platform, models, agents, mcp, tools

    public var title: String {
        switch self {
        case .platform: return "Platform"
        case .models: return "Local models"
        case .agents: return "AI agents"
        case .mcp: return "MCP servers"
        case .tools: return "Sharing and Kubernetes"
        }
    }
}

/// How a tool got onto this Mac. The update uses the same way.
public enum InstallMethod: Sendable, Equatable {
    /// Apple's signed installer package from GitHub (Apple container).
    case applePackage
    /// `brew install <name>`.
    case homebrewFormula(String)
    /// `brew install --cask <name>`.
    case homebrewCask(String)
    /// An app that updates itself, like Ollama.app or LM Studio.app.
    case appBundle(String)
    /// LM Studio core (llmster) from LM Studio's install script.
    case lmStudioScript
    /// mlx-lm in the app's own uv tool folder.
    case appRuntime
    /// A copy the app downloaded and checked itself (cloudflared, uv).
    case appDownload
    /// An MCP server image.
    case containerImage(String)
    /// `npm install -g <package>` under a Node prefix (like /opt/homebrew).
    case npmGlobal(package: String, prefix: String)
    /// `uv tool install <package>`.
    case uvTool(String)
    /// `pipx install <package>`.
    case pipx(String)
    /// A tool with its own update command (Claude Code's native install: `claude update`).
    case selfUpdater(String)
    /// Found, but not from a source the app can update.
    case other(String)

    public var title: String {
        switch self {
        case .applePackage: return "Apple installer"
        case .homebrewFormula, .homebrewCask: return "Homebrew"
        case .appBundle: return "App"
        case .lmStudioScript: return "LM Studio installer"
        case .appRuntime: return "Container Deck"
        case .appDownload: return "Container Deck download"
        case .containerImage: return "Image"
        case .npmGlobal: return "npm"
        case .uvTool: return "uv"
        case .pipx: return "pipx"
        case .selfUpdater: return "Own updater"
        case .other: return "Other"
        }
    }

    /// True when the app can install one exact version (not only the newest).
    public var canPickVersion: Bool {
        switch self {
        case .applePackage, .appRuntime, .npmGlobal: return true
        default: return false
        }
    }
}

/// The pill on each row.
public enum ComponentStatus: Sendable, Equatable {
    case upToDate
    case updateAvailable
    case notInstalled
    /// The newest version could not be read (offline, rate limited).
    case unknown
    /// A feature the app uses failed with the installed version (a health check, or a real
    /// failure a screen reported).
    case notWorking

    public var title: String {
        switch self {
        case .upToDate: return "Up to date"
        case .updateAvailable: return "Update available"
        case .notInstalled: return "Not installed"
        case .unknown: return "Not checked"
        case .notWorking: return "Not working with this version"
        }
    }
}

/// One row in Settings, Components.
public struct ComponentInfo: Sendable, Equatable, Identifiable {
    /// "container", "ollama", or "mcp:<server>" for MCP servers.
    public var id: String
    public var kind: ComponentKind
    public var name: String
    /// Install path or image, shown small.
    public var location: String?
    public var method: InstallMethod?
    /// Installed version text, like "1.6.1" or "sha256:1a7a0996".
    public var installed: String?
    /// Newest release anywhere, like "1.7.1".
    public var latest: String?
    /// The version an update installs. nil when there is no safe update.
    public var target: String?
    public var status: ComponentStatus
    /// Release notes for `target` (or `latest`).
    public var notesURL: URL?
    /// Where to get it by hand.
    public var downloadURL: URL?
    /// The tested version, like "1.7.x".
    public var testedText: String?
    /// One extra line, like what did not work with this version.
    public var note: String?
    /// The update is done by the tool itself (Open App) instead of by Container Deck.
    public var updatesItself: Bool
    /// A few lines of release notes for `target` (Apple container).
    public var notesSummary: [String] = []
    /// The installed version is in the tested line (or there is no tested version).
    public var matchesTested = true
    /// Last health checks of the installed version, with failures screens reported.
    public var health: ComponentHealthReport?
    /// The tested release "Switch to the tested version" installs (an upgrade or a downgrade).
    public var switchTarget: String?

    public init(id: String, kind: ComponentKind, name: String, location: String? = nil, method: InstallMethod? = nil,
                installed: String? = nil, latest: String? = nil, target: String? = nil, status: ComponentStatus,
                notesURL: URL? = nil, downloadURL: URL? = nil, testedText: String? = nil, note: String? = nil,
                updatesItself: Bool = false) {
        self.id = id
        self.kind = kind
        self.name = name
        self.location = location
        self.method = method
        self.installed = installed
        self.latest = latest
        self.target = target
        self.status = status
        self.notesURL = notesURL
        self.downloadURL = downloadURL
        self.testedText = testedText
        self.note = note
        self.updatesItself = updatesItself
    }

    /// True when Container Deck can run the update from the row.
    public var canUpdateInApp: Bool { status == .updateAvailable && !updatesItself && method != nil }

    /// Failed checks, in plain words ("Kubernetes clusters can't be listed").
    public var failedChecks: [HealthCheck] { health?.failed ?? [] }

    /// Something failed on a version other than the tested one: offer to switch to the tested one.
    public var offersSwitch: Bool { status == .notWorking && switchTarget != nil }
}
