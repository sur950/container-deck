import Foundation

/// Constants for Sandboxes. A sandbox is a labelled container plus its own network,
/// so everything needed to bring it back after an app restart lives in these labels.
public enum SandboxConfig {
    // MARK: Labels (on the container, and the main one on its network too)

    /// Marks a container (and its network) as a sandbox. Value is the format version.
    public static let label = "deck.sandbox"
    public static let labelVersion = "1"
    public static let labelTemplate = "deck.sandbox.template"
    /// "isolated", "open" or "allowlist" (`SandboxEgress`).
    public static let labelEgress = "deck.sandbox.egress"
    /// Allowed hosts, comma separated.
    public static let labelAllow = "deck.sandbox.allow"
    public static let labelNetwork = "deck.sandbox.network"
    public static let labelGateway = "deck.sandbox.gateway"
    public static let labelSubnet = "deck.sandbox.subnet"
    public static let labelWorkspace = "deck.sandbox.workspace"
    /// "ro" or "rw".
    public static let labelWorkspaceMode = "deck.sandbox.workspace-mode"
    public static let labelModelKind = "deck.sandbox.model.kind"
    /// Model base URL as seen from the Mac (never a key).
    public static let labelModelURL = "deck.sandbox.model.url"
    public static let labelModelName = "deck.sandbox.model.name"
    /// "1" when an API key for this sandbox is kept in the Keychain.
    public static let labelHasKey = "deck.sandbox.key"
    public static let labelProxyPort = "deck.sandbox.proxy-port"
    public static let labelRelayPort = "deck.sandbox.relay-port"
    /// Agent tool a sandbox was made for (`AgentTool` raw value). Set by agent profiles.
    public static let labelAgent = "deck.sandbox.agent"
    /// Agent profile id that made the sandbox.
    public static let labelProfile = "deck.sandbox.profile"
    /// Chat history volume mounted at `chatPath` (sandboxes made before chat volumes have none).
    public static let labelChatVolume = "deck.sandbox.chat-volume"
    /// Where the chat volume is mounted inside the sandbox, read write, so agents can read the history.
    public static let chatPath = "/deck/chat"
    /// "off" when the sandbox was made with "Save chat history" turned off.
    public static let labelChatHistory = "deck.sandbox.chat-history"

    // MARK: Network

    /// Each sandbox gets its own network named `<sandbox>-net`.
    public static let networkSuffix = "-net"
    /// Allow list proxy port on the sandbox gateway. Every sandbox has its own gateway
    /// address, so all of them can share one port number.
    public static let proxyPort: UInt16 = 39128
    /// Model relay port on the sandbox gateway (forwards to a model server on this Mac).
    public static let relayPort: UInt16 = 39434
    /// Longest request head the proxy reads before it gives up.
    public static let maxRequestHead = 32 * 1024
    /// Egress events kept per sandbox for the Egress tab.
    public static let maxEvents = 300

    // MARK: Inside the container

    public static let workspacePath = "/workspace"
    /// In memory folder (tmpfs) that holds secrets. Never on the container disk.
    public static let secretsPath = "/run/deck"
    public static let apiKeyFile = "/run/deck/openai_api_key"
    /// Sourced by shells (`ENV` for sh, `BASH_ENV` for bash). Exports the key from the file.
    public static let envScript = "/run/deck/env.sh"
    /// Keeps the container alive and stops fast on SIGTERM. Works with any `sh`.
    public static let keepAliveEntrypoint = "/bin/sh"
    public static let keepAliveArguments = ["-c", "trap 'exit 0' TERM INT; while :; do sleep 3600 & wait $!; done"]

    // MARK: Keychain

    /// Keychain service for sandbox API keys. Account is the sandbox name.
    public static let keychainService = AppConfig.bundleID + ".sandbox"

    // MARK: Defaults

    public static let defaultCPUs = 2
    public static let defaultMemoryMB = 2048
    /// Placeholder key for local servers that need any key at all. Not a secret.
    public static let localKeyPlaceholder = "local"

    // MARK: Templates (data, shown in the create form)

    public static let templates: [SandboxTemplate] = [
        SandboxTemplate(
            id: "alpine", title: "Alpine", image: "alpine:latest",
            summary: "Small Linux with BusyBox tools. Starts in a second."
        ),
        SandboxTemplate(
            id: "python", title: "Python", image: "python:3.12-slim",
            summary: "Python 3.12 with pip. Good for agent scripts and SDKs."
        ),
        SandboxTemplate(
            id: "uv", title: "Python with uv", image: "ghcr.io/astral-sh/uv:python3.12-bookworm-slim",
            summary: "Python 3.12 with the uv package manager."
        ),
        SandboxTemplate(
            id: "node", title: "Node.js", image: "node:22-slim",
            summary: "Node.js 22 with npm. For JavaScript agents and MCP servers."
        ),
        SandboxTemplate(
            id: "aider", title: "Aider", image: "paulgauthier/aider",
            summary: "Open source coding agent. Run aider in the terminal.", shell: "/bin/bash"
        ),
    ]

    public static let customTemplateID = "custom"

    /// Templates for agent profiles (Agents and MCP). Not shown in the New Sandbox form:
    /// the agent CLI is installed on first start into a cache volume (see `AgentSandboxRecipe`).
    public static let agentTemplates: [SandboxTemplate] = [
        SandboxTemplate(
            id: "agent-node", title: "Coding agent (Node.js)", image: "node:22-slim",
            summary: "Node.js 22. Installs the agent CLI with npm on first start.", shell: "/bin/bash"
        ),
        SandboxTemplate(
            id: "agent-python", title: "Coding agent (Python)", image: "python:3.12-slim",
            summary: "Python 3.12. Installs the agent with pip on first start.", shell: "/bin/bash"
        ),
    ]

    public static func template(id: String?) -> SandboxTemplate? {
        templates.first { $0.id == id } ?? agentTemplates.first { $0.id == id }
    }
}

/// A starting image for a sandbox.
public struct SandboxTemplate: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var image: String
    public var summary: String
    /// Preferred shell for the terminal. Falls back to /bin/sh when missing.
    public var shell: String

    public init(id: String, title: String, image: String, summary: String, shell: String = "/bin/sh") {
        self.id = id
        self.title = title
        self.image = image
        self.summary = summary
        self.shell = shell
    }
}
