import Foundation

/// A setting a catalog server asks for.
public struct MCPCatalogField: Sendable, Hashable, Codable, Identifiable {
    public var key: String
    public var label: String
    /// Secrets go to the Keychain and never into agent config files.
    public var secret: Bool
    public var required: Bool
    public var placeholder: String
    public var id: String { key }

    public init(key: String, label: String, secret: Bool = false, required: Bool = false, placeholder: String = "") {
        self.key = key
        self.label = label
        self.secret = secret
        self.required = required
        self.placeholder = placeholder
    }
}

/// A folder from the Mac the server needs, mounted at `containerPath`.
public struct MCPCatalogMount: Sendable, Hashable, Codable {
    public var label: String
    public var containerPath: String
    public var readOnly: Bool

    public init(label: String, containerPath: String, readOnly: Bool = false) {
        self.label = label
        self.containerPath = containerPath
        self.readOnly = readOnly
    }
}

/// One server in the curated catalog.
public struct MCPCatalogItem: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var title: String
    public var summary: String
    public var image: String
    public var transport: MCPTransport
    /// Arguments after the image (command inside the container).
    public var command: [String]
    /// Port inside the container and URL path, for HTTP and SSE servers.
    public var containerPort: Int?
    public var path: String?
    public var fields: [MCPCatalogField]
    public var mount: MCPCatalogMount?
    public var homepage: String
    public var publisher: String

    public init(id: String, title: String, summary: String, image: String, transport: MCPTransport, command: [String] = [],
                containerPort: Int? = nil, path: String? = nil, fields: [MCPCatalogField] = [], mount: MCPCatalogMount? = nil,
                homepage: String, publisher: String) {
        self.id = id
        self.title = title
        self.summary = summary
        self.image = image
        self.transport = transport
        self.command = command
        self.containerPort = containerPort
        self.path = path
        self.fields = fields
        self.mount = mount
        self.homepage = homepage
        self.publisher = publisher
    }
}

/// Curated servers. Every image is multi arch (arm64 checked on Docker Hub, Nov 2026).
/// The `mcp/` images are the Docker MCP catalog builds of the reference servers.
public enum MCPCatalog {
    public static let items: [MCPCatalogItem] = [
        MCPCatalogItem(
            id: "time", title: "Time", summary: "Current time and time zone conversion.",
            image: "mcp/time", transport: .stdio,
            homepage: "https://github.com/modelcontextprotocol/servers/tree/main/src/time", publisher: "MCP reference"
        ),
        MCPCatalogItem(
            id: "fetch", title: "Fetch", summary: "Fetch web pages and turn them into Markdown.",
            image: "mcp/fetch", transport: .stdio,
            homepage: "https://github.com/modelcontextprotocol/servers/tree/main/src/fetch", publisher: "MCP reference"
        ),
        MCPCatalogItem(
            id: "filesystem", title: "Filesystem", summary: "Read and write files in one folder you choose.",
            image: "mcp/filesystem", transport: .stdio, command: ["/projects"],
            mount: MCPCatalogMount(label: "Folder", containerPath: "/projects"),
            homepage: "https://github.com/modelcontextprotocol/servers/tree/main/src/filesystem", publisher: "MCP reference"
        ),
        MCPCatalogItem(
            id: "git", title: "Git", summary: "Read, search and change a Git repository.",
            image: "mcp/git", transport: .stdio,
            mount: MCPCatalogMount(label: "Repository", containerPath: "/workspace"),
            homepage: "https://github.com/modelcontextprotocol/servers/tree/main/src/git", publisher: "MCP reference"
        ),
        MCPCatalogItem(
            id: "memory", title: "Memory", summary: "A knowledge graph the agent keeps between chats.",
            image: "mcp/memory", transport: .stdio,
            homepage: "https://github.com/modelcontextprotocol/servers/tree/main/src/memory", publisher: "MCP reference"
        ),
        MCPCatalogItem(
            id: "sequentialthinking", title: "Sequential Thinking", summary: "Step by step problem solving tool.",
            image: "mcp/sequentialthinking", transport: .stdio,
            homepage: "https://github.com/modelcontextprotocol/servers/tree/main/src/sequentialthinking", publisher: "MCP reference"
        ),
        MCPCatalogItem(
            id: "github", title: "GitHub", summary: "Issues, pull requests and code on GitHub.",
            image: "ghcr.io/github/github-mcp-server", transport: .stdio, command: ["stdio"],
            fields: [MCPCatalogField(key: "GITHUB_PERSONAL_ACCESS_TOKEN", label: "Access token", secret: true, required: true,
                                     placeholder: "github_pat_…")],
            homepage: "https://github.com/github/github-mcp-server", publisher: "GitHub"
        ),
        MCPCatalogItem(
            id: "playwright", title: "Playwright", summary: "Drive a headless browser: open pages, click, fill forms.",
            image: "mcp/playwright", transport: .stdio,
            homepage: "https://github.com/microsoft/playwright-mcp", publisher: "Microsoft"
        ),
        MCPCatalogItem(
            id: "context7", title: "Context7", summary: "Up to date docs and code examples for libraries. Runs over HTTP.",
            image: "mcp/context7", transport: .http, command: ["node", "dist/index.js", "--transport", "http"],
            containerPort: 8080, path: "/mcp",
            homepage: "https://github.com/upstash/context7", publisher: "Upstash"
        ),
        MCPCatalogItem(
            id: "everything", title: "Everything (test server)", summary: "Test server with every MCP feature. Good for trying a setup.",
            image: "mcp/everything", transport: .stdio,
            homepage: "https://github.com/modelcontextprotocol/servers/tree/main/src/everything", publisher: "MCP reference"
        ),
    ]

    public static func item(_ id: String) -> MCPCatalogItem? {
        items.first { $0.id == id }
    }
}
