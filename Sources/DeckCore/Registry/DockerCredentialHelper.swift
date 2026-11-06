import Foundation

// Docker credential helper support. Reads ~/.docker/config.json and asks
// `docker-credential-<name> get` for a login, so it can be passed to
// `container registry login`. Nothing here is stored by us.

/// A login handed back by a Docker credential helper.
public struct DockerCredential: Sendable, Equatable {
    public var serverURL: String
    public var username: String
    public var secret: String

    public init(serverURL: String, username: String, secret: String) {
        self.serverURL = serverURL
        self.username = username
        self.secret = secret
    }
}

/// One registry that a helper in config.json can give a login for.
public struct DockerCredentialSource: Sendable, Hashable, Identifiable {
    public var id: String { configKey }
    /// The key exactly as written in config.json, for example "https://index.docker.io/v1/".
    /// This is what the helper expects on stdin.
    public var configKey: String
    /// Host for `container registry login`, for example "docker.io".
    public var server: String
    /// Helper name, for example "osxkeychain" for docker-credential-osxkeychain.
    public var helper: String

    public init(configKey: String, server: String, helper: String) {
        self.configKey = configKey
        self.server = server
        self.helper = helper
    }
}

/// The parts of Docker's config.json we care about.
public struct DockerConfigFile: Sendable, Equatable {
    public var credsStore: String?
    public var credHelpers: [String: String]
    /// Keys of the "auths" object.
    public var authServers: [String]

    public init(credsStore: String? = nil, credHelpers: [String: String] = [:], authServers: [String] = []) {
        self.credsStore = credsStore
        self.credHelpers = credHelpers
        self.authServers = authServers
    }

    /// Parses config.json. Unknown keys are ignored.
    public init(data: Data) throws {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw DeckError.parse("Docker config.json")
        }
        guard let root = object as? [String: Any] else {
            throw DeckError.parse("Docker config.json")
        }
        let store = (root["credsStore"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.credsStore = (store?.isEmpty ?? true) ? nil : store
        var helpers: [String: String] = [:]
        if let raw = root["credHelpers"] as? [String: Any] {
            for (key, value) in raw {
                if let name = value as? String, !name.isEmpty { helpers[key] = name }
            }
        }
        self.credHelpers = helpers
        if let auths = root["auths"] as? [String: Any] {
            self.authServers = auths.keys.sorted()
        } else {
            self.authServers = []
        }
    }

    /// `$DOCKER_CONFIG/config.json`, or `~/.docker/config.json`.
    public static func defaultPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> String {
        if let dir = environment["DOCKER_CONFIG"], !dir.isEmpty {
            return (dir as NSString).appendingPathComponent("config.json")
        }
        return (home as NSString).appendingPathComponent(".docker/config.json")
    }

    /// Reads the config file. nil when it is missing or unreadable.
    public static func load(path: String? = nil) -> DockerConfigFile? {
        let file = path ?? defaultPath()
        guard let data = FileManager.default.contents(atPath: file) else { return nil }
        return try? DockerConfigFile(data: data)
    }

    /// Every registry a helper can give a login for. A credHelpers entry wins
    /// over the global credsStore for the same registry.
    public var sources: [DockerCredentialSource] {
        var result: [DockerCredentialSource] = []
        var seenServers = Set<String>()
        for key in credHelpers.keys.sorted() {
            guard let helper = credHelpers[key] else { continue }
            let server = Self.registryHost(from: key)
            guard !server.isEmpty, !seenServers.contains(server) else { continue }
            seenServers.insert(server)
            result.append(DockerCredentialSource(configKey: key, server: server, helper: helper))
        }
        if let store = credsStore {
            for key in authServers {
                let server = Self.registryHost(from: key)
                guard !server.isEmpty, !seenServers.contains(server) else { continue }
                seenServers.insert(server)
                result.append(DockerCredentialSource(configKey: key, server: server, helper: store))
            }
        }
        return result
    }

    /// "https://index.docker.io/v1/" becomes "docker.io". "https://ghcr.io" becomes "ghcr.io".
    public static func registryHost(from key: String) -> String {
        var host = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for scheme in ["https://", "http://"] where host.hasPrefix(scheme) {
            host = String(host.dropFirst(scheme.count))
        }
        if let slash = host.firstIndex(of: "/") {
            host = String(host[..<slash])
        }
        switch host {
        case "index.docker.io", "registry-1.docker.io", "registry.hub.docker.com", "docker.io":
            return "docker.io"
        default:
            return host
        }
    }
}

/// Runs `docker-credential-<name>` to read a stored login.
public struct DockerCredentialHelper: Sendable {
    /// Places GUI apps do not have on PATH but helpers often live in.
    public static let extraSearchPaths = ["/usr/local/bin", "/opt/homebrew/bin"]

    public let name: String
    let runner: any CommandRunning
    let files: FileSystem
    let pathEnv: String

    public init(
        name: String,
        runner: any CommandRunning = ProcessRunner(),
        files: FileSystem = .live,
        pathEnv: String = ProcessInfo.processInfo.environment["PATH"] ?? ""
    ) {
        self.name = name
        self.runner = runner
        self.files = files
        self.pathEnv = pathEnv
    }

    public var executableName: String { "docker-credential-\(name)" }

    /// Folders searched in order: PATH, then the extra folders.
    var searchDirectories: [String] {
        var dirs: [String] = []
        for dir in pathEnv.split(separator: ":") where !dir.isEmpty {
            let value = String(dir)
            if !dirs.contains(value) { dirs.append(value) }
        }
        for dir in Self.extraSearchPaths where !dirs.contains(dir) {
            dirs.append(dir)
        }
        return dirs
    }

    /// Full path of the helper, or nil when it is not installed.
    public func locate() -> String? {
        // A helper name with a slash would let config.json point anywhere.
        guard !name.isEmpty, !name.contains("/") else { return nil }
        for dir in searchDirectories {
            let path = (dir as NSString).appendingPathComponent(executableName)
            if files.isExecutable(path) { return path }
        }
        return nil
    }

    /// Asks the helper for the login of `server` (the key from config.json).
    public func get(server: String) async throws -> DockerCredential {
        guard let path = locate() else {
            throw DeckError.commandFailed("\(executableName) was not found. Install it or add it to your PATH.")
        }
        // Helpers such as gcloud call other tools, so give them a full PATH.
        let fullPath = searchDirectories.joined(separator: ":")
        let result = try await runner.run(
            "/usr/bin/env",
            ["PATH=\(fullPath)", path, "get"],
            stdin: Data((server + "\n").utf8)
        )
        guard result.succeeded else {
            throw DeckError.commandFailed("\(executableName) could not read the login for \(server). \(result.failureMessage)")
        }
        return try Self.parse(result.stdout, server: server)
    }

    /// Parses helper output: {"ServerURL": "...", "Username": "...", "Secret": "..."}.
    public static func parse(_ output: String, server: String) throws -> DockerCredential {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any] else {
            throw DeckError.parse("docker credential helper")
        }
        let username = (json["Username"] as? String) ?? ""
        let secret = (json["Secret"] as? String) ?? ""
        let serverURL = (json["ServerURL"] as? String) ?? server
        guard !secret.isEmpty else {
            throw DeckError.commandFailed("The helper has no saved login for \(server).")
        }
        // Docker Hub identity tokens only work with Docker's own login flow.
        guard !username.isEmpty, username != "<token>" else {
            throw DeckError.commandFailed("The saved login for \(server) is a token only Docker can use. Sign in with a username and access token instead.")
        }
        return DockerCredential(serverURL: serverURL, username: username, secret: secret)
    }
}
