import Foundation

/// One TCP socket in the listen state, from `lsof`.
public struct ListeningSocket: Sendable, Equatable, Hashable {
    public var pid: Int32
    /// Short process name from lsof ("ollama", "python3.12").
    public var processName: String
    /// "127.0.0.1", "*", "::1", "192.168.64.1".
    public var address: String
    public var port: Int

    public init(pid: Int32, processName: String, address: String, port: Int) {
        self.pid = pid
        self.processName = processName
        self.address = address
        self.port = port
    }
}

/// Finds local model servers. Pure parsing lives in `ModelDiscoveryParser` so it can be tested
/// with recorded output. The runner and HTTP client are swapped for fakes in tests.
public struct ModelDiscovery: Sendable {
    let runner: CommandRunning
    let http: AIHTTPFetching
    let fileExists: @Sendable (String) -> Bool
    let managedPIDs: @Sendable () -> Set<Int32>
    let timeout: TimeInterval

    public init(runner: CommandRunning = ProcessRunner(),
                http: AIHTTPFetching = AIHTTPClient(),
                fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: AIConfig.expand($0)) },
                managedPIDs: @escaping @Sendable () -> Set<Int32> = { MLXServerRecord.load().map { [$0.pid] } ?? [] },
                timeout: TimeInterval = AIConfig.probeTimeout) {
        self.runner = runner
        self.http = http
        self.fileExists = fileExists
        self.managedPIDs = managedPIDs
        self.timeout = timeout
    }

    public func discover() async -> [ModelEndpoint] {
        let sockets = await listeningSockets()
        let commands = await processCommands(Set(sockets.map(\.pid)))
        let targets = ModelDiscoveryParser.probeTargets(sockets: sockets, commands: commands)
        let managed = managedPIDs()

        var found: [ModelEndpoint] = []
        await withTaskGroup(of: ModelEndpoint?.self) { group in
            for target in targets {
                group.addTask { await probe(target, managed: managed) }
            }
            for await endpoint in group {
                if let endpoint { found.append(endpoint) }
            }
        }
        found += installedButStopped(running: found)
        return ModelDiscoveryParser.sorted(found)
    }

    // MARK: - System

    func listeningSockets() async -> [ListeningSocket] {
        guard let result = try? await runner.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"]) else { return [] }
        // lsof exits 1 when one of many lookups fails but still prints the rest.
        return ModelDiscoveryParser.parseLsof(result.stdout)
    }

    func processCommands(_ pids: Set<Int32>) async -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        let list = pids.sorted().map(String.init).joined(separator: ",")
        guard let result = try? await runner.run("/bin/ps", ["-o", "pid=,command=", "-p", list]) else { return [:] }
        return ModelDiscoveryParser.parsePS(result.stdout)
    }

    func installedButStopped(running: [ModelEndpoint]) -> [ModelEndpoint] {
        var extra: [ModelEndpoint] = []
        let kinds = Set(running.map(\.kind))
        if !kinds.contains(.ollama), (AIConfig.ollamaSearchPaths + [AIConfig.ollamaApp]).contains(where: fileExists) {
            extra.append(ModelDiscoveryParser.installedEndpoint(.ollama, port: 11434))
        }
        if !kinds.contains(.lmStudio), (AIConfig.lmStudioApps + AIConfig.lmStudioCLIPaths).contains(where: fileExists) {
            extra.append(ModelDiscoveryParser.installedEndpoint(.lmStudio, port: 1234))
        }
        return extra
    }

    // MARK: - Probing

    func probe(_ target: ProbeTarget, managed: Set<Int32>) async -> ModelEndpoint? {
        let host = target.probeHost
        func fetch(_ path: String) async -> Data? {
            guard let url = AIHTTP.url(host: host, port: target.port, path: path),
                  let (data, status) = try? await http.get(url, timeout: timeout),
                  (200..<300).contains(status) else { return nil }
            return data
        }

        let openAI = await fetch("/v1/models").flatMap(ModelDiscoveryParser.parseOpenAIModels)
        var isOllama = target.processKind == .ollama || openAI?.ownedBy.contains("library") == true || target.port == 11434
        var ollamaVersion: String?
        var ollamaModels: [ModelEndpointModel]?
        if isOllama || openAI == nil {
            ollamaVersion = await fetch("/api/version").flatMap(ModelDiscoveryParser.parseOllamaVersion)
            isOllama = ollamaVersion != nil
            if isOllama {
                ollamaModels = await fetch("/api/tags").flatMap(ModelDiscoveryParser.parseOllamaTags)
                let loaded = await fetch("/api/ps").map(ModelDiscoveryParser.parseOllamaLoaded) ?? []
                ollamaModels = ollamaModels.map { ModelDiscoveryParser.markLoaded($0, loaded: Set(loaded)) }
            }
        }

        var kind = ModelDiscoveryParser.classify(processKind: target.processKind, ownedBy: openAI?.ownedBy ?? [], isOllama: isOllama)
        var models = ollamaModels ?? openAI?.models ?? []
        if kind == .lmStudio || (kind == .openAICompatible && target.port == 1234) {
            if let rich = await fetch("/api/v0/models").flatMap(ModelDiscoveryParser.parseLMStudioModels) {
                kind = .lmStudio
                models = rich
            }
        }

        guard openAI != nil || isOllama else {
            // A model server that does not answer yet (loading a model, starting up).
            guard let processKind = target.processKind,
                  ModelDiscoveryParser.reportsWhenSilent(processKind, port: target.port) else { return nil }
            return ModelDiscoveryParser.endpoint(kind: processKind, target: target, status: .notResponding, models: [], version: nil,
                                                 managed: target.pid.map(managed.contains) ?? false)
        }

        if kind == .mlxLM || kind == .oMLX, let command = target.command {
            models = ModelDiscoveryParser.markServedModel(models, command: command)
        }
        return ModelDiscoveryParser.endpoint(kind: kind, target: target, status: .running, models: models, version: ollamaVersion,
                                             managed: target.pid.map(managed.contains) ?? false)
    }
}

/// A port worth probing.
public struct ProbeTarget: Sendable, Equatable {
    public var port: Int
    /// Address the server listens on, nil when lsof did not see it.
    public var bindAddress: String?
    public var pid: Int32?
    public var command: String?
    public var processKind: ModelServerKind?

    /// Where to send probes: the bound address when the server listens on one non loopback address, else loopback.
    public var probeHost: String {
        guard let bindAddress, bindAddress != "*", bindAddress != "0.0.0.0", bindAddress != "::",
              !ModelEndpoint.isLoopback(bindAddress) else { return "127.0.0.1" }
        return bindAddress
    }
}

/// Pure functions behind discovery. Unit tested with recorded output.
public enum ModelDiscoveryParser {
    // MARK: lsof and ps

    /// Reads `lsof -nP -iTCP -sTCP:LISTEN -Fpcn` output.
    public static func parseLsof(_ text: String) -> [ListeningSocket] {
        var sockets: [ListeningSocket] = []
        var pid: Int32 = 0
        var name = ""
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p":
                pid = Int32(value) ?? 0
                name = ""
            case "c":
                name = value
            case "n":
                guard let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) else { continue }
                var address = String(value[..<colon])
                if address.hasPrefix("[") && address.hasSuffix("]") {
                    address = String(address.dropFirst().dropLast())
                }
                let socket = ListeningSocket(pid: pid, processName: name, address: address, port: port)
                if !sockets.contains(socket) { sockets.append(socket) }
            default:
                continue
            }
        }
        return sockets
    }

    /// Reads `ps -o pid=,command= -p ...` output.
    public static func parsePS(_ text: String) -> [Int32: String] {
        var commands: [Int32: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let space = line.firstIndex(of: " "), let pid = Int32(line[..<space]) else { continue }
            commands[pid] = line[space...].trimmingCharacters(in: .whitespaces)
        }
        return commands
    }

    /// Model server kind from a command line, nil when it does not look like one.
    public static func kind(forCommand command: String) -> ModelServerKind? {
        let lower = command.lowercased()
        return AIConfig.processKeywords.first { lower.contains($0.keyword) }?.kind
    }

    /// Ports to probe: the well known ones plus every port a known model server process listens on.
    /// One target per port. The widest bind address wins ("*" over a LAN address over loopback).
    public static func probeTargets(sockets: [ListeningSocket], commands: [Int32: String]) -> [ProbeTarget] {
        var byPort: [Int: ProbeTarget] = [:]
        for socket in sockets {
            let command = commands[socket.pid] ?? socket.processName
            let kind = kind(forCommand: command) ?? kind(forCommand: socket.processName)
            // Ollama's per model runners listen on random ports. They are not endpoints.
            if kind == .ollama, command.lowercased().contains(" runner") { continue }
            let wellKnown = AIConfig.wellKnownPorts.contains { $0.port == socket.port }
            guard kind != nil || wellKnown else { continue }
            var target = byPort[socket.port] ?? ProbeTarget(port: socket.port, bindAddress: nil, pid: socket.pid, command: command, processKind: kind)
            if bindRank(socket.address) > bindRank(target.bindAddress) {
                target.bindAddress = socket.address
            }
            byPort[socket.port] = target
        }
        for (port, _) in AIConfig.wellKnownPorts where byPort[port] == nil {
            byPort[port] = ProbeTarget(port: port, bindAddress: nil, pid: nil, command: nil, processKind: nil)
        }
        return byPort.values.sorted { $0.port < $1.port }
    }

    /// True when a silent port is still worth showing: dedicated server commands and the well known ports.
    /// Helper processes of desktop apps (LM Studio, Ollama) listen on other ports and are skipped.
    public static func reportsWhenSilent(_ kind: ModelServerKind, port: Int) -> Bool {
        if AIConfig.wellKnownPorts.contains(where: { $0.port == port }) { return true }
        return [.mlxLM, .oMLX, .llamaCpp, .vLLM].contains(kind)
    }

    static func bindRank(_ address: String?) -> Int {
        guard let address else { return 0 }
        if address == "*" || address == "0.0.0.0" || address == "::" { return 3 }
        if ModelEndpoint.isLoopback(address) { return 1 }
        return 2
    }

    // MARK: HTTP bodies

    /// `/v1/models` in the OpenAI shape. nil when the body is not that shape.
    public static func parseOpenAIModels(_ data: Data) -> (models: [ModelEndpointModel], ownedBy: [String])? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["data"] as? [[String: Any]] else { return nil }
        var models: [ModelEndpointModel] = []
        var owners: [String] = []
        for item in list {
            guard let id = item["id"] as? String, !id.isEmpty else { continue }
            models.append(ModelEndpointModel(id: id))
            if let owner = item["owned_by"] as? String { owners.append(owner) }
        }
        return (models, owners)
    }

    /// Ollama `/api/version`.
    public static func parseOllamaVersion(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? String, !version.isEmpty else { return nil }
        return version
    }

    /// Ollama `/api/tags`.
    public static func parseOllamaTags(_ data: Data) -> [ModelEndpointModel]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["models"] as? [[String: Any]] else { return nil }
        return list.compactMap { item in
            guard let name = (item["name"] as? String) ?? (item["model"] as? String) else { return nil }
            let details = item["details"] as? [String: Any]
            return ModelEndpointModel(
                id: name,
                sizeBytes: uint64(item["size"]),
                parameterSize: details?["parameter_size"] as? String,
                quantization: details?["quantization_level"] as? String
            )
        }
    }

    /// Names of the models Ollama has in memory (`/api/ps`).
    public static func parseOllamaLoaded(_ data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["models"] as? [[String: Any]] else { return [] }
        return list.compactMap { ($0["name"] as? String) ?? ($0["model"] as? String) }
    }

    /// LM Studio `/api/v0/models`: adds loaded state and quantization.
    public static func parseLMStudioModels(_ data: Data) -> [ModelEndpointModel]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["data"] as? [[String: Any]],
              list.contains(where: { $0["state"] != nil || $0["compatibility_type"] != nil }) else { return nil }
        return list.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            if let type = item["type"] as? String, type == "embeddings" { return ModelEndpointModel(id: id, isLoaded: (item["state"] as? String) == "loaded") }
            return ModelEndpointModel(id: id, quantization: item["quantization"] as? String, isLoaded: (item["state"] as? String) == "loaded")
        }
    }

    static func markLoaded(_ models: [ModelEndpointModel], loaded: Set<String>) -> [ModelEndpointModel] {
        models.map { model in
            var copy = model
            copy.isLoaded = loaded.contains(model.id)
            return copy
        }
    }

    /// Marks the model an MLX server was started with (`--model <path or repo>`) as loaded and lists it first.
    public static func markServedModel(_ models: [ModelEndpointModel], command: String) -> [ModelEndpointModel] {
        guard let served = modelArgument(command) else { return models }
        let servedTail = tail(served)
        var result = models.map { model -> ModelEndpointModel in
            var copy = model
            copy.isLoaded = model.id == served || tail(model.id) == servedTail
            return copy
        }
        if !result.contains(where: \.isLoaded) {
            result.insert(ModelEndpointModel(id: served, isLoaded: true), at: 0)
        }
        return result.sorted { $0.isLoaded && !$1.isLoaded }
    }

    /// The value after `--model` in a command line. Paths may contain spaces, so it runs to the next " --".
    public static func modelArgument(_ command: String) -> String? {
        guard let range = command.range(of: "--model ") else { return nil }
        let rest = command[range.upperBound...]
        let end = rest.range(of: " --")?.lowerBound ?? rest.endIndex
        let value = rest[..<end].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private static func tail(_ id: String) -> String {
        id.split(separator: "/").suffix(2).joined(separator: "/")
    }

    // MARK: Building endpoints

    /// Kind from the strongest signal: the process, then the server's own answers.
    public static func classify(processKind: ModelServerKind?, ownedBy: [String], isOllama: Bool) -> ModelServerKind {
        if isOllama { return .ollama }
        if let processKind, processKind != .openAICompatible { return processKind }
        let owners = Set(ownedBy.map { $0.lowercased() })
        if owners.contains("llamacpp") { return .llamaCpp }
        if owners.contains("vllm") { return .vLLM }
        if owners.contains("organization_owner") { return .lmStudio }
        if owners.contains("omlx") { return .oMLX }
        return processKind ?? .openAICompatible
    }

    static func endpoint(kind: ModelServerKind, target: ProbeTarget, status: ModelEndpointStatus, models: [ModelEndpointModel],
                         version: String?, managed: Bool) -> ModelEndpoint {
        let host = target.probeHost
        let base = AIHTTP.url(host: host, port: target.port, path: "/v1") ?? URL(fileURLWithPath: "/")
        let native: URL? = kind == .ollama ? AIHTTP.url(host: host, port: target.port, path: "") : nil
        return ModelEndpoint(
            id: "\(host):\(target.port)",
            kind: kind,
            name: managed ? "\(kind.displayName) (\(AppConfig.appName))" : nil,
            host: host,
            port: target.port,
            baseURL: base,
            nativeURL: native,
            status: status,
            models: models,
            bindAddress: target.bindAddress ?? (status == .running ? "127.0.0.1" : nil),
            version: version,
            isManaged: managed,
            pid: target.pid
        )
    }

    static func installedEndpoint(_ kind: ModelServerKind, port: Int) -> ModelEndpoint {
        ModelEndpoint(
            id: kind.rawValue,
            kind: kind,
            host: "127.0.0.1",
            port: port,
            baseURL: AIHTTP.url(host: "127.0.0.1", port: port, path: "/v1") ?? URL(fileURLWithPath: "/"),
            nativeURL: kind == .ollama ? AIHTTP.url(host: "127.0.0.1", port: port, path: "") : nil,
            status: .installed
        )
    }

    /// Running first, then the managed server, then by kind and port.
    public static func sorted(_ endpoints: [ModelEndpoint]) -> [ModelEndpoint] {
        let order = ModelServerKind.allCases
        func rank(_ status: ModelEndpointStatus) -> Int {
            switch status {
            case .running: return 0
            case .notResponding: return 1
            case .installed: return 2
            }
        }
        return endpoints.sorted { a, b in
            if rank(a.status) != rank(b.status) { return rank(a.status) < rank(b.status) }
            if a.isManaged != b.isManaged { return a.isManaged }
            let ka = order.firstIndex(of: a.kind) ?? 0, kb = order.firstIndex(of: b.kind) ?? 0
            if ka != kb { return ka < kb }
            return a.port < b.port
        }
    }

    static func uint64(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber { return number.uint64Value }
        if let text = value as? String { return UInt64(text) }
        return nil
    }
}
