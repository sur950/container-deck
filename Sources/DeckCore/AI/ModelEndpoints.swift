import Foundation

// PUBLIC API for other areas (Sandboxes, Agents). Stable shape: fields and
// method names below are only ever added to, never renamed or removed.
//
//     let endpoints = await ModelEndpoints.current()            // cached for a few seconds
//     for endpoint in endpoints where endpoint.isRunning {
//         endpoint.baseURL                                      // http://127.0.0.1:11434/v1
//         endpoint.models.map(\.id)                             // ["qwen3:0.6b", ...]
//         endpoint.containerEnvironment(gateway: "192.168.64.1") // OPENAI_BASE_URL and friends
//     }
//
// Discovery reads which processes listen on TCP ports (lsof, no root), probes the
// well known model server ports and the ports of known model server processes with
// `/v1/models`, `/api/tags` and `/api/version`, and reports installed servers that
// are not running (Ollama, LM Studio) with `status == .installed`.

/// Which kind of server an endpoint is.
public enum ModelServerKind: String, Codable, Sendable, CaseIterable, Hashable {
    case ollama
    case lmStudio
    case mlxLM
    case oMLX
    case llamaCpp
    case vLLM
    case openAICompatible

    /// Name for people.
    public var displayName: String {
        switch self {
        case .ollama: return "Ollama"
        case .lmStudio: return "LM Studio"
        case .mlxLM: return "MLX LM"
        case .oMLX: return "oMLX"
        case .llamaCpp: return "llama.cpp"
        case .vLLM: return "vLLM"
        case .openAICompatible: return "OpenAI compatible"
        }
    }

    /// API key value clients should send. Local servers ignore it, but many SDKs need one set.
    public var placeholderAPIKey: String {
        switch self {
        case .ollama: return "ollama"
        case .lmStudio: return "lm-studio"
        default: return "local"
        }
    }
}

/// Whether an endpoint answers right now.
public enum ModelEndpointStatus: String, Codable, Sendable, Hashable {
    /// Answers on its port.
    case running
    /// Installed on this Mac but not running. `baseURL` is where it will listen.
    case installed
    /// A port is open and the process looks like a model server, but it did not answer the probe.
    case notResponding
}

/// One model an endpoint serves.
public struct ModelEndpointModel: Codable, Sendable, Hashable, Identifiable {
    /// The id to send as `model` in OpenAI requests.
    public var id: String
    /// Size on disk in bytes, when the server reports it (Ollama).
    public var sizeBytes: UInt64?
    /// "7.2B", when known.
    public var parameterSize: String?
    /// "Q4_K_M", "4bit", when known.
    public var quantization: String?
    /// True when the model is in memory now (Ollama `/api/ps`, LM Studio, the model an MLX server was started with).
    public var isLoaded: Bool

    public init(id: String, sizeBytes: UInt64? = nil, parameterSize: String? = nil, quantization: String? = nil, isLoaded: Bool = false) {
        self.id = id
        self.sizeBytes = sizeBytes
        self.parameterSize = parameterSize
        self.quantization = quantization
        self.isLoaded = isLoaded
    }

    /// Short name: "SmolLM-135M" for "/path/to/mlx-community/SmolLM-135M" or "mlx-community/SmolLM-135M".
    public var displayName: String { ModelDisplayName.short(id) }
}

/// One local model server.
public struct ModelEndpoint: Codable, Sendable, Hashable, Identifiable {
    /// "127.0.0.1:11434" or "ollama" for an installed server that is not running.
    public var id: String
    public var kind: ModelServerKind
    /// "Ollama", "LM Studio", "MLX LM".
    public var name: String
    /// Host to reach it from this Mac. Always a loopback or local address.
    public var host: String
    public var port: Int
    /// OpenAI compatible base URL, ends in "/v1". Clients append "/chat/completions".
    public var baseURL: URL
    /// Server's own API root when it has one (Ollama: "http://127.0.0.1:11434").
    public var nativeURL: URL?
    public var status: ModelEndpointStatus
    public var models: [ModelEndpointModel]
    /// Address the server listens on: "127.0.0.1", "*" (all addresses) or a specific one like "192.168.64.1".
    public var bindAddress: String?
    /// Server version when it reports one.
    public var version: String?
    /// True when Container Deck started it (the MLX server on the AI Models screen).
    public var isManaged: Bool
    /// Process id of the listening process, when known.
    public var pid: Int32?

    public init(id: String, kind: ModelServerKind, name: String? = nil, host: String, port: Int, baseURL: URL, nativeURL: URL? = nil,
                status: ModelEndpointStatus, models: [ModelEndpointModel] = [], bindAddress: String? = nil, version: String? = nil,
                isManaged: Bool = false, pid: Int32? = nil) {
        self.id = id
        self.kind = kind
        self.name = name ?? kind.displayName
        self.host = host
        self.port = port
        self.baseURL = baseURL
        self.nativeURL = nativeURL
        self.status = status
        self.models = models
        self.bindAddress = bindAddress
        self.version = version
        self.isManaged = isManaged
        self.pid = pid
    }

    public var isRunning: Bool { status == .running }

    /// True when containers can reach it through their network gateway:
    /// it listens on all addresses or on a non loopback address.
    public var reachableFromContainers: Bool {
        guard let bindAddress else { return false }
        return !ModelEndpoint.isLoopback(bindAddress)
    }

    /// Base URL a container should use, given its network's gateway ("192.168.64.1").
    /// nil when the server only listens on loopback, so containers cannot reach it.
    /// A server bound to one address is reached on that address.
    public func containerBaseURL(gateway: String) -> URL? {
        guard reachableFromContainers, let bindAddress else { return nil }
        let host = (bindAddress == "*" || bindAddress == "0.0.0.0" || bindAddress == "::") ? gateway : bindAddress
        return URL(string: "http://\(host):\(port)/v1")
    }

    /// Environment for a container that should use this endpoint:
    /// `OPENAI_BASE_URL`, `OPENAI_API_BASE`, `OPENAI_API_KEY`, and `OLLAMA_HOST` for Ollama.
    /// Empty when the server is not reachable from containers.
    public func containerEnvironment(gateway: String) -> [String: String] {
        guard let url = containerBaseURL(gateway: gateway) else { return [:] }
        var env = [
            "OPENAI_BASE_URL": url.absoluteString,
            "OPENAI_API_BASE": url.absoluteString,
            "OPENAI_API_KEY": kind.placeholderAPIKey
        ]
        if kind == .ollama, let host = url.host {
            env["OLLAMA_HOST"] = "http://\(host):\(port)"
        }
        return env
    }

    /// Same as `containerEnvironment`, for use on this Mac (loopback base URL).
    public var hostEnvironment: [String: String] {
        var env = [
            "OPENAI_BASE_URL": baseURL.absoluteString,
            "OPENAI_API_BASE": baseURL.absoluteString,
            "OPENAI_API_KEY": kind.placeholderAPIKey
        ]
        if kind == .ollama {
            env["OLLAMA_HOST"] = "http://\(host):\(port)"
        }
        return env
    }

    static func isLoopback(_ address: String) -> Bool {
        address == "127.0.0.1" || address == "::1" || address == "localhost" || address.hasPrefix("127.")
    }
}

/// Entry point for discovery. Safe to call from any task. Every caller (AI Models tabs, chat,
/// Dashboard tile, sandboxes, agents) goes through one shared probe, so each server gets one
/// `GET /v1/models` per round however many views ask at the same moment.
public enum ModelEndpoints {
    /// Finds every local model server now (after a start or stop). Joins a probe that started
    /// at the same moment, never one from before the call.
    public static func discover() async -> [ModelEndpoint] {
        await probes.endpoints(maxAge: 0)
    }

    /// The last discovery when it is at most `maxAge` seconds old, else a new one.
    public static func current(maxAge: TimeInterval = AIConfig.cacheLifetime) async -> [ModelEndpoint] {
        await probes.endpoints(maxAge: maxAge)
    }

    /// Only the servers that answer right now.
    public static func running() async -> [ModelEndpoint] {
        await current().filter(\.isRunning)
    }

    private static let probes = EndpointProbeCenter { await ModelDiscovery().discover() }
}

/// One shared, cached discovery. Callers asking while a probe runs wait for that probe
/// instead of starting their own.
public actor EndpointProbeCenter {
    private let probe: @Sendable () async -> [ModelEndpoint]
    private var value: [ModelEndpoint]?
    private var date = Date.distantPast
    private var inFlight: (task: Task<[ModelEndpoint], Never>, started: Date)?
    /// Probes started. For tests.
    public private(set) var probeCount = 0

    public init(probe: @escaping @Sendable () async -> [ModelEndpoint]) {
        self.probe = probe
    }

    /// A result at most `maxAge` seconds old. With `maxAge` 0 only a probe that starts now (or
    /// started within the last moment) is used.
    public func endpoints(maxAge: TimeInterval) async -> [ModelEndpoint] {
        let now = Date()
        if let value, now.timeIntervalSince(date) <= maxAge { return value }
        if let inFlight, now.timeIntervalSince(inFlight.started) <= max(maxAge, 0.05) {
            return await inFlight.task.value
        }
        let probe = self.probe
        let task = Task { await probe() }
        inFlight = (task, now)
        probeCount += 1
        let result = await task.value
        if inFlight?.started == now { inFlight = nil }
        if now >= date {
            value = result
            date = now
        }
        return result
    }
}
