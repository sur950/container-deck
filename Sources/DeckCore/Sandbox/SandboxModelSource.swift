import Foundation

/// What kind of model server a sandbox talks to. Decides which variables are set.
public enum SandboxModelKind: String, Sendable, Hashable, CaseIterable, Identifiable {
    /// Any OpenAI compatible server (mlx_lm.server, LM Studio, vLLM, OpenAI). Base URL ends in /v1.
    case openAI = "openai"
    /// Ollama. Base URL is the server root, like http://127.0.0.1:11434.
    case ollama

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .openAI: return "OpenAI compatible"
        case .ollama: return "Ollama"
        }
    }
}

/// A model endpoint a sandbox can use. The Local AI area can make its endpoints conform
/// to this, and the create form also has a manual entry (`ManualModelSource`).
public protocol SandboxModelSource: Sendable {
    var title: String { get }
    var kind: SandboxModelKind { get }
    /// Base URL as seen from this Mac.
    var baseURL: URL { get }
    /// API key, read from the Keychain by the source. Never written to disk in plain text.
    var apiKey: String? { get }
    /// Model to use by default, if known.
    var defaultModel: String? { get }
}

/// A model endpoint typed in by hand.
public struct ManualModelSource: SandboxModelSource, Hashable {
    public var title: String
    public var kind: SandboxModelKind
    public var baseURL: URL
    public var apiKey: String?
    public var defaultModel: String?

    public init(title: String = "Manual", kind: SandboxModelKind, baseURL: URL, apiKey: String? = nil, defaultModel: String? = nil) {
        self.title = title
        self.kind = kind
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.defaultModel = defaultModel
    }
}

/// Common local servers, offered as quick picks in the form.
public struct SandboxModelPreset: Sendable, Hashable, Identifiable {
    public var id: String { title }
    public var title: String
    public var kind: SandboxModelKind
    public var url: String

    public static let local: [SandboxModelPreset] = [
        SandboxModelPreset(title: "Ollama", kind: .ollama, url: "http://127.0.0.1:11434"),
        SandboxModelPreset(title: "LM Studio", kind: .openAI, url: "http://127.0.0.1:1234/v1"),
        SandboxModelPreset(title: "MLX server", kind: .openAI, url: "http://127.0.0.1:8080/v1"),
    ]
}

/// One server choice in the sandbox form: a preset, a server found running, or both merged.
public struct SandboxServerChoice: Sendable, Identifiable {
    public var id: String { url }
    public var title: String
    public var kind: SandboxModelKind
    public var url: String
    /// The running server behind this choice, when one was found.
    public var source: (any SandboxModelSource)?
    public var isRunning: Bool { source != nil }

    /// Presets first, in their order. A running server on the same local port as a preset
    /// replaces that preset (so Ollama shows once, marked running). Other servers follow.
    public static func merge(presets: [SandboxModelPreset] = SandboxModelPreset.local,
                             sources: [any SandboxModelSource]) -> [SandboxServerChoice] {
        var remaining = sources
        var choices: [SandboxServerChoice] = presets.map { preset in
            if let index = remaining.firstIndex(where: { sameServer($0.baseURL.absoluteString, preset.url) }) {
                let source = remaining.remove(at: index)
                return SandboxServerChoice(title: preset.title, kind: source.kind,
                                           url: source.baseURL.absoluteString, source: source)
            }
            return SandboxServerChoice(title: preset.title, kind: preset.kind, url: preset.url, source: nil)
        }
        for source in remaining where !choices.contains(where: { sameServer($0.url, source.baseURL.absoluteString) }) {
            choices.append(SandboxServerChoice(title: source.title, kind: source.kind,
                                               url: source.baseURL.absoluteString, source: source))
        }
        return choices
    }

    /// Same server when the port matches and both hosts are this Mac (127.0.0.1, localhost, ::1),
    /// or when host and port both match. The path (/v1) does not matter.
    public static func sameServer(_ a: String, _ b: String) -> Bool {
        guard let ua = URLComponents(string: a), let ub = URLComponents(string: b),
              let ha = ua.host?.lowercased(), let hb = ub.host?.lowercased() else { return false }
        let portA = ua.port ?? (ua.scheme == "https" ? 443 : 80)
        let portB = ub.port ?? (ub.scheme == "https" ? 443 : 80)
        guard portA == portB else { return false }
        let local: Set<String> = ["127.0.0.1", "localhost", "::1", "[::1]"]
        return ha == hb || (local.contains(ha) && local.contains(hb))
    }

    /// True when this choice is the one the form currently points at.
    public func matches(url current: String) -> Bool { Self.sameServer(url, current) }
}

/// The model settings a sandbox keeps in its labels (no key).
public struct SandboxModel: Sendable, Hashable {
    public var kind: SandboxModelKind
    /// Base URL as seen from this Mac.
    public var url: URL
    public var name: String?
    public var hasKey: Bool

    public init(kind: SandboxModelKind, url: URL, name: String? = nil, hasKey: Bool = false) {
        self.kind = kind
        self.url = url
        self.name = name
        self.hasKey = hasKey
    }

    public init(source: any SandboxModelSource, name: String? = nil) {
        self.init(kind: source.kind, url: source.baseURL, name: name ?? source.defaultModel,
                  hasKey: !(source.apiKey ?? "").isEmpty)
    }
}

/// How a sandbox reaches its model.
public enum SandboxModelRoute: Sendable, Hashable {
    /// Plain HTTP to a server on this Mac or the local network: the app relays
    /// `gateway:relayPort` to `host:port`. Works on every network mode.
    case relay(host: String, port: Int)
    /// HTTPS to an outside host on an allow list network: through the proxy (host added to the list).
    case proxy(host: String)
    /// Straight out (Internet network).
    case direct
    /// An Isolated sandbox cannot reach an outside HTTPS host.
    case unreachable(String)

    /// Picks the route for a model URL on a network mode.
    public static func route(for url: URL, egress: SandboxEgress) -> SandboxModelRoute {
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            return .unreachable("The model address has no host.")
        }
        let scheme = (url.scheme ?? "http").lowercased()
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        if isLoopback(host) {
            guard scheme == "http" else { return .unreachable("Use http for a model on this Mac.") }
            return .relay(host: host == "localhost" ? "127.0.0.1" : host, port: port)
        }
        if scheme == "http" && (egress != .open || isPrivate(host)) {
            return .relay(host: host, port: port)
        }
        switch egress {
        case .open: return .direct
        case .allowList: return .proxy(host: host)
        case .isolated: return .unreachable("An Isolated sandbox can only reach models on this Mac or your local network over http.")
        }
    }

    /// The model base URL as written into the container.
    public func containerURL(for url: URL, gateway: String, relayPort: UInt16 = SandboxConfig.relayPort) -> URL {
        guard case .relay = self, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.scheme = "http"
        parts.host = gateway
        parts.port = Int(relayPort)
        return parts.url ?? url
    }

    public var isReachable: Bool {
        if case .unreachable = self { return false }
        return true
    }

    static func isLoopback(_ host: String) -> Bool {
        ["127.0.0.1", "localhost", "::1", "[::1]", "0.0.0.0"].contains(host) || host.hasPrefix("127.")
    }

    /// RFC 1918 addresses and .local names.
    static func isPrivate(_ host: String) -> Bool {
        if host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (192, 168): return true
        case (172, 16...31): return true
        default: return false
        }
    }
}
