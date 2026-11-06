import Foundation

/// An MCP server installed through the app. Saved in Application Support.
/// Secret values are never stored here, only their names (values live in the Keychain).
public struct MCPInstalledServer: Sendable, Hashable, Codable, Identifiable {
    public enum Kind: String, Sendable, Hashable, Codable {
        /// Runs in a container from an image.
        case container
        /// A command on this Mac (stdio only, not in a container).
        case hostCommand
        /// A server on the network, reached by URL (HTTP or SSE). Nothing runs here.
        case remote
    }

    public var name: String
    public var kind: Kind
    public var catalogID: String?
    public var image: String
    public var transport: MCPTransport
    /// Container: arguments after the image. Host command: the executable then its arguments.
    public var command: [String]
    public var containerPort: Int?
    public var hostPort: Int?
    public var path: String?
    public var env: [EnvVar]
    public var secretKeys: [String]
    public var mounts: [MountSpec]
    public var createdAt: Date
    /// Remote servers: the URL agents connect to.
    public var remoteURL: String?
    /// Remote servers: headers sent with each request. Agents keep them in their config.
    public var headers: [EnvVar]?

    public var id: String { name }

    public init(name: String, kind: Kind = .container, catalogID: String? = nil, image: String = "", transport: MCPTransport,
                command: [String] = [], containerPort: Int? = nil, hostPort: Int? = nil, path: String? = nil,
                env: [EnvVar] = [], secretKeys: [String] = [], mounts: [MountSpec] = [], createdAt: Date = Date(),
                remoteURL: String? = nil, headers: [EnvVar]? = nil) {
        self.name = name
        self.kind = kind
        self.catalogID = catalogID
        self.image = image
        self.transport = transport
        self.command = command
        self.containerPort = containerPort
        self.hostPort = hostPort
        self.path = path
        self.env = env
        self.secretKeys = secretKeys
        self.mounts = mounts
        self.createdAt = createdAt
        self.remoteURL = remoteURL
        self.headers = headers
    }

    /// Long running container (HTTP or SSE).
    public var isLongRunning: Bool { kind == .container && transport != .stdio }
}

public enum MCPLaunchError: Error, LocalizedError, Equatable {
    case badName
    case missingPort

    public var errorDescription: String? {
        switch self {
        case .badName: return "Use letters, numbers, dashes or underscores for the name."
        case .missingPort: return "HTTP servers need the port the server listens on inside the container."
        }
    }
}

/// Command lines and run options for installed servers.
public enum MCPLaunch {
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 48 && name.unicodeScalars.allSatisfy {
            ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "-" || $0 == "_"
        } && !(name.first == "-")
    }

    /// Lowercase name made from a title, for suggestions.
    public static func suggestedName(_ title: String) -> String {
        let lowered = title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let collapsed = String(lowered).split(separator: "-").joined(separator: "-")
        return String(collapsed.prefix(40))
    }

    public static func containerName(_ server: MCPInstalledServer) -> String {
        AgentsConfig.containerPrefix + server.name
    }

    public static func url(_ server: MCPInstalledServer) -> String? {
        if server.kind == .remote { return server.remoteURL }
        guard server.isLongRunning, let port = server.hostPort else { return nil }
        return "http://127.0.0.1:\(port)\(server.path ?? (server.transport == .sse ? "/sse" : "/mcp"))"
    }

    public static func labels(_ server: MCPInstalledServer) -> [String: String] {
        [AgentsConfig.serverLabel: server.name, AgentsConfig.transportLabel: server.transport.rawValue]
    }

    /// Run options for a long running HTTP or SSE server. Secrets are passed with an env file, not here.
    public static func runOptions(_ server: MCPInstalledServer) throws -> RunOptions {
        guard isValidName(server.name) else { throw MCPLaunchError.badName }
        guard let containerPort = server.containerPort, let hostPort = server.hostPort else { throw MCPLaunchError.missingPort }
        return RunOptions(
            image: server.image, name: containerName(server), command: server.command,
            env: server.env.filter { !$0.key.isEmpty },
            ports: [PortMapping(hostAddress: "127.0.0.1", hostPort: hostPort, containerPort: containerPort)],
            mounts: server.mounts, labels: labels(server), detach: true
        )
    }

    /// `container run` arguments for a stdio server. Env values are not in here:
    /// `--env KEY` makes the container take the value from the agent's environment.
    public static func stdioRunArguments(_ server: MCPInstalledServer) -> [String] {
        var args = ["run", "--interactive", "--rm"]
        for (key, value) in labels(server).sorted(by: { $0.key < $1.key }) { args += ["--label", "\(key)=\(value)"] }
        for mount in server.mounts { args += ContainerClient.mountArguments(mount) }
        let keys = server.env.map(\.key).filter { !$0.isEmpty } + server.secretKeys
        for key in keys { args += ["--env", key] }
        args.append(server.image)
        args += server.command
        return args
    }

    /// The entry an agent config gets. stdio servers: the agent spawns `container run -i --rm ...`.
    /// Secrets are read from the Keychain by a small shell line at spawn time, so they never sit in the config.
    public static func entry(_ server: MCPInstalledServer, cliPath: String) -> MCPServerEntry {
        if server.kind == .remote {
            let headers = Dictionary((server.headers ?? []).filter { !$0.key.isEmpty }.map { ($0.key, $0.value) }, uniquingKeysWith: { $1 })
            return .remote(server.name, transport: server.transport == .stdio ? .http : server.transport, url: server.remoteURL ?? "", headers: headers)
        }
        if server.kind == .hostCommand {
            let env = Dictionary(server.env.map { ($0.key, $0.value) }, uniquingKeysWith: { $1 })
            return .stdio(server.name, command: server.command.first ?? "", args: Array(server.command.dropFirst()), env: env)
        }
        if server.isLongRunning, let url = url(server) {
            return .remote(server.name, transport: server.transport, url: url)
        }
        let env = Dictionary(server.env.filter { !$0.key.isEmpty }.map { ($0.key, $0.value) }, uniquingKeysWith: { $1 })
        let runArgs = stdioRunArguments(server)
        guard !server.secretKeys.isEmpty else {
            return .stdio(server.name, command: cliPath, args: runArgs, env: env)
        }
        return .stdio(server.name, command: "/bin/sh", args: ["-c", secretScript(server, cliPath: cliPath, runArgs: runArgs)], env: env)
    }

    /// Shell line that loads each secret from the Keychain and then runs the container.
    static func secretScript(_ server: MCPInstalledServer, cliPath: String, runArgs: [String]) -> String {
        var parts: [String] = []
        for key in server.secretKeys {
            let account = secretAccount(server: server.name, key: key)
            parts.append("\(key)=\"$(/usr/bin/security find-generic-password -s \(shellQuote(AgentsConfig.secretService)) -a \(shellQuote(account)) -w)\" && export \(key)")
        }
        parts.append("exec " + ([cliPath] + runArgs).map(shellQuote).joined(separator: " "))
        return parts.joined(separator: " && ")
    }

    public static func secretAccount(server: String, key: String) -> String {
        "\(server)/\(key)"
    }

    /// The full command line, for showing and copying.
    public static func commandLine(_ entry: MCPServerEntry) -> String {
        if let url = entry.url { return url }
        return ([entry.command ?? ""] + entry.args).map(shellQuote).joined(separator: " ")
    }

    public static func shellQuote(_ value: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./:=,@%+")
        if !value.isEmpty, value.unicodeScalars.allSatisfy({ safe.contains($0) }) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Name of our server when an agent entry runs one of our stdio containers.
    public static func managedServerName(in entry: MCPServerEntry) -> String? {
        let prefix = AgentsConfig.serverLabel + "="
        for arg in entry.args {
            if arg.hasPrefix(prefix) { return String(arg.dropFirst(prefix.count)) }
            if let range = arg.range(of: "'" + prefix) ?? arg.range(of: " " + prefix) {
                let rest = arg[range.upperBound...]
                let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
                if !name.isEmpty { return String(name) }
            }
        }
        return nil
    }

    /// First free host port from `start`, skipping ones in `used`.
    public static func freePort(startingAt start: Int = AgentsConfig.firstHostPort, used: Set<Int>, isFree: (Int) -> Bool = PortProbe.isFree) -> Int {
        var port = start
        while port < 65_000 {
            if !used.contains(port), isFree(port) { return port }
            port += 1
        }
        return start
    }
}

/// Checks whether a local TCP port can be bound.
public enum PortProbe {
    public static func isFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return result == 0
    }
}

/// Installed servers, saved as JSON in Application Support.
public struct MCPServerRegistry: Sendable {
    public var file: URL

    public init(file: URL? = nil) {
        if let file {
            self.file = file
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.file = base.appendingPathComponent(AgentsConfig.supportFolder).appendingPathComponent(AgentsConfig.serversFile)
        }
    }

    public func load() -> [MCPInstalledServer] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([MCPInstalledServer].self, from: data)) ?? []
    }

    public func save(_ servers: [MCPInstalledServer]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(servers).write(to: file, options: .atomic)
    }
}
