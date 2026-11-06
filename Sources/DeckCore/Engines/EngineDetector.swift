import Foundation

/// Everything detection reads from the Mac. Tests pass fake closures.
public struct EngineEnvironment: Sendable {
    public var home: String
    /// Value of DOCKER_HOST, if set.
    public var dockerHost: String?
    public var files: FileSystem
    public var readFile: @Sendable (String) -> Data?
    /// Follows symlinks to the real path.
    public var resolvePath: @Sendable (String) -> String

    public init(
        home: String,
        dockerHost: String?,
        files: FileSystem,
        readFile: @escaping @Sendable (String) -> Data?,
        resolvePath: @escaping @Sendable (String) -> String
    ) {
        self.home = home
        self.dockerHost = dockerHost
        self.files = files
        self.readFile = readFile
        self.resolvePath = resolvePath
    }

    public static func live() -> EngineEnvironment {
        EngineEnvironment(
            home: FileManager.default.homeDirectoryForCurrentUser.path,
            dockerHost: ProcessInfo.processInfo.environment["DOCKER_HOST"],
            files: .live,
            readFile: { FileManager.default.contents(atPath: $0) },
            resolvePath: { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        )
    }
}

/// A place an engine might be. Only a hint until we probe it.
public struct EngineCandidate: Sendable, Hashable {
    public var kind: EngineKind
    public var name: String
    public var socketPath: String
    public var source: String

    public init(kind: EngineKind, name: String, socketPath: String, source: String) {
        self.kind = kind
        self.name = name
        self.socketPath = socketPath
        self.source = source
    }
}

/// Finds Docker Desktop, OrbStack, Rancher Desktop, Podman, Colima, Lima and
/// any Docker context on this Mac.
public struct EngineDetector: Sendable {
    public static let podmanPaths = ["/opt/homebrew/bin/podman", "/usr/local/bin/podman", "/opt/podman/bin/podman"]
    public static let nerdctlNamespaces = ["default", "k8s.io"]

    static let appBundles: [EngineKind: [String]] = [
        .dockerDesktop: ["/Applications/Docker.app"],
        .orbStack: ["/Applications/OrbStack.app"],
        .rancherDesktop: ["/Applications/Rancher Desktop.app"],
        .podman: ["/Applications/Podman Desktop.app"],
        .colima: ["/opt/homebrew/bin/colima", "/usr/local/bin/colima"]
    ]

    let env: EngineEnvironment
    let runner: any CommandRunning

    public init(environment: EngineEnvironment = .live(), runner: any CommandRunning = CancellableRunner()) {
        self.env = environment
        self.runner = runner
    }

    // MARK: - Full detection

    public func detect() async -> [DetectedEngine] {
        var candidates = socketCandidates()
        let podman = await podmanInfo()
        candidates.append(contentsOf: podman.candidates)
        let unique = dedupe(candidates)

        var engines: [DetectedEngine] = []
        for candidate in unique {
            var engine = await probe(candidate)
            if engine.kind == .podman {
                engine.podmanBinary = podman.binary
                engine.podmanConnection = podman.connectionForSocket[candidate.socketPath]
            }
            engines.append(engine)
        }

        engines.append(contentsOf: await nerdctlEngines())

        // A machine Podman knows about whose socket is missing is stopped.
        for stopped in podman.stoppedMachines where !engines.contains(where: { $0.kind == .podman && $0.isRunning }) {
            engines.append(DetectedEngine(
                id: "podman-machine:\(stopped)", kind: .podman, name: "Podman (\(stopped))", state: .stopped,
                note: "Start it with podman machine start.", podmanBinary: podman.binary
            ))
        }

        // Several sockets can point at one engine (for example /var/run/docker.sock).
        // Keep one running entry per real engine and drop extra stopped entries of the same kind.
        engines = collapse(engines)

        // Installed apps without a socket are stopped. Unknown ones are not found.
        for kind in EngineKind.wellKnown where !engines.contains(where: { $0.kind == kind }) {
            let installed = (Self.appBundles[kind] ?? []).contains(where: env.files.fileExists)
                || (kind == .podman && podman.binary != nil)
            engines.append(DetectedEngine(
                id: "missing:\(kind.rawValue)", kind: kind, name: kind.title,
                state: installed ? .stopped : .notFound,
                note: installed ? "Installed, but not running." : nil,
                podmanBinary: kind == .podman ? podman.binary : nil
            ))
        }
        return sortEngines(engines)
    }

    // MARK: - Candidates (pure, tested)

    /// Every socket worth probing, most specific first.
    public func socketCandidates() -> [EngineCandidate] {
        let home = env.home
        var list: [EngineCandidate] = []
        func add(_ kind: EngineKind, _ name: String, _ path: String, _ source: String) {
            if env.files.fileExists(path) {
                list.append(EngineCandidate(kind: kind, name: name, socketPath: path, source: source))
            }
        }

        add(.orbStack, "OrbStack", home + "/.orbstack/run/docker.sock", "OrbStack socket")
        add(.rancherDesktop, "Rancher Desktop", home + "/.rd/docker.sock", "Rancher Desktop socket")

        for profile in env.files.contentsOfDirectory(home + "/.colima").sorted() where !profile.hasPrefix("_") && !profile.hasPrefix(".") {
            let name = profile == "default" ? "Colima" : "Colima (\(profile))"
            add(.colima, name, home + "/.colima/\(profile)/docker.sock", "Colima profile \(profile)")
        }

        for instance in env.files.contentsOfDirectory(home + "/.lima").sorted() where !instance.hasPrefix("_") && !instance.hasPrefix(".") {
            add(.lima, "Lima (\(instance))", home + "/.lima/\(instance)/sock/docker.sock", "Lima instance \(instance)")
        }

        add(.podman, "Podman", home + "/.local/share/containers/podman/machine/podman.sock", "Podman socket")
        add(.dockerDesktop, "Docker Desktop", home + "/.docker/run/docker.sock", "Docker Desktop socket")

        for context in dockerContexts() {
            let kind = Self.kind(forSocketPath: env.resolvePath(context.path))
            add(kind, kind == .other ? "Docker context \(context.name)" : kind.title, context.path, "Docker context \(context.name)")
        }

        if let host = env.dockerHost, let path = Self.unixPath(fromHost: host) {
            let kind = Self.kind(forSocketPath: env.resolvePath(path))
            add(kind, kind == .other ? "DOCKER_HOST" : kind.title, path, "DOCKER_HOST")
        }

        let system = "/var/run/docker.sock"
        let kind = Self.kind(forSocketPath: env.resolvePath(system))
        add(kind == .other ? .dockerDesktop : kind, kind == .other ? "Docker Desktop" : kind.title, system, "/var/run/docker.sock")
        return list
    }

    /// Unix sockets from ~/.docker/contexts/meta/*/meta.json.
    public func dockerContexts() -> [(name: String, path: String)] {
        let root = env.home + "/.docker/contexts/meta"
        var found: [(name: String, path: String)] = []
        for folder in env.files.contentsOfDirectory(root).sorted() {
            guard let data = env.readFile(root + "/" + folder + "/meta.json"),
                  let context = Self.parseContextMeta(data),
                  let path = Self.unixPath(fromHost: context.host)
            else { continue }
            found.append((name: context.name, path: path))
        }
        return found
    }

    /// Removes candidates that point at the same real socket. The first one wins.
    public func dedupe(_ candidates: [EngineCandidate]) -> [EngineCandidate] {
        var seen = Set<String>()
        var result: [EngineCandidate] = []
        for candidate in candidates {
            let real = env.resolvePath(candidate.socketPath)
            if seen.insert(real).inserted {
                result.append(candidate)
            }
        }
        return result
    }

    // MARK: - Probing

    func probe(_ candidate: EngineCandidate) async -> DetectedEngine {
        let real = env.resolvePath(candidate.socketPath)
        var engine = DetectedEngine(
            id: "socket:\(real)", kind: candidate.kind, name: candidate.name, state: .stopped,
            endpoint: .dockerSocket(candidate.socketPath), note: candidate.socketPath
        )
        let api = DockerAPI(socketPath: candidate.socketPath, runner: runner)
        guard await api.ping() else {
            engine.note = "Socket found at \(candidate.socketPath), but the engine does not answer."
            return engine
        }
        engine.state = .running
        let version = try? await api.version()
        let info = try? await api.info()
        if let number = version?.version, !number.isEmpty { engine.version = number }
        if let uid = info?.id, !uid.isEmpty { engine.engineUID = uid }
        let named = Self.name(for: candidate, realPath: real, version: version, info: info)
        engine.kind = named.kind
        engine.name = named.name
        engine.imageCount = info?.images
        return engine
    }

    /// Names an engine from its socket path and its /version and /info answers.
    public static func name(
        for candidate: EngineCandidate, realPath: String, version: DockerVersion?, info: DockerInfo?
    ) -> (kind: EngineKind, name: String) {
        let os = (info?.operatingSystem ?? "").lowercased()
        let host = (info?.name ?? "").lowercased()
        if version?.isPodman == true { return (.podman, candidate.kind == .podman ? candidate.name : "Podman") }
        if os.contains("orbstack") || host == "orbstack" { return (.orbStack, "OrbStack") }
        if os.contains("docker desktop") || host == "docker-desktop" { return (.dockerDesktop, "Docker Desktop") }
        if os.contains("rancher") || host.contains("rancher-desktop") { return (.rancherDesktop, "Rancher Desktop") }
        if candidate.kind == .colima || candidate.kind == .lima { return (candidate.kind, candidate.name) }
        if host.hasPrefix("colima") { return (.colima, "Colima") }
        let byPath = kind(forSocketPath: realPath)
        if byPath != .other { return (byPath, candidate.kind == byPath ? candidate.name : byPath.title) }
        return (candidate.kind, candidate.name)
    }

    /// Guesses the engine from where its socket really lives.
    public static func kind(forSocketPath path: String) -> EngineKind {
        let lower = path.lowercased()
        if lower.contains("/.orbstack/") { return .orbStack }
        if lower.contains("/.rd/") || lower.contains("rancher-desktop") { return .rancherDesktop }
        if lower.contains("/.colima/") { return .colima }
        if lower.contains("podman") { return .podman }
        if lower.contains("/.lima/") { return .lima }
        if lower.contains("/.docker/") || lower.contains("docker.raw.sock") { return .dockerDesktop }
        return .other
    }

    /// "/path" from "unix:///path". nil for tcp or ssh hosts.
    public static func unixPath(fromHost host: String) -> String? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("unix://") else { return nil }
        let path = String(trimmed.dropFirst("unix://".count))
        return path.isEmpty ? nil : path
    }

    public static func parseContextMeta(_ data: Data) -> (name: String, host: String)? {
        struct Meta: Decodable {
            struct Endpoint: Decodable { var Host: String? }
            var Name: String?
            var Endpoints: [String: Endpoint]?
        }
        guard let meta = try? JSONDecoder().decode(Meta.self, from: data),
              let host = meta.Endpoints?["docker"]?.Host
        else { return nil }
        return (name: meta.Name ?? "context", host: host)
    }

    func collapse(_ engines: [DetectedEngine]) -> [DetectedEngine] {
        var result: [DetectedEngine] = []
        for engine in engines {
            if engine.isRunning {
                // Two sockets can lead to the same daemon. /info ID tells us.
                if let uid = engine.engineUID, result.contains(where: { $0.engineUID == uid }) { continue }
                result.append(engine)
            } else if !result.contains(where: { $0.kind == engine.kind && $0.name == engine.name }) {
                result.append(engine)
            }
        }
        // Drop stopped duplicates when a running engine of the same name exists.
        return result.filter { engine in
            engine.isRunning || !result.contains { $0.isRunning && $0.kind == engine.kind && $0.name == engine.name }
        }
    }

    func sortEngines(_ engines: [DetectedEngine]) -> [DetectedEngine] {
        func rank(_ state: EngineState) -> Int {
            switch state {
            case .running: return 0
            case .stopped: return 1
            case .notFound: return 2
            }
        }
        return engines.enumerated().sorted { a, b in
            let ra = rank(a.element.state), rb = rank(b.element.state)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    // MARK: - Podman

    struct PodmanInfo: Sendable {
        var binary: String?
        var candidates: [EngineCandidate] = []
        var connectionForSocket: [String: String] = [:]
        var stoppedMachines: [String] = []
    }

    public func podmanBinary() -> String? {
        Self.podmanPaths.first(where: env.files.isExecutable)
    }

    func podmanInfo() async -> PodmanInfo {
        var info = PodmanInfo(binary: podmanBinary())
        guard let binary = info.binary else { return info }

        // Machines and their API sockets.
        var names: [String] = []
        if let result = try? await runner.run(binary, ["machine", "list", "--format", "json"]), result.succeeded {
            names = Self.parsePodmanMachineNames(result.stdout)
        }
        if let result = try? await runner.run(binary, ["machine", "inspect"] + names), result.succeeded {
            for machine in Self.parsePodmanMachineInspect(result.stdout) {
                let label = machine.name == "podman-machine-default" ? "Podman" : "Podman (\(machine.name))"
                if let socket = machine.socketPath, env.files.fileExists(socket), machine.state != "stopped" {
                    info.candidates.append(EngineCandidate(kind: .podman, name: label, socketPath: socket, source: "podman machine \(machine.name)"))
                    info.connectionForSocket[socket] = machine.name
                } else {
                    info.stoppedMachines.append(machine.name)
                }
            }
        }

        // Extra connections with a local unix socket.
        if let result = try? await runner.run(binary, ["system", "connection", "list", "--format", "json"]), result.succeeded {
            for connection in Self.parsePodmanConnections(result.stdout) {
                guard let path = Self.unixPath(fromHost: connection.uri), env.files.fileExists(path) else { continue }
                info.candidates.append(EngineCandidate(kind: .podman, name: "Podman (\(connection.name))", socketPath: path, source: "podman connection \(connection.name)"))
                info.connectionForSocket[path] = connection.name
            }
        }
        return info
    }

    public static func parsePodmanMachineNames(_ text: String) -> [String] {
        struct Entry: Decodable { var Name: String? }
        guard let list = try? JSONDecoder().decode([Entry].self, from: Data(text.utf8)) else { return [] }
        return list.compactMap { $0.Name?.replacingOccurrences(of: "*", with: "") }
    }

    public static func parsePodmanMachineInspect(_ text: String) -> [(name: String, socketPath: String?, state: String)] {
        struct Entry: Decodable {
            struct Socket: Decodable { var Path: String? }
            struct Connection: Decodable { var PodmanSocket: Socket? }
            var Name: String?
            var State: String?
            var ConnectionInfo: Connection?
        }
        guard let list = try? JSONDecoder().decode([Entry].self, from: Data(text.utf8)) else { return [] }
        return list.map { entry in
            (name: entry.Name ?? "podman-machine-default",
             socketPath: entry.ConnectionInfo?.PodmanSocket?.Path,
             state: (entry.State ?? "").lowercased())
        }
    }

    public static func parsePodmanConnections(_ text: String) -> [(name: String, uri: String)] {
        struct Entry: Decodable {
            var Name: String?
            var URI: String?
        }
        guard let list = try? JSONDecoder().decode([Entry].self, from: Data(text.utf8)) else { return [] }
        return list.compactMap { entry in
            guard let uri = entry.URI else { return nil }
            return (name: entry.Name ?? "podman", uri: uri)
        }
    }

    // MARK: - Rancher Desktop containerd (nerdctl)

    public var nerdctlPath: String { env.home + "/.rd/bin/nerdctl" }

    func nerdctlEngines() async -> [DetectedEngine] {
        let binary = nerdctlPath
        guard env.files.isExecutable(binary) else { return [] }
        var engines: [DetectedEngine] = []
        for namespace in Self.nerdctlNamespaces {
            let result = try? await runner.run(binary, NerdctlEngine.imagesArguments(namespace: namespace))
            let running = result?.succeeded ?? false
            let count = running ? NerdctlEngine.parseImages(result?.stdout ?? "").count : nil
            engines.append(DetectedEngine(
                id: "nerdctl:\(namespace)", kind: .rancherContainerd,
                name: "Rancher Desktop (\(namespace))",
                state: running ? .running : .stopped,
                endpoint: .nerdctl(binary: binary, namespace: namespace),
                note: running ? "containerd namespace \(namespace)" : "Start Rancher Desktop to read this namespace.",
                imageCount: count
            ))
        }
        // nerdctl exits 1 with "Rancher Desktop is not running" when the app is closed.
        // The Rancher Desktop app entry already shows that, so add nothing here.
        if !engines.contains(where: { $0.isRunning }) { return [] }
        // In dockerd mode these namespaces are empty. Hide them then.
        if engines.allSatisfy({ ($0.imageCount ?? 0) == 0 }) {
            return engines.allSatisfy({ $0.isRunning }) ? [] : Array(engines.prefix(1))
        }
        return engines.filter { ($0.imageCount ?? 0) > 0 || !$0.isRunning }
    }
}
