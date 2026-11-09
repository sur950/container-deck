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

/// A folder or file from the Mac the server needs, mounted at `containerPath`.
public struct MCPCatalogMount: Sendable, Hashable, Codable {
    public var label: String
    public var containerPath: String
    public var readOnly: Bool
    /// A single file (a kubeconfig), not a folder.
    public var isFile: Bool
    /// The server works without it (MarkItDown also reads URLs).
    public var optional: Bool
    /// Filled in when it exists on this Mac, like `~/.kube/config`.
    public var suggestedPath: String?

    public init(label: String, containerPath: String, readOnly: Bool = false, isFile: Bool = false, optional: Bool = false,
                suggestedPath: String? = nil) {
        self.label = label
        self.containerPath = containerPath
        self.readOnly = readOnly
        self.isFile = isFile
        self.optional = optional
        self.suggestedPath = suggestedPath
    }

    /// `suggestedPath` with `~` expanded, when that file or folder exists.
    public func existingSuggestion(home: String = NSHomeDirectory(), fileManager: FileManager = .default) -> String? {
        guard let suggestedPath, !suggestedPath.isEmpty else { return nil }
        let path = suggestedPath.hasPrefix("~/") ? home + suggestedPath.dropFirst(1) : suggestedPath
        var isFolder: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue != isFile else { return nil }
        return path
    }
}

/// A named container volume that keeps the server's data between runs.
public struct MCPCatalogVolume: Sendable, Hashable, Codable {
    public var suffix: String
    public var containerPath: String

    public init(suffix: String, containerPath: String) {
        self.suffix = suffix
        self.containerPath = containerPath
    }

    /// "deck-mcp-memory-data" for a server named "memory".
    public func name(server: String) -> String {
        AgentsConfig.containerPrefix + server + "-" + suffix
    }
}

/// Featured groups, in the order they show.
public enum MCPCatalogGroup: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case noAccount, account
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .noAccount: return "No account needed"
        case .account: return "Connect an account"
        }
    }
}

/// One server in the catalog.
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
    /// Remote servers (from the MCP Registry): reached by URL, no container.
    public var remoteURL: String?
    /// Fixed settings the server always gets, like `BRAVE_MCP_TRANSPORT=stdio`.
    public var env: [EnvVar]
    /// Data kept between runs (stdio containers are removed after each run).
    public var volume: MCPCatalogVolume?
    /// Featured group. Only used for items in `MCPCatalog.items`.
    public var group: MCPCatalogGroup
    /// Docker Hub repository whose pull count ranks this server, like "mcp/playwright".
    public var pullRepository: String?
    /// Pulls when the list was made. Used until Docker Hub answers, and when it does not.
    public var pullSnapshot: Int
    /// Where and when linux/arm64 was checked for the image.
    public var arm64Note: String
    /// Docker's catalog entry the settings come from.
    public var configSource: String

    public init(id: String, title: String, summary: String, image: String, transport: MCPTransport, command: [String] = [],
                containerPort: Int? = nil, path: String? = nil, fields: [MCPCatalogField] = [], mount: MCPCatalogMount? = nil,
                homepage: String, publisher: String, remoteURL: String? = nil, env: [EnvVar] = [], volume: MCPCatalogVolume? = nil,
                group: MCPCatalogGroup = .noAccount, pullRepository: String? = nil, pullSnapshot: Int = 0,
                arm64Note: String = "", configSource: String = "") {
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
        self.remoteURL = remoteURL
        self.env = env
        self.volume = volume
        self.group = group
        self.pullRepository = pullRepository
        self.pullSnapshot = pullSnapshot
        self.arm64Note = arm64Note
        self.configSource = configSource
    }

    /// Server name suggested in the install form: the last part of the id ("registry:io.github.x/files" gives "files").
    public var defaultServerName: String {
        let tail = id.split(separator: ":").last.map(String.init) ?? id
        let parts = tail.split(separator: "/").map(String.init)
        var last = parts.last ?? tail
        // "com.githubcard/mcp" says little in its last part. Use the publisher's own name then.
        if ["mcp", "server", "mcp-server", "mcpserver"].contains(last.lowercased()), parts.count > 1 {
            last = parts[0].split(separator: ".").last.map(String.init) ?? last
        }
        let name = MCPLaunch.suggestedName(last)
        return name.isEmpty ? "server" : name
    }

    /// Pulls to show: the live Docker Hub count when there is one, else the snapshot.
    public func pulls(_ live: [String: Int]) -> Int {
        guard let pullRepository, let count = live[pullRepository], count > 0 else { return pullSnapshot }
        return count
    }
}

/// Featured servers.
///
/// How they are picked, so the list follows real use and not taste:
/// 1. Ranked by Docker Hub pulls in Docker's official MCP catalog (the `mcp/` namespace, the
///    images Docker's MCP Toolkit installs). Counts recorded 9 Nov 2026 in `pullSnapshot`, then
///    kept current from Docker Hub by `MCPPullCountClient`.
/// 2. Kept only when it is useful to most developers and agents (not one vendor's niche product),
///    runs locally as a linux/arm64 container, and needs no account or one widely used account or token.
/// 3. Left out on purpose:
///    - near duplicates and servers archived upstream: puppeteer (Playwright covers it), slack (the
///      reference server is archived), firecrawl (a paid scraper next to Fetch, Playwright and DuckDuckGo),
///    - servers that make little sense in a Linux container here: docker (this app is for Apple
///      container), desktop-commander (wants host shell access), obsidian (talks to the Obsidian app
///      on the Mac, which a container cannot reach by default), node-code-sandbox (needs a Docker socket),
///    - one product each: sonarqube, clickhouse, dynatrace, neo4j, mongodb, redis, n8n, dockerhub,
///    - the Everything test server (kept in `retired` so old installs still match, and in Browse).
///
/// Settings, mounts, commands and transports come from Docker's catalog source
/// (github.com/docker/mcp-registry, `servers/<name>/server.yaml`). Where that file relies on
/// Docker's gateway, the item says how it differs.
public enum MCPCatalog {
    /// When `pullSnapshot` and `arm64Note` were recorded.
    public static let snapshotDate = "9 Nov 2026"

    static let reference = "https://github.com/modelcontextprotocol/servers/tree/main/src/"
    static let source = "https://github.com/docker/mcp-registry/blob/main/servers/"
    static let hubArm64 = "linux/arm64 on Docker Hub, checked 9 Nov 2026"

    /// The featured list, grouped and in no special order. Use `featured(_:live:)` to show it.
    public static let items: [MCPCatalogItem] = noAccount + account

    static let noAccount: [MCPCatalogItem] = [
        MCPCatalogItem(
            id: "playwright", title: "Playwright", summary: "Drive a headless browser: open pages, click, fill forms.",
            image: "mcp/playwright", transport: .stdio,
            homepage: "https://github.com/microsoft/playwright-mcp", publisher: "Microsoft",
            pullRepository: "mcp/playwright", pullSnapshot: 2_715_289, arm64Note: hubArm64, configSource: source + "playwright/server.yaml"
        ),
        MCPCatalogItem(
            id: "fetch", title: "Fetch", summary: "Fetch web pages and turn them into Markdown.",
            image: "mcp/fetch", transport: .stdio,
            homepage: reference + "fetch", publisher: "MCP reference",
            pullRepository: "mcp/fetch", pullSnapshot: 1_978_687, arm64Note: hubArm64, configSource: source + "fetch/server.yaml"
        ),
        MCPCatalogItem(
            id: "time", title: "Time", summary: "Current time and time zone conversion.",
            image: "mcp/time", transport: .stdio,
            homepage: reference + "time", publisher: "MCP reference",
            pullRepository: "mcp/time", pullSnapshot: 1_071_917, arm64Note: hubArm64, configSource: source + "time/server.yaml"
        ),
        MCPCatalogItem(
            id: "duckduckgo", title: "DuckDuckGo", summary: "Search the web and read result pages. No API key.",
            image: "mcp/duckduckgo", transport: .stdio,
            homepage: "https://github.com/nickclyde/duckduckgo-mcp-server", publisher: "Community",
            pullRepository: "mcp/duckduckgo", pullSnapshot: 1_036_843, arm64Note: hubArm64, configSource: source + "duckduckgo/server.yaml"
        ),
        // Docker's catalog now points Context7 at its hosted URL. The image still runs it locally over HTTP.
        MCPCatalogItem(
            id: "context7", title: "Context7", summary: "Up to date docs and code examples for libraries. Runs over HTTP.",
            image: "mcp/context7", transport: .http, command: ["node", "dist/index.js", "--transport", "http"],
            containerPort: 8080, path: "/mcp",
            homepage: "https://github.com/upstash/context7", publisher: "Upstash",
            pullRepository: "mcp/context7", pullSnapshot: 663_132, arm64Note: hubArm64, configSource: source + "context7/server.yaml"
        ),
        // Docker keeps memory in a volume on /app/dist. A new volume here starts empty and would hide
        // the server's code, so the file goes to its own volume through MEMORY_FILE_PATH.
        MCPCatalogItem(
            id: "memory", title: "Memory", summary: "A knowledge graph the agent keeps between chats.",
            image: "mcp/memory", transport: .stdio,
            homepage: reference + "memory", publisher: "MCP reference",
            env: [EnvVar(key: "MEMORY_FILE_PATH", value: "/data/memory.json")],
            volume: MCPCatalogVolume(suffix: "data", containerPath: "/data"),
            pullRepository: "mcp/memory", pullSnapshot: 573_381, arm64Note: hubArm64, configSource: source + "memory/server.yaml"
        ),
        MCPCatalogItem(
            id: "sequentialthinking", title: "Sequential Thinking", summary: "Step by step problem solving tool.",
            image: "mcp/sequentialthinking", transport: .stdio,
            homepage: reference + "sequentialthinking", publisher: "MCP reference",
            pullRepository: "mcp/sequentialthinking", pullSnapshot: 437_708, arm64Note: hubArm64,
            configSource: source + "sequentialthinking/server.yaml"
        ),
        MCPCatalogItem(
            id: "filesystem", title: "Filesystem", summary: "Read and write files in one folder you choose.",
            image: "mcp/filesystem", transport: .stdio, command: ["/projects"],
            mount: MCPCatalogMount(label: "Folder", containerPath: "/projects"),
            homepage: reference + "filesystem", publisher: "MCP reference",
            pullRepository: "mcp/filesystem", pullSnapshot: 318_105, arm64Note: hubArm64, configSource: source + "filesystem/server.yaml"
        ),
        MCPCatalogItem(
            id: "youtube-transcript", title: "YouTube Transcript", summary: "Get the transcript of a YouTube video.",
            image: "mcp/youtube-transcript", transport: .stdio,
            homepage: "https://github.com/jkawamoto/mcp-youtube-transcript", publisher: "Community",
            pullRepository: "mcp/youtube-transcript", pullSnapshot: 306_973, arm64Note: hubArm64,
            configSource: source + "youtube_transcript/server.yaml"
        ),
        MCPCatalogItem(
            id: "git", title: "Git", summary: "Read, search and change a Git repository.",
            image: "mcp/git", transport: .stdio,
            mount: MCPCatalogMount(label: "Repository", containerPath: "/workspace"),
            homepage: reference + "git", publisher: "MCP reference",
            pullRepository: "mcp/git", pullSnapshot: 193_935, arm64Note: hubArm64, configSource: source + "git/server.yaml"
        ),
        MCPCatalogItem(
            id: "wikipedia", title: "Wikipedia", summary: "Search Wikipedia and read articles and summaries.",
            image: "mcp/wikipedia-mcp", transport: .stdio,
            homepage: "https://github.com/Rudra-ravi/wikipedia-mcp", publisher: "Community",
            pullRepository: "mcp/wikipedia-mcp", pullSnapshot: 189_270, arm64Note: hubArm64, configSource: source + "wikipedia-mcp/server.yaml"
        ),
        MCPCatalogItem(
            id: "markitdown", title: "MarkItDown", summary: "Turn PDF, Word, Excel, PowerPoint and web pages into Markdown.",
            image: "mcp/markitdown", transport: .stdio,
            mount: MCPCatalogMount(label: "Files folder", containerPath: "/workdir", readOnly: true, optional: true),
            homepage: "https://github.com/microsoft/markitdown/tree/main/packages/markitdown-mcp", publisher: "Microsoft",
            pullRepository: "mcp/markitdown", pullSnapshot: 169_573, arm64Note: hubArm64, configSource: source + "markitdown/server.yaml"
        ),
    ]

    static let account: [MCPCatalogItem] = [
        MCPCatalogItem(
            id: "grafana", title: "Grafana", summary: "Search dashboards, query metrics and logs, and look at alerts.",
            image: "mcp/grafana", transport: .stdio, command: ["--transport=stdio"],
            fields: [
                MCPCatalogField(key: "GRAFANA_URL", label: "Grafana URL", required: true, placeholder: "https://example.grafana.net"),
                MCPCatalogField(key: "GRAFANA_API_KEY", label: "Service account token", secret: true, required: true, placeholder: "glsa_…"),
            ],
            homepage: "https://github.com/grafana/mcp-grafana", publisher: "Grafana Labs", group: .account,
            pullRepository: "mcp/grafana", pullSnapshot: 1_164_170, arm64Note: hubArm64, configSource: source + "grafana/server.yaml"
        ),
        // Docker mounts the kubeconfig file at the same place. The cluster address in it must be
        // reachable from a container (not 127.0.0.1).
        MCPCatalogItem(
            id: "kubernetes", title: "Kubernetes", summary: "Look at and manage a cluster with your kubeconfig.",
            image: "mcp/kubernetes", transport: .stdio,
            mount: MCPCatalogMount(label: "Kubeconfig", containerPath: "/home/appuser/.kube/config", readOnly: true, isFile: true,
                                   suggestedPath: "~/.kube/config"),
            homepage: "https://github.com/Flux159/mcp-server-kubernetes", publisher: "Community", group: .account,
            pullRepository: "mcp/kubernetes", pullSnapshot: 467_134, arm64Note: hubArm64, configSource: source + "kubernetes/server.yaml"
        ),
        MCPCatalogItem(
            id: "brave-search", title: "Brave Search", summary: "Web, news, image and video search with the Brave Search API.",
            image: "mcp/brave-search", transport: .stdio,
            fields: [MCPCatalogField(key: "BRAVE_API_KEY", label: "API key", secret: true, required: true, placeholder: "BSA…")],
            homepage: "https://github.com/brave/brave-search-mcp-server", publisher: "Brave",
            env: [EnvVar(key: "BRAVE_MCP_TRANSPORT", value: "stdio")], group: .account,
            pullRepository: "mcp/brave-search", pullSnapshot: 296_840, arm64Note: hubArm64, configSource: source + "brave/server.yaml"
        ),
        // Docker builds OPENAPI_MCP_HEADERS from the token in its gateway. The server also reads
        // NOTION_TOKEN directly, so the token can stay in the Keychain.
        MCPCatalogItem(
            id: "notion", title: "Notion", summary: "Search, read and edit pages and databases in Notion.",
            image: "mcp/notion", transport: .stdio,
            fields: [MCPCatalogField(key: "NOTION_TOKEN", label: "Integration token", secret: true, required: true, placeholder: "ntn_…")],
            homepage: "https://github.com/makenotion/notion-mcp-server", publisher: "Notion", group: .account,
            pullRepository: "mcp/notion", pullSnapshot: 283_837, arm64Note: hubArm64, configSource: source + "notion/server.yaml"
        ),
        // Fill in Jira, Confluence or both. API tokens are for Cloud, personal tokens for Server and Data Center.
        MCPCatalogItem(
            id: "atlassian", title: "Atlassian", summary: "Jira issues and Confluence pages, on Cloud or your own server.",
            image: "mcp/atlassian", transport: .stdio,
            fields: [
                MCPCatalogField(key: "JIRA_URL", label: "Jira URL", placeholder: "https://your-company.atlassian.net"),
                MCPCatalogField(key: "JIRA_USERNAME", label: "Jira email", placeholder: "you@company.com"),
                MCPCatalogField(key: "JIRA_API_TOKEN", label: "Jira API token", secret: true),
                MCPCatalogField(key: "JIRA_PERSONAL_TOKEN", label: "Jira personal token", secret: true, placeholder: "Server and Data Center"),
                MCPCatalogField(key: "CONFLUENCE_URL", label: "Confluence URL", placeholder: "https://your-company.atlassian.net/wiki"),
                MCPCatalogField(key: "CONFLUENCE_USERNAME", label: "Confluence email", placeholder: "you@company.com"),
                MCPCatalogField(key: "CONFLUENCE_API_TOKEN", label: "Confluence API token", secret: true),
                MCPCatalogField(key: "CONFLUENCE_PERSONAL_TOKEN", label: "Confluence personal token", secret: true,
                                placeholder: "Server and Data Center"),
            ],
            homepage: "https://github.com/sooperset/mcp-atlassian", publisher: "Community", group: .account,
            pullRepository: "mcp/atlassian", pullSnapshot: 177_446, arm64Note: hubArm64, configSource: source + "atlassian/server.yaml"
        ),
        // GitHub's own image (Docker's "github-official"). mcp/github is the archived reference server,
        // but its Docker Hub count is the one comparable with the rest, so it ranks this entry.
        MCPCatalogItem(
            id: "github", title: "GitHub", summary: "Issues, pull requests and code on GitHub.",
            image: "ghcr.io/github/github-mcp-server", transport: .stdio, command: ["stdio"],
            fields: [MCPCatalogField(key: "GITHUB_PERSONAL_ACCESS_TOKEN", label: "Access token", secret: true, required: true,
                                     placeholder: "github_pat_…")],
            homepage: "https://github.com/github/github-mcp-server", publisher: "GitHub", group: .account,
            pullRepository: "mcp/github", pullSnapshot: 157_593,
            arm64Note: "linux/arm64 in the ghcr.io image index, checked 9 Nov 2026", configSource: source + "github-official/server.yaml"
        ),
    ]

    /// No longer featured, kept so servers installed from older lists still match their entry.
    public static let retired: [MCPCatalogItem] = [
        MCPCatalogItem(
            id: "everything", title: "Everything (test server)", summary: "Test server with every MCP feature. Good for trying a setup.",
            image: "mcp/everything", transport: .stdio,
            homepage: reference + "everything", publisher: "MCP reference",
            pullRepository: "mcp/everything", pullSnapshot: 90_420, arm64Note: hubArm64
        ),
    ]

    /// Every catalog id the app has shipped. Never remove one: installed servers point at it.
    public static var all: [MCPCatalogItem] { items + retired }

    public static func item(_ id: String) -> MCPCatalogItem? {
        all.first { $0.id == id }
    }

    /// Docker Hub repositories to ask for counts.
    public static var pullRepositories: [String] {
        var seen = Set<String>()
        return items.compactMap(\.pullRepository).filter { seen.insert($0).inserted }
    }

    /// One group, most pulled first. Ties keep the title order so the list never shuffles.
    public static func featured(_ group: MCPCatalogGroup, live: [String: Int] = [:]) -> [MCPCatalogItem] {
        sorted(items.filter { $0.group == group }, live: live)
    }

    public static func sorted(_ items: [MCPCatalogItem], live: [String: Int]) -> [MCPCatalogItem] {
        items.sorted { a, b in
            let pa = a.pulls(live), pb = b.pulls(live)
            return pa != pb ? pa > pb : a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }
}
